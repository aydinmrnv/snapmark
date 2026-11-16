import Cocoa
import Vision
import ScreenCaptureKit
import AudioToolbox

// MARK: - Grab Text (on-device OCR)

enum TextGrabber {
    /// Recognise text off the main thread; lines come back top-to-bottom, left-to-right.
    static func recognize(_ image: CGImage, completion: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let req = VNRecognizeTextRequest()
            req.recognitionLevel = .accurate
            req.usesLanguageCorrection = true
            try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
            let obs = (req.results ?? []).sorted {
                let a = $0.boundingBox, b = $1.boundingBox
                if abs(a.midY - b.midY) > min(a.height, b.height) * 0.5 { return a.midY > b.midY }
                return a.minX < b.minX
            }
            let text = obs.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            DispatchQueue.main.async { completion(text) }
        }
    }
}

// MARK: - Pin (floating screenshot)

final class PinWindow: NSPanel {
    static var open: [PinWindow] = []

    static func show(_ image: NSImage, near point: NSPoint? = nil) {
        let screen = NSScreen.main ?? NSScreen.screens[0]
        var size = image.size
        let maxS = CGSize(width: screen.visibleFrame.width * 0.6, height: screen.visibleFrame.height * 0.6)
        let k = min(1, maxS.width / max(size.width, 1), maxS.height / max(size.height, 1))
        size = CGSize(width: size.width * k, height: size.height * k)
        let origin = point.map { NSPoint(x: $0.x, y: $0.y - size.height) }
            ?? NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
        let w = PinWindow(contentRect: NSRect(origin: origin, size: size), image: image)
        open.append(w)
        w.orderFrontRegardless()
        Toast.show("Pinned · drag to move · scroll to resize · double-click to close")
    }

    private let aspect: CGFloat

    init(contentRect: NSRect, image: NSImage) {
        aspect = image.size.width / max(image.size.height, 1)
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .resizable], backing: .buffered, defer: false)
        level = .floating
        isMovableByWindowBackground = true
        hasShadow = true
        backgroundColor = .clear
        isOpaque = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        let v = PinView(image: image)
        v.wantsLayer = true
        v.layer?.cornerRadius = 8
        v.layer?.masksToBounds = true
        contentView = v
    }

    override var canBecomeKey: Bool { true }

    override func scrollWheel(with e: NSEvent) {
        let factor = 1 + e.scrollingDeltaY * (e.hasPreciseScrollingDeltas ? 0.004 : 0.04)
        var f = frame
        let w = min(max(80, f.width * factor), 4000)
        let h = w / aspect
        f.origin.y += f.height - h
        f.size = NSSize(width: w, height: h)
        setFrame(f, display: true)
    }

    override func keyDown(with e: NSEvent) {
        if e.keyCode == 53 { closePin() } else { super.keyDown(with: e) }
    }

    func closePin() {
        orderOut(nil)
        PinWindow.open.removeAll { $0 === self }
    }
}

final class PinView: NSView {
    let image: NSImage
    private var hovering = false { didSet { needsDisplay = true } }
    init(image: NSImage) { self.image = image; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var mouseDownCanMoveWindow: Bool { true }
    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func draw(_ dirtyRect: NSRect) {
        image.draw(in: bounds)
        if hovering {
            let r = CGRect(x: 8, y: bounds.height - 30, width: 22, height: 22)
            NSColor.black.withAlphaComponent(0.6).setFill()
            NSBezierPath(ovalIn: r).fill()
            let x = NSBezierPath()
            x.move(to: CGPoint(x: r.minX + 7, y: r.minY + 7)); x.line(to: CGPoint(x: r.maxX - 7, y: r.maxY - 7))
            x.move(to: CGPoint(x: r.minX + 7, y: r.maxY - 7)); x.line(to: CGPoint(x: r.maxX - 7, y: r.minY + 7))
            x.lineWidth = 2; NSColor.white.setStroke(); x.stroke()
            NSColor.white.withAlphaComponent(0.5).setStroke()
            let b = NSBezierPath(rect: bounds.insetBy(dx: 0.5, dy: 0.5)); b.lineWidth = 1; b.stroke()
        }
    }
    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if hovering, CGRect(x: 8, y: bounds.height - 30, width: 22, height: 22).contains(p) || e.clickCount == 2 {
            (window as? PinWindow)?.closePin(); return
        }
        window?.performDrag(with: e)
    }
    override func rightMouseDown(with e: NSEvent) {
        let m = NSMenu()
        m.addItem(withTitle: "Copy", action: #selector(copyImage), keyEquivalent: "").target = self
        m.addItem(withTitle: "Close", action: #selector(closeIt), keyEquivalent: "").target = self
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }
    @objc func copyImage() { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
    @objc func closeIt() { (window as? PinWindow)?.closePin() }
}

// MARK: - Toast

enum Toast {
    private static var panel: NSPanel?

    static func show(_ message: String, symbol: String = "checkmark.circle.fill") {
        panel?.orderOut(nil)
        let label = NSTextField(labelWithString: message)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .white
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.contentTintColor = .white
        let stack = NSStackView(views: [icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 16)
        let bg = NSVisualEffectView()
        bg.material = .hudWindow; bg.state = .active; bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true; bg.layer?.cornerRadius = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bg.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bg.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bg.topAnchor), stack.bottomAnchor.constraint(equalTo: bg.bottomAnchor),
        ])
        let size = stack.fittingSize
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let p = NSPanel(contentRect: NSRect(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.minY + 80,
                                            width: size.width, height: size.height),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.level = .statusBar
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = bg
        p.alphaValue = 0
        p.orderFrontRegardless()
        panel = p
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; p.animator().alphaValue = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            guard panel === p else { return }
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; p.animator().alphaValue = 0 }, completionHandler: { p.orderOut(nil) })
        }
    }
}

// MARK: - Timing (written to ~/Library/Logs/Snapmark.log)

enum Perf {
    static var marks: [String: CFAbsoluteTime] = [:]
    static let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Snapmark.log")
    static var lapT = CFAbsoluteTimeGetCurrent()
    static func lap(_ name: String) { let n = CFAbsoluteTimeGetCurrent(); write(String(format: "  lap %@: %.1f ms", name, (n - lapT) * 1000)); lapT = n }
    static func start(_ name: String) { marks[name] = CFAbsoluteTimeGetCurrent() }
    @discardableResult
    static func end(_ name: String, log: Bool = true) -> Double {
        guard let t = marks.removeValue(forKey: name) else { return -1 }
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        if log { write(String(format: "%@: %.1f ms", name, ms)) }
        return ms
    }
    static func write(_ line: String) {
        let s = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(s.data(using: .utf8)!); try? h.close() }
        else { try? s.write(to: logURL, atomically: true, encoding: .utf8) }
    }
}

// MARK: - Benchmark (--bench): runs capture cycles without user input and logs the numbers.

enum Bench {
    static var active = false
    static var results: [String: [Double]] = [:]
    static var runsLeft = 0
    static var onOverlay: (() -> Void)?

    static func run(cycles: Int = 5) {
        active = true
        runsLeft = cycles
        Perf.write("---- bench start ----")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { next() }
    }

    static func record(_ k: String, _ v: Double) { results[k, default: []].append(v) }

    static func next() {
        guard runsLeft > 0 else { finish(); return }
        runsLeft -= 1
        onOverlay = {
            guard let s = CaptureSession.current, let scr = NSScreen.main else { return }
            // Simulate 200 mouse moves across the screen and time the hover/redraw work.
            let r = Geo.cgRect(scr)
            var total = 0.0
            for i in 0..<200 {
                let p = CGPoint(x: r.minX + CGFloat(i * 37 % Int(r.width)), y: r.minY + CGFloat(i * 23 % Int(r.height)))
                let t = CFAbsoluteTimeGetCurrent()
                s.mouse = p
                s.updateHover()
                CATransaction.flush()
                total += (CFAbsoluteTimeGetCurrent() - t) * 1000
            }
            record("hover per move", total / 200)
            s.selectionScreen = scr
            s.selection = CGRect(x: r.midX - 400, y: r.midY - 300, width: 800, height: 600)
            Perf.start("capture → editor visible")
            s.finish(.edit)
        }
        AppDelegate.shared.capture(.region)
    }

    static func editorShown() {
        let ms = Perf.end("capture → editor visible", log: false)
        if ms >= 0 { record("capture → editor visible", ms) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { next() }
    }

    static func finish() {
        var lines = ["---- bench results (median of runs) ----"]
        for (k, v) in results.sorted(by: { $0.key < $1.key }) {
            let m = v.sorted()[v.count / 2]
            lines.append(String(format: "%@: %.1f ms   (all: %@)", k, m, v.map { String(format: "%.0f", $0) }.joined(separator: ", ")))
        }
        lines.forEach(Perf.write)
        print(lines.joined(separator: "\n"))
        exit(0)
    }
}

// MARK: - Screen grabbing (fast path + ScreenCaptureKit fallback)

enum ScreenGrab {
    private typealias Fn = @convention(c) (CGDirectDisplayID) -> Unmanaged<CGImage>?
    /// CGDisplayCreateImage is hidden from the SDK but still ships in CoreGraphics and is ~4x faster
    /// than SCScreenshotManager. If it ever disappears or fails, we fall back to ScreenCaptureKit.
    private static let legacy: Fn? = {
        guard let h = dlopen(nil, RTLD_NOW), let sym = dlsym(h, "CGDisplayCreateImage") else { return nil }
        return unsafeBitCast(sym, to: Fn.self)
    }()
    private static var content: SCShareableContent?
    /// System sounds play asynchronously; NSSound blocks the main thread for ~0.8 s the first time.
    private static let soundID: SystemSoundID = {
        var id: SystemSoundID = 0
        AudioServicesCreateSystemSoundID(URL(fileURLWithPath: "/System/Library/Sounds/Tink.aiff") as CFURL, &id)
        return id
    }()
    static func playShutter() { AudioServicesPlaySystemSound(soundID) }

    /// Warm caches so the first capture doesn't pay for them.
    static func prewarm() {
        _ = soundID
        refreshContent()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { _ in refreshContent(); OverlayWindow.pool.removeAll() }
    }
    static func refreshContent() {
        Task { content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
    }

    struct Target: Sendable { let id: CGDirectDisplayID; let pixels: CGSize }

    static func grab(_ t: Target) async throws -> CGImage {
        if let f = legacy, let img = f(t.id)?.takeRetainedValue() { return img }
        let c: SCShareableContent
        if let cached = content { c = cached } else { c = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true); content = c }
        guard let d = c.displays.first(where: { $0.displayID == t.id }) else { throw CocoaError(.featureUnsupported) }
        let me = c.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let cfg = SCStreamConfiguration()
        cfg.width = Int(t.pixels.width); cfg.height = Int(t.pixels.height)
        cfg.showsCursor = false
        cfg.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(display: d, excludingApplications: me, exceptingWindows: []), configuration: cfg)
    }
}
