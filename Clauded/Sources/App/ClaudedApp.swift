import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let registry = InstanceRegistry()
    let hookInstallState = HookInstallState()

    private var daemon: HookDaemon?
    private var statusBarController: StatusBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let daemon = HookDaemon(registry: registry)
        daemon.start()
        self.daemon = daemon

        let statusBar = StatusBarController(registry: registry)
        statusBarController = statusBar

        let panel = InstancePanelView(
            onOpenSettings: { [weak self, weak statusBar] in
                guard let self, let statusBar else { return }
                let settings = SettingsView()
                    .environment(hookInstallState)
                statusBar.openSettings(contentView: settings)
            },
            onClose: { [weak statusBar] in
                statusBar?.close()
            }
        )
        .environment(registry)

        statusBar.setup(contentView: panel)

        // First-run: auto-install hooks so the app works immediately. If it fails
        // (permissions, unparseable file, whatever), we leave the state untouched
        // and surface it in Settings.
        if !UserDefaults.standard.bool(forKey: "didAttemptFirstInstall") {
            UserDefaults.standard.set(true, forKey: "didAttemptFirstInstall")
            if hookInstallState.status == .notInstalled {
                hookInstallState.toggleInstallation()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemon?.stop()
    }
}

@main
struct ClaudedApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.hookInstallState)
        }
    }
}
