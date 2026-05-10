import AppKit
import SwiftUI

/// Owns the free-floating "Hat Haritası" window. We use an `NSPanel` instead
/// of the popover because:
///
///   - The popover is ~380×540 — too small for a route map.
///   - The user wants the map visible while the menu-bar popover is dismissed
///     (transient popover behaviour would close the popover the moment the
///     map window takes focus). A panel can stay key without stealing focus.
///
/// We deliberately keep this in `AppKit` rather than the new SwiftUI Window
/// scenes so it works as an accessory app (`LSUIElement=true`); accessory apps
/// don't get a SwiftUI WindowGroup chrome anyway.
@MainActor
final class MapWindowController {
    static let shared = MapWindowController()
    private init() {}

    private var window: NSWindow?
    private var hostController: NSHostingController<LineMapView>?

    /// Show the map for `line`, anchored at `anchorStop` (used to compute ETAs
    /// for the live bus overlay). If the window already exists, just retarget
    /// it to the new line.
    ///
    /// Accessory apps (`LSUIElement=true`) need to flip activation policy to
    /// `.regular` while the window is visible — otherwise the window appears
    /// behind every other app and `makeKeyAndOrderFront` is a no-op for the
    /// user. We flip back to `.accessory` on close so we don't pollute the
    /// Dock or Cmd+Tab list during normal menu-bar use.
    func open(line: Line, anchorStop: StopProfile?) {
        let view = LineMapView(line: line, anchorStop: anchorStop)

        // Always step up to .regular before showing.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        if let win = window, let host = hostController {
            host.rootView = view
            win.title = "Hat \(line.code) — Harita"
            win.makeKeyAndOrderFront(nil)
            win.orderFrontRegardless()
            return
        }

        let host = NSHostingController(rootView: view)
        // Standard NSWindow (NOT NSPanel) — panels in accessory apps don't
        // reliably show their titlebar / chrome and behave oddly with
        // activation. Plain windows just work.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 800),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = "Hat \(line.code) — Harita"
        win.titlebarAppearsTransparent = false
        win.isReleasedWhenClosed = false
        win.contentViewController = host
        win.center()
        if let saved = UserDefaults.standard.string(forKey: MapFrameKey.value) {
            win.setFrame(from: saved)
        }
        win.delegate = WindowSaver.shared
        win.makeKeyAndOrderFront(nil)
        win.orderFrontRegardless()
        self.window = win
        self.hostController = host
    }

    /// Called by `WindowSaver` on `windowWillClose` so we drop back to
    /// accessory mode and stop occupying a Dock tile.
    fileprivate func windowDidClose() {
        window = nil
        hostController = nil
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Top-level constant so we can read/write it without crossing the
/// `MapWindowController`'s `@MainActor` isolation in the delegate's nonisolated
/// callbacks.
private enum MapFrameKey { static let value = "egoMac.mapWindow.frame" }

/// Persists window size between launches via `NSWindowDelegate` and tells
/// the controller when the window goes away so the app can drop back to
/// `.accessory` activation policy.
private final class WindowSaver: NSObject, NSWindowDelegate {
    static let shared = WindowSaver()
    func windowDidResize(_ notification: Notification) { save(notification) }
    func windowDidMove(_ notification: Notification) { save(notification) }
    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in MapWindowController.shared.windowDidClose() }
    }
    private func save(_ note: Notification) {
        guard let w = note.object as? NSWindow else { return }
        UserDefaults.standard.set(w.frameDescriptor, forKey: MapFrameKey.value)
    }
}
