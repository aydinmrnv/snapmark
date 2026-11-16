import Cocoa
import SwiftUI
import ImageIO

extension Notification.Name { static let libraryChanged = Notification.Name("SnapmarkLibraryChanged") }

final class Library: ObservableObject {
    static let shared = Library()

    @Published var items: [URL] = []
    @Published var delay: Bool = UserDefaults.standard.bool(forKey: "delay") {
        didSet { UserDefaults.standard.set(delay, forKey: "delay") }
    }
    @Published var version = 0   // bumps when files change so thumbnails refresh

    let dir: URL = {
        let pics = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        let d = pics.appendingPathComponent("Snapmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    private var thumbCache: [String: NSImage] = [:]

    func reload() {
        let keys: [URLResourceKey] = [.creationDateKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys,
                                                                   options: [.skipsHiddenFiles])) ?? []
        items = files
            .filter { ["png", "jpg", "jpeg"].contains($0.pathExtension.lowercased()) }
            .sorted { creation($0) > creation($1) }
        version += 1
        NotificationCenter.default.post(name: .libraryChanged, object: nil)
    }

    func creation(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    func modified(_ url: URL) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? .distantPast
    }

    func newURL() -> URL {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        var url = dir.appendingPathComponent("Snap \(f.string(from: Date())).png")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = dir.appendingPathComponent("Snap \(f.string(from: Date())) \(n).png"); n += 1
        }
        return url
    }

    func thumbnail(_ url: URL) -> NSImage? {
        let key = url.path + "\(modified(url).timeIntervalSince1970)"
        if let t = thumbCache[key] { return t }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 520,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        thumbCache[key] = img
        return img
    }

    /// Decode a thumbnail off the main thread; cached results come back immediately.
    func thumbnail(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        let key = url.path + "\(modified(url).timeIntervalSince1970)"
        if let t = thumbCache[key] { completion(t); return }
        DispatchQueue.global(qos: .userInitiated).async {
            var img: NSImage?
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                     kCGImageSourceThumbnailMaxPixelSize: 260,
                                                                     kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary) {
                img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async { if let img { self.thumbCache[key] = img }; completion(img) }
        }
    }

    func pixelSize(_ url: URL) -> String {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { return "" }
        return "\(w) × \(h)"
    }

    func copyToClipboard(_ url: URL) {
        guard let img = NSImage(contentsOf: url) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([img])
    }

    func trash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        reload()
    }
}

// MARK: - SwiftUI library window

struct LibraryView: View {
    @ObservedObject var lib = Library.shared
    @State private var selection: URL?

    var body: some View {
        VStack(spacing: 0) {
            captureBar
            Divider()
            if lib.items.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)], spacing: 18) {
                        ForEach(lib.items, id: \.self) { url in
                            ThumbCell(url: url, selected: selection == url, version: lib.version)
                                .onTapGesture(count: 2) { AppDelegate.shared.openEditor(url) }
                                .simultaneousGesture(TapGesture().onEnded { selection = url })
                                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
                                .contextMenu {
                                    Button("Open in Editor") { AppDelegate.shared.openEditor(url) }
                                    Button("Copy Image") { lib.copyToClipboard(url) }
                                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                    Divider()
                                    Button("Move to Trash") { lib.trash(url) }
                                }
                        }
                    }
                    .padding(20)
                }
                .background(Color(nsColor: .underPageBackgroundColor))
            }
        }
        .frame(minWidth: 620, minHeight: 400)
        .onAppear { lib.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in lib.reload() }
    }

    var captureBar: some View {
        HStack(spacing: 10) {
            CaptureButton(title: "Capture", symbol: "rectangle.dashed", hint: "⌃⇧1") { AppDelegate.shared.capture(.region) }
            CaptureButton(title: "Window", symbol: "macwindow", hint: "⌃⇧2") { AppDelegate.shared.capture(.window) }
            CaptureButton(title: "Full Screen", symbol: "display", hint: "⌃⇧3") { AppDelegate.shared.capture(.fullscreen) }
            Toggle(isOn: $lib.delay) { Label("3s delay", systemImage: "timer") }
                .toggleStyle(.button)
                .padding(.leading, 6)
            Spacer()
            Text("\(lib.items.count) capture\(lib.items.count == 1 ? "" : "s")")
                .foregroundStyle(.secondary)
            Button {
                NSWorkspace.shared.open(lib.dir)
            } label: { Image(systemName: "folder") }
            .help("Open captures folder")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "camera.viewfinder").font(.system(size: 56)).foregroundStyle(.secondary)
            Text("No captures yet").font(.title2.weight(.semibold))
            Text("Press ⌃⇧1 anywhere: hover to snap to a window or panel and click,\nor drag to select any region. ⌃⇧2 captures a window, ⌃⇧3 the full screen.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CaptureButton: View {
    let title: String, symbol: String, hint: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                Text(hint).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
        }
        .controlSize(.large)
    }
}

struct ThumbCell: View {
    let url: URL
    let selected: Bool
    let version: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor))
                if let img = Library.shared.thumbnail(url) {
                    Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(8)
                }
            }
            .frame(height: 150)
            .overlay(RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 3 : 1))
            .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.callout).lineLimit(1).truncationMode(.middle)
            Text(Library.shared.pixelSize(url)).font(.caption).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .id("\(url.path)-\(version)")
    }
}
