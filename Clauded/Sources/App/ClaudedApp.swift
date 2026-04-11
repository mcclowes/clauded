import SwiftUI

private enum Defaults {
    static let didAttemptFirstInstall = "com.mcclowes.clauded.didAttemptFirstInstall"
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = InstanceRegistry()
    let hookInstallState = HookInstallState()
    let launchAtLogin = LaunchAtLoginController()

    private var daemon: HookDaemon?
    private var statusBarController: StatusBarController?
    private var reaperTask: Task<Void, Never>?
    private var autoYesResponder: AutoYesResponder?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let daemon = HookDaemon(registry: registry)
        self.daemon = daemon
        Task { await daemon.start() }

        let statusBar = StatusBarController(registry: registry)
        statusBarController = statusBar

        let responder = AutoYesResponder(sender: AppleScriptKeystrokeSender())
        autoYesResponder = responder
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
            }
        }

        let panel = InstancePanelView(
            onOpenSettings: { [weak statusBar] in
                statusBar?.openSettings()
            },
            onClose: { [weak statusBar] in
                statusBar?.close()
            }
        )
        .environment(registry)

        statusBar.setup(contentView: panel)

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
        }
    }
}
