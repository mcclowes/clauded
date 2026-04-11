import AppKit
import os
import SwiftUI

@MainActor
final class StatusBarController {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "StatusBarController")

    static let panelWidth: CGFloat = 360
    static let panelHeight: CGFloat = 480

    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private let registry: InstanceRegistry

    init(registry: InstanceRegistry) {
        self.registry = registry
    }

    func setup(contentView: some View) {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.action = #selector(statusBarButtonClicked(_:))
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        let hosting = NSHostingController(rootView: contentView)
        hosting.view.frame = NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight)
        popover.contentSize = NSSize(width: Self.panelWidth, height: Self.panelHeight)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting

        observeRegistry()
    }

    /// Event-driven icon refresh. `withObservationTracking` fires `onChange` exactly
    /// once per dependency mutation, so we re-register after each firing. Replaces a
    /// prior 300 ms polling loop that was waking the main thread 3× a second.
    private func observeRegistry() {
        withObservationTracking { [weak self] in
            self?.refreshIcon()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeRegistry()
            }
        }
    }

    func refreshIcon() {
        guard let button = statusItem?.button else { return }
        let attentionCount = registry.needsAttentionCount
        let total = registry.instances.count

        let symbolName = if attentionCount > 0 {
            "bell.badge.fill"
        } else if total > 0 {
            "terminal.fill"
        } else {
            "terminal"
        }
        button.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: "Clauded")
        button.image?.isTemplate = attentionCount == 0
        button.title = attentionCount > 0 ? " \(attentionCount)" : ""
    }

    @objc private func statusBarButtonClicked(_ sender: NSStatusBarButton) {
        toggle()
    }

    func toggle() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            show()
        }
    }

    func show() {
        guard let button = statusItem?.button else { return }
        // Reap on open so the user never sees a stale row — covers the case where a
        // terminal was killed between ticks of the background reaper.
        registry.reapDeadInstances()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        // `close()` is synchronous and skips the animation; `performClose` animates
        // and defers the real close, which races with programmatic app activation
        // after a row click.
        popover.close()
    }

    /// Route the Settings button through the standard SwiftUI `Settings` scene so there
    /// is exactly one Settings window path. Previously we also hand-rolled an NSWindow,
    /// which meant Cmd-, and the gear button could open two different windows.
    func openSettings() {
        close()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }
}
