import Cocoa
import SwiftUI
import ApplicationServices

// Onboarding panel in the style of the AI desktop apps: it opens the right System Settings pane,
// floats next to the Settings window, and offers a draggable app icon to drop into the permission list.

enum Perm: String {
    case screen, accessibility

    var title: String { self == .screen ? "Screen Recording" : "Accessibility" }
    var detail: String {
        self == .screen
            ? "Required — lets Snapmark take screenshots."
            : "Optional — lets the capture snap to buttons, sidebars and panels inside windows."
    }
    var settingsURL: URL {
        URL(string: self == .screen
            ? "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
            : "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    }
    var tccService: String { self == .screen ? "ScreenCapture" : "Accessibility" }
}

final class PermissionState: ObservableObject {
    static let shared = PermissionState()

    @Published var screen = false
    @Published var screenNeedsRestart = false
    @Published var accessibility = false
    @Published var focus: Perm = .screen

    var screenReady: Bool { screen && !screenNeedsRestart }

    func refresh() {
        let ax = AXIsProcessTrusted()
        let pre = CGPreflightScreenCaptureAccess()
        // Preflight is cached for the life of the process; window titles of other apps
        // become visible as soon as the toggle is switched on, so use that as a live signal.
        let live = pre || Self.canSeeOtherWindowTitles()
        if ax != accessibility { accessibility = ax }
        if live != screen { screen = live }
        if (live && !pre) != screenNeedsRestart { screenNeedsRestart = live && !pre }
    }

    static func canSeeOtherWindowTitles() -> Bool {
        let me = getpid()
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        return list.contains { w in
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let name = w[kCGWindowName as String] as? String ?? ""
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            return pid != me && layer == 0 && !name.isEmpty && !["Window Server", "Dock"].contains(owner)
        }
    }
}

final class PermissionsController: NSObject, NSWindowDelegate {
    static let shared = PermissionsController()
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastSettingsFrame: CGRect?
    private var userMovedPanel = false
    private var programmaticMove = false
    let state = PermissionState.shared

    var isShowing: Bool { panel?.isVisible ?? false }

    /// Show the panel, focused on the first missing permission (or `p`).
    func show(_ p: Perm? = nil) {
        state.refresh()
        let target = p ?? (state.screenReady ? .accessibility : .screen)
        state.focus = target
        if panel == nil { buildPanel() }
        userMovedPanel = false
        openSettings(target)
        panel?.orderFrontRegardless()
        position()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in self?.tick() }
    }

    func close() {
        timer?.invalidate(); timer = nil
        panel?.orderOut(nil)
    }

    func openSettings(_ p: Perm) {
        state.focus = p
        // Asking registers Snapmark with TCC so it can appear in the list; the drag tile covers the cases where it doesn't.
        if p == .screen { CGRequestScreenCaptureAccess() }
        else {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(opts)
        }
        NSWorkspace.shared.open(p.settingsURL)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.position() }
    }

    /// Clears a stale entry (e.g. left over from an older build) so the toggle works again.
    func reset(_ p: Perm) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        task.arguments = ["reset", p.tccService, Bundle.main.bundleIdentifier ?? "io.github.aydinmrnv.snapmark"]
        try? task.run()
        task.waitUntilExit()
        state.refresh()
        openSettings(p)
    }

    func restartApp() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.7; /usr/bin/open \"\(path)\" --args --permissions-done"]
        try? task.run()
        NSApp.terminate(nil)
    }

    private func tick() {
        state.refresh()
        if !userMovedPanel { position() }
        if state.screenReady && state.accessibility {
            // Everything granted: show the success state briefly, then get out of the way.
            timer?.invalidate(); timer = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in self?.close() }
        }
    }

    private func buildPanel() {
        let p = NonKeyPanel(contentRect: NSRect(x: 0, y: 0, width: 360, height: 470),
                        styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = false   // only the title area moves it, so the icon tile can be dragged
        p.level = .floating
        p.becomesKeyOnlyIfNeeded = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.delegate = self
        let host = NSHostingView(rootView: PermissionsView(controller: self, state: state))
        p.contentView = host
        p.setContentSize(host.fittingSize)
        panel = p
    }

    func windowDidMove(_ notification: Notification) {
        if !programmaticMove { userMovedPanel = true }
    }

    func windowWillClose(_ notification: Notification) { timer?.invalidate(); timer = nil }

    /// Park the panel beside the System Settings window (right side if it fits, else left, else bottom of screen).
    private func position() {
        guard let panel else { return }
        if let host = panel.contentView as? NSHostingView<PermissionsView> { panel.setContentSize(host.fittingSize) }
        let size = panel.frame.size
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var origin: CGPoint

        if let s = settingsWindowFrame() {
            let gap: CGFloat = 14
            let midY = s.midY - size.height / 2
            if s.maxX + gap + size.width <= vf.maxX {
                origin = CGPoint(x: s.maxX + gap, y: midY)
            } else if s.minX - gap - size.width >= vf.minX {
                origin = CGPoint(x: s.minX - gap - size.width, y: midY)
            } else {
                origin = CGPoint(x: s.maxX - size.width - 20, y: s.minY + 20)
            }
            origin.y = min(max(origin.y, vf.minY + 8), vf.maxY - size.height - 8)
        } else {
            origin = CGPoint(x: vf.midX - size.width / 2, y: vf.minY + 60)
        }
        if panel.frame.origin != origin {
            programmaticMove = true
            panel.setFrameOrigin(origin)
            programmaticMove = false
        }
    }

    /// System Settings window frame in Cocoa (bottom-left) coordinates. Window bounds don't need any permission.
    private func settingsWindowFrame() -> CGRect? {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in list {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            guard ["System Settings", "System Preferences"].contains(owner), layer == 0,
                  let bd = w[kCGWindowBounds as String], let r = CGRect(dictionaryRepresentation: bd as! CFDictionary),
                  r.width > 300 else { continue }
            let h = Geo.primaryHeight
            return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
        }
        return nil
    }
}

/// Never takes keyboard focus, so typing (e.g. the System Settings password prompt) always goes where you expect.
final class NonKeyPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

extension PermissionsController {
    /// Bring System Settings (and its password prompt) to the front with keyboard focus.
    func focusSystemSettings() {
        let ids = ["com.apple.systempreferences", "com.apple.SystemSettings"]
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate()
                return
            }
        }
    }
}

// MARK: - SwiftUI content

struct PermissionsView: View {
    let controller: PermissionsController
    @ObservedObject var state: PermissionState

    var allDone: Bool { state.screenReady && state.accessibility }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(allDone ? "You're all set" : "Set up Snapmark").font(.headline)
                    Text(allDone ? "Press ⌃⇧1 anywhere to capture." : "Two quick permissions in System Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.top, 6)

            VStack(spacing: 8) {
                row(.screen, granted: state.screen)
                row(.accessibility, granted: state.accessibility)
            }

            if state.screenNeedsRestart {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill").foregroundStyle(.orange)
                    Text("Screen Recording is on. Restart Snapmark to start capturing.").font(.caption)
                    Spacer(minLength: 0)
                    Button("Restart") { controller.restartApp() }.controlSize(.small)
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
            }

            if !allDone {
                let focusGranted = state.focus == .screen ? state.screen : state.accessibility
                VStack(spacing: 8) {
                    Text(focusGranted ? "Done — \(state.focus.title) is on." :
                         "Drag Snapmark into the \(state.focus.title) list,\nthen turn its switch on.")
                        .font(.callout.weight(.medium))
                        .multilineTextAlignment(.center)
                    DragAppTile()
                        .frame(width: 220, height: 82)
                        .opacity(focusGranted ? 0.4 : 1)
                    Text("If Snapmark is already listed, just flip its switch on.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
            }

            HStack {
                Menu("Switch is on but it isn't working?") {
                    Button("Reset Screen Recording entry") { controller.reset(.screen) }
                    Button("Reset Accessibility entry") { controller.reset(.accessibility) }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .font(.caption)
                Spacer()
                Button(allDone ? "Done" : "Later") { controller.close() }.controlSize(.small)
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    @ViewBuilder
    func row(_ p: Perm, granted: Bool) -> some View {
        let focused = state.focus == p
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : (focused ? "circle.dotted" : "circle"))
                .font(.title3)
                .foregroundStyle(granted ? Color.green : (focused ? Color.accentColor : Color.secondary))
            VStack(alignment: .leading, spacing: 2) {
                Text(p.title).font(.subheadline.weight(.semibold))
                Text(p.detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            if granted {
                Text("On").font(.caption.weight(.semibold)).foregroundStyle(.green)
            } else {
                Button(focused ? "Reopen" : "Open") { controller.openSettings(p) }.controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(focused && !granted ? Color.accentColor.opacity(0.08) : Color.primary.opacity(0.04)))
    }
}

/// A draggable tile carrying the app bundle's file URL — System Settings' privacy lists accept it as a drop.
struct DragAppTile: NSViewRepresentable {
    func makeNSView(context: Context) -> DragAppView { DragAppView() }
    func updateNSView(_ nsView: DragAppView, context: Context) {}
}

final class DragAppView: NSView, NSDraggingSource {
    private var hovering = false
    private var bob: CGFloat = 0
    private var animTimer: Timer?

    override init(frame: NSRect) {
        super.init(frame: frame)
        animTimer = Timer.scheduledTimer(withTimeInterval: 1 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.bob = sin(Date().timeIntervalSinceReferenceDate * 3) * 3
            self.needsDisplay = true
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { animTimer?.invalidate() }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .cursorUpdate, .inVisibleRect], owner: self))
    }
    override func cursorUpdate(with event: NSEvent) { NSCursor.openHand.set() }
    override func mouseEntered(with event: NSEvent) { hovering = true; NSCursor.openHand.set() }
    override func mouseExited(with event: NSEvent) { hovering = false; NSCursor.arrow.set() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    private var appIcon: NSImage { NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath) }

    override func draw(_ dirtyRect: NSRect) {
        let r = bounds.insetBy(dx: 2, dy: 2)
        let bg = NSBezierPath(roundedRect: r, xRadius: 14, yRadius: 14)
        (hovering ? NSColor.controlAccentColor.withAlphaComponent(0.16) : NSColor.controlBackgroundColor).setFill()
        bg.fill()
        NSColor.controlAccentColor.withAlphaComponent(hovering ? 0.9 : 0.45).setStroke()
        bg.lineWidth = 1.5
        bg.stroke()

        let iconSize: CGFloat = 54
        let iconRect = CGRect(x: 14, y: (bounds.height - iconSize) / 2 + bob, width: iconSize, height: iconSize)
        appIcon.draw(in: iconRect)

        let title: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 15, weight: .semibold), .foregroundColor: NSColor.labelColor]
        let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        ("Snapmark" as NSString).draw(at: CGPoint(x: 80, y: bounds.midY + 2), withAttributes: title)
        ("Drag me into Settings" as NSString).draw(at: CGPoint(x: 80, y: bounds.midY - 16), withAttributes: sub)

        if let hand = NSImage(systemSymbolName: "hand.point.up.left.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular).applying(.init(paletteColors: [.controlAccentColor]))) {
            hand.draw(in: CGRect(x: bounds.maxX - 30, y: bounds.midY - 9 - bob / 2, width: hand.size.width, height: hand.size.height))
        }
    }

    private var downEvent: NSEvent?
    override func mouseDown(with e: NSEvent) { downEvent = e; NSCursor.closedHand.set() }
    override func mouseUp(with e: NSEvent) { downEvent = nil; NSCursor.openHand.set() }
    override func mouseDragged(with e: NSEvent) {
        guard let start = downEvent else { return }
        downEvent = nil
        beginAppDrag(start)
    }

    private func beginAppDrag(_ e: NSEvent) {
        let url = Bundle.main.bundleURL as NSURL
        let item = NSDraggingItem(pasteboardWriter: url)
        let icon = appIcon
        let p = convert(e.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 32, y: p.y - 32, width: 64, height: 64), contents: icon)
        beginDraggingSession(with: [item], event: e, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        NSCursor.arrow.set()
        PermissionState.shared.refresh()
        // Dropping into Settings usually triggers a password prompt there: give it the keyboard.
        if NSApp.isActive { NSApp.deactivate() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { PermissionsController.shared.focusSystemSettings() }
    }
}
