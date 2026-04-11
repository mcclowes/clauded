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
    private var observationTask: Task<Void, Never>?

    init(registry: InstanceRegistry) {
        self.registry = registry
    }

    deinit {
        observationTask?.cancel()
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

        refreshIcon()
        startObserving()
    }

    private func startObserving() {
        observationTask?.cancel()
        // Poll the observable registry on a short interval so the icon stays in sync.
        // Using observation tracking + animation would be nicer but requires a host
        // view; polling once per 300ms is trivially cheap and robust for a menu bar.
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshIcon()
                try? await Task.sleep(for: .milliseconds(300))
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

    private var settingsWindow: NSWindow?

    func openSettings(contentView: some View) {
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        close()
        let hosting = NSHostingController(rootView: contentView)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Clauded Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow = window
    }
}
