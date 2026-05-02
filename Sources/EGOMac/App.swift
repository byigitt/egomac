import AppKit
import SwiftUI

// Manual NSApplication setup so this builds as a single SwiftPM executable
// without requiring an .xcodeproj. The .app bundle (built via build.sh) sets
// LSUIElement=true so we never appear in the Dock.
@main
struct EGOMacApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory) // belt-and-suspenders even without bundle
        app.run()
        _ = delegate // keep strong reference
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?
    private let viewModel = BusViewModel(config: ConfigLoader.load())

    func applicationDidFinishLaunching(_ notification: Notification) {
        DebugLog.log("─── EGO Mac launched (pid \(ProcessInfo.processInfo.processIdentifier)) ───")

        // macOS aggressively terminates "idle" accessory apps (LSUIElement=true) via
        // Automatic Termination. Without these guards, the menu bar icon disappears
        // a few seconds after launch when no popover/window is visible.
        ProcessInfo.processInfo.disableAutomaticTermination("EGO Mac status item")
        ProcessInfo.processInfo.disableSuddenTermination()

        ConfigLoader.writeDefaultIfMissing()
        Notifier.requestPermission()

        // Warm up the search index in the background so the first Settings open
        // feels instant, and so we get an early log line confirming the embedded
        // stops blob decoded correctly.
        _ = SearchIndex.shared

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        DebugLog.log("statusItem created (length=\(statusItem.length))")
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "bus.fill",
                accessibilityDescription: "EGO Mac"
            )
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
            button.font = .systemFont(ofSize: 12, weight: .semibold)
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 380, height: 540)
        popover.contentViewController = NSHostingController(
            rootView: PopoverView(viewModel: viewModel)
        )

        viewModel.onTitleChange = { [weak self] title in
            self?.statusItem.button?.title = title
        }
        viewModel.start()

        // Refresh once immediately so the popover has data the moment the user clicks.
        Task { await viewModel.refresh() }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            // Refresh on open for snappy feel.
            Task { await viewModel.refresh() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        DebugLog.log("applicationWillTerminate")
        viewModel.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
