import SwiftUI

private enum Defaults {
    static let didAttemptFirstInstall = "com.mcclowes.clauded.didAttemptFirstInstall"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = InstanceRegistry()
    let hookInstallState = HookInstallState()
    let accessibilityState = AccessibilityPermissionState()
    let launchAtLogin = LaunchAtLoginController()
    let keyBindings = KeyBindingsStore()
    let globalHotkeys = GlobalHotkeyStore()
    let quickReplyStore = QuickReplyStore()

    private var daemon: HookDaemon?
    private var statusBarController: StatusBarController?
    private var reaperTask: Task<Void, Never>?
    private var autoYesResponder: AutoYesResponder?
    private var globalHotkeyController: GlobalHotkeyController?
    private var quickReplyController: QuickReplyController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let daemon = HookDaemon(registry: registry)
        self.daemon = daemon
        Task { await daemon.start() }

        let statusBar = StatusBarController(registry: registry, hookInstallState: hookInstallState)
        statusBarController = statusBar

        let keystrokeSender = AppleScriptKeystrokeSender(permissionState: accessibilityState)
        let responder = AutoYesResponder(sender: keystrokeSender)
        autoYesResponder = responder
        let quickReply = QuickReplyController(store: quickReplyStore, sender: keystrokeSender)
        quickReplyController = quickReply
        registry.onArmedAwaitingInput = { [weak responder] instance in
            responder?.handle(instance)
        }

        // Claude Code's SessionEnd hook doesn't fire when a terminal tab/window is
        // closed abruptly, so instances would otherwise linger forever. Sweep the
        // registry periodically to drop sessions whose processes are gone.
        reaperTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.registry.reapDeadInstances()
                self?.registry.dismissStaleCrashedInstances()
            }
        }

        let panel = InstancePanelView(
            onClose: { [weak statusBar] in
                statusBar?.close()
            }
        )
        .environment(registry)
        .environment(hookInstallState)
        .environment(accessibilityState)
        .environment(keyBindings)
        .environment(quickReply)

        statusBar.setup(contentView: panel)

        let hotkey = GlobalHotkeyController()
        hotkey.onTrigger = { [weak self] in self?.handleJumpToAttention() }
        hotkey.update(binding: globalHotkeys.jumpToAttention)
        globalHotkeyController = hotkey
        observeGlobalHotkeyBinding()

        // First-run: auto-install hooks so the app works immediately. If it fails
        // (permissions, unparseable file, whatever), we leave the state untouched
        // and surface it in Settings. We also auto-run on `.partial` so a stale install
        // (e.g. the app was moved since last launch) is repaired without the user
        // having to hunt for a Repair button.
        if !UserDefaults.standard.bool(forKey: Defaults.didAttemptFirstInstall) {
            UserDefaults.standard.set(true, forKey: Defaults.didAttemptFirstInstall)
            if hookInstallState.status == .notInstalled || hookInstallState.status == .partial {
                hookInstallState.toggleInstallation()
            }
        } else if hookInstallState.status == .partial {
            // Subsequent launches: opportunistically repair stale installs (e.g. shim
            // path changed after app move).
            hookInstallState.toggleInstallation()
        }

        // Keep an eye on settings.json after launch: if the user (or another tool)
        // strips our entries, `status` flips and the menu bar/popover will show a
        // warning banner with a one-click reinstall. No auto-heal at this point —
        // a silent rewrite of settings.json behind the user's back is worse than a
        // visible warning.
        hookInstallState.startHealthCheck()
    }

    private func observeGlobalHotkeyBinding() {
        withObservationTracking { [weak self] in
            _ = self?.globalHotkeys.jumpToAttention
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                globalHotkeyController?.update(binding: globalHotkeys.jumpToAttention)
                observeGlobalHotkeyBinding()
            }
        }
    }

    private func handleJumpToAttention() {
        statusBarController?.close()
        if let instance = registry.oldestAwaitingAttention {
            TerminalFocuser.focus(pid: instance.pid)
        } else {
            statusBarController?.show()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        reaperTask?.cancel()
        // Block on stop so the socket is released before the process exits. Actor hop
        // is synchronous enough here (just unlinks the socket / releases flock).
        if let daemon {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await daemon.stop()
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 1.0)
        }
    }
}

@main
struct ClaudedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.hookInstallState)
                .environment(appDelegate.launchAtLogin)
                .environment(appDelegate.keyBindings)
                .environment(appDelegate.globalHotkeys)
                .environment(appDelegate.quickReplyStore)
        }
    }
}
