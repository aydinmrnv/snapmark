import Cocoa
import Carbon
import SwiftUI

enum CaptureMode { case region, window, fullscreen }

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var shared: AppDelegate!
    var statusItem: NSStatusItem!
    var libraryWindow: NSWindow?
    var editor: EditorWindowController?
    var editorHiddenForCapture = false
    var hotKeyRefs: [EventHotKeyRef?] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        let args = CommandLine.arguments

        if let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count {
            AppIcon.writePNG(to: URL(fileURLWithPath: args[i + 1]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--test-stitch"), i + 2 < args.count {
            StitchTest.run(input: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2]))
            exit(0)
        }
        if let i = args.firstIndex(of: "--selftest"), i + 2 < args.count {
            SelfTest.run(input: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2]))
            exit(0)
        }

        buildMainMenu()
        buildStatusItem()
        registerHotKeys()
        Library.shared.reload()
        ScreenGrab.prewarm()
        prewarmEditor(after: 0.8)

        if let i = args.firstIndex(of: "--snapshot-editor"), i + 2 < args.count {
            // Debug: open an image in the editor and render the window to a PNG.
            openEditor(URL(fileURLWithPath: args[i + 1]))
            let out = URL(fileURLWithPath: args[i + 2])
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                if let ed = self.editor, let v = ed.window?.contentView {
                    ed.setTool(.arrow)
                    v.layoutSubtreeIfNeeded()
                    if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: out)
                    }
                }
                exit(0)
            }
            return
        }
        if let i = args.firstIndex(of: "--snapshot-overlay"), i + 2 < args.count {
            CaptureSession.snapshot(input: URL(fileURLWithPath: args[i + 1]), output: URL(fileURLWithPath: args[i + 2])); return
        }
        if args.contains("--bench") { Bench.run(); return }
        if let i = args.firstIndex(of: "--open"), i + 1 < args.count {
            openEditor(URL(fileURLWithPath: args[i + 1]))
        } else {
            showLibrary()
        }

        // First run (or after a rebuild invalidated permissions): walk through setup.
        PermissionState.shared.refresh()
        let st = PermissionState.shared
        if !st.screenReady || (!st.accessibility && !UserDefaults.standard.bool(forKey: "skippedAX")) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { PermissionsController.shared.show() }
            if st.screenReady { UserDefaults.standard.set(true, forKey: "skippedAX") }  // only nag about the optional one once
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showLibrary() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // MARK: Menus

    func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Snapmark", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(withTitle: "Permissions…", action: #selector(showPermissions(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Snapmark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Snapmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let file = NSMenu(title: "File")
        addCaptureItems(to: file)
        file.addItem(.separator())
        file.addItem(withTitle: "Save", action: #selector(EditorWindowController.saveDocument(_:)), keyEquivalent: "s")
        let exp = file.addItem(withTitle: "Export…", action: #selector(EditorWindowController.exportDocument(_:)), keyEquivalent: "s")
        exp.keyEquivalentModifierMask = [.command, .shift]
        file.addItem(.separator())
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = file

        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: #selector(EditorWindowController.undoEdit(_:)), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: #selector(EditorWindowController.redoEdit(_:)), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste (image as object)", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let gt = edit.addItem(withTitle: "Grab Text", action: #selector(EditorWindowController.grabText(_:)), keyEquivalent: "t")
        gt.keyEquivalentModifierMask = [.command, .shift]
        let pin = edit.addItem(withTitle: "Pin to Screen", action: #selector(EditorWindowController.pinToScreen(_:)), keyEquivalent: "p")
        pin.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(withTitle: "Delete Annotation", action: #selector(EditorWindowController.deleteSelected(_:)), keyEquivalent: "")
        editItem.submenu = edit

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let view = NSMenu(title: "View")
        view.addItem(withTitle: "Zoom In", action: #selector(EditorWindowController.zoomIn(_:)), keyEquivalent: "+")
        view.addItem(withTitle: "Zoom Out", action: #selector(EditorWindowController.zoomOut(_:)), keyEquivalent: "-")
        view.addItem(withTitle: "Actual Size", action: #selector(EditorWindowController.zoomActual(_:)), keyEquivalent: "0")
        view.addItem(withTitle: "Zoom to Fit", action: #selector(EditorWindowController.zoomFit(_:)), keyEquivalent: "9")
        viewItem.submenu = view

        let winItem = NSMenuItem(); main.addItem(winItem)
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Library", action: #selector(showLibraryAction(_:)), keyEquivalent: "l")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    func addCaptureItems(to menu: NSMenu) {
        let items: [(String, Selector, String)] = [
            ("All-in-One Capture", #selector(captureRegion(_:)), "1"),
            ("Capture Window", #selector(captureWindow(_:)), "2"),
            ("Capture Full Screen", #selector(captureFull(_:)), "3"),
        ]
        for (title, sel, key) in items {
            let it = menu.addItem(withTitle: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = [.control, .shift]
            it.target = self
        }
        let delay = menu.addItem(withTitle: "3-Second Delay", action: #selector(toggleDelay(_:)), keyEquivalent: "")
        delay.target = self
    }

    func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: "Snapmark")
        let menu = NSMenu()
        addCaptureItems(to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Library", action: #selector(showLibraryAction(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Enable Smart Element Detection…", action: #selector(enableElementDetection(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Permissions…", action: #selector(showPermissions(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Snapmark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
    }

    @objc func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleDelay(_:)) { item.state = Library.shared.delay ? .on : .off }
        return true
    }

    @objc func captureRegion(_ s: Any?) { capture(.region) }
    @objc func captureWindow(_ s: Any?) { capture(.window) }
    @objc func captureFull(_ s: Any?) { capture(.fullscreen) }
    @objc func toggleDelay(_ s: Any?) { Library.shared.delay.toggle() }
    @objc func showLibraryAction(_ s: Any?) { showLibrary() }

    // MARK: Hotkeys (Carbon — no Accessibility permission needed)

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            DispatchQueue.main.async {
                switch hk.id {
                case 1: AppDelegate.shared.capture(.region)
                case 2: AppDelegate.shared.capture(.window)
                case 3: AppDelegate.shared.capture(.fullscreen)
                default: break
                }
            }
            return noErr
        }, 1, &spec, nil, nil)

        let keys: [(UInt32, Int)] = [(1, kVK_ANSI_1), (2, kVK_ANSI_2), (3, kVK_ANSI_3)]
        for (id, code) in keys {
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: OSType(0x534E4D4B), id: id) // 'SNMK'
            RegisterEventHotKey(UInt32(code), UInt32(controlKey | shiftKey), hkID, GetApplicationEventTarget(), 0, &ref)
            hotKeyRefs.append(ref)
        }
    }

    // MARK: Capture

    func capture(_ mode: CaptureMode) {
        Perf.start("hotkey → overlay visible")
        // If one of our own windows is in front (e.g. the Library button was clicked), get it out of the way first.
        var wait = Library.shared.delay ? 3.0 : 0.0
        if NSApp.isActive {
            // Like Snagit: our own windows get out of the way while you capture.
            if let lib = libraryWindow, lib.isVisible, lib.isKeyWindow { lib.orderOut(nil); wait = max(wait, 0.03) }
            if let w = editor?.window, w.isVisible { w.orderOut(nil); editorHiddenForCapture = true; wait = max(wait, 0.03) }
        }
        PermissionState.shared.refresh()
        if !PermissionState.shared.screenReady { PermissionsController.shared.show(.screen); return }
        let kind: CaptureKind = mode == .region ? .smart : (mode == .window ? .window : .fullscreen)
        CaptureSession.start(kind, delay: wait)
    }

    @objc func enableElementDetection(_ s: Any?) { PermissionsController.shared.show(.accessibility) }
    @objc func showPermissions(_ s: Any?) { PermissionsController.shared.show() }

    // MARK: Windows

    func openEditor(_ url: URL, extras: [Annotation] = [], preloaded: ImageDoc? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        editorHiddenForCapture = false
        if let ed = editor {
            ed.load(url: url, extras: extras, preloaded: preloaded)
            ed.window?.makeKeyAndOrderFront(nil)
            editorDidShow()
            return
        }
        guard let ec = EditorWindowController(url: url, extras: extras, preloaded: preloaded) else {
            let a = NSAlert(); a.messageText = "Couldn't open \(url.lastPathComponent)"; a.runModal(); return
        }
        ec.onClose = { [weak self] in self?.editor = nil; self?.prewarmEditor(after: 1) }
        editor = ec
        ec.showWindow(nil)
        editorDidShow()
    }

    private func editorDidShow() {
        editor?.window?.displayIfNeeded()
        CATransaction.flush()
        if Bench.active { Bench.editorShown() } else { Perf.end("capture → editor visible") }
    }

    /// Build the editor window ahead of time (hidden) so the first capture opens instantly.
    func prewarmEditor(after delay: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.editor == nil,
                  let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue), let blank = ctx.makeImage(),
                  let ec = EditorWindowController(url: FileManager.default.temporaryDirectory.appendingPathComponent("Snapmark.png"),
                                                  preloaded: ImageDoc(base: blank, scale: 1)) else { return }
            ec.onClose = { [weak self] in self?.editor = nil; self?.prewarmEditor(after: 1) }
            self.editor = ec
        }
    }

    /// Called when a capture is cancelled: bring back the editor if we hid it to capture.
    func captureCancelled() {
        if editorHiddenForCapture, let w = editor?.window {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
        }
        editorHiddenForCapture = false
    }

    func showLibrary() {
        if libraryWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable],
                             backing: .buffered, defer: false)
            w.title = "Snapmark Library"
            w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: LibraryView())
            w.setFrameAutosaveName("SnapmarkLibrary")
            if !w.setFrameUsingName("SnapmarkLibrary") { w.center() }
            libraryWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        libraryWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: App icon (drawn in code)

enum AppIcon {
    static func make(size: CGFloat = 1024) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
            let inset = r.insetBy(dx: size * 0.09, dy: size * 0.09)
            let path = NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2)
            NSGradient(colors: [NSColor(red: 1.0, green: 0.42, blue: 0.21, alpha: 1),
                                NSColor(red: 0.91, green: 0.15, blue: 0.36, alpha: 1)])!.draw(in: path, angle: -90)
            let cfg = NSImage.SymbolConfiguration(pointSize: size * 0.42, weight: .semibold)
            if let sym = NSImage(systemSymbolName: "camera.viewfinder", accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg) {
                let tinted = NSImage(size: sym.size, flipped: false) { rr in
                    sym.draw(in: rr); NSColor.white.set(); rr.fill(using: .sourceAtop); return true
                }
                let s = tinted.size
                tinted.draw(in: NSRect(x: r.midX - s.width / 2, y: r.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    static func writePNG(to url: URL) {
        let img = make()
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = NSSize(width: 1024, height: 1024)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        img.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
        NSGraphicsContext.restoreGraphicsState()
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
