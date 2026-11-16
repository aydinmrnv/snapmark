import Cocoa
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

// MARK: - Model

enum Tool: Int, CaseIterable {
    case select, arrow, line, rect, ellipse, pen, highlight, text, callout, step, blur, spotlight, crop,
         magnify, redact, softblur, stamp, eyedropper
    // Not in the toolbar: objects created by capture / paste.
    case cursor = 100, image = 101

    static var toolbar: [Tool] { allCases.filter { $0.rawValue < 100 } }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rect: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .callout: return "text.bubble.fill"
        case .step: return "1.circle.fill"
        case .blur: return "square.grid.3x3.fill"
        case .spotlight: return "flashlight.on.fill"
        case .crop: return "crop"
        case .magnify: return "plus.magnifyingglass"
        case .redact: return "rectangle.fill"
        case .softblur: return "drop.halffull"
        case .stamp: return "face.smiling"
        case .eyedropper: return "eyedropper"
        case .cursor: return "cursorarrow"
        case .image: return "photo"
        }
    }
    var name: String {
        switch self {
        case .select: return "Select"
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rect: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .pen: return "Pen"
        case .highlight: return "Highlighter"
        case .text: return "Text"
        case .callout: return "Callout"
        case .step: return "Step"
        case .blur: return "Pixelate"
        case .spotlight: return "Spotlight"
        case .crop: return "Crop"
        case .magnify: return "Magnify"
        case .redact: return "Redact"
        case .softblur: return "Blur"
        case .stamp: return "Stamp"
        case .eyedropper: return "Color Picker"
        case .cursor: return "Mouse Cursor"
        case .image: return "Image"
        }
    }
    var key: String {
        switch self {
        case .select: return "v"; case .arrow: return "a"; case .line: return "l"; case .rect: return "r"
        case .ellipse: return "e"; case .pen: return "p"; case .highlight: return "h"; case .text: return "t"
        case .callout: return "k"; case .step: return "n"; case .blur: return "x"; case .spotlight: return "s"
        case .crop: return "c"; case .magnify: return "m"; case .redact: return "d"; case .softblur: return "b"
        case .stamp: return "g"; case .eyedropper: return "i"; default: return ""
        }
    }
    var hint: String {
        switch self {
        case .select: return "Click to select · drag to move · drag handles to resize · ⌫ deletes"
        case .arrow, .line: return "Drag to draw · ⇧ snaps to 45° · drag the ends to adjust"
        case .rect, .ellipse: return "Drag to draw · ⇧ for square/circle"
        case .pen: return "Drag to draw freehand"
        case .highlight: return "Drag over an area to highlight it"
        case .text, .callout: return "Click to type · Return to finish · double-click text to edit"
        case .step: return "Click to drop numbered steps"
        case .blur: return "Drag over sensitive info to pixelate it"
        case .spotlight: return "Drag to spotlight an area and dim the rest"
        case .crop: return "Drag the crop area · Return to apply · Esc to cancel"
        case .magnify: return "Drag to place a magnifier · drag its corners to resize"
        case .redact: return "Drag over text to cover it with a solid box"
        case .softblur: return "Drag over an area to blur it"
        case .stamp: return "Click to place the stamp chosen on the right"
        case .eyedropper: return "Click anywhere on the image to pick its color"
        case .cursor, .image: return ""
        }
    }
    /// Tools whose shape is a rectangle defined by a/b corners.
    var isBoxy: Bool { [.rect, .ellipse, .highlight, .blur, .spotlight, .cursor, .image, .magnify, .redact, .softblur].contains(self) }
    var keepsAspect: Bool { self == .cursor || self == .image }
    /// Area tools are only grabbed by their edge while a drawing tool is active, so you can draw on top of them.
    var isArea: Bool { [.highlight, .blur, .spotlight, .softblur, .redact, .magnify].contains(self) }
}

struct Annotation {
    var id = UUID()
    var tool: Tool
    var a: CGPoint
    var b: CGPoint
    var points: [CGPoint] = []
    var color: NSColor
    var width: CGFloat
    var text: String = ""
    var number: Int = 0
    var image: NSImage?

    var rect: CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var font: NSFont { .systemFont(ofSize: 10 + width * 3, weight: .bold) }
    var stepRadius: CGFloat { 10 + width * 2.2 }
    var stampSize: CGFloat { 18 + width * 4 }
    var calloutPad: CGFloat { font.pointSize * 0.55 }

    var calloutBox: CGRect {
        let s = ((text.isEmpty ? " " : text) as NSString).size(withAttributes: [.font: font])
        return CGRect(x: a.x, y: a.y, width: s.width + calloutPad * 2, height: s.height + calloutPad * 1.3)
    }

    var bounds: CGRect {
        switch tool {
        case .pen:
            guard let f = points.first else { return .zero }
            var r = CGRect(origin: f, size: .zero)
            for p in points { r = r.union(CGRect(origin: p, size: .zero)) }
            return r.insetBy(dx: -width, dy: -width)
        case .text:
            let s = (text as NSString).size(withAttributes: [.font: font])
            return CGRect(origin: a, size: s)
        case .callout:
            return calloutBox
        case .step:
            return CGRect(x: a.x - stepRadius, y: a.y - stepRadius, width: stepRadius * 2, height: stepRadius * 2)
        case .stamp:
            let s = stampSize * 1.25
            return CGRect(x: a.x - s / 2, y: a.y - s / 2, width: s, height: s)
        case .cursor, .image:
            return rect
        default:
            return rect.insetBy(dx: -width / 2, dy: -width / 2)
        }
    }

    /// Everything this annotation can paint on (incl. arrowheads and shadows) — used for partial redraws.
    var paintBounds: CGRect {
        let pad: CGFloat
        switch tool {
        case .arrow: pad = max(14, width * 3) + 6
        case .magnify: pad = width + 8
        default: pad = width + 8
        }
        return bounds.insetBy(dx: -pad, dy: -pad)
    }

    /// `loose`: whole-area hit (select tool). Otherwise area tools are only hit on their edge.
    func hit(_ p: CGPoint, loose: Bool = true) -> Bool {
        switch tool {
        case .arrow, .line:
            return distance(p, a, b) <= max(8, width * 1.5)
        case .pen:
            for i in 1..<max(points.count, 1) where distance(p, points[i - 1], points[i]) <= max(8, width) { return true }
            return false
        case .rect, .ellipse, .highlight, .blur, .spotlight, .softblur, .redact, .magnify:
            if loose && tool.isArea { return rect.insetBy(dx: -6, dy: -6).contains(p) }
            let outer = rect.insetBy(dx: -8, dy: -8), inner = rect.insetBy(dx: 8 + width, dy: 8 + width)
            return outer.contains(p) && !(inner.width > 0 && inner.height > 0 && inner.contains(p))
        default:
            return bounds.insetBy(dx: -4, dy: -4).contains(p)
        }
    }

    var handles: [CGPoint] {
        switch tool {
        case .arrow, .line: return [a, b]
        case _ where tool.isBoxy:
            let r = rect
            return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)]
        default: return []
        }
    }

    mutating func offset(_ dx: CGFloat, _ dy: CGFloat) {
        a.x += dx; a.y += dy; b.x += dx; b.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let l2 = dx * dx + dy * dy
    if l2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / l2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

/// The document: a base bitmap (in pixels) plus vector annotations (in points).
final class ImageDoc {
    private(set) var base: CGImage
    let scale: CGFloat
    var items: [Annotation] = []
    var nextStep = 1
    private(set) var baseImage: NSImage
    private var pixCache: [String: NSImage] = [:]
    private let ci = CIContext()

    var size: CGSize { CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale) }

    init(base: CGImage, scale: CGFloat) {
        self.base = base
        self.scale = scale
        self.baseImage = NSImage(cgImage: base, size: CGSize(width: CGFloat(base.width) / scale, height: CGFloat(base.height) / scale))
    }

    convenience init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        var scale: CGFloat = 1
        if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
           let dpi = p[kCGImagePropertyDPIWidth] as? Double, dpi > 72 {
            scale = CGFloat((dpi / 72).rounded())
        }
        self.init(base: cg, scale: max(1, scale))
    }

    func setBase(_ img: CGImage) {
        base = img
        baseImage = NSImage(cgImage: img, size: size)
        pixCache = [:]
        hasAlpha = computeHasAlpha()
    }

    /// Whether the image has transparent pixels (shadow / rounded corners). Screenshots report an alpha
    /// channel even when fully opaque, so sample the corners instead of trusting alphaInfo.
    private(set) lazy var hasAlpha: Bool = computeHasAlpha()

    private func computeHasAlpha() -> Bool {
        switch base.alphaInfo { case .none, .noneSkipFirst, .noneSkipLast: return false; default: break }
        let w = base.width, h = base.height
        for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1), (w / 2, 0), (0, h / 2)] {
            guard let px = base.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { continue }
            var d = [UInt8](repeating: 0, count: 4)
            guard let ctx = CGContext(data: &d, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { continue }
            ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            if d[3] < 250 { return true }
        }
        return false
    }

    /// Gaussian-blurred copy of the base image under `r`.
    func softBlurred(_ r: CGRect) -> NSImage? {
        let r = r.intersection(CGRect(origin: .zero, size: size))
        guard r.width >= 1, r.height >= 1 else { return nil }
        let key = "g\(r)"
        if let c = pixCache[key] { return c }
        let H = CGFloat(base.height)
        let px = CGRect(x: r.minX * scale, y: H - r.maxY * scale, width: r.width * scale, height: r.height * scale).integral
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(CIImage(cgImage: base).clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(10 * scale, forKey: kCIInputRadiusKey)
        guard let out = f.outputImage?.cropped(to: px), let cg = ci.createCGImage(out, from: px) else { return nil }
        let img = NSImage(cgImage: cg, size: r.size)
        if pixCache.count > 64 { pixCache = [:] }
        pixCache[key] = img
        return img
    }

    /// Colour of the base image at a point (top-left point coordinates).
    func color(at p: CGPoint) -> NSColor? {
        let x = Int(p.x * scale), y = Int(p.y * scale)
        guard x >= 0, y >= 0, x < base.width, y < base.height,
              let px = base.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else { return nil }
        var data = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(px, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return NSColor(srgbRed: CGFloat(data[0]) / 255, green: CGFloat(data[1]) / 255, blue: CGFloat(data[2]) / 255, alpha: 1)
    }

    /// Pixelated copy of the base image under `r` (point coordinates, top-left origin).
    func pixelated(_ r: CGRect) -> NSImage? {
        let r = r.intersection(CGRect(origin: .zero, size: size))
        guard r.width >= 1, r.height >= 1 else { return nil }
        let key = "\(r)"
        if let c = pixCache[key] { return c }
        let H = CGFloat(base.height)
        let px = CGRect(x: r.minX * scale, y: H - r.maxY * scale, width: r.width * scale, height: r.height * scale).integral
        let input = CIImage(cgImage: base)
        guard let f = CIFilter(name: "CIPixellate") else { return nil }
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(max(12, 14 * scale), forKey: kCIInputScaleKey)
        f.setValue(CIVector(x: px.minX, y: px.minY), forKey: kCIInputCenterKey)
        guard let out = f.outputImage?.cropped(to: px), let cg = ci.createCGImage(out, from: px) else { return nil }
        let img = NSImage(cgImage: cg, size: r.size)
        if pixCache.count > 64 { pixCache = [:] }
        pixCache[key] = img
        return img
    }
}

// MARK: - Rendering (shared by on-screen canvas and export)

enum Renderer {
    static func drawDocument(_ doc: ImageDoc, extra: Annotation? = nil, skip: UUID? = nil, clip: CGRect? = nil) {
        let rect = CGRect(origin: .zero, size: doc.size)
        doc.baseImage.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                           hints: [.interpolation: NSImageInterpolation.high.rawValue])
        var all = doc.items.filter { $0.id != skip }
        if let e = extra { all.append(e) }
        // Partial redraw: only touch annotations that overlap the dirty area.
        if let c = clip { all = all.filter { $0.tool == .spotlight || $0.paintBounds.intersects(c) } }

        // Pixelation / blur / redaction sit on the image itself, beneath spotlight dimming and other marks.
        for a in all where a.tool == .blur || a.tool == .softblur || a.tool == .redact { draw(a, doc: doc) }

        // Spotlights: one dim layer with every spotlight punched out, drawn beneath other annotations.
        let spots = all.filter { $0.tool == .spotlight }
        if !spots.isEmpty, let cg = NSGraphicsContext.current?.cgContext {
            cg.saveGState()
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
            cg.setFillColor(NSColor.black.withAlphaComponent(0.6).cgColor)
            cg.fill(rect)
            cg.setBlendMode(.clear)
            for s in spots {
                let r = s.rect
                cg.addPath(CGPath(roundedRect: r, cornerWidth: min(10, r.width / 2), cornerHeight: min(10, r.height / 2), transform: nil))
            }
            cg.fillPath()
            cg.endTransparencyLayer()
            cg.restoreGState()
        }
        for a in all where ![.spotlight, .blur, .softblur, .redact].contains(a.tool) { draw(a, doc: doc) }
    }

    static func shadow() -> NSShadow {
        let s = NSShadow()
        s.shadowColor = NSColor.black.withAlphaComponent(0.35)
        s.shadowBlurRadius = 3
        s.shadowOffset = NSSize(width: 0, height: -1)
        return s
    }

    static func contrasting(_ c: NSColor) -> NSColor { c.luminance > 0.7 ? .black : .white }

    static func draw(_ a: Annotation, doc: ImageDoc) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let c = a.color
        switch a.tool {
        case .arrow:
            shadow().set()
            c.setFill()
            arrowPath(from: a.a, to: a.b, width: a.width).fill()
        case .line:
            shadow().set()
            c.setStroke()
            let p = NSBezierPath(); p.move(to: a.a); p.line(to: a.b)
            p.lineWidth = a.width; p.lineCapStyle = .round; p.stroke()
        case .rect:
            shadow().set()
            c.setStroke()
            let p = NSBezierPath(roundedRect: a.rect, xRadius: 3, yRadius: 3)
            p.lineWidth = a.width; p.lineJoinStyle = .round; p.stroke()
        case .ellipse:
            shadow().set()
            c.setStroke()
            let p = NSBezierPath(ovalIn: a.rect); p.lineWidth = a.width; p.stroke()
        case .pen:
            guard a.points.count > 1 else { return }
            shadow().set()
            c.setStroke()
            let p = NSBezierPath(); p.move(to: a.points[0])
            for pt in a.points.dropFirst() { p.line(to: pt) }
            p.lineWidth = a.width; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
        case .highlight:
            c.withAlphaComponent(0.45).setFill()
            a.rect.fill(using: .multiply)
        case .text:
            guard !a.text.isEmpty else { return }
            let s = NSShadow()
            s.shadowColor = (c.brightnessComponentSafe > 0.6 ? NSColor.black : NSColor.white).withAlphaComponent(0.9)
            s.shadowBlurRadius = 3
            s.shadowOffset = .zero
            (a.text as NSString).draw(at: a.a, withAttributes: [.font: a.font, .foregroundColor: c, .shadow: s])
        case .callout:
            let box = a.calloutBox
            shadow().set()
            c.setFill()
            NSBezierPath(roundedRect: box, xRadius: a.calloutPad, yRadius: a.calloutPad).fill()
            NSShadow().set()
            (a.text as NSString).draw(at: CGPoint(x: box.minX + a.calloutPad, y: box.minY + a.calloutPad * 0.65),
                                      withAttributes: [.font: a.font, .foregroundColor: contrasting(c)])
        case .step:
            shadow().set()
            c.setFill()
            let r = a.stepRadius
            NSBezierPath(ovalIn: CGRect(x: a.a.x - r, y: a.a.y - r, width: r * 2, height: r * 2)).fill()
            NSShadow().set()
            let str = "\(a.number)" as NSString
            let f = NSFont.systemFont(ofSize: r * 1.1, weight: .heavy)
            let sz = str.size(withAttributes: [.font: f])
            str.draw(at: CGPoint(x: a.a.x - sz.width / 2, y: a.a.y - sz.height / 2), withAttributes: [.font: f, .foregroundColor: contrasting(c)])
        case .blur:
            if let img = doc.pixelated(a.rect) {
                let r = a.rect.intersection(CGRect(origin: .zero, size: doc.size))
                img.draw(in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .cursor, .image:
            if a.tool == .image { shadow().set() }
            a.image?.draw(in: a.rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                          hints: [.interpolation: NSImageInterpolation.high.rawValue])
        case .softblur:
            if let img = doc.softBlurred(a.rect) {
                let r = a.rect.intersection(CGRect(origin: .zero, size: doc.size))
                img.draw(in: r, from: .zero, operation: .copy, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .redact:
            c.setFill()
            NSBezierPath(roundedRect: a.rect, xRadius: 2, yRadius: 2).fill()
        case .magnify:
            let r = a.rect
            guard r.width > 2, r.height > 2 else { return }
            let z: CGFloat = 2
            shadow().set()
            NSColor.white.setFill(); NSBezierPath(ovalIn: r).fill()
            NSShadow().set()
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: r).addClip()
            let W = doc.size.width, H = doc.size.height
            doc.baseImage.draw(in: CGRect(x: r.midX - r.midX * z, y: r.midY - r.midY * z, width: W * z, height: H * z),
                               from: .zero, operation: .copy, fraction: 1, respectFlipped: true,
                               hints: [.interpolation: NSImageInterpolation.high.rawValue])
            NSGraphicsContext.restoreGraphicsState()
            c.setStroke()
            let ring = NSBezierPath(ovalIn: r); ring.lineWidth = max(2, a.width * 0.8); ring.stroke()
        case .stamp:
            let f = NSFont.systemFont(ofSize: a.stampSize)
            let str = a.text as NSString
            let sz = str.size(withAttributes: [.font: f])
            shadow().set()
            str.draw(at: CGPoint(x: a.a.x - sz.width / 2, y: a.a.y - sz.height / 2), withAttributes: [.font: f])
        case .select, .crop, .spotlight, .eyedropper:
            break
        }
    }

    /// Tapered shaft + filled head.
    static func arrowPath(from a: CGPoint, to b: CGPoint, width w: CGFloat) -> NSBezierPath {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = hypot(dx, dy)
        let p = NSBezierPath()
        guard len > 1 else { return p }
        let ux = dx / len, uy = dy / len, px = -uy, py = ux
        let headLen = min(len * 0.8, max(16, w * 4.2))
        let headW = max(9, w * 2.6)
        let base = CGPoint(x: b.x - ux * headLen, y: b.y - uy * headLen)
        func pt(_ o: CGPoint, _ k: CGFloat) -> CGPoint { CGPoint(x: o.x + px * k, y: o.y + py * k) }
        p.move(to: pt(a, w * 0.2))
        p.line(to: pt(base, w * 0.55))
        p.line(to: pt(base, headW))
        p.line(to: b)
        p.line(to: pt(base, -headW))
        p.line(to: pt(base, -w * 0.55))
        p.line(to: pt(a, -w * 0.2))
        p.close()
        p.lineJoinStyle = .round
        return p
    }

    /// Draw into a new bitmap of `size` points at the document's pixel scale, with a flipped (top-left) context.
    static func bitmap(size: CGSize, scale: CGFloat, _ body: () -> Void) -> CGImage? {
        let pw = max(1, Int((size.width * scale).rounded())), ph = max(1, Int((size.height * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pw, height: ph, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.translateBy(x: 0, y: CGFloat(ph))
        ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        body()
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }

    /// Flatten to a bitmap at full pixel resolution.
    static func flatten(_ doc: ImageDoc) -> CGImage? {
        bitmap(size: doc.size, scale: doc.scale) { drawDocument(doc) }
    }

    @discardableResult
    static func write(_ img: CGImage, to url: URL, type: UTType, scale: CGFloat) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else { return false }
        var props: [CFString: Any] = [kCGImagePropertyDPIWidth: 72 * scale, kCGImagePropertyDPIHeight: 72 * scale]
        var image = img
        if type == .jpeg {
            props[kCGImageDestinationLossyCompressionQuality] = 0.9
            // JPEG has no alpha: composite onto white so transparent shadows don't turn black.
            let size = CGSize(width: CGFloat(img.width) / scale, height: CGFloat(img.height) / scale)
            if let flat = bitmap(size: size, scale: scale, {
                NSColor.white.setFill(); CGRect(origin: .zero, size: size).fill()
                NSImage(cgImage: img, size: size).draw(in: CGRect(origin: .zero, size: size))
            }) { image = flat }
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        return CGImageDestinationFinalize(dest)
    }
}

extension NSColor {
    var brightnessComponentSafe: CGFloat { luminance }
    var luminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 0.5 }
        return 0.299 * c.redComponent + 0.587 * c.greenComponent + 0.114 * c.blueComponent
    }
}

// MARK: - Canvas

final class CanvasView: NSView, NSTextFieldDelegate {
    weak var controller: EditorWindowController?
    let doc: ImageDoc
    var tool: Tool = .arrow {
        didSet {
            if tool != .crop { cropRect = nil }
            window?.invalidateCursorRects(for: self)
            needsDisplay = true
        }
    }
    var color: NSColor = .systemRed
    var strokeWidth: CGFloat = 5
    var draft: Annotation?
    var selected: UUID? { didSet { needsDisplay = true; controller?.updateStatus() } }
    var cropRect: CGRect?

    private enum Drag { case none, draw, move(CGPoint), handle(Int, CGPoint, CGFloat), crop(CGPoint) }
    private var drag: Drag = .none
    private var dragStart: CGPoint = .zero
    private var movedSinceDown = false
    private var textField: NSTextField?
    private var textPoint: CGPoint = .zero
    private var textTool: Tool = .text
    private var editingID: UUID?

    init(doc: ImageDoc) {
        self.doc = doc
        super.init(frame: CGRect(origin: .zero, size: doc.size))
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { !doc.hasAlpha }
    override var wantsDefaultClipping: Bool { true }

    /// Last area painted by an in-progress drag, so each frame only repaints old ∪ new.
    private var lastDirty: CGRect = .null

    /// Repaint just what changed for the annotation being drawn / moved / resized.
    private func invalidateLive(_ a: Annotation?) {
        guard let a else { needsDisplay = true; return }
        if a.tool == .spotlight { needsDisplay = true; lastDirty = .null; return }
        let m = magnification
        var r = a.paintBounds.insetBy(dx: -14 / m, dy: -14 / m)   // selection outline + handles
        if a.tool == .magnify { r = r.insetBy(dx: -a.rect.width, dy: -a.rect.height) }
        setNeedsDisplay(lastDirty.isNull ? r : r.union(lastDirty))
        lastDirty = r
    }

    private static let checker: NSColor = {
        let img = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { r in
            NSColor(white: 0.92, alpha: 1).setFill(); r.fill()
            NSColor(white: 0.84, alpha: 1).setFill()
            CGRect(x: 0, y: 0, width: 10, height: 10).fill(); CGRect(x: 10, y: 10, width: 10, height: 10).fill()
            return true
        }
        return NSColor(patternImage: img)
    }()
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: tool == .select ? .arrow : ([.text, .callout].contains(tool) ? .iBeam : .crosshair))
        if let a = selectedItem {
            for h in a.handles {
                let s = 10 / magnification
                addCursorRect(CGRect(x: h.x - s / 2, y: h.y - s / 2, width: s, height: s), cursor: .pointingHand)
            }
        }
    }

    var selectedIndex: Int? { selected.flatMap { id in doc.items.firstIndex { $0.id == id } } }
    var selectedItem: Annotation? { selectedIndex.map { doc.items[$0] } }
    var magnification: CGFloat { max(enclosingScrollView?.magnification ?? 1, 0.01) }

    override func draw(_ dirtyRect: NSRect) {
        // Checkerboard only matters where the image is transparent (e.g. after adding a drop shadow).
        if doc.hasAlpha { CanvasView.checker.setFill(); dirtyRect.intersection(bounds).fill() }

        let partial = dirtyRect.width * dirtyRect.height < bounds.width * bounds.height * 0.9
        Renderer.drawDocument(doc, extra: draft, skip: editingID, clip: partial ? dirtyRect : nil)

        if let a = selectedItem {
            let m = magnification
            let r = a.bounds.insetBy(dx: -4, dy: -4)
            let p = NSBezierPath(rect: r)
            p.lineWidth = 1.5 / m
            p.setLineDash([5 / m, 4 / m], count: 2, phase: 0)
            NSColor.white.setStroke(); p.stroke()
            p.setLineDash([5 / m, 4 / m], count: 2, phase: 4.5 / m)
            NSColor.systemBlue.setStroke(); p.stroke()
            for h in a.handles {
                let s = 9 / m
                let hr = CGRect(x: h.x - s / 2, y: h.y - s / 2, width: s, height: s)
                NSColor.white.setFill(); NSBezierPath(ovalIn: hr).fill()
                let ring = NSBezierPath(ovalIn: hr); ring.lineWidth = 1.5 / m
                NSColor.systemBlue.setStroke(); ring.stroke()
            }
        }

        if let c = cropRect {
            let m = magnification
            let dim = NSBezierPath(rect: bounds)
            dim.append(NSBezierPath(rect: c))
            dim.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.5).setFill()
            dim.fill()
            let border = NSBezierPath(rect: c)
            border.lineWidth = 1.5 / m
            border.setLineDash([6 / m, 4 / m], count: 2, phase: 0)
            NSColor.white.setStroke(); border.stroke()
            let label = "\(Int(c.width * doc.scale)) × \(Int(c.height * doc.scale))" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 12 / m, weight: .semibold),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.7),
            ]
            label.draw(at: CGPoint(x: c.minX + 4 / m, y: c.minY + 4 / m), withAttributes: attrs)
        }
    }

    private func point(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: min(max(p.x, 0), bounds.width), y: min(max(p.y, 0), bounds.height))
    }

    private func constrained(_ start: CGPoint, _ p: CGPoint, shift: Bool, tool: Tool) -> CGPoint {
        guard shift else { return p }
        let dx = p.x - start.x, dy = p.y - start.y
        switch tool {
        case .arrow, .line:
            let angle = (atan2(dy, dx) / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: start.x + cos(angle) * len, y: start.y + sin(angle) * len)
        case .rect, .ellipse, .highlight, .blur, .crop, .spotlight, .magnify, .redact, .softblur:
            let s = max(abs(dx), abs(dy))
            return CGPoint(x: start.x + (dx < 0 ? -s : s), y: start.y + (dy < 0 ? -s : s))
        default: return p
        }
    }

    private func handleIndex(at p: CGPoint) -> Int? {
        guard let a = selectedItem else { return nil }
        let r = 8 / magnification
        return a.handles.firstIndex { hypot($0.x - p.x, $0.y - p.y) <= r }
    }

    override func mouseDown(with e: NSEvent) {
        if textField != nil { commitText(); return }
        window?.makeFirstResponder(self)
        let p = point(e)
        movedSinceDown = false
        dragStart = p
        drag = .none

        // 1. Handles of the selected object (any tool).
        if let h = handleIndex(at: p), let a = selectedItem {
            lastDirty = a.paintBounds
            if a.tool.isBoxy {
                let corners = a.handles
                let r = a.rect
                drag = .handle(h, corners[3 - h], r.height > 0 ? r.width / r.height : 1)
            } else {
                drag = .handle(h, .zero, 1)
            }
            return
        }

        // 2. Grab an existing object to move it (select tool: any; drawing tools: same kind of object).
        let loose = tool == .select
        if tool != .crop, tool != .eyedropper, let hit = doc.items.last(where: { $0.hit(p, loose: loose) }),
           loose || hit.tool == tool || hit.id == selected || [.cursor, .image].contains(hit.tool) {
            if [.text, .callout].contains(hit.tool), e.clickCount == 2 || ([.text, .callout].contains(tool) && hit.tool == tool) {
                editText(hit); return
            }
            if ![.step, .stamp].contains(tool) || hit.tool == tool {
                selected = hit.id
                lastDirty = hit.paintBounds
                drag = .move(p)
                window?.invalidateCursorRects(for: self)
                return
            }
        }

        switch tool {
        case .select:
            selected = nil
        case .text, .callout:
            beginText(at: p, tool: tool)
        case .step:
            controller?.pushUndo()
            var a = Annotation(tool: .step, a: p, b: p, color: color, width: strokeWidth)
            a.number = doc.nextStep
            doc.nextStep += 1
            doc.items.append(a)
            selected = a.id
        case .stamp:
            controller?.pushUndo()
            var a = Annotation(tool: .stamp, a: p, b: p, color: color, width: strokeWidth)
            a.text = controller?.currentStamp ?? "✅"
            doc.items.append(a)
            selected = a.id
        case .eyedropper:
            if let c = doc.color(at: p) { controller?.pickedColor(c) }
            return
        case .crop:
            cropRect = CGRect(origin: p, size: .zero)
            drag = .crop(p)
        default:
            selected = nil
            draft = Annotation(tool: tool, a: p, b: p, points: [p], color: color, width: strokeWidth)
            lastDirty = .null
            drag = .draw
        }
        needsDisplay = true
    }

    override func mouseDragged(with e: NSEvent) {
        let raw = point(e)
        let shift = e.modifierFlags.contains(.shift)
        switch drag {
        case .none: return
        case .move(let o):
            guard let i = selectedIndex else { return }
            if !movedSinceDown { controller?.pushUndo(); movedSinceDown = true }
            doc.items[i].offset(raw.x - o.x, raw.y - o.y)
            drag = .move(raw)
        case .handle(let h, let fixed, let ratio):
            guard let i = selectedIndex else { return }
            if !movedSinceDown { controller?.pushUndo(); movedSinceDown = true }
            var a = doc.items[i]
            if a.tool.isBoxy {
                var q = raw
                if a.tool.keepsAspect != shift { // aspect-locked for images/cursor; ⇧ toggles
                    let dx = raw.x - fixed.x, dy = raw.y - fixed.y
                    let w = max(abs(dx), abs(dy) * ratio)
                    q = CGPoint(x: fixed.x + (dx < 0 ? -w : w), y: fixed.y + (dy < 0 ? -1 : 1) * w / ratio)
                }
                a.a = fixed; a.b = q
            } else if h == 0 {
                a.a = constrained(a.b, raw, shift: shift, tool: a.tool)
            } else {
                a.b = constrained(a.a, raw, shift: shift, tool: a.tool)
            }
            doc.items[i] = a
        case .crop(let s):
            let p = constrained(s, raw, shift: shift, tool: .crop)
            cropRect = CGRect(x: min(s.x, p.x), y: min(s.y, p.y), width: abs(p.x - s.x), height: abs(p.y - s.y))
            controller?.updateStatus()
        case .draw:
            guard let d = draft else { return }
            draft?.b = constrained(d.a, raw, shift: shift, tool: d.tool)
            if d.tool == .pen { draft?.points.append(raw) }
        }
        // Only repaint what moved this frame.
        switch drag {
        case .draw: invalidateLive(draft)
        case .move, .handle: invalidateLive(selectedItem)
        default: needsDisplay = true
        }
    }

    override func mouseUp(with e: NSEvent) {
        if case .draw = drag, let d = draft {
            let big = d.tool == .pen ? d.points.count > 2 : (d.rect.width > 3 || d.rect.height > 3)
            let area = d.rect.width > 3 && d.rect.height > 3
            let needsArea = [.highlight, .blur, .rect, .ellipse, .spotlight, .magnify, .redact, .softblur].contains(d.tool)
            if big && (!needsArea || area) {
                controller?.pushUndo()
                doc.items.append(d)
                selected = d.id
            }
            draft = nil
        }
        if case .handle = drag, let i = selectedIndex, doc.items[i].tool.isBoxy {
            let r = doc.items[i].rect
            doc.items[i].a = r.origin
            doc.items[i].b = CGPoint(x: r.maxX, y: r.maxY)
        }
        if case .crop = drag, let c = cropRect, c.width < 3 || c.height < 3 { cropRect = nil }
        drag = .none
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
        controller?.updateStatus()
    }

    override func keyDown(with e: NSEvent) {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.shift, .capsLock, .numericPad, .function])
        switch e.keyCode {
        case 51, 117: deleteSelected(); return
        case 36, 76:
            if cropRect != nil { controller?.applyCrop() }
            else if let a = selectedItem, [.text, .callout].contains(a.tool) { editText(a) }
            return
        case 53:
            if cropRect != nil { cropRect = nil } else { selected = nil }
            needsDisplay = true; return
        case 123, 124, 125, 126:
            if let i = selectedIndex {
                let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
                let d: (CGFloat, CGFloat) = [123: (-step, 0), 124: (step, 0), 125: (0, step), 126: (0, -step)][e.keyCode]!
                controller?.pushUndo()
                doc.items[i].offset(d.0, d.1); needsDisplay = true
            }
            return
        default: break
        }
        if mods.isEmpty, let ch = e.charactersIgnoringModifiers?.lowercased(),
           let t = Tool.toolbar.first(where: { $0.key == ch }) {
            controller?.setTool(t); return
        }
        super.keyDown(with: e)
    }

    func deleteSelected() {
        guard let id = selected else { return }
        controller?.pushUndo()
        doc.items.removeAll { $0.id == id }
        selected = nil
        controller?.updateStatus()
    }

    // MARK: Paste images as movable objects

    @objc func paste(_ sender: Any?) {
        guard let img = NSImage(pasteboard: NSPasteboard.general) else { NSSound.beep(); return }
        addImage(img, at: nil)
    }

    func addImage(_ img: NSImage, at center: CGPoint?) {
        var s = img.size
        let maxS = CGSize(width: doc.size.width * 0.6, height: doc.size.height * 0.6)
        let k = min(1, maxS.width / max(s.width, 1), maxS.height / max(s.height, 1))
        s = CGSize(width: s.width * k, height: s.height * k)
        let c = center ?? CGPoint(x: doc.size.width / 2, y: doc.size.height / 2)
        var a = Annotation(tool: .image, a: CGPoint(x: c.x - s.width / 2, y: c.y - s.height / 2),
                           b: CGPoint(x: c.x + s.width / 2, y: c.y + s.height / 2), color: .black, width: 1)
        a.image = img
        controller?.pushUndo()
        doc.items.append(a)
        selected = a.id
        controller?.setTool(.select)
    }

    // MARK: Text editing

    private func beginText(at p: CGPoint, tool t: Tool, existing: Annotation? = nil) {
        textTool = t
        let w = existing?.width ?? strokeWidth
        let font = NSFont.systemFont(ofSize: 10 + w * 3, weight: .bold)
        let pad: CGFloat = t == .callout ? font.pointSize * 0.55 : 0
        let tf = NSTextField(frame: NSRect(x: p.x + pad - 2, y: p.y + pad * 0.65 - 1, width: 160, height: ceil(font.pointSize * 1.3) + 2))
        tf.font = font
        let c = existing?.color ?? color
        tf.textColor = t == .callout ? Renderer.contrasting(c) : c
        tf.backgroundColor = t == .callout ? c : NSColor.white.withAlphaComponent(0.85)
        tf.stringValue = existing?.text ?? ""
        tf.placeholderString = "Type here"
        tf.isBordered = false
        tf.drawsBackground = true
        tf.focusRingType = .none
        tf.delegate = self
        tf.cell?.isScrollable = true
        textPoint = p
        textField = tf
        addSubview(tf)
        resizeField(tf)
        window?.makeFirstResponder(tf)
    }

    private func editText(_ a: Annotation) {
        editingID = a.id
        selected = nil
        beginText(at: a.a, tool: a.tool, existing: a)
        needsDisplay = true
    }

    private func resizeField(_ tf: NSTextField) {
        let s = (tf.stringValue.isEmpty ? "Type here" : tf.stringValue) as NSString
        let w = s.size(withAttributes: [.font: tf.font!]).width + 24
        tf.setFrameSize(NSSize(width: max(80, w), height: tf.frame.height))
    }

    func controlTextDidChange(_ obj: Notification) {
        if let tf = textField { resizeField(tf) }
    }

    func controlTextDidEndEditing(_ obj: Notification) { commitText() }

    func commitText() {
        guard let tf = textField else { return }
        textField = nil
        let text = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        tf.removeFromSuperview()
        if let id = editingID, let i = doc.items.firstIndex(where: { $0.id == id }) {
            controller?.pushUndo()
            if text.isEmpty { doc.items.remove(at: i) } else { doc.items[i].text = text; selected = id }
        } else if !text.isEmpty {
            controller?.pushUndo()
            var a = Annotation(tool: textTool, a: textPoint, b: textPoint, color: color, width: strokeWidth)
            a.text = text
            doc.items.append(a)
            selected = a.id
        }
        editingID = nil
        window?.makeFirstResponder(self)
        needsDisplay = true
    }
}

/// Keeps the canvas centred when it's smaller than the viewport.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let dv = documentView else { return r }
        if r.width > dv.frame.width { r.origin.x = (dv.frame.width - r.width) / 2 }
        if r.height > dv.frame.height { r.origin.y = (dv.frame.height - r.height) / 2 }
        return r
    }
}

final class SwatchButton: NSButton {
    let swatch: NSColor
    var isCurrent = false { didSet { needsDisplay = true } }
    init(color: NSColor, target: AnyObject, action: Selector) {
        swatch = color
        super.init(frame: NSRect(x: 0, y: 0, width: 22, height: 22))
        self.target = target; self.action = action
        isBordered = false; title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 22).isActive = true
        heightAnchor.constraint(equalToConstant: 22).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 4, dy: 4)
        swatch.setFill(); NSBezierPath(ovalIn: r).fill()
        NSColor.separatorColor.setStroke(); NSBezierPath(ovalIn: r).stroke()
        if isCurrent {
            let ring = NSBezierPath(ovalIn: bounds.insetBy(dx: 1, dy: 1)); ring.lineWidth = 2
            NSColor.controlAccentColor.setStroke(); ring.stroke()
        }
    }
}

/// Drag this into Slack, Mail, Finder, a browser upload field… to drop the finished image.
final class DragWell: NSView, NSDraggingSource {
    weak var controller: EditorWindowController?

    override init(frame: NSRect) {
        super.init(frame: frame)
        toolTip = "Drag the finished image into any app"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let p = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        p.setLineDash([3, 2], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.12).setFill(); p.fill()
        NSColor.controlAccentColor.setStroke(); p.stroke()
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: NSColor.controlAccentColor]
        if let img = NSImage(systemSymbolName: "hand.draw.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .semibold).applying(.init(paletteColors: [.controlAccentColor]))) {
            img.draw(in: CGRect(x: 8, y: (bounds.height - img.size.height) / 2, width: img.size.width, height: img.size.height))
        }
        ("Drag" as NSString).draw(at: CGPoint(x: 26, y: (bounds.height - 14) / 2), withAttributes: attrs)
    }

    override func mouseDown(with e: NSEvent) {
        guard let url = controller?.fileForDrag() else { return }
        let thumb = NSImage(contentsOf: url) ?? NSImage()
        let s = thumb.size
        let k = 120 / max(s.width, s.height, 1)
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let origin = convert(e.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: origin.x - s.width * k / 2, y: origin.y - s.height * k / 2, width: s.width * k, height: s.height * k), contents: thumb)
        beginDraggingSession(with: [item], event: e, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

// MARK: - Editor chrome widgets

/// Big icon-over-label tool button used in the top bar. Drawn by hand so every icon sits in the
/// same fixed box and every label on the same baseline, whatever the symbol's own proportions.
final class ToolButton: NSButton {
    let tool: Tool
    var label: String { didSet { needsDisplay = true } }
    var symbol: NSImage? { didSet { needsDisplay = true } }
    var isCurrent = false { didSet { needsDisplay = true } }
    private var hovering = false { didSet { needsDisplay = true } }

    static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
    }

    init(tool: Tool, label: String, target: AnyObject, action: Selector) {
        self.tool = tool
        self.label = label
        self.symbol = ToolButton.symbolImage(tool.symbol)
        super.init(frame: .zero)
        self.target = target; self.action = action
        title = ""
        isBordered = false
        setAccessibilityLabel(label)
        toolTip = "\(tool.name)  (\(tool.key.uppercased()))"
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 58).isActive = true
        heightAnchor.constraint(equalToConstant: 50).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 8, yRadius: 8)
        if isCurrent {
            NSColor.controlAccentColor.withAlphaComponent(0.2).setFill(); bg.fill()
        } else if hovering {
            NSColor.labelColor.withAlphaComponent(0.07).setFill(); bg.fill()
        }
        let tint: NSColor = isCurrent ? .controlAccentColor : .labelColor

        // Icon: scaled to fit a fixed 22×20 box, centred at a fixed height.
        let box = CGRect(x: bounds.midX - 11, y: 7, width: 22, height: 20)
        if let sym = symbol {
            let s = sym.size
            let k = min(box.width / max(s.width, 1), box.height / max(s.height, 1), 1)
            let d = CGSize(width: s.width * k, height: s.height * k)
            let r = CGRect(x: box.midX - d.width / 2, y: box.midY - d.height / 2, width: d.width, height: d.height)
            let tinted = NSImage(size: s, flipped: false) { rr in
                sym.draw(in: rr); tint.set(); rr.fill(using: .sourceAtop); return true
            }
            tinted.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }

        // Label: one shared baseline for all buttons.
        let font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: tint]
        let str = label as NSString
        let w = str.size(withAttributes: attrs).width
        str.draw(at: CGPoint(x: bounds.midX - w / 2, y: 31), withAttributes: attrs)
    }
}

/// One-click style preset; draws a sample of the current tool in that style.
final class StyleTile: NSButton {
    let style: (NSColor, CGFloat)
    var isCurrent = false { didSet { needsDisplay = true } }
    private let sample: NSImage

    init(tool: Tool, color: NSColor, width: CGFloat, target: AnyObject, action: Selector) {
        style = (color, width)
        sample = StyleTile.render(tool: tool, color: color, width: width)
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false; title = ""
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 64).isActive = true
        heightAnchor.constraint(equalToConstant: 46).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let bg = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        NSColor(white: 0.5, alpha: 0.12).setFill(); bg.fill()
        sample.draw(in: r)
        if isCurrent {
            bg.lineWidth = 2; NSColor.controlAccentColor.setStroke(); bg.stroke()
        }
    }

    private static let dummy = ImageDoc(base: {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }(), scale: 1)

    static func render(tool: Tool, color: NSColor, width: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: 60, height: 42), flipped: true) { _ in
            let w = width <= 3 ? 2 : (width <= 5 ? 3.2 : 4.6)   // thin / medium / thick, scaled to fit the tile
            var a = Annotation(tool: tool, a: CGPoint(x: 10, y: 33), b: CGPoint(x: 50, y: 9), color: color, width: w)
            switch tool {
            case .rect, .ellipse, .highlight, .redact: a.a = CGPoint(x: 12, y: 10); a.b = CGPoint(x: 48, y: 32)
            case .magnify: a.a = CGPoint(x: 17, y: 8); a.b = CGPoint(x: 43, y: 34)
            case .pen: a.points = (0...20).map { i in CGPoint(x: 10 + CGFloat(i) * 2, y: 21 + sin(CGFloat(i) / 3) * 9) }
            case .text: a.text = "Aa"; a.width = 4; a.a = CGPoint(x: 16, y: 8)
            case .callout: a.text = "Text"; a.width = 2; a.a = CGPoint(x: 9, y: 9)
            case .step: a.number = 1; a.width = 3; a.a = CGPoint(x: 30, y: 21)
            default: break
            }
            Renderer.draw(a, doc: dummy)
            return true
        }
    }
}

/// Thumbnail strip of recent captures along the bottom of the editor.
final class TrayItem: NSButton {
    let fileURL: URL
    var isCurrent = false { didSet { needsDisplay = true } }
    init(url: URL, target: AnyObject, action: Selector) {
        fileURL = url
        super.init(frame: .zero)
        self.target = target; self.action = action
        isBordered = false; title = ""
        image = Library.shared.thumbnail(url)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = url.deletingPathExtension().lastPathComponent
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 96).isActive = true
        heightAnchor.constraint(equalToConstant: 64).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let bg = NSBezierPath(roundedRect: r, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill(); bg.fill()
        NSGraphicsContext.saveGraphicsState()
        bg.addClip()
        if let img = image {
            let s = img.size, k = min((r.width - 8) / max(s.width, 1), (r.height - 8) / max(s.height, 1))
            let d = CGSize(width: s.width * k, height: s.height * k)
            img.draw(in: CGRect(x: r.midX - d.width / 2, y: r.midY - d.height / 2, width: d.width, height: d.height))
        }
        NSGraphicsContext.restoreGraphicsState()
        bg.lineWidth = isCurrent ? 2.5 : 1
        (isCurrent ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        bg.stroke()
    }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

// MARK: - Editor window (single window; captures load into it)

struct Snapshot { let base: CGImage; let items: [Annotation]; let nextStep: Int }

final class EditorWindowController: NSWindowController, NSWindowDelegate {
    private(set) var url: URL!
    private(set) var doc: ImageDoc!
    var canvas: CanvasView!
    var scroll: NSScrollView!
    var toolButtons: [ToolButton] = []
    var moreButton: ToolButton!
    var currentStamp = "✅"
    private var toolBeforePicker: Tool = .arrow
    static let moreTools: [Tool] = [.line, .ellipse, .pen, .blur, .spotlight, .eyedropper]
    static let stamps = ["✅", "❌", "⚠️", "⭐️", "👉", "👍", "👎", "❗️", "❓", "💡", "🔥", "🎯", "🐞", "🚀", "👀", "📌", "🔒", "💬"]
    var colorWell: NSColorWell!
    var swatches: [SwatchButton] = []
    var widthSlider: NSSlider!
    var widthLabel: NSTextField!
    var status: NSTextField!
    var zoomLabel: NSTextField!
    var cropButton: NSButton!
    var cursorButton: NSButton!
    var shareButton: NSButton!
    var stylesGrid: NSStackView!
    var stylesTitle: NSTextField!
    var trayStack: NSStackView!
    var undoStack: [Snapshot] = []
    var redoStack: [Snapshot] = []
    var dirty = false
    var onClose: (() -> Void)?
    private var flash: String?
    private var cursorBackup: Annotation?
    private var trayObserver: Any?
    private var currentTool: Tool = .arrow
    private var currentColor: NSColor = .systemRed
    private var currentWidth: CGFloat = 5

    init?(url: URL, extras: [Annotation] = [], preloaded: ImageDoc? = nil) {
        guard preloaded != nil || ImageDoc(url: url) != nil else { return nil }
        let vf = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: min(1380, vf.width * 0.94), height: min(900, vf.height * 0.94)),
                           styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                           backing: .buffered, defer: false)
        win.titlebarAppearsTransparent = true
        win.titleVisibility = .hidden
        win.minSize = NSSize(width: 1180, height: 620)
        win.isReleasedWhenClosed = false
        win.center()
        super.init(window: win)
        win.delegate = self
        let initial = win.frame
        buildUI()
        win.setFrame(initial, display: false)
        if !win.setFrameUsingName("SnapmarkEditor") { win.center() }
        win.setFrameAutosaveName("SnapmarkEditor")
        load(url: url, extras: extras, preloaded: preloaded)
        trayObserver = NotificationCenter.default.addObserver(forName: .libraryChanged, object: nil, queue: .main) { [weak self] _ in self?.rebuildTray() }
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Loading

    /// Show a capture in this window (saving whatever was open before).
    func load(url newURL: URL, extras: [Annotation] = [], preloaded: ImageDoc? = nil) {
        if url == newURL, extras.isEmpty, preloaded == nil { return }
        if url != nil { canvas.commitText(); if dirty { save() } }
        guard let d = preloaded ?? ImageDoc(url: newURL) else { NSSound.beep(); return }
        d.items.append(contentsOf: extras)
        url = newURL
        doc = d
        cursorBackup = extras.first { $0.tool == .cursor }
        undoStack.removeAll(); redoStack.removeAll()
        dirty = !extras.isEmpty

        canvas = CanvasView(doc: d)
        canvas.controller = self
        canvas.tool = currentTool
        canvas.color = currentColor
        canvas.strokeWidth = currentWidth
        scroll.documentView = canvas
        window?.title = newURL.deletingPathExtension().lastPathComponent
        window?.representedURL = newURL
        cursorButton.isHidden = cursorBackup == nil
        rebuildTray()
        setTool(currentTool)
        DispatchQueue.main.async { self.zoomFit(nil) }
    }

    // MARK: UI

    private func buildUI() {
        guard let win = window else { return }
        let content = NSView()
        win.contentView = content

        // ── Top bar ────────────────────────────────────────────────
        let top = NSVisualEffectView()
        top.material = .titlebar; top.blendingMode = .withinWindow
        top.translatesAutoresizingMaskIntoConstraints = false

        let captureB = NSButton(title: "Capture", image: NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)!,
                                target: self, action: #selector(newCapture(_:)))
        captureB.imagePosition = .imageLeading
        captureB.bezelStyle = .rounded
        captureB.controlSize = .large
        captureB.bezelColor = NSColor(red: 0.9, green: 0.22, blue: 0.2, alpha: 1)
        captureB.contentTintColor = .white
        captureB.toolTip = "New capture (⌃⇧1)"

        let libraryB = NSButton(title: "Library", image: NSImage(systemSymbolName: "square.grid.2x2", accessibilityDescription: nil)!,
                                target: self, action: #selector(openLibrary(_:)))
        libraryB.imagePosition = .imageLeading
        libraryB.bezelStyle = .rounded
        libraryB.controlSize = .large

        let order: [Tool] = [.select, .arrow, .text, .callout, .rect, .step, .highlight, .softblur, .redact, .magnify, .stamp, .crop]
        toolButtons = order.map { ToolButton(tool: $0, label: EditorWindowController.shortLabel($0), target: self, action: #selector(toolClicked(_:))) }
        moreButton = ToolButton(tool: .line, label: "More", target: self, action: #selector(showMoreTools(_:)))
        moreButton.symbol = ToolButton.symbolImage("ellipsis.circle")
        moreButton.toolTip = "Line, Ellipse, Pen, Pixelate, Spotlight, Color Picker"
        let tools = NSStackView(views: toolButtons + [moreButton])
        tools.spacing = 2

        let drag = DragWell(frame: .zero)
        drag.controller = self

        let undoB = iconButton("arrow.uturn.backward", #selector(undoEdit(_:)), "Undo (⌘Z)")
        let redoB = iconButton("arrow.uturn.forward", #selector(redoEdit(_:)), "Redo (⇧⌘Z)")

        let copyB = NSButton(title: "Copy All", image: NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)!,
                             target: self, action: #selector(copy(_:)))
        copyB.imagePosition = .imageLeading; copyB.bezelStyle = .rounded; copyB.controlSize = .large
        copyB.toolTip = "Copy the finished image (⌘C)"

        shareButton = NSButton(title: "Share", image: NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)!,
                               target: self, action: #selector(showShareMenu(_:)))
        shareButton.imagePosition = .imageLeading; shareButton.bezelStyle = .rounded; shareButton.controlSize = .large
        shareButton.bezelColor = .controlAccentColor
        shareButton.contentTintColor = .white

        let leftGroup = NSStackView(views: [captureB, libraryB]); leftGroup.spacing = 6
        let textB = iconButton("text.viewfinder", #selector(grabText(_:)), "Grab Text: copy all text in the image (⇧⌘T)")
        let pinB = iconButton("pin", #selector(pinToScreen(_:)), "Pin: float this image above all windows (⇧⌘P)")
        let rightGroup = NSStackView(views: [undoB, redoB, textB, pinB, drag, copyB, shareButton]); rightGroup.spacing = 6
        let s1 = NSView(), s2 = NSView()
        s1.setContentHuggingPriority(.init(1), for: .horizontal)
        s2.setContentHuggingPriority(.init(1), for: .horizontal)
        let topRow = NSStackView(views: [leftGroup, s1, tools, s2, rightGroup])
        topRow.spacing = 8
        topRow.edgeInsets = NSEdgeInsets(top: 0, left: 80, bottom: 0, right: 14) // leave room for traffic lights
        topRow.translatesAutoresizingMaskIntoConstraints = false
        top.addSubview(topRow)

        // ── Canvas ─────────────────────────────────────────────────
        scroll = NSScrollView()
        scroll.contentView = CenteringClipView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.05
        scroll.maxMagnification = 8
        scroll.backgroundColor = NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.13, alpha: 1) : NSColor(white: 0.88, alpha: 1) }
        scroll.drawsBackground = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(self, selector: #selector(magChanged), name: NSScrollView.didEndLiveMagnifyNotification, object: scroll)

        // ── Properties sidebar ─────────────────────────────────────
        let side = NSVisualEffectView()
        side.material = .sidebar; side.blendingMode = .withinWindow
        side.translatesAutoresizingMaskIntoConstraints = false

        stylesTitle = sectionLabel("QUICK STYLES")
        stylesGrid = NSStackView(); stylesGrid.orientation = .vertical; stylesGrid.alignment = .leading; stylesGrid.spacing = 2

        let palette: [NSColor] = [.systemRed, .systemOrange, .systemYellow, .systemGreen, .systemBlue, .systemPurple, .systemPink, .black, .white]
        swatches = palette.map { SwatchButton(color: $0, target: self, action: #selector(swatchClicked(_:))) }
        colorWell = NSColorWell(style: .minimal)
        colorWell.target = self; colorWell.action = #selector(colorWellChanged(_:))
        let swRow1 = NSStackView(views: Array(swatches[0..<5])); swRow1.spacing = 2
        let swRow2 = NSStackView(views: Array(swatches[5...]) + [colorWell]); swRow2.spacing = 2

        widthSlider = NSSlider(value: 5, minValue: 1, maxValue: 20, target: self, action: #selector(widthChanged(_:)))
        widthSlider.translatesAutoresizingMaskIntoConstraints = false
        widthSlider.widthAnchor.constraint(equalToConstant: 150).isActive = true
        widthLabel = NSTextField(labelWithString: "5")
        widthLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let widthRow = NSStackView(views: [widthSlider, widthLabel]); widthRow.spacing = 8

        cropButton = NSButton(title: "Apply Crop", image: NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)!,
                              target: self, action: #selector(applyCropAction(_:)))
        cropButton.imagePosition = .imageLeading; cropButton.bezelStyle = .rounded
        cropButton.isHidden = true

        cursorButton = NSButton(checkboxWithTitle: "Show mouse cursor", target: self, action: #selector(toggleCursor(_:)))
        cursorButton.toolTip = "The captured pointer is a separate object: drag it, resize it, or remove it"

        func fx(_ title: String, _ sym: String, _ sel: Selector, _ tag: Int = 0) -> NSButton {
            let b = NSButton(title: title, image: NSImage(systemSymbolName: sym, accessibilityDescription: nil)!, target: self, action: sel)
            b.imagePosition = .imageLeading; b.bezelStyle = .rounded; b.controlSize = .small; b.tag = tag
            b.alignment = .left
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 98).isActive = true
            return b
        }
        let fxGrid = NSGridView(views: [
            [fx("Border", "square", #selector(fxBorder(_:))), fx("Shadow", "shadow", #selector(fxShadow(_:)))],
            [fx("Corners", "app", #selector(fxRound(_:))), fx("Flatten", "square.stack.3d.down.right", #selector(fxFlatten(_:)))],
            [fx("Rotate ⟲", "rotate.left", #selector(fxRotateBtn(_:)), 0), fx("Rotate ⟳", "rotate.right", #selector(fxRotateBtn(_:)), 1)],
            [fx("Flip ↔", "arrow.left.and.right.righttriangle.left.righttriangle.right", #selector(fxFlipBtn(_:)), 0),
             fx("Flip ↕", "arrow.up.and.down.righttriangle.up.righttriangle.down", #selector(fxFlipBtn(_:)), 1)],
            [fx("50%", "minus.magnifyingglass", #selector(fxResizeBtn(_:)), 50), fx("200%", "plus.magnifyingglass", #selector(fxResizeBtn(_:)), 200)],
            [fx("Backdrop", "photo.artframe", #selector(fxBackdrop(_:))), fx("Grab Text", "text.viewfinder", #selector(grabText(_:)))],
        ])
        fxGrid.rowSpacing = 4; fxGrid.columnSpacing = 6

        let sideStack = NSStackView(views: [
            stylesTitle, stylesGrid,
            divider(), sectionLabel("COLOR"), swRow1, swRow2,
            sectionLabel("THICKNESS / SIZE"), widthRow,
            cropButton, cursorButton,
            divider(), sectionLabel("IMAGE EFFECTS"), fxGrid,
        ])
        sideStack.orientation = .vertical
        sideStack.alignment = .leading
        sideStack.spacing = 8
        sideStack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        sideStack.setCustomSpacing(4, after: stylesTitle)
        let sideScroll = NSScrollView()
        sideScroll.drawsBackground = false
        sideScroll.hasVerticalScroller = true
        sideScroll.autohidesScrollers = true
        let sideDoc = FlippedView()
        sideDoc.translatesAutoresizingMaskIntoConstraints = false
        sideStack.translatesAutoresizingMaskIntoConstraints = false
        sideDoc.addSubview(sideStack)
        sideScroll.documentView = sideDoc
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        side.addSubview(sideScroll)

        // ── Status strip + recent tray ─────────────────────────────
        status = NSTextField(labelWithString: "")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        zoomLabel = NSTextField(labelWithString: "100%")
        zoomLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        zoomLabel.alignment = .center
        zoomLabel.widthAnchor.constraint(equalToConstant: 44).isActive = true
        let zOut = iconButton("minus.magnifyingglass", #selector(zoomOut(_:)), "Zoom out (⌘−)", small: true)
        let zIn = iconButton("plus.magnifyingglass", #selector(zoomIn(_:)), "Zoom in (⌘+)", small: true)
        let zFit = NSButton(title: "Fit", target: self, action: #selector(zoomFit(_:))); zFit.controlSize = .small; zFit.bezelStyle = .rounded
        let z100 = NSButton(title: "100%", target: self, action: #selector(zoomActual(_:))); z100.controlSize = .small; z100.bezelStyle = .rounded
        let s3 = NSView(); s3.setContentHuggingPriority(.init(1), for: .horizontal)
        let statusRow = NSStackView(views: [status, s3, zFit, z100, zOut, zoomLabel, zIn])
        statusRow.spacing = 6
        statusRow.edgeInsets = NSEdgeInsets(top: 4, left: 12, bottom: 4, right: 12)
        statusRow.translatesAutoresizingMaskIntoConstraints = false

        let statusBG = NSVisualEffectView()
        statusBG.material = .titlebar; statusBG.blendingMode = .withinWindow
        statusBG.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(statusBG)

        let tray = NSVisualEffectView()
        tray.material = .underWindowBackground; tray.blendingMode = .withinWindow
        tray.translatesAutoresizingMaskIntoConstraints = false
        trayStack = NSStackView(); trayStack.spacing = 6
        trayStack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        trayStack.translatesAutoresizingMaskIntoConstraints = false
        let trayScroll = NSScrollView()
        trayScroll.drawsBackground = false
        trayScroll.hasHorizontalScroller = true
        trayScroll.autohidesScrollers = true
        trayScroll.horizontalScrollElasticity = .allowed
        trayScroll.verticalScrollElasticity = .none
        let trayDoc = FlippedView()
        trayDoc.translatesAutoresizingMaskIntoConstraints = false
        trayDoc.addSubview(trayStack)
        trayScroll.documentView = trayDoc
        trayScroll.translatesAutoresizingMaskIntoConstraints = false
        tray.addSubview(trayScroll)

        let lines = (0..<4).map { _ -> NSBox in let b = NSBox(); b.boxType = .separator; b.translatesAutoresizingMaskIntoConstraints = false; return b }
        for v in [top, scroll!, side, statusRow, tray] + lines as [NSView] { content.addSubview(v) }
        statusRow.removeFromSuperview(); content.addSubview(statusRow, positioned: .above, relativeTo: nil)

        let sideW: CGFloat = 248
        NSLayoutConstraint.activate([
            top.topAnchor.constraint(equalTo: content.topAnchor),
            top.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            top.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            top.heightAnchor.constraint(equalToConstant: 64),
            topRow.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            topRow.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            topRow.centerYAnchor.constraint(equalTo: top.centerYAnchor, constant: 2),

            lines[0].topAnchor.constraint(equalTo: top.bottomAnchor),
            lines[0].leadingAnchor.constraint(equalTo: content.leadingAnchor),
            lines[0].trailingAnchor.constraint(equalTo: content.trailingAnchor),

            scroll.topAnchor.constraint(equalTo: lines[0].bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: lines[1].leadingAnchor),
            scroll.bottomAnchor.constraint(equalTo: lines[2].topAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),

            lines[1].topAnchor.constraint(equalTo: lines[0].bottomAnchor),
            lines[1].bottomAnchor.constraint(equalTo: lines[2].topAnchor),
            lines[1].trailingAnchor.constraint(equalTo: side.leadingAnchor),
            lines[1].widthAnchor.constraint(equalToConstant: 1),

            side.topAnchor.constraint(equalTo: lines[0].bottomAnchor),
            side.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            side.bottomAnchor.constraint(equalTo: lines[2].topAnchor),
            side.widthAnchor.constraint(equalToConstant: sideW),
            sideScroll.topAnchor.constraint(equalTo: side.topAnchor),
            sideScroll.leadingAnchor.constraint(equalTo: side.leadingAnchor),
            sideScroll.trailingAnchor.constraint(equalTo: side.trailingAnchor),
            sideScroll.bottomAnchor.constraint(equalTo: side.bottomAnchor),
            sideDoc.widthAnchor.constraint(equalToConstant: sideW),
            sideStack.topAnchor.constraint(equalTo: sideDoc.topAnchor),
            sideStack.leadingAnchor.constraint(equalTo: sideDoc.leadingAnchor),
            sideStack.trailingAnchor.constraint(equalTo: sideDoc.trailingAnchor),
            sideStack.bottomAnchor.constraint(equalTo: sideDoc.bottomAnchor),

            lines[2].leadingAnchor.constraint(equalTo: content.leadingAnchor),
            lines[2].trailingAnchor.constraint(equalTo: content.trailingAnchor),
            lines[2].bottomAnchor.constraint(equalTo: statusRow.topAnchor),

            statusRow.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusRow.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusRow.bottomAnchor.constraint(equalTo: lines[3].topAnchor),
            statusRow.heightAnchor.constraint(equalToConstant: 30),
            statusBG.topAnchor.constraint(equalTo: statusRow.topAnchor),
            statusBG.bottomAnchor.constraint(equalTo: statusRow.bottomAnchor),
            statusBG.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBG.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            lines[3].leadingAnchor.constraint(equalTo: content.leadingAnchor),
            lines[3].trailingAnchor.constraint(equalTo: content.trailingAnchor),
            lines[3].bottomAnchor.constraint(equalTo: tray.topAnchor),

            tray.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tray.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tray.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            tray.heightAnchor.constraint(equalToConstant: 84),
            trayScroll.topAnchor.constraint(equalTo: tray.topAnchor),
            trayScroll.leadingAnchor.constraint(equalTo: tray.leadingAnchor),
            trayScroll.trailingAnchor.constraint(equalTo: tray.trailingAnchor),
            trayScroll.bottomAnchor.constraint(equalTo: tray.bottomAnchor),
            trayDoc.heightAnchor.constraint(equalTo: trayScroll.heightAnchor),
            trayStack.topAnchor.constraint(equalTo: trayDoc.topAnchor),
            trayStack.leadingAnchor.constraint(equalTo: trayDoc.leadingAnchor),
            trayStack.trailingAnchor.constraint(equalTo: trayDoc.trailingAnchor),
            trayStack.bottomAnchor.constraint(equalTo: trayDoc.bottomAnchor),
        ])
    }

    private func iconButton(_ sym: String, _ sel: Selector, _ tip: String, small: Bool = false) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: sym, accessibilityDescription: tip)!, target: self, action: sel)
        b.bezelStyle = .rounded
        b.controlSize = small ? .small : .large
        b.toolTip = tip
        return b
    }

    private func sectionLabel(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: 10, weight: .semibold)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func divider() -> NSView {
        let b = NSBox(); b.boxType = .separator
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 220).isActive = true
        return b
    }

    // MARK: Quick styles

    private func presets(for t: Tool) -> [(NSColor, CGFloat)] {
        switch t {
        case .highlight:
            return [.systemYellow, .systemGreen, .systemPink, .systemBlue, .systemOrange, .systemPurple].map { ($0, 5) }
        case .text, .callout, .step:
            return [(.systemRed, 5), (.systemBlue, 5), (.black, 5), (.systemOrange, 5), (.systemGreen, 5), (.white, 5),
                    (.systemRed, 3), (.systemBlue, 9), (.black, 9)]
        case .redact:
            return [(.black, 5), (.white, 5), (.darkGray, 5)]
        case .magnify:
            return [(.white, 5), (.black, 5), (.systemRed, 5), (.systemBlue, 5), (.systemOrange, 5), (.systemGreen, 5)]
        case .arrow, .line, .rect, .ellipse, .pen:
            return [(.systemRed, 5), (.systemOrange, 5), (.systemYellow, 5), (.systemGreen, 5), (.systemBlue, 5), (.systemPurple, 5),
                    (.black, 3), (.white, 5), (.systemRed, 3), (.systemRed, 9), (.systemBlue, 9), (.black, 9)]
        default:
            return []
        }
    }

    private func rebuildStyles() {
        stylesGrid.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if currentTool == .stamp {
            stylesTitle.stringValue = "STAMPS"
            stylesTitle.isHidden = false; stylesGrid.isHidden = false
            var row: [NSView] = []
            for e in EditorWindowController.stamps {
                let b = NSButton(title: e, target: self, action: #selector(stampPicked(_:)))
                b.font = .systemFont(ofSize: 22)
                b.bezelStyle = .regularSquare
                b.isBordered = e == currentStamp
                b.translatesAutoresizingMaskIntoConstraints = false
                b.widthAnchor.constraint(equalToConstant: 34).isActive = true
                b.heightAnchor.constraint(equalToConstant: 34).isActive = true
                row.append(b)
                if row.count == 6 { let r = NSStackView(views: row); r.spacing = 1; stylesGrid.addArrangedSubview(r); row = [] }
            }
            if !row.isEmpty { let r = NSStackView(views: row); r.spacing = 1; stylesGrid.addArrangedSubview(r) }
            return
        }
        stylesTitle.stringValue = "QUICK STYLES"
        let ps = presets(for: currentTool)
        stylesTitle.isHidden = ps.isEmpty
        stylesGrid.isHidden = ps.isEmpty
        var row: [NSView] = []
        for (c, w) in ps {
            let t = StyleTile(tool: currentTool, color: c, width: w, target: self, action: #selector(styleClicked(_:)))
            t.isCurrent = c == currentColor && w == currentWidth
            row.append(t)
            if row.count == 3 { let r = NSStackView(views: row); r.spacing = 2; stylesGrid.addArrangedSubview(r); row = [] }
        }
        if !row.isEmpty { let r = NSStackView(views: row); r.spacing = 2; stylesGrid.addArrangedSubview(r) }
    }

    private func refreshStyleHighlight() {
        for case let r as NSStackView in stylesGrid.arrangedSubviews {
            for case let t as StyleTile in r.arrangedSubviews { t.isCurrent = t.style.0 == currentColor && t.style.1 == currentWidth }
        }
    }

    // MARK: Tray

    func rebuildTray() {
        guard trayStack != nil else { return }
        trayStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for u in Library.shared.items.prefix(60) {
            let item = TrayItem(url: u, target: self, action: #selector(trayClicked(_:)))
            item.isCurrent = u == url
            trayStack.addArrangedSubview(item)
        }
    }

    @objc func trayClicked(_ s: TrayItem) { load(url: s.fileURL) }

    // MARK: State

    func setTool(_ t: Tool) {
        canvas.commitText()
        currentTool = t
        canvas.tool = t
        for b in toolButtons { b.isCurrent = b.tool == t }
        if EditorWindowController.moreTools.contains(t) {
            moreButton.isCurrent = true
            moreButton.symbol = ToolButton.symbolImage(t.symbol)
            moreButton.label = EditorWindowController.shortLabel(t)
        } else {
            moreButton.isCurrent = false
            moreButton.symbol = ToolButton.symbolImage("ellipsis.circle")
            moreButton.label = "More"
        }
        if t != .eyedropper { toolBeforePicker = t }
        cropButton.isHidden = t != .crop
        rebuildStyles()
        updateStatus()
    }

    func setColor(_ c: NSColor) {
        currentColor = c
        canvas.color = c
        colorWell.color = c
        for s in swatches { s.isCurrent = s.swatch == c }
        refreshStyleHighlight()
        modifySelected { $0.color = c }
    }

    func setWidth(_ w: CGFloat) {
        currentWidth = w
        canvas.strokeWidth = w
        widthSlider.doubleValue = Double(w)
        widthLabel.stringValue = "\(Int(w))"
        refreshStyleHighlight()
        modifySelected { $0.width = w }
    }

    func modifySelected(_ f: (inout Annotation) -> Void) {
        guard let i = canvas.selectedIndex, ![.cursor, .image].contains(doc.items[i].tool) else { return }
        pushUndo()
        f(&doc.items[i])
        canvas.needsDisplay = true
    }

    func updateStatus() {
        guard status != nil, doc != nil else { return }
        var parts = ["\(doc.base.width) × \(doc.base.height) px"]
        if let a = canvas.selectedItem { parts.append("Selected: \(a.tool.name) — drag to move, handles to resize, ⌫ to delete") }
        else { parts.append(canvas.tool.hint) }
        if let f = flash { parts.insert(f, at: 0) }
        status.stringValue = parts.joined(separator: "   ·   ")
        zoomLabel.stringValue = "\(Int((scroll.magnification * 100).rounded()))%"
        cursorButton?.state = doc.items.contains { $0.tool == .cursor } ? .on : .off
    }

    private func showFlash(_ s: String) {
        flash = "✓ " + s
        updateStatus()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.flash = nil; self?.updateStatus() }
    }

    func pushUndo() {
        undoStack.append(Snapshot(base: doc.base, items: doc.items, nextStep: doc.nextStep))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
        dirty = true
    }

    private func restore(_ s: Snapshot) {
        if s.base !== doc.base { doc.setBase(s.base); canvas.setFrameSize(doc.size) }
        doc.items = s.items
        doc.nextStep = s.nextStep
        canvas.selected = nil
        canvas.needsDisplay = true
        dirty = true
        updateStatus()
    }

    /// Replace the base image; annotations shift by `offset`. If `flatten`, annotations are burned in first.
    private func rebase(_ name: String, size: CGSize, offset: CGPoint = .zero, flatten: Bool = false, draw: (NSImage) -> Void) {
        canvas.commitText()
        let source: NSImage
        if flatten {
            guard let f = Renderer.flatten(doc) else { return }
            source = NSImage(cgImage: f, size: doc.size)
        } else { source = doc.baseImage }
        guard let img = Renderer.bitmap(size: size, scale: doc.scale, { draw(source) }) else { return }
        pushUndo()
        if flatten { doc.items = [] }
        doc.setBase(img)
        for i in doc.items.indices { doc.items[i].offset(offset.x, offset.y) }
        canvas.selected = nil
        canvas.setFrameSize(doc.size)
        canvas.needsDisplay = true
        zoomFit(nil)
        showFlash(name)
    }

    private func transformPixels(_ name: String, _ make: (Int, Int) -> (Int, Int, CGAffineTransform)) {
        canvas.commitText()
        guard let f = Renderer.flatten(doc) else { return }
        let (w, h, t) = make(f.width, f.height)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return }
        ctx.concatenate(t)
        ctx.draw(f, in: CGRect(x: 0, y: 0, width: f.width, height: f.height))
        guard let out = ctx.makeImage() else { return }
        pushUndo()
        doc.items = []
        doc.setBase(out)
        canvas.selected = nil
        canvas.setFrameSize(doc.size)
        canvas.needsDisplay = true
        zoomFit(nil)
        showFlash(name)
    }

    func applyCrop() {
        guard let r0 = canvas.cropRect else { return }
        let r = r0.intersection(CGRect(origin: .zero, size: doc.size))
        guard r.width >= 4, r.height >= 4 else { return }
        let px = CGRect(x: r.minX * doc.scale, y: r.minY * doc.scale, width: r.width * doc.scale, height: r.height * doc.scale).integral
        guard let cropped = doc.base.cropping(to: px) else { return }
        pushUndo()
        let ox = px.minX / doc.scale, oy = px.minY / doc.scale
        doc.setBase(cropped)
        for i in doc.items.indices { doc.items[i].offset(-ox, -oy) }
        canvas.cropRect = nil
        canvas.setFrameSize(doc.size)
        setTool(.arrow)
        zoomFit(nil)
    }

    // MARK: Actions

    @objc func toolClicked(_ s: ToolButton) { setTool(s.tool); window?.makeFirstResponder(canvas) }
    @objc func styleClicked(_ s: StyleTile) { setColor(s.style.0); setWidth(s.style.1); window?.makeFirstResponder(canvas) }
    @objc func swatchClicked(_ s: SwatchButton) { setColor(s.swatch) }
    @objc func colorWellChanged(_ s: NSColorWell) { setColor(s.color) }
    @objc func widthChanged(_ s: NSSlider) {
        let w = CGFloat(s.doubleValue.rounded())
        // Coalesce a slider drag into one undo step.
        if canvas.selectedIndex != nil, NSApp.currentEvent?.type == .leftMouseDragged {
            currentWidth = w; canvas.strokeWidth = w; widthLabel.stringValue = "\(Int(w))"
            if let i = canvas.selectedIndex { doc.items[i].width = w; canvas.needsDisplay = true }
            refreshStyleHighlight()
        } else {
            setWidth(w)
        }
    }
    @objc func applyCropAction(_ s: Any?) { applyCrop() }

    static func shortLabel(_ t: Tool) -> String {
        switch t {
        case .select: return "Move"; case .rect: return "Shape"; case .highlight: return "Highlight"
        case .eyedropper: return "Picker"; case .blur: return "Pixelate"
        default: return t.name
        }
    }

    @objc func showMoreTools(_ s: ToolButton) {
        let m = NSMenu()
        for t in EditorWindowController.moreTools {
            let it = NSMenuItem(title: "\(t.name)", action: #selector(moreToolPicked(_:)), keyEquivalent: t.key)
            it.keyEquivalentModifierMask = []
            it.target = self
            it.tag = t.rawValue
            it.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
            it.state = t == currentTool ? .on : .off
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: s.bounds.height + 2), in: s)
    }

    @objc func moreToolPicked(_ s: NSMenuItem) {
        if let t = Tool(rawValue: s.tag) { setTool(t); window?.makeFirstResponder(canvas) }
    }

    @objc func stampPicked(_ s: NSButton) {
        currentStamp = s.title
        rebuildStyles()
        if let i = canvas.selectedIndex, doc.items[i].tool == .stamp {
            pushUndo(); doc.items[i].text = s.title; canvas.needsDisplay = true
        }
        window?.makeFirstResponder(canvas)
    }

    func pickedColor(_ c: NSColor) {
        setColor(c)
        showFlash("Picked color")
        setTool(toolBeforePicker == .eyedropper ? .arrow : toolBeforePicker)
    }

    /// OCR the image (without annotations) and put the text on the clipboard.
    @objc func grabText(_ s: Any?) {
        showFlash("Reading text…")
        TextGrabber.recognize(doc.base) { [weak self] text in
            guard let self else { return }
            if text.isEmpty { self.showFlash("No text found"); return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let n = text.split(separator: "\n").count
            self.showFlash("Copied \(n) line\(n == 1 ? "" : "s") of text")
        }
    }

    @objc func pinToScreen(_ s: Any?) {
        canvas.commitText()
        guard let cg = Renderer.flatten(doc) else { return }
        PinWindow.show(NSImage(cgImage: cg, size: doc.size))
    }

    @objc func fxBackdrop(_ s: Any?) {
        let pad = max(48, min(doc.size.width, doc.size.height) * 0.08)
        let size = CGSize(width: doc.size.width + pad * 2, height: doc.size.height + pad * 2)
        let scale = doc.scale
        let c = currentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let c1 = c.blended(withFraction: 0.35, of: .white) ?? c
        let c2 = c.blended(withFraction: 0.35, of: .black) ?? c
        rebase("Backdrop added", size: size, offset: CGPoint(x: pad, y: pad)) { img in
            NSGradient(starting: c1, ending: c2)?.draw(in: CGRect(origin: .zero, size: size), angle: 60)
            let r = CGRect(x: pad, y: pad, width: img.size.width, height: img.size.height)
            let rr = NSBezierPath(roundedRect: r, xRadius: 12, yRadius: 12)
            NSGraphicsContext.saveGraphicsState()
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.4)
            sh.shadowBlurRadius = 26 * scale
            sh.shadowOffset = NSSize(width: 0, height: -10 * scale)
            sh.set()
            NSColor.white.setFill(); rr.fill()
            NSGraphicsContext.restoreGraphicsState()
            rr.addClip()
            img.draw(in: r)
        }
    }

    @objc func newCapture(_ s: Any?) { AppDelegate.shared.capture(.region) }
    @objc func openLibrary(_ s: Any?) { AppDelegate.shared.showLibrary() }

    @objc func toggleCursor(_ s: NSButton) {
        pushUndo()
        if let i = doc.items.firstIndex(where: { $0.tool == .cursor }) {
            cursorBackup = doc.items[i]
            doc.items.remove(at: i)
            if canvas.selected == cursorBackup?.id { canvas.selected = nil }
        } else if let c = cursorBackup {
            doc.items.append(c)
        }
        canvas.needsDisplay = true
        updateStatus()
    }

    @objc func pasteImage(_ s: Any?) { canvas.paste(s) }

    @objc func showShareMenu(_ s: NSButton) {
        let m = NSMenu()
        for (t, sym, sel) in [("Copy to Clipboard", "doc.on.doc", #selector(copy(_:))),
                              ("Save as PNG…", "photo", #selector(exportPNG(_:))),
                              ("Save as JPEG…", "photo.on.rectangle", #selector(exportJPEG(_:))),
                              ("Save to Desktop", "menubar.dock.rectangle", #selector(saveToDesktop(_:))),
                              ("Show in Finder", "folder", #selector(revealInFinder(_:))),
                              ("More (AirDrop, Mail, Messages…)", "square.and.arrow.up", #selector(share(_:)))] {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: "")
            it.target = self
            it.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)
            m.addItem(it)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: s.bounds.height + 4), in: s)
    }

    @objc func fxBorder(_ s: Any?) {
        let b = max(2, canvas.strokeWidth)
        let size = CGSize(width: doc.size.width + b * 2, height: doc.size.height + b * 2)
        let c = canvas.color
        rebase("Border added", size: size, offset: CGPoint(x: b, y: b)) { img in
            c.setFill(); CGRect(origin: .zero, size: size).fill()
            img.draw(in: CGRect(x: b, y: b, width: img.size.width, height: img.size.height))
        }
    }

    @objc func fxShadow(_ s: Any?) {
        let pad: CGFloat = 36
        let size = CGSize(width: doc.size.width + pad * 2, height: doc.size.height + pad * 2)
        let scale = doc.scale
        rebase("Drop shadow added", size: size, offset: CGPoint(x: pad, y: pad * 0.7)) { img in
            let sh = NSShadow()
            sh.shadowColor = NSColor.black.withAlphaComponent(0.45)
            sh.shadowBlurRadius = 22 * scale
            sh.shadowOffset = NSSize(width: 0, height: -8 * scale)
            sh.set()
            img.draw(in: CGRect(x: pad, y: pad * 0.7, width: img.size.width, height: img.size.height))
        }
    }

    @objc func fxRound(_ s: Any?) {
        let size = doc.size
        rebase("Corners rounded", size: size) { img in
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 14, yRadius: 14).addClip()
            img.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    @objc func fxResizeBtn(_ s: NSButton) { resize(percent: s.tag) }
    @objc func fxResize(_ s: NSMenuItem) { resize(percent: s.tag) }
    private func resize(percent: Int) {
        let k = CGFloat(percent) / 100
        let size = CGSize(width: (doc.size.width * k).rounded(), height: (doc.size.height * k).rounded())
        rebase("Resized to \(percent)%", size: size, flatten: true) { img in img.draw(in: CGRect(origin: .zero, size: size)) }
    }

    @objc func fxRotateBtn(_ s: NSButton) { rotate(right: s.tag == 1) }
    private func rotate(right: Bool) {
        transformPixels(right ? "Rotated right" : "Rotated left") { w, h in
            let W = CGFloat(w), H = CGFloat(h)
            let t = right ? CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: W)
                          : CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: H, ty: 0)
            return (h, w, t)
        }
    }

    @objc func fxFlipBtn(_ s: NSButton) {
        let vertical = s.tag == 1
        transformPixels(vertical ? "Flipped vertically" : "Flipped horizontally") { w, h in
            let t = vertical ? CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(h))
                             : CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(w), ty: 0)
            return (w, h, t)
        }
    }

    @objc func fxFlatten(_ s: Any?) {
        rebase("Annotations flattened", size: doc.size, flatten: true) { img in img.draw(in: CGRect(origin: .zero, size: img.size)) }
    }

    @objc func undoEdit(_ s: Any?) {
        canvas.commitText()
        guard let last = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(Snapshot(base: doc.base, items: doc.items, nextStep: doc.nextStep))
        restore(last)
    }

    @objc func redoEdit(_ s: Any?) {
        guard let next = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(Snapshot(base: doc.base, items: doc.items, nextStep: doc.nextStep))
        restore(next)
    }

    @objc func deleteSelected(_ s: Any?) { canvas.deleteSelected() }

    @objc func copy(_ s: Any?) {
        canvas.commitText()
        guard let cg = Renderer.flatten(doc) else { return }
        let img = NSImage(cgImage: cg, size: doc.size)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
        showFlash("Copied to clipboard")
    }

    @discardableResult
    func save() -> Bool {
        canvas.commitText()
        guard let cg = Renderer.flatten(doc) else { return false }
        let ok = Renderer.write(cg, to: url, type: .png, scale: doc.scale)
        if ok { dirty = false; Library.shared.reload() }
        return ok
    }

    func fileForDrag() -> URL? { save() ? url : nil }

    @objc func saveDocument(_ s: Any?) { if save() { showFlash("Saved to library") } }

    @objc func exportDocument(_ s: Any?) { export(type: .png) }
    @objc func exportPNG(_ s: Any?) { export(type: .png) }
    @objc func exportJPEG(_ s: Any?) { export(type: .jpeg) }

    private func export(type: UTType) {
        canvas.commitText()
        guard let win = window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + (type == .jpeg ? ".jpg" : ".png")
        panel.isExtensionHidden = false
        panel.beginSheetModal(for: win) { [weak self] resp in
            guard resp == .OK, let self, let dest = panel.url, let cg = Renderer.flatten(self.doc) else { return }
            if Renderer.write(cg, to: dest, type: type, scale: self.doc.scale) { self.showFlash("Exported \(dest.lastPathComponent)") }
        }
    }

    @objc func saveToDesktop(_ s: Any?) {
        canvas.commitText()
        guard let desk = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first,
              let cg = Renderer.flatten(doc) else { return }
        var dest = desk.appendingPathComponent(url.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = desk.appendingPathComponent(url.deletingPathExtension().lastPathComponent + " \(n).png"); n += 1
        }
        if Renderer.write(cg, to: dest, type: .png, scale: doc.scale) { showFlash("Saved to Desktop") }
    }

    @objc func revealInFinder(_ s: Any?) {
        if save() { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func share(_ s: Any?) {
        guard save() else { return }
        NSSharingServicePicker(items: [url]).show(relativeTo: shareButton.bounds, of: shareButton, preferredEdge: .minY)
    }

    // MARK: Zoom

    @objc func magChanged() { updateStatus(); canvas.needsDisplay = true; window?.invalidateCursorRects(for: canvas) }

    private func setZoom(_ m: CGFloat) {
        scroll.magnification = min(max(m, scroll.minMagnification), scroll.maxMagnification)
        magChanged()
    }
    @objc func zoomIn(_ s: Any?) { setZoom(scroll.magnification * 1.25) }
    @objc func zoomOut(_ s: Any?) { setZoom(scroll.magnification / 1.25) }
    @objc func zoomActual(_ s: Any?) { setZoom(1) }
    @objc func zoomFit(_ s: Any?) {
        window?.contentView?.layoutSubtreeIfNeeded()
        let avail = scroll.contentSize
        let m = min(1, min((avail.width - 48) / doc.size.width, (avail.height - 48) / doc.size.height))
        setZoom(m)
    }

    // MARK: Window

    func windowWillClose(_ notification: Notification) {
        canvas.commitText()
        if dirty { save() }
        NotificationCenter.default.removeObserver(self)
        if let o = trayObserver { NotificationCenter.default.removeObserver(o) }
        onClose?()
    }
}

// MARK: - Self test (renders one of every annotation; used to verify drawing headlessly)

enum SelfTest {
    static func run(input: URL, output: URL) {
        guard let doc = ImageDoc(url: input) else { print("cannot load \(input.path)"); return }
        let W = doc.size.width, H = doc.size.height
        func P(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * W, y: y * H) }
        doc.items = [
            Annotation(tool: .spotlight, a: P(0.03, 0.27), b: P(0.65, 0.6), color: .black, width: 5),
            Annotation(tool: .highlight, a: P(0.05, 0.08), b: P(0.45, 0.16), color: .systemYellow, width: 5),
            Annotation(tool: .blur, a: P(0.55, 0.05), b: P(0.95, 0.25), color: .systemRed, width: 5),
            Annotation(tool: .rect, a: P(0.05, 0.3), b: P(0.35, 0.55), color: .systemRed, width: 5),
            Annotation(tool: .ellipse, a: P(0.4, 0.3), b: P(0.6, 0.55), color: .systemBlue, width: 5),
            Annotation(tool: .arrow, a: P(0.9, 0.9), b: P(0.66, 0.42), color: .systemRed, width: 5),
            Annotation(tool: .line, a: P(0.05, 0.62), b: P(0.4, 0.62), color: .systemGreen, width: 3),
            Annotation(tool: .pen, a: .zero, b: .zero, points: (0..<40).map { i in P(0.05 + CGFloat(i) * 0.008, 0.75 + sin(CGFloat(i) / 4) * 0.04) }, color: .systemPurple, width: 5),
        ]
        var t = Annotation(tool: .text, a: P(0.45, 0.66), b: .zero, color: .systemRed, width: 5); t.text = "Click here!"
        var c = Annotation(tool: .callout, a: P(0.45, 0.74), b: .zero, color: .systemBlue, width: 5); c.text = "This is a callout"
        doc.items += [t, c]
        doc.items.append(Annotation(tool: .softblur, a: P(0.72, 0.30), b: P(0.95, 0.42), color: .black, width: 5))
        doc.items.append(Annotation(tool: .redact, a: P(0.05, 0.03), b: P(0.30, 0.06), color: .black, width: 5))
        doc.items.append(Annotation(tool: .magnify, a: P(0.70, 0.48), b: P(0.88, 0.66), color: .white, width: 5))
        var st = Annotation(tool: .stamp, a: P(0.62, 0.92), b: .zero, color: .black, width: 5); st.text = "✅"
        doc.items.append(st)
        let cur = NSCursor.arrow
        var k = Annotation(tool: .cursor, a: P(0.7, 0.7), b: CGPoint(x: P(0.7, 0.7).x + cur.image.size.width * 2, y: P(0.7, 0.7).y + cur.image.size.height * 2), color: .black, width: 1)
        k.image = cur.image
        doc.items.append(k)
        for n in 1...3 {
            var s = Annotation(tool: .step, a: P(0.1 * CGFloat(n), 0.92), b: .zero, color: .systemOrange, width: 5); s.number = n
            doc.items.append(s)
        }
        guard let cg = Renderer.flatten(doc) else { print("flatten failed"); return }
        print(Renderer.write(cg, to: output, type: .png, scale: doc.scale) ? "ok \(cg.width)x\(cg.height)" : "write failed")
    }
}
