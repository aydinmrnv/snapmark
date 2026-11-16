import Cocoa

// Scrolling capture: scroll the content under the selection and stitch the frames into one tall image.
// Snapmark scrolls by itself; if the app ignores synthetic scrolling, it switches to letting you scroll.

@MainActor
final class ScrollCapture {
    static var current: ScrollCapture?

    private let rect: CGRect            // global CG points
    private let screen: NSScreen
    private let scale: CGFloat
    private let target: ScreenGrab.Target
    private let pxRect: CGRect          // crop inside the display grab, in pixels
    private let maxHeight = 30000

    private var stitcher: Stitcher
    private var hud: ScrollHUD?
    private var keyMonitor: Any?
    private var stopped = false
    private var manual = false
    private var savedMouse: CGPoint = .zero

    static func start(rect: CGRect, screen: NSScreen, scale: CGFloat, first: CGImage) {
        guard current == nil else { return }
        let s = ScrollCapture(rect: rect, screen: screen, scale: scale, first: first)
        current = s
        s.run()
    }

    private init(rect: CGRect, screen: NSScreen, scale: CGFloat, first: CGImage) {
        self.rect = rect
        self.screen = screen
        self.scale = scale
        let sf = Geo.cgRect(screen)
        target = ScreenGrab.Target(id: Geo.displayID(screen), pixels: CGSize(width: sf.width * scale, height: sf.height * scale))
        let l = rect.offsetBy(dx: -sf.minX, dy: -sf.minY)
        pxRect = CGRect(x: l.minX * scale, y: l.minY * scale, width: l.width * scale, height: l.height * scale).integral
        stitcher = Stitcher(first: first)
    }

    private func run() {
        savedMouse = Geo.mouse()
        hud = ScrollHUD(near: rect, on: screen) { [weak self] in self?.stop() }
        hud?.update(height: stitcher.height, manual: false)
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if e.keyCode == 53 || e.keyCode == 36 { Task { @MainActor in self?.stop() } }
        }
        Task { await loop() }
    }

    private func grab() async -> CGImage? {
        guard let full = try? await ScreenGrab.grab(target), let crop = full.cropping(to: pxRect) else { return nil }
        return Stitcher.copy(crop)
    }

    private func scrollOnce() {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        CGWarpMouseCursorPosition(center)
        // Scroll about 70% of the visible height so consecutive frames overlap enough to line up.
        let amount = Int32(max(40, rect.height * 0.7))
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: -amount, wheel2: 0, wheel3: 0) {
            e.location = center
            e.post(tap: .cghidEventTap)
        }
    }

    private func loop() async {
        try? await Task.sleep(nanoseconds: 120_000_000)   // let the capture overlay disappear
        var unchanged = 0
        var everMoved = false
        var tries = 0
        while !stopped {
            if manual {
                try? await Task.sleep(nanoseconds: 90_000_000)
            } else {
                scrollOnce()
                try? await Task.sleep(nanoseconds: 220_000_000)
            }
            guard !stopped, let frame = await grab() else { break }
            let added = stitcher.add(frame)
            hud?.update(height: stitcher.height, manual: manual)
            if added > 0 { everMoved = true; unchanged = 0 } else { unchanged += 1 }
            tries += 1
            if stitcher.height >= maxHeight { break }
            if !manual {
                // Nothing moved on the first attempts: this app ignores synthetic scrolling, so hand over to the user.
                if !everMoved && tries >= 2 {
                    manual = true
                    hud?.update(height: stitcher.height, manual: true)
                    continue
                }
                // Reached the bottom (allow one retry for content that loads lazily).
                if everMoved && unchanged >= 2 { break }
            }
        }
        finish()
    }

    private func stop() { stopped = true }

    private func finish() {
        guard ScrollCapture.current === self else { return }
        ScrollCapture.current = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        hud?.close()
        CGWarpMouseCursorPosition(savedMouse)
        guard let img = stitcher.render() else { return }
        ScreenGrab.playShutter()
        let url = Library.shared.newURL()
        let sc = scale
        DispatchQueue.global(qos: .utility).async {
            Renderer.write(img, to: url, type: .png, scale: sc)
            DispatchQueue.main.async { Library.shared.reload() }
        }
        AppDelegate.shared.openEditor(url, preloaded: ImageDoc(base: img, scale: sc))
    }
}

// MARK: - Stitching

/// Lines frames up by comparing per-row fingerprints. Rows that stay put between frames
/// (sticky headers/footers) are detected and kept only once.
struct Stitcher {
    private var rows: [CGImage] = []        // vertical strips of the scrolling middle, in order
    private var top: CGImage?               // fixed header (from the first frame)
    private var bottom: CGImage?            // fixed footer (from the latest frame)
    private var prev: CGImage
    private var prevSig: [UInt64]
    private(set) var width: Int
    private var fixedTop = 0, fixedBottom = 0
    private var bandsKnown = false

    init(first: CGImage) {
        prev = first
        prevSig = Stitcher.signature(first)
        width = first.width
        rows = [first]
    }

    var height: Int { (top?.height ?? 0) + rows.reduce(0) { $0 + $1.height } + (bottom?.height ?? 0) }

    /// Adds a frame; returns how many new rows it contributed.
    mutating func add(_ frame: CGImage) -> Int {
        guard frame.width == width, frame.height == prev.height else { return 0 }
        let sig = Stitcher.signature(frame)
        if sig == prevSig { return 0 }
        let H = sig.count

        if !bandsKnown {
            // Fixed header/footer: leading/trailing rows identical in both frames.
            var t = 0; while t < H / 3, sig[t] == prevSig[t] { t += 1 }
            var b = 0; while b < H / 3, sig[H - 1 - b] == prevSig[H - 1 - b] { b += 1 }
            fixedTop = t; fixedBottom = b
            bandsKnown = true
            // Split the first frame into header / middle / footer.
            if let first = rows.first, rows.count == 1 {
                rows = []
                if t > 0 { top = first.cropping(to: CGRect(x: 0, y: 0, width: width, height: t)) }
                if let mid = first.cropping(to: CGRect(x: 0, y: t, width: width, height: H - t - b)) { rows = [mid] }
            }
        }
        let lo = fixedTop, hi = H - fixedBottom      // moving band [lo, hi)
        let band = hi - lo
        guard band > 8 else { return 0 }

        // Find shift d: frame row (lo + i) == prev row (lo + i + d).
        var bestD = 0, bestScore = 0.0
        let a = Array(prevSig[lo..<hi]), c = Array(sig[lo..<hi])
        for d in 1..<band {
            let overlap = band - d
            if overlap < max(8, band / 8) { break }
            var same = 0
            let step = max(1, overlap / 300)
            var n = 0
            var i = 0
            while i < overlap { if a[i + d] == c[i] { same += 1 }; n += 1; i += step }
            let score = Double(same) / Double(n)
            if score > bestScore { bestScore = score; bestD = d }
        }
        guard bestScore > 0.8, bestD > 0 else { return 0 }

        // New content = the last bestD rows of the moving band.
        guard let strip = frame.cropping(to: CGRect(x: 0, y: hi - bestD, width: width, height: bestD)) else { return 0 }
        rows.append(Stitcher.copy(strip))
        if fixedBottom > 0 { bottom = frame.cropping(to: CGRect(x: 0, y: hi, width: width, height: fixedBottom)).map(Stitcher.copy) }
        prev = frame
        prevSig = sig
        return bestD
    }

    func render() -> CGImage? {
        let parts = [top].compactMap { $0 } + rows + [bottom].compactMap { $0 }
        let H = parts.reduce(0) { $0 + $1.height }
        guard H > 0, let ctx = CGContext(data: nil, width: width, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpaceCreateDeviceRGB(),
                                         bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        var y = H
        for p in parts {
            y -= p.height
            ctx.draw(p, in: CGRect(x: 0, y: y, width: p.width, height: p.height))
        }
        return ctx.makeImage()
    }

    /// One 64-bit fingerprint per row (FNV-1a over every 3rd pixel, ignoring the outer columns where scrollbars live).
    static func signature(_ img: CGImage) -> [UInt64] {
        let w = img.width, h = img.height
        var buf = [UInt32](repeating: 0, count: w * h)
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return [] }
        let margin = min(w / 10, 40)
        var out = [UInt64](repeating: 0, count: h)
        buf.withUnsafeBufferPointer { p in
            for y in 0..<h {
                var hash: UInt64 = 0xcbf29ce484222325
                var x = margin
                let row = y * w
                while x < w - margin {
                    hash = (hash ^ UInt64(p[row + x] & 0x00F0F0F0)) &* 0x100000001b3   // drop low bits: tolerate tiny rendering noise
                    x += 3
                }
                out[y] = hash
            }
        }
        return out
    }

    static func copy(_ img: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return img }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage() ?? img
    }
}

// MARK: - Progress HUD

final class ScrollHUD: NSPanel {
    private let label = NSTextField(labelWithString: "")
    private let onStop: () -> Void

    init(near r: CGRect, on screen: NSScreen, onStop: @escaping () -> Void) {
        self.onStop = onStop
        let size = NSSize(width: 330, height: 44)
        // Below the selection if there's room, otherwise above, otherwise the screen's bottom corner.
        let sf = screen.frame
        let rBottom = Geo.primaryHeight - r.maxY, rTop = Geo.primaryHeight - r.minY
        var origin = NSPoint(x: min(max(sf.minX + 8, r.midX - size.width / 2), sf.maxX - size.width - 8), y: rBottom - size.height - 10)
        if origin.y < sf.minY + 8 { origin.y = rTop + 10 }
        if origin.y + size.height > sf.maxY - 8 { origin = NSPoint(x: sf.maxX - size.width - 16, y: sf.minY + 16) }
        super.init(contentRect: NSRect(origin: origin, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        sharingType = .none          // keep the HUD out of the frames we grab
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let bg = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        bg.material = .hudWindow; bg.state = .active; bg.appearance = NSAppearance(named: .vibrantDark)
        bg.wantsLayer = true; bg.layer?.cornerRadius = 12
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        let stop = NSButton(title: "Done", target: nil, action: nil)
        stop.bezelStyle = .rounded
        stop.bezelColor = accent
        stop.target = self; stop.action = #selector(stopClicked)
        let spin = NSProgressIndicator()
        spin.style = .spinning; spin.controlSize = .small; spin.startAnimation(nil)
        let row = NSStackView(views: [spin, label, stop])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 10)
        row.frame = bg.bounds
        row.autoresizingMask = [.width, .height]
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bg.addSubview(row)
        contentView = bg
        orderFrontRegardless()
    }

    func update(height: Int, manual: Bool) {
        label.stringValue = manual ? "Scroll down yourself · \(height) px" : "Scrolling… \(height) px · Esc to stop"
    }

    @objc private func stopClicked() { onStop() }
}

// MARK: - Self-test (--test-stitch in out): simulate scrolling over a tall image with a sticky header.
enum StitchTest {
    static func run(input: URL, output: URL) {
        guard let src = CGImageSourceCreateWithURL(input as CFURL, nil), let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { print("no input"); return }
        let W = 900, H = 4000, header = 70, view = 900
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let tallCtx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
        tallCtx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
        // Stripes with text so every row is distinctive.
        for i in 0..<(H / 50) {
            tallCtx.setFillColor(CGColor(red: CGFloat(i % 7) / 7, green: 0.3, blue: CGFloat(i % 5) / 5, alpha: 0.35))
            tallCtx.fill(CGRect(x: CGFloat((i * 37) % 600), y: CGFloat(H - i * 50 - 30), width: 260, height: 18))
        }
        let tall = tallCtx.makeImage()!
        func frame(_ off: Int) -> CGImage {
            let c = CGContext(data: nil, width: W, height: view, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: info)!
            // content scrolled by `off`, header fixed on top
            let part = tall.cropping(to: CGRect(x: 0, y: off, width: W, height: view - header))!
            c.draw(part, in: CGRect(x: 0, y: 0, width: W, height: view - header))
            c.setFillColor(CGColor(red: 0.95, green: 0.4, blue: 0.1, alpha: 1)); c.fill(CGRect(x: 0, y: view - header, width: W, height: header))
            c.setFillColor(.white); c.fill(CGRect(x: 20, y: view - header + 20, width: 200, height: 30))
            return c.makeImage()!
        }
        var st = Stitcher(first: frame(0))
        var off = 0
        let maxOff = H - (view - header)
        var steps = 0
        while off < maxOff {
            off = min(off + 613, maxOff)
            _ = st.add(frame(off)); steps += 1
        }
        _ = st.add(frame(maxOff)) // bottom reached: no change
        let out = st.render()!
        let expected = header + H
        print("frames: \(steps + 1)  stitched height: \(out.height)  expected: \(expected)  \(out.height == expected ? "OK" : "MISMATCH")")
        // Pixel check of the content part.
        let a = Stitcher.signature(out.cropping(to: CGRect(x: 0, y: header, width: W, height: out.height - header))!)
        let b = Stitcher.signature(tall)
        print("content rows identical: \(a == b)")
        if let d = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil) { CGImageDestinationAddImage(d, out, nil); CGImageDestinationFinalize(d) }
    }
}
