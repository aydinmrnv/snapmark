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
        PermissionState.shared.refresh()
        if !PermissionState.shared.screenReady {
            end()
            PermissionsController.shared.show(.screen)
            return
        }
        windows = Self.loadWindows()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            var jobs: [(CGDirectDisplayID, SCContentFilter, SCStreamConfiguration)] = []
            for screen in NSScreen.screens {
                let id = Geo.displayID(screen)
                guard let d = content.displays.first(where: { $0.displayID == id }) else { continue }
                let cfg = SCStreamConfiguration()
                cfg.width = Int(screen.frame.width * screen.backingScaleFactor)
                cfg.height = Int(screen.frame.height * screen.backingScaleFactor)
                cfg.showsCursor = false
                cfg.captureResolution = .best
                jobs.append((id, SCContentFilter(display: d, excludingWindows: []), cfg))
            }
            // All displays at once.
            try await withThrowingTaskGroup(of: (CGDirectDisplayID, CGImage).self) { group in
                for (id, filter, cfg) in jobs {
                    group.addTask { (id, try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)) }
                }
                for try await (id, img) in group { shots[id] = img }
            }
        } catch {
            NSLog("Snapmark capture error: \(error)")
            end()
            PermissionsController.shared.show(.screen)
            return
        }

        if kind == .fullscreen {
            let p = cursor?.location ?? Geo.mouse()
            if let s = Geo.screen(at: p) { selection = Geo.cgRect(s); selectionScreen = s; finish(.edit) } else { end() }
            return
        }

        for screen in NSScreen.screens {
            guard let shot = shots[Geo.displayID(screen)] else { continue }
            let v = OverlayView(session: self, screen: screen, shot: shot)
            let w = OverlayWindow(screen: screen, view: v)
            overlays.append(w); views.append(v)
        }
        NSApp.activate(ignoringOtherApps: true)
        for w in overlays { w.orderFrontRegardless() }
        mouse = Geo.mouse()
        let keyWin = overlays.first { $0.frame.contains(NSEvent.mouseLocation) } ?? overlays.first
        keyWin?.makeKeyAndOrderFront(nil)
        if let kv = keyWin?.contentView?.subviews.first { keyWin?.makeFirstResponder(kv) }
        NSCursor.crosshair.set()
        updateHover()
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

    enum Action { case edit, copy, text, pin }

    func finish(_ action: Action) {
        guard let screen = selectionScreen ?? Geo.screen(at: selection.origin),
              let shot = shots[Geo.displayID(screen)] else { cancel(); return }
        let sf = Geo.cgRect(screen)
        let scale = CGFloat(shot.width) / sf.width
        let local = selection.offsetBy(dx: -sf.minX, dy: -sf.minY)
        let px = CGRect(x: local.minX * scale, y: local.minY * scale, width: local.width * scale, height: local.height * scale)
            .integral.intersection(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
        guard px.width >= 2, px.height >= 2, let img = shot.cropping(to: px) else { cancel(); return }
        let origin = CGPoint(x: px.minX / scale + sf.minX, y: px.minY / scale + sf.minY)
        let captured = CGRect(origin: origin, size: CGSize(width: px.width / scale, height: px.height / scale))

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
        NSSound(named: "Tink")?.play()

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
        let url = Library.shared.newURL()
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
        case .text:
            break
        }
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

    private func end() {
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll(); views.removeAll()
        CaptureSession.current = nil
        NSCursor.arrow.set()
    }
}

// MARK: - Overlay window & view (GPU-composited: every mouse move only updates layer paths/positions)

final class OverlayWindow: NSWindow {
    init(screen: NSScreen, view: OverlayView) {
        super.init(contentRect: NSRect(origin: .zero, size: screen.frame.size), styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = .screenSaver
        isOpaque = true
        hasShadow = false
        acceptsMouseMovedEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        // Frozen screenshot as the window's backing layer; overlay layers sit above it.
        let container = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        container.wantsLayer = true
        container.layer?.contents = view.shot
        container.layer?.contentsGravity = .resize
        let host = NSView(frame: container.bounds)
        host.wantsLayer = true
        host.autoresizingMask = [.width, .height]
        container.addSubview(host)
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        view.attach(layerHost: host)
        contentView = container
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class OverlayView: NSView {
    unowned let session: CaptureSession
    let screen: NSScreen
    let shot: CGImage
    let cgFrame: CGRect
    let scale: CGFloat
    var toolbar: NSView?

    // Layers (in the unflipped host's coordinates).
    private let dim = CAShapeLayer()
    private let border = CAShapeLayer()
    private let handles = CAShapeLayer()
    private let hLine = CALayer()
    private let vLine = CALayer()
    private let label = CALayer()
    private let hint = CALayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeMarks = CAShapeLayer()
    private let loupeInfo = CALayer()
    private var labelText = "", infoText = ""

    init(session: CaptureSession, screen: NSScreen, shot: CGImage) {
        self.session = session
        self.screen = screen
        self.shot = shot
        self.cgFrame = Geo.cgRect(screen)
        self.scale = CGFloat(shot.width) / screen.frame.width
        super.init(frame: NSRect(origin: .zero, size: screen.frame.size))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func attach(layerHost host: NSView) {
        guard let root = host.layer else { return }
        let ac = accent.cgColor
        dim.fillRule = .evenOdd
        border.fillColor = nil; border.strokeColor = ac
        handles.fillColor = NSColor.white.cgColor; handles.strokeColor = ac; handles.lineWidth = 2
        hLine.backgroundColor = accent.withAlphaComponent(0.75).cgColor
        vLine.backgroundColor = accent.withAlphaComponent(0.75).cgColor
        loupe.cornerRadius = 10; loupe.masksToBounds = true
        loupe.borderColor = NSColor.white.cgColor; loupe.borderWidth = 3
        loupe.backgroundColor = NSColor.black.cgColor
        loupeImage.magnificationFilter = .nearest
        loupe.addSublayer(loupeImage)
        loupeMarks.fillColor = accent.withAlphaComponent(0.35).cgColor
        loupeMarks.strokeColor = NSColor.white.cgColor; loupeMarks.lineWidth = 1
        loupe.addSublayer(loupeMarks)
        for l in [dim, border, handles, hLine, vLine, label, hint, loupe, loupeInfo] as [CALayer] {
            l.contentsScale = scale
            l.actions = ["position": NSNull(), "bounds": NSNull(), "path": NSNull(), "contents": NSNull(), "hidden": NSNull(), "frame": NSNull()]
            root.addSublayer(l)
        }
        let tip = session.kind == .window
            ? "Click a window to capture it   ·   Esc to cancel"
            : "Click to capture the highlighted area, or drag to select a region   ·   Esc to cancel"
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
    override func mouseEntered(with event: NSEvent) { window?.makeKey(); window?.makeFirstResponder(self); setCursor() }
    override func mouseMoved(with e: NSEvent) { setCursor(); session.mouseMoved(g(e)) }
    override func mouseDown(with e: NSEvent) { session.mouseDown(g(e), clickCount: e.clickCount) }
    override func mouseDragged(with e: NSEvent) { session.mouseDragged(g(e)) }
    override func mouseUp(with e: NSEvent) { session.mouseUp(g(e)) }
    override func rightMouseDown(with event: NSEvent) { session.cancel() }
    override func scrollWheel(with e: NSEvent) { session.scroll(e) }
    override func keyDown(with e: NSEvent) { if !session.keyDown(e) { super.keyDown(with: e) } }
    override func performKeyEquivalent(with e: NSEvent) -> Bool { session.keyDown(e) }

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

        // Dim + border
        let path = CGMutablePath()
        path.addRect(bounds)
        let f = focus.map(local)
        if let f, f.intersects(bounds) { path.addRect(fy(f)) }
        dim.path = path
        dim.fillColor = NSColor.black.withAlphaComponent(isSelection ? 0.45 : 0.32).cgColor
        if let f, f.intersects(bounds) {
            border.isHidden = false
            border.lineWidth = isSelection ? 2 : 3
            border.path = CGPath(rect: fy(f.insetBy(dx: -1, dy: -1)), transform: nil)

            let px = "\(Int((f.width * scale).rounded())) × \(Int((f.height * scale).rounded()))"
            var text = px
            if !isSelection, !session.hoverLabel.isEmpty {
                text = session.hoverLabel + "   " + px
                if session.hoverStack.count > 1 { text += "   ⇅ scroll" }
            }
            setPill(label, text: text, cache: &labelText, font: .monospacedDigitSystemFont(ofSize: 12, weight: .semibold), bg: accent)
            var lr = CGRect(origin: CGPoint(x: f.minX, y: f.minY - 26 >= 4 ? f.minY - 26 : f.minY + 6), size: label.bounds.size)
            lr.origin.x = min(max(4, lr.minX), bounds.maxX - lr.width - 4)
            label.frame = fy(lr)
            label.isHidden = false
        } else {
            border.isHidden = true
            label.isHidden = true
        }

        // Handles
        if adjusting, let f {
            let hp = CGMutablePath()
            for p in session.handlePoints(f) { hp.addEllipse(in: fy(CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10))) }
            handles.path = hp
            handles.isHidden = false
        } else {
            handles.isHidden = true
        }

        // Crosshair + loupe
        let showCross = onThisScreen && !adjusting
        hLine.isHidden = !showCross; vLine.isHidden = !showCross
        loupe.isHidden = !showCross; loupeInfo.isHidden = !showCross
        hint.isHidden = !(hovering && onThisScreen)
        if showCross {
            let m = local(session.mouse)
            hLine.frame = fy(CGRect(x: 0, y: m.y.rounded(.down), width: bounds.width, height: 1))
            vLine.frame = fy(CGRect(x: m.x.rounded(.down), y: 0, width: 1, height: bounds.height))
            updateLoupe(at: m)
        }
    }

    private func updateLoupe(at m: CGPoint) {
        let span: CGFloat = 15, L: CGFloat = 124
        let want = CGRect(x: (m.x - span / 2) * scale, y: (m.y - span / 2) * scale, width: span * scale, height: span * scale).integral
        var o = CGPoint(x: m.x + 22, y: m.y + 22)
        if o.x + L > bounds.maxX - 6 { o.x = m.x - 22 - L }
        if o.y + L + 30 > bounds.maxY - 6 { o.y = m.y - 22 - L - 30 }
        let box = CGRect(origin: o, size: CGSize(width: L, height: L))
        loupe.frame = fy(box)

        let pxSize = L / (span * scale)
        if let crop = shot.cropping(to: want) {
            // Keep pixels aligned when the crop is clipped at a screen edge.
            let got = want.intersection(CGRect(x: 0, y: 0, width: shot.width, height: shot.height))
            let dst = CGRect(x: (got.minX - want.minX) * pxSize, y: (got.minY - want.minY) * pxSize,
                             width: CGFloat(crop.width) * pxSize, height: CGFloat(crop.height) * pxSize)
            loupeImage.contents = crop
            loupeImage.frame = CGRect(x: dst.minX, y: L - dst.maxY, width: dst.width, height: dst.height)
        }
        if loupeMarks.path == nil {
            let c = CGRect(x: L / 2 - pxSize / 2, y: L / 2 - pxSize / 2, width: pxSize, height: pxSize)
            let p = CGMutablePath()
            p.addRect(CGRect(x: 0, y: c.minY, width: c.minX, height: pxSize))
            p.addRect(CGRect(x: c.maxX, y: c.minY, width: L - c.maxX, height: pxSize))
            p.addRect(CGRect(x: c.minX, y: 0, width: pxSize, height: c.minY))
            p.addRect(CGRect(x: c.minX, y: c.maxY, width: pxSize, height: L - c.maxY))
            loupeMarks.frame = CGRect(x: 0, y: 0, width: L, height: L)
            loupeMarks.path = p
            let center = CAShapeLayer()
            center.path = CGPath(rect: c, transform: nil)
            center.fillColor = nil; center.strokeColor = NSColor.white.cgColor; center.lineWidth = 1
            loupeMarks.addSublayer(center)
        }

        var info = "\(Int(m.x * scale)), \(Int(m.y * scale))"
        if case .dragging = session.phase {
            info = "\(Int((session.selection.width * scale).rounded())) × \(Int((session.selection.height * scale).rounded()))"
        }
        setPill(loupeInfo, text: info, cache: &infoText, font: .monospacedDigitSystemFont(ofSize: 11, weight: .semibold), bg: NSColor.black.withAlphaComponent(0.75))
        let s = loupeInfo.bounds.size
        loupeInfo.frame = fy(CGRect(x: box.midX - s.width / 2, y: box.maxY + 6, width: s.width, height: s.height))
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

    // MARK: Toolbar (vertical, docked beside the selection)

    func showToolbar() {
        if toolbar == nil {
            let bg = NSVisualEffectView()
            bg.material = .hudWindow
            bg.state = .active
            bg.blendingMode = .withinWindow
            bg.wantsLayer = true
            bg.layer?.cornerRadius = 10
            bg.appearance = NSAppearance(named: .vibrantDark)
            func b(_ title: String, _ sym: String, _ sel: Selector, _ tip: String) -> NSButton {
                let x = NSButton(title: title, image: NSImage(systemSymbolName: sym, accessibilityDescription: title)!, target: self, action: sel)
                x.imagePosition = .imageLeading
                x.bezelStyle = .rounded
                x.controlSize = .large
                x.toolTip = tip
                x.alignment = .left
                x.translatesAutoresizingMaskIntoConstraints = false
                x.widthAnchor.constraint(equalToConstant: 124).isActive = true
                return x
            }
            let capture = b("Capture", "camera.fill", #selector(doCapture), "Open in the editor (Return or double-click)")
            capture.bezelColor = accent
            capture.contentTintColor = .white
            let stack = NSStackView(views: [
                capture,
                b("Copy", "doc.on.doc", #selector(doCopy), "Copy to clipboard, skip the editor (⌘C)"),
                b("Grab Text", "text.viewfinder", #selector(doText), "Copy the text in this area (T)"),
                b("Pin", "pin", #selector(doPin), "Float it above all windows (P)"),
                b("Redo", "arrow.counterclockwise", #selector(doReselect), "Select again (Esc)"),
                b("Cancel", "xmark", #selector(doCancel), "Cancel capture"),
            ])
            stack.orientation = .vertical
            stack.spacing = 6
            stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
            stack.translatesAutoresizingMaskIntoConstraints = false
            bg.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
                stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
            ])
            addSubview(bg)
            bg.setFrameSize(stack.fittingSize)
            toolbar = bg
        }
        toolbar?.isHidden = false
        positionToolbar()
    }

    func positionToolbar() {
        guard let tb = toolbar, !tb.isHidden else { return }
        let f = local(session.selection)
        let sz = tb.frame.size
        var x = f.maxX + 12
        if x + sz.width > bounds.maxX - 8 { x = f.minX - sz.width - 12 }
        if x < 8 { x = f.maxX - sz.width - 12 }
        let y = min(max(8, f.minY), bounds.maxY - sz.height - 8)
        tb.setFrameOrigin(CGPoint(x: x, y: y))
    }

    @objc func doCapture() { session.finish(.edit) }
    @objc func doCopy() { session.finish(.copy) }
    @objc func doText() { session.finish(.text) }
    @objc func doPin() { session.finish(.pin) }
    @objc func doCancel() { session.cancel() }
    @objc func doReselect() { session.reselect() }
}
