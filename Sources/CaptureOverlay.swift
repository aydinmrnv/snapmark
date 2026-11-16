import Cocoa
import ScreenCaptureKit
import ApplicationServices

// Snagit-style capture: freeze the screen, highlight windows / UI elements under the
// mouse, click to take one or drag a region, then adjust with handles before capturing.

struct WinInfo { let frame: CGRect; let pid: pid_t; let owner: String; let title: String }
struct CursorSnap { let image: NSImage; let hotSpot: NSPoint; let location: CGPoint }

enum CaptureKind { case smart, window, fullscreen }

/// Global coordinates used throughout: CoreGraphics space (origin top-left of primary display, y down).
enum Geo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }
    static func cgRect(_ s: NSScreen) -> CGRect {
        let f = s.frame
        return CGRect(x: f.minX, y: primaryHeight - f.maxY, width: f.width, height: f.height)
    }
    static func mouse() -> CGPoint {
        let m = NSEvent.mouseLocation
        return CGPoint(x: m.x, y: primaryHeight - m.y)
    }
    static func displayID(_ s: NSScreen) -> CGDirectDisplayID {
        (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
    static func screen(at p: CGPoint) -> NSScreen? {
        NSScreen.screens.first { cgRect($0).contains(p) } ?? NSScreen.main
    }
}

let accent = NSColor(red: 1.0, green: 0.47, blue: 0.12, alpha: 1)

final class CaptureSession {
    static var current: CaptureSession?

    let kind: CaptureKind
    var windows: [WinInfo] = []
    var shots: [CGDirectDisplayID: CGImage] = [:]
    var overlays: [OverlayWindow] = []
    var views: [OverlayView] = []
    var cursor: CursorSnap?
    var previousApp: NSRunningApplication?
    let axEnabled = AXIsProcessTrusted()

    enum Phase { case hover, pressed(CGPoint), dragging(CGPoint), adjusting }
    var phase: Phase = .hover
    var mouse: CGPoint = .zero
    var hoverStack: [CGRect] = []
    var hoverLevel = 0
    var hoverLabel = ""
    var selection: CGRect = .zero
    var selectionScreen: NSScreen?
    private var activeHandle: Int?
    private var moveOffset: CGPoint?
    private var scrollAccum: CGFloat = 0
    private var hoverPending = false
    private let axQueue = DispatchQueue(label: "snapmark.ax", qos: .userInteractive)
    private var axBusy = false
    private var axPending: (CGPoint, pid_t, CGRect)?

    var hoverRect: CGRect? { hoverStack.indices.contains(hoverLevel) ? hoverStack[hoverLevel] : nil }

    init(kind: CaptureKind) { self.kind = kind }

    // MARK: Start

    static func start(_ kind: CaptureKind, delay: Double) {
        guard current == nil else { return }
        let s = CaptureSession(kind: kind)
        current = s
        if let front = NSWorkspace.shared.frontmostApplication, front != NSRunningApplication.current {
            s.previousApp = front
        }
        // Grab the cursor *before* anything changes on screen.
        s.snapshotCursor()
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if delay > 0.5 { s.snapshotCursor() }
            Task { @MainActor in await s.freezeAndShow() }
        }
    }

    private func snapshotCursor() {
        let c = NSCursor.currentSystem ?? NSCursor.arrow
        cursor = CursorSnap(image: c.image, hotSpot: c.hotSpot, location: Geo.mouse())
    }

    @MainActor
    private func freezeAndShow() async {
        let screens = NSScreen.screens
        func target(_ s: NSScreen) -> ScreenGrab.Target {
            ScreenGrab.Target(id: Geo.displayID(s), pixels: CGSize(width: s.frame.width * s.backingScaleFactor, height: s.frame.height * s.backingScaleFactor))
        }
        // The screen under the cursor is grabbed first and shown as soon as it's ready; the others follow.
        let main = Geo.screen(at: cursor?.location ?? Geo.mouse()) ?? screens[0]
        let mainT = target(main)
        let first = Task.detached(priority: .userInitiated) { try await ScreenGrab.grab(mainT) }
        let winList = Task.detached(priority: .userInitiated) { CaptureSession.loadWindows() }

        if kind == .fullscreen {
            guard let img = try? await first.value else { failed(); return }
            shots[mainT.id] = img
            selection = Geo.cgRect(main); selectionScreen = main
            finish(.edit)
            return
        }

        for screen in screens {
            let v = OverlayView(session: self, screen: screen)
            let w = OverlayWindow.reuse(screen: screen)
            w.install(v)
            overlays.append(w); views.append(v)
        }
        guard let img = try? await first.value else { failed(); return }
        guard !ended else { return }
        shots[mainT.id] = img
        windows = await winList.value
        show(on: main)
        NSApp.activate(ignoringOtherApps: true)
        mouse = Geo.mouse()
        if let w = overlays.first(where: { ($0.contentView?.subviews.last as? OverlayView)?.screen == main }) {
            w.makeKeyAndOrderFront(nil)
            if let kv = w.contentView?.subviews.last { w.makeFirstResponder(kv) }
        }
        NSCursor.crosshair.set()
        updateHover()
        overlays.forEach { $0.displayIfNeeded() }
        CATransaction.flush()
        let ms = Perf.end("hotkey → overlay visible", log: !Bench.active)
        if Bench.active { Bench.record("hotkey → overlay visible", ms) }

        for screen in screens where screen != main {
            let t = target(screen)
            Task.detached(priority: .userInitiated) {
                let img = try? await ScreenGrab.grab(t)
                await MainActor.run { [weak self] in
                    guard let self, !self.ended, let img else { return }
                    self.shots[t.id] = img
                    self.show(on: screen)
                    self.redraw()
                }
            }
        }
        if Bench.active { DispatchQueue.main.async { Bench.onOverlay?() } }
    }

    private func show(on screen: NSScreen) {
        guard let i = views.firstIndex(where: { $0.screen == screen }) else { return }
        views[i].shot = shots[Geo.displayID(screen)]
        overlays[i].showShot(views[i].shot)
        overlays[i].orderFrontRegardless()
    }

    private func failed() {
        end()
        PermissionsController.shared.show(.screen)
    }

    static func loadWindows() -> [WinInfo] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let screens = NSScreen.screens.map(Geo.cgRect)
        var out: [WinInfo] = []
        for w in list {
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            guard alpha > 0.01, layer < 1000, owner != "Window Server",
                  let bd = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: bd as! CFDictionary),
                  r.width >= 24, r.height >= 24 else { continue }
            // Skip transparent full-screen helper windows (Dock, wallpaper, etc.) that aren't real windows.
            if layer != 0, screens.contains(where: { abs($0.width - r.width) < 2 && abs($0.height - r.height) < 2 }) { continue }
            out.append(WinInfo(frame: r, pid: w[kCGWindowOwnerPID as String] as? pid_t ?? 0, owner: owner,
                               title: w[kCGWindowName as String] as? String ?? ""))
        }
        return out
    }

    // MARK: Hover detection

    func scheduleHover() {
        guard !hoverPending else { return }
        hoverPending = true
        DispatchQueue.main.async { [weak self] in self?.hoverPending = false; self?.updateHover() }
    }

    func updateHover() {
        guard case .hover = phase else { redraw(); return }
        let p = mouse
        var stack: [CGRect] = []
        var label = ""
        let scr = Geo.screen(at: p).map(Geo.cgRect)
        var hitWindow: WinInfo?
        if let w = windows.first(where: { $0.frame.contains(p) }) {
            label = w.owner
            hitWindow = w
            // Keep the element-level levels we already have if we're still inside the same window.
            if kind == .smart, axEnabled, let cur = hoverStack.first, w.frame.contains(cur), cur.contains(p), hoverStack.count > 1 {
                stack = Array(hoverStack.prefix { !$0.equalTo(w.frame) && w.frame.contains($0) })
            }
            if stack.last.map({ !$0.equalTo(w.frame) }) ?? true { stack.append(w.frame) }
        }
        if kind == .smart, axEnabled, let w = hitWindow { requestAX(p, w) }
        if kind == .smart, let s = scr, stack.last.map({ !$0.equalTo(s) }) ?? true {
            stack.append(s)
            if label.isEmpty { label = "Full Screen" }
        }
        if let s = scr { stack = stack.map { $0.intersection(s) }.filter { !$0.isNull && $0.width > 4 && $0.height > 4 } }
        if stack != hoverStack {
            hoverStack = stack
            hoverLevel = stack.firstIndex(where: { $0.width >= 70 && $0.height >= 32 }) ?? 0
        }
        hoverLabel = label
        redraw()
    }

    /// Element lookup is IPC to the other app, so it runs off the main thread; only the newest request is kept.
    private func requestAX(_ p: CGPoint, _ w: WinInfo) {
        axPending = (p, w.pid, w.frame)
        guard !axBusy else { return }
        runNextAX()
    }

    private func runNextAX() {
        guard let (p, pid, frame) = axPending else { axBusy = false; return }
        axPending = nil
        axBusy = true
        axQueue.async { [weak self] in
            let ax = CaptureSession.axStack(pid: pid, at: p, window: frame)
            DispatchQueue.main.async {
                guard let self else { return }
                self.applyAX(ax, at: p, window: frame)
                self.runNextAX()
            }
        }
    }

    private func applyAX(_ ax: [CGRect], at p: CGPoint, window: CGRect) {
        guard case .hover = phase, window.contains(mouse) else { return }
        var stack = ax.filter { !$0.equalTo(window) }
        stack.append(window)
        let scr = Geo.screen(at: mouse).map(Geo.cgRect)
        if let s = scr, !window.equalTo(s) { stack.append(s) }
        if let s = scr { stack = stack.map { $0.intersection(s) }.filter { !$0.isNull && $0.width > 4 && $0.height > 4 } }
        // Only keep element rects that still contain the mouse.
        stack = stack.filter { $0.insetBy(dx: -1, dy: -1).contains(mouse) }
        if stack != hoverStack {
            hoverStack = stack
            hoverLevel = stack.firstIndex(where: { $0.width >= 70 && $0.height >= 32 }) ?? 0
            redraw()
        }
    }

    /// Accessibility hierarchy under the point, smallest first, clipped to the window.
    static func axStack(pid: pid_t, at p: CGPoint, window: CGRect) -> [CGRect] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.08)
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(p.x), Float(p.y), &hit) == .success, var cur = hit else { return [] }
        var out: [CGRect] = []
        for _ in 0..<14 {
            var roleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(cur, kAXRoleAttribute as CFString, &roleRef)
            let role = roleRef as? String ?? ""
            if role == kAXApplicationRole as String { break }
            if let f = axFrame(cur) {
                let c = f.intersection(window)
                if !c.isNull, c.width >= 14, c.height >= 14, c.insetBy(dx: -1, dy: -1).contains(p) {
                    if let last = out.last {
                        if c.width * c.height > last.width * last.height + 4 { out.append(c) }
                    } else { out.append(c) }
                }
            }
            if role == kAXWindowRole as String { break }
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(cur, kAXParentAttribute as CFString, &parent) == .success,
                  let par = parent, CFGetTypeID(par) == AXUIElementGetTypeID() else { break }
            cur = par as! AXUIElement
        }
        return out
    }

    static func axFrame(_ el: AXUIElement) -> CGRect? {
        var pRef: CFTypeRef?, sRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sRef) == .success,
              let pv = pRef, let sv = sRef else { return nil }
        var pt = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &pt)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        return CGRect(origin: pt, size: sz)
    }

    // MARK: Events (global coords)

    func mouseMoved(_ p: CGPoint) {
        mouse = p
        if case .hover = phase { scheduleHover() } else { redraw() }
    }

    func mouseDown(_ p: CGPoint, clickCount: Int) {
        mouse = p
        if case .adjusting = phase {
            if let h = handle(at: p) { activeHandle = h; return }
            if selection.contains(p) {
                if clickCount >= 2 { finish(.edit); return }
                moveOffset = CGPoint(x: p.x - selection.minX, y: p.y - selection.minY)
                return
            }
            hideToolbar()
        }
        phase = .pressed(p)
        redraw()
    }

    func mouseDragged(_ p: CGPoint) {
        mouse = p
        switch phase {
        case .pressed(let s):
            if kind == .smart, hypot(p.x - s.x, p.y - s.y) > 4 {
                selectionScreen = Geo.screen(at: s)
                phase = .dragging(s)
                selection = clip(rect(s, p))
            }
        case .dragging(let s):
            selection = clip(rect(s, p))
        case .adjusting:
            if let h = activeHandle { resize(handle: h, to: p) }
            else if let o = moveOffset {
                var r = selection
                r.origin = CGPoint(x: p.x - o.x, y: p.y - o.y)
                if let sf = selectionScreen.map(Geo.cgRect) {
                    r.origin.x = min(max(r.minX, sf.minX), sf.maxX - r.width)
                    r.origin.y = min(max(r.minY, sf.minY), sf.maxY - r.height)
                }
                selection = r
                positionToolbar()
            }
        case .hover: break
        }
        redraw()
    }

    func mouseUp(_ p: CGPoint) {
        mouse = p
        switch phase {
        case .pressed:
            if let r = hoverRect {
                selectionScreen = Geo.screen(at: p)
                selection = clip(r)
                if kind == .window { finish(.edit) } else { enterAdjust() }
            } else { phase = .hover }
        case .dragging:
            if selection.width >= 4 && selection.height >= 4 { enterAdjust() } else { phase = .hover; updateHover() }
        case .adjusting:
            activeHandle = nil; moveOffset = nil
            selection = selection.standardized
            positionToolbar()
        case .hover: break
        }
        redraw()
    }

    func scroll(_ e: NSEvent) {
        guard case .hover = phase, hoverStack.count > 1 else { return }
        scrollAccum += e.scrollingDeltaY
        let threshold: CGFloat = e.hasPreciseScrollingDeltas ? 18 : 1
        if scrollAccum >= threshold { hoverLevel = min(hoverLevel + 1, hoverStack.count - 1); scrollAccum = 0 }
        else if scrollAccum <= -threshold { hoverLevel = max(hoverLevel - 1, 0); scrollAccum = 0 }
        redraw()
    }

    func keyDown(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        switch e.keyCode {
        case 53: // esc
            if case .adjusting = phase { reselect() } else { cancel() }
        case 36, 76: // return
            if case .adjusting = phase { finish(.edit) }
            else if case .hover = phase, let r = hoverRect { selectionScreen = Geo.screen(at: mouse); selection = clip(r); finish(.edit) }
        case 123, 124, 125, 126:
            guard case .adjusting = phase else { return false }
            let d: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
            let v: (CGFloat, CGFloat) = [123: (-d, 0), 124: (d, 0), 125: (0, d), 126: (0, -d)][e.keyCode]!
            if e.modifierFlags.contains(.option) { selection.size.width = max(4, selection.width + v.0); selection.size.height = max(4, selection.height + v.1) }
            else { selection = selection.offsetBy(dx: v.0, dy: v.1) }
            selection = clip(selection)
            positionToolbar(); redraw()
        case 8 where cmd: // ⌘C
            if case .adjusting = phase { finish(.copy) }
        case 17 where !cmd: // T: grab text
            if case .adjusting = phase { finish(.text) } else { return false }
        case 1 where !cmd: // S: scrolling capture
            if case .adjusting = phase { finish(.scroll) } else { return false }
        case 35 where !cmd: // P: pin
            if case .adjusting = phase { finish(.pin) } else { return false }
        default:
            return false
        }
        return true
    }

    // MARK: Geometry helpers

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    private func clip(_ r: CGRect) -> CGRect {
        guard let s = selectionScreen.map(Geo.cgRect) else { return r }
        let c = r.standardized.intersection(s)
        return c.isNull ? .zero : c
    }

    /// 0..7: tl, t, tr, r, br, b, bl, l
    func handlePoints(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.midX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.midY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.midX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.minX, y: r.midY)]
    }

    private func handle(at p: CGPoint) -> Int? {
        handlePoints(selection).firstIndex { hypot($0.x - p.x, $0.y - p.y) <= 8 }
    }

    private func resize(handle h: Int, to p: CGPoint) {
        var minX = selection.minX, minY = selection.minY, maxX = selection.maxX, maxY = selection.maxY
        if [0, 6, 7].contains(h) { minX = p.x }
        if [2, 3, 4].contains(h) { maxX = p.x }
        if [0, 1, 2].contains(h) { minY = p.y }
        if [4, 5, 6].contains(h) { maxY = p.y }
        // Allow dragging past the opposite edge by swapping which handle is active.
        if minX > maxX { swap(&minX, &maxX); activeHandle = [0: 2, 2: 0, 3: 7, 7: 3, 4: 6, 6: 4][h] ?? h }
        if minY > maxY { swap(&minY, &maxY); activeHandle = [0: 6, 6: 0, 1: 5, 5: 1, 2: 4, 4: 2][activeHandle ?? h] ?? activeHandle }
        selection = clip(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        positionToolbar()
    }

    // MARK: Adjust toolbar

    private func enterAdjust() {
        phase = .adjusting
        NSCursor.arrow.set()
        views.forEach { $0.toolbar?.isHidden = true }
        if let v = views.first(where: { $0.screen == selectionScreen }) {
            v.showToolbar()
            v.window?.makeKeyAndOrderFront(nil)
            v.window?.makeFirstResponder(v)
        }
        positionToolbar()
        redraw()
    }

    private func hideToolbar() { views.forEach { $0.toolbar?.isHidden = true } }
    private func positionToolbar() { views.first(where: { $0.screen == selectionScreen })?.positionToolbar() }

    func redraw() { views.forEach { $0.updateLayers() } }

    // MARK: Finish

    enum Action { case edit, copy, text, pin, scroll }

    func finish(_ action: Action) {
        guard let screen = selectionScreen ?? Geo.screen(at: selection.origin),
              let shot = shots[Geo.displayID(screen)] else { cancel(); return }
        let sf = Geo.cgRect(screen)
        let scale = CGFloat(shot.width) / sf.width
        let local = selection.offsetBy(dx: -sf.minX, dy: -sf.minY)
        let px = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        guard px.width >= 2, px.height >= 2, let crop = shot.cropping(to: px) else { cancel(); return }
        // Copy the pixels out so the full-screen grabs can be freed right away (and drawing never touches them).
        let img: CGImage = {
            guard let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: crop.colorSpace ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return crop }
            ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            return ctx.makeImage() ?? crop
        }()
        let origin = CGPoint(x: px.minX / scale + sf.minX, y: px.minY / scale + sf.minY)
        let captured = CGRect(origin: origin, size: CGSize(width: px.width / scale, height: px.height / scale))

        if action == .scroll {
            end()
            MainActor.assumeIsolated { ScrollCapture.start(rect: captured, screen: screen, scale: scale, first: img) }
            return
        }

        var extras: [Annotation] = []
        if let c = cursor, captured.contains(c.location) {
            let o = CGPoint(x: c.location.x - origin.x - c.hotSpot.x, y: c.location.y - origin.y - c.hotSpot.y)
            var a = Annotation(tool: .cursor, a: o, b: CGPoint(x: o.x + c.image.size.width, y: o.y + c.image.size.height),
                               color: .black, width: 1)
            a.image = c.image
            extras.append(a)
        }

        let prev = previousApp
        end()
        ScreenGrab.playShutter()

        // Grab Text doesn't need a file.
        if action == .text {
            Toast.show("Reading text…", symbol: "text.viewfinder")
            TextGrabber.recognize(img) { text in
                if text.isEmpty { Toast.show("No text found", symbol: "exclamationmark.circle"); return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                let n = text.split(separator: "\n").count
                Toast.show("Copied \(n) line\(n == 1 ? "" : "s") of text")
            }
            prev?.activate()
            return
        }

        // Save to the library in the background; the editor works from the in-memory image right away.
        let url = Bench.active ? FileManager.default.temporaryDirectory.appendingPathComponent("bench.png") : Library.shared.newURL()
        if !Bench.active { Perf.start("capture → editor visible") }
        DispatchQueue.global(qos: .utility).async {
            Renderer.write(img, to: url, type: .png, scale: scale)
            DispatchQueue.main.async { Library.shared.reload() }
        }

        switch action {
        case .edit:
            AppDelegate.shared.openEditor(url, extras: extras, preloaded: ImageDoc(base: img, scale: scale))
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects([NSImage(cgImage: img, size: captured.size)])
            Toast.show("Copied to clipboard")
            prev?.activate()
        case .pin:
            let topLeft = NSPoint(x: captured.minX, y: Geo.primaryHeight - captured.minY)
            PinWindow.show(NSImage(cgImage: img, size: captured.size), near: topLeft)
            prev?.activate()
        case .text, .scroll:
            break
        }
    }

    /// Debug: render the capture screen over a given image, with a selection and the toolbar, to a PNG.
    static func snapshot(input: URL, output: URL) {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let screen = NSScreen.main else { return }
        let s = CaptureSession(kind: .smart)
        let v = OverlayView(session: s, screen: screen)
        let w = OverlayWindow(screen: screen)
        w.install(v)
        s.views = [v]; s.overlays = [w]
        let sf = Geo.cgRect(screen)
        let scaled: CGImage? = {
            let W = Int(sf.width * screen.backingScaleFactor), H = Int(sf.height * screen.backingScaleFactor)
            guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H)); return ctx.makeImage()
        }()
        v.shot = scaled; w.showShot(scaled)
        // Hover state with the loupe, then the adjusting state with the toolbar.
        s.mouse = CGPoint(x: sf.minX + sf.width * 0.3, y: sf.minY + sf.height * 0.3)
        s.hoverStack = [CGRect(x: sf.minX + sf.width * 0.2, y: sf.minY + sf.height * 0.2, width: sf.width * 0.3, height: sf.height * 0.25)]
        s.hoverLabel = "Safari"
        v.updateLayers()
        func dump(_ out: URL) {
            guard let root = w.contentView, let layer = root.layer else { return }
            root.layoutSubtreeIfNeeded()
            let W = Int(root.bounds.width * screen.backingScaleFactor), H = Int(root.bounds.height * screen.backingScaleFactor)
            guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
            ctx.scaleBy(x: screen.backingScaleFactor, y: screen.backingScaleFactor)
            layer.render(in: ctx)
            if let cg = ctx.makeImage(), let d = CGImageDestinationCreateWithURL(out as CFURL, "public.png" as CFString, 1, nil) {
                CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d)
            }
        }
        w.orderBack(nil); w.alphaValue = 0.01
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            dump(output.deletingPathExtension().appendingPathExtension("hover.png"))
            s.selectionScreen = screen
            s.selection = CGRect(x: sf.minX + sf.width * 0.25, y: sf.minY + sf.height * 0.22, width: sf.width * 0.4, height: sf.height * 0.4)
            s.phase = .adjusting
            v.showToolbar()
            v.updateLayers()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { dump(output); exit(0) }
        }
    }

    /// Typed into the toolbar's W × H fields (points shown as pixels).
    func applySize(width: CGFloat, height: CGFloat) {
        guard case .adjusting = phase else { return }
        selection.size = CGSize(width: max(4, width), height: max(4, height))
        if let sf = selectionScreen.map(Geo.cgRect) {
            selection.origin.x = min(selection.minX, sf.maxX - selection.width)
            selection.origin.y = min(selection.minY, sf.maxY - selection.height)
        }
        selection = clip(selection)
        positionToolbar(); redraw()
    }

    func reselect() {
        phase = .hover
        hideToolbar()
        updateHover()
    }

    func cancel() {
        let prev = previousApp
        end()
        if AppDelegate.shared.editorHiddenForCapture { AppDelegate.shared.captureCancelled() } else { prev?.activate() }
    }

    private(set) var ended = false
    private func end() {
        ended = true
        overlays.forEach { $0.alphaValue = 0; $0.ignoresMouseEvents = true }
        let old = overlays
        DispatchQueue.main.async { old.forEach { $0.orderOut(nil); $0.contentView = nil } }
        overlays.removeAll(); views.removeAll()
        ScreenGrab.refreshContent()
        CaptureSession.current = nil
        NSCursor.arrow.set()
    }
}

// MARK: - Overlay window & view (GPU-composited: every mouse move only updates layer paths/positions)

final class OverlayWindow: NSWindow {
    /// Windows are kept between captures: creating a full-screen window costs ~50-100 ms of WindowServer time.
    static var pool: [CGDirectDisplayID: OverlayWindow] = [:]
    static func reuse(screen: NSScreen) -> OverlayWindow {
        let id = Geo.displayID(screen)
        if let w = pool[id], w.frame == screen.frame { return w }
        let w = OverlayWindow(screen: screen)
        pool[id] = w
        return w
    }

    private var container: NSView?

    init(screen: NSScreen) {
        super.init(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    func install(_ view: OverlayView) {
        alphaValue = 1
        ignoresMouseEvents = false
        // Frozen screenshot as the window's backing layer; overlay layers sit above it.
        let c = NSView(frame: NSRect(origin: .zero, size: frame.size))
        c.wantsLayer = true
        c.layer?.contentsGravity = .resize
        c.layer?.actions = ["contents": NSNull()]
        let host = NSView(frame: c.bounds)
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        c.addSubview(host)
        view.frame = c.bounds
        view.autoresizingMask = [.width, .height]
        c.addSubview(view)
        view.attach(layerHost: host)
        contentView = c
        container = c
    }

    func showShot(_ img: CGImage?) { container?.layer?.contents = img }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView, NSTextFieldDelegate {
    let session: CaptureSession
    let screen: NSScreen
    var shot: CGImage?
    let cgFrame: CGRect
    let scale: CGFloat
    var toolbar: NSView?

    // Everything is a plain CALayer (GPU-composited) or a small shape layer; nothing full-screen is redrawn on the CPU.
    private let dims = (0..<4).map { _ in CALayer() }          // top, bottom, left, right
    private let edges = (0..<4).map { _ in CAShapeLayer() }    // dashed / solid outline, one thin layer per side
    private let handles = (0..<8).map { _ in CALayer() }
    private let hLine = CALayer()
    private let vLine = CALayer()
    private let label = CALayer()
    private let hint = CALayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeGrid = CAShapeLayer()
    private let loupeInfo = CALayer()
    private let swatch = CALayer()
    private var labelText = "", infoText = ""
    private var wField: NSTextField?, hField: NSTextField?

    init(session: CaptureSession, screen: NSScreen) {
        self.session = session
        self.screen = screen
        self.cgFrame = Geo.cgRect(screen)
        self.scale = screen.backingScaleFactor
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(layerHost host: NSView) {
        guard let root = host.layer else { return }
        let ac = accent.cgColor
        let noAnim: [String: any CAAction] = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(),
                                             "hidden": NSNull(), "frame": NSNull(), "backgroundColor": NSNull(), "lineDashPattern": NSNull()]
        for d in dims { d.backgroundColor = NSColor.black.withAlphaComponent(0.4).cgColor }
        for e in edges { e.strokeColor = ac; e.fillColor = nil }
        for h in handles {
            h.backgroundColor = NSColor.white.cgColor
            h.borderColor = ac; h.borderWidth = 1.5
            h.bounds = CGRect(x: 0, y: 0, width: 9, height: 9)
            h.shadowOpacity = 0.35; h.shadowRadius = 1.5; h.shadowOffset = .zero
        }
        hLine.backgroundColor = accent.withAlphaComponent(0.85).cgColor
        vLine.backgroundColor = accent.withAlphaComponent(0.85).cgColor
        loupe.cornerRadius = 62; loupe.masksToBounds = true
        loupe.borderColor = NSColor.white.cgColor; loupe.borderWidth = 3
        loupe.backgroundColor = NSColor.black.cgColor
        loupeImage.magnificationFilter = .nearest
        loupe.addSublayer(loupeImage)
        loupeGrid.strokeColor = accent.cgColor; loupeGrid.fillColor = nil; loupeGrid.lineWidth = 1.5
        loupe.addSublayer(loupeGrid)
        swatch.cornerRadius = 3; swatch.borderColor = NSColor.white.cgColor; swatch.borderWidth = 1
        let all: [CALayer] = dims + edges + handles + [hLine, vLine, label, hint, loupe, loupeInfo, swatch]
        for l in all {
            l.contentsScale = scale
            l.actions = noAnim
            root.addSublayer(l)
        }
        for l in [loupeImage, loupeGrid] as [CALayer] { l.actions = noAnim }
        let tip = session.kind == .window
            ? "Click a window to capture it   ·   Esc to cancel"
            : "Click to capture the highlighted area, or drag to select   ·   scroll to pick a bigger area   ·   Esc to cancel"
        if let (img, sz) = OverlayView.pill(tip, font: .systemFont(ofSize: 13, weight: .medium), bg: NSColor.black.withAlphaComponent(0.72), scale: scale, radius: 14, padX: 14, padY: 6) {
            hint.contents = img
            hint.frame = CGRect(x: (bounds.width - sz.width) / 2, y: 52, width: sz.width, height: sz.height)
        }
    }

    // Convert flipped (top-left) local rects/points into the unflipped layer space.
    private func fy(_ r: CGRect) -> CGRect { CGRect(x: r.minX, y: bounds.height - r.maxY, width: r.width, height: r.height) }
    private func local(_ r: CGRect) -> CGRect { r.offsetBy(dx: -cgFrame.minX, dy: -cgFrame.minY) }
    private func local(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x - cgFrame.minX, y: p.y - cgFrame.minY) }
    private func g(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x + cgFrame.minX, y: p.y + cgFrame.minY)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .cursorUpdate, .mouseEnteredAndExited], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { setCursor() }
    private func setCursor() {
        if case .adjusting = session.phase { NSCursor.arrow.set() } else { NSCursor.crosshair.set() }
    }
    override func mouseEntered(with event: NSEvent) { guard !session.ended else { return }; window?.makeKey(); if !(window?.firstResponder is NSTextView) { window?.makeFirstResponder(self) }; setCursor() }
    override func mouseMoved(with e: NSEvent) { guard !session.ended else { return }; setCursor(); session.mouseMoved(g(e)) }
    override func mouseDown(with e: NSEvent) { guard !session.ended else { return }; window?.makeFirstResponder(self); session.mouseDown(g(e), clickCount: e.clickCount) }
    override func mouseDragged(with e: NSEvent) { guard !session.ended else { return }; session.mouseDragged(g(e)) }
    override func mouseUp(with e: NSEvent) { guard !session.ended else { return }; session.mouseUp(g(e)) }
    override func rightMouseDown(with event: NSEvent) { guard !session.ended else { return }; session.cancel() }
    override func scrollWheel(with e: NSEvent) { guard !session.ended else { return }; session.scroll(e) }
    override func keyDown(with e: NSEvent) { guard !session.ended else { return }; if !session.keyDown(e) { super.keyDown(with: e) } }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard !session.ended, !(window?.firstResponder is NSTextView) else { return false }
        return session.keyDown(e)
    }

    // MARK: Layer updates

    func updateLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var focus: CGRect?
        var isSelection = false
        switch session.phase {
        case .hover, .pressed: focus = session.hoverRect
        case .dragging, .adjusting: focus = session.selection; isSelection = true
        }
        let adjusting: Bool = { if case .adjusting = session.phase { return true }; return false }()
        let hovering: Bool = { if case .hover = session.phase { return true }; return false }()
        let onThisScreen = cgFrame.contains(session.mouse)

        // Dim everything except the focus rect, using four solid layers around it.
        let f = focus.map(local).flatMap { $0.intersects(bounds) ? $0.intersection(bounds) : nil }
        let dimAlpha: CGFloat = isSelection ? 0.5 : 0.35
        for d in dims { d.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha).cgColor }
        if let f {
            dims[0].frame = fy(CGRect(x: 0, y: 0, width: bounds.width, height: f.minY))
            dims[1].frame = fy(CGRect(x: 0, y: f.maxY, width: bounds.width, height: bounds.height - f.maxY))
            dims[2].frame = fy(CGRect(x: 0, y: f.minY, width: f.minX, height: f.height))
            dims[3].frame = fy(CGRect(x: f.maxX, y: f.minY, width: bounds.width - f.maxX, height: f.height))
        } else {
            dims[0].frame = fy(bounds)
            for d in dims.dropFirst() { d.frame = .zero }
        }

        // Outline: dashed while hovering (like a marquee), solid once selected.
        if let f {
            let lw: CGFloat = isSelection ? 1.5 : 2.5
            let r = f.insetBy(dx: -lw / 2, dy: -lw / 2)
            let sides: [(CGPoint, CGPoint)] = [
                (CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)), (CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)),
                (CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY)), (CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)),
            ]
            for (e, (a, b)) in zip(edges, sides) {
                let box = fy(CGRect(x: min(a.x, b.x) - lw, y: min(a.y, b.y) - lw, width: abs(b.x - a.x) + lw * 2, height: abs(b.y - a.y) + lw * 2))
                e.frame = box
                let p = CGMutablePath()
                let fa = fy(CGRect(origin: a, size: .zero)).origin, fb = fy(CGRect(origin: b, size: .zero)).origin
                p.move(to: CGPoint(x: fa.x - box.minX, y: fa.y - box.minY)); p.addLine(to: CGPoint(x: fb.x - box.minX, y: fb.y - box.minY))
                e.path = p
                e.lineWidth = lw
                e.lineDashPattern = isSelection ? nil : [7, 4]
                e.isHidden = false
            }

            let px = "\(Int((f.width * scale).rounded())) × \(Int((f.height * scale).rounded()))"
            var text = px
            if !isSelection, !session.hoverLabel.isEmpty { text = session.hoverLabel + "   " + px }
            setPill(label, text: text, cache: &labelText, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), bg: accent)
            var lr = CGRect(origin: CGPoint(x: f.minX, y: f.minY - 26 >= 4 ? f.minY - 26 : f.minY + 6), size: label.bounds.size)
            lr.origin.x = min(max(4, lr.minX), bounds.maxX - lr.width - 4)
            label.frame = fy(lr)
            label.isHidden = adjusting   // the toolbar shows the size once a region is selected
        } else {
            edges.forEach { $0.isHidden = true }
            label.isHidden = true
        }

        // Square handles on corners and edges.
        if adjusting, let f {
            for (h, p) in zip(handles, session.handlePoints(f)) { h.position = fy(CGRect(origin: p, size: .zero)).origin; h.isHidden = false }
        } else {
            handles.forEach { $0.isHidden = true }
        }

        // Full-screen crosshair + magnifier
        let showCross = onThisScreen && !adjusting
        hLine.isHidden = !showCross; vLine.isHidden = !showCross
        loupe.isHidden = !showCross || shot == nil; loupeInfo.isHidden = loupe.isHidden; swatch.isHidden = loupe.isHidden
        hint.isHidden = !(hovering && onThisScreen)
        if showCross {
            let m = local(session.mouse)
            hLine.frame = fy(CGRect(x: 0, y: m.y.rounded(.down), width: bounds.width, height: 1))
            vLine.frame = fy(CGRect(x: m.x.rounded(.down), y: 0, width: 1, height: bounds.height))
            if shot != nil { updateLoupe(at: m) }
        }
        if adjusting { syncSizeFields() }
    }

    private func updateLoupe(at m: CGPoint) {
        guard let shot else { return }
        let span: CGFloat = 13, L: CGFloat = 124
        let want = CGRect(x: (m.x - span / 2) * scale, y: (m.y - span / 2) * scale, width: span * scale, height: span * scale).integral
        var o = CGPoint(x: m.x + 26, y: m.y + 26)
        if o.x + L > bounds.maxX - 6 { o.x = m.x - 26 - L }
        if o.y + L + 34 > bounds.maxY - 6 { o.y = m.y - 26 - L - 34 }
        let box = CGRect(origin: o, size: CGSize(width: L, height: L))
        loupe.frame = fy(box)

        let pxSize = L / (span * scale)
        var hex = ""
        if let crop = shot.cropping(to: want) {
            let got = want.intersection(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
            let dst = CGRect(x: (got.minX - want.minX) * pxSize, y: (got.minY - want.minY) * pxSize,
                             width: CGFloat(crop.width) * pxSize, height: CGFloat(crop.height) * pxSize)
            loupeImage.contents = crop
            loupeImage.frame = CGRect(x: dst.minX, y: L - dst.maxY, width: dst.width, height: dst.height)
        }
        // Color of the pixel under the cursor.
        let cp = CGRect(x: (m.x * scale).rounded(.down), y: (m.y * scale).rounded(.down), width: 1, height: 1)
        if let one = shot.cropping(to: cp) {
            var d = [UInt8](repeating: 0, count: 4)
            if let ctx = CGContext(data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                   bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                ctx.draw(one, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                hex = String(format: "#%02X%02X%02X", d[0], d[1], d[2])
                swatch.backgroundColor = CGColor(red: CGFloat(d[0]) / 255, green: CGFloat(d[1]) / 255, blue: CGFloat(d[2]) / 255, alpha: 1)
            }
        }
        if loupeGrid.path == nil {
            let c = CGRect(x: L / 2 - pxSize / 2, y: L / 2 - pxSize / 2, width: pxSize, height: pxSize)
            loupeGrid.frame = CGRect(x: 0, y: 0, width: L, height: L)
            loupeGrid.path = CGPath(rect: c, transform: nil)
        }

        var info = "\(Int(m.x * scale)), \(Int(m.y * scale))   \(hex)"
        if case .dragging = session.phase {
            info = "\(Int((session.selection.width * scale).rounded())) × \(Int((session.selection.height * scale).rounded()))"
        }
        setPill(loupeInfo, text: info, cache: &infoText, font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), bg: NSColor.black.withAlphaComponent(0.78))
        let s = loupeInfo.bounds.size
        let infoRect = CGRect(x: box.midX - s.width / 2 + 9, y: box.maxY + 8, width: s.width, height: s.height)
        loupeInfo.frame = fy(infoRect)
        swatch.frame = fy(CGRect(x: infoRect.minX - 18, y: infoRect.midY - 6, width: 12, height: 12))
    }

    private func setPill(_ layer: CALayer, text: String, cache: inout String, font: NSFont, bg: NSColor) {
        guard text != cache else { return }
        cache = text
        if let (img, sz) = OverlayView.pill(text, font: font, bg: bg, scale: scale) {
            layer.contents = img
            layer.bounds = CGRect(origin: .zero, size: sz)
        }
    }

    static func pill(_ text: String, font: NSFont, bg: NSColor, scale: CGFloat, radius: CGFloat = 5, padX: CGFloat = 7, padY: CGFloat = 3) -> (CGImage, CGSize)? {
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
        let ts = (text as NSString).size(withAttributes: attrs)
        let size = CGSize(width: ceil(ts.width + padX * 2), height: ceil(ts.height + padY * 2))
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        bg.setFill()
        NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: min(radius, size.height / 2), yRadius: min(radius, size.height / 2)).fill()
        (text as NSString).draw(at: CGPoint(x: padX, y: padY), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
        guard let cg = rep.cgImage else { return nil }
        return (cg, size)
    }

    // MARK: Toolbar (horizontal, under the selection)

    func showToolbar() {
        if toolbar == nil { toolbar = makeToolbar() }
        toolbar?.isHidden = false
        syncSizeFields(force: true)
        positionToolbar()
    }

    private func makeToolbar() -> NSView {
        let bg = NSVisualEffectView()
        bg.material = .hudWindow
        bg.state = .active
        bg.blendingMode = .withinWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 12
        bg.layer?.borderWidth = 0.5
        bg.layer?.borderColor = NSColor.white.withAlphaComponent(0.15).cgColor
        bg.appearance = NSAppearance(named: .vibrantDark)

        func tool(_ title: String, _ sym: String, _ sel: Selector, _ tip: String, primary: Bool = false) -> NSView {
            let b = CaptureBarButton(title: title, symbol: sym, primary: primary, target: self, action: sel)
            b.toolTip = tip
            return b
        }
        func sep() -> NSView {
            let v = NSBox(); v.boxType = .separator
            v.translatesAutoresizingMaskIntoConstraints = false
            v.heightAnchor.constraint(equalToConstant: 36).isActive = true
            return v
        }
        func field() -> NSTextField {
            let f = NSTextField()
            f.alignment = .center
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            f.bezelStyle = .roundedBezel
            f.focusRingType = .none
            f.delegate = self
            f.target = self; f.action = #selector(sizeTyped(_:))
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 58).isActive = true
            let nf = NumberFormatter(); nf.allowsFloats = false; nf.minimum = 4; nf.maximum = 20000
            f.formatter = nf
            return f
        }
        let w = field(), h = field()
        wField = w; hField = h
        let times = NSTextField(labelWithString: "×")
        times.textColor = .secondaryLabelColor
        let sizeRow = NSStackView(views: [w, times, h])
        sizeRow.spacing = 4
        let sizeCaption = NSTextField(labelWithString: "Size (px)")
        sizeCaption.font = .systemFont(ofSize: 10, weight: .medium)
        sizeCaption.textColor = .secondaryLabelColor
        let sizeBox = NSStackView(views: [sizeRow, sizeCaption])
        sizeBox.orientation = .vertical
        sizeBox.spacing = 3

        let stack = NSStackView(views: [
            tool("Capture", "camera.fill", #selector(doCapture), "Open in the editor (Return or double-click)", primary: true),
            tool("Scrolling", "arrow.up.and.down.text.horizontal", #selector(doScroll), "Scroll and stitch everything below (S)"),
            sep(),
            tool("Copy", "doc.on.doc", #selector(doCopy), "Copy to clipboard, skip the editor (⌘C)"),
            tool("Grab Text", "text.viewfinder", #selector(doText), "Copy the text in this area (T)"),
            tool("Pin", "pin", #selector(doPin), "Float it above all windows (P)"),
            sep(),
            sizeBox,
            sep(),
            tool("Redo", "arrow.counterclockwise", #selector(doReselect), "Select again (Esc)"),
            tool("Cancel", "xmark", #selector(doCancel), "Cancel capture"),
        ])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        addSubview(bg)
        bg.setFrameSize(stack.fittingSize)
        return bg
    }

    private var lastSize: CGSize = .zero
    private func syncSizeFields(force: Bool = false) {
        guard let wField, let hField else { return }
        let sz = CGSize(width: (session.selection.width * scale).rounded(), height: (session.selection.height * scale).rounded())
        guard force || sz != lastSize else { return }
        lastSize = sz
        if window?.firstResponder !== wField.currentEditor() { wField.integerValue = Int(sz.width) }
        if window?.firstResponder !== hField.currentEditor() { hField.integerValue = Int(sz.height) }
    }

    @objc private func sizeTyped(_ s: Any?) {
        guard let wField, let hField else { return }
        session.applySize(width: CGFloat(wField.integerValue) / scale, height: CGFloat(hField.integerValue) / scale)
        syncSizeFields(force: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.cancelOperation(_:)) { window?.makeFirstResponder(self); syncSizeFields(force: true); return true }
        if sel == #selector(NSResponder.insertNewline(_:)) { sizeTyped(nil); window?.makeFirstResponder(self); return true }
        return false
    }

    func positionToolbar() {
        guard let tb = toolbar, !tb.isHidden else { return }
        let f = local(session.selection)
        let sz = tb.frame.size
        var x = f.midX - sz.width / 2
        x = min(max(8, x), bounds.maxX - sz.width - 8)
        // Below the selection; above it if there's no room; inside the bottom edge as a last resort.
        var y = f.maxY + 12
        if y + sz.height > bounds.maxY - 8 { y = f.minY - sz.height - 12 }
        if y < 8 { y = f.maxY - sz.height - 12 }
        tb.setFrameOrigin(CGPoint(x: x, y: y))
    }

    @objc func doCapture() { session.finish(.edit) }
    @objc func doScroll() { session.finish(.scroll) }
    @objc func doCopy() { session.finish(.copy) }
    @objc func doText() { session.finish(.text) }
    @objc func doPin() { session.finish(.pin) }
    @objc func doCancel() { session.cancel() }
    @objc func doReselect() { session.reselect() }
}

/// Icon-over-label button used in the capture toolbar.
final class CaptureBarButton: NSControl {
    private let title: String
    private let symbol: NSImage?
    private let primary: Bool
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    init(title: String, symbol: String, primary: Bool, target: AnyObject, action: Selector) {
        self.title = title
        self.symbol = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .medium))
        self.primary = primary
        super.init(frame: NSRect(x: 0, y: 0, width: 66, height: 52))
        self.target = target; self.action = action
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: max(60, (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)]).width + 18)).isActive = true
        heightAnchor.constraint(equalToConstant: 52).isActive = true
        setAccessibilityRole(.button); setAccessibilityLabel(title)
    }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.arrow.set() }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)), let action { NSApp.sendAction(action, to: target, from: self) }
    }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 2)
        let bgPath = NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8)
        if primary { accent.withAlphaComponent(pressed ? 0.8 : 1).setFill(); bgPath.fill() }
        else if hovering || pressed { NSColor.white.withAlphaComponent(pressed ? 0.22 : 0.12).setFill(); bgPath.fill() }
        let fg = NSColor.white
        if let img = symbol {
            let tinted = NSImage(size: img.size, flipped: false) { rect in
                img.draw(in: rect); fg.set(); rect.fill(using: .sourceAtop); return true
            }
            let box = CGRect(x: bounds.midX - 12, y: 7, width: 24, height: 22)
            let k = min(box.width / img.size.width, box.height / img.size.height, 1)
            let s = CGSize(width: img.size.width * k, height: img.size.height * k)
            tinted.draw(in: CGRect(x: box.midX - s.width / 2, y: box.midY - s.height / 2, width: s.width, height: s.height))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: primary ? .semibold : .medium), .foregroundColor: fg]
        let ts = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: CGPoint(x: bounds.midX - ts.width / 2, y: 33), withAttributes: attrs)
    }
}
