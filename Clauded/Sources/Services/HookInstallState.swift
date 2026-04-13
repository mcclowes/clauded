import Foundation
import Observation
import os

/// Observable wrapper around `HookInstaller` so SwiftUI can show current install status
/// without touching the disk on every render.
@MainActor
@Observable
final class HookInstallState {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "HookInstallState")

    /// How often we re-read settings.json to catch drift. The Claude Code team treats
    /// settings as user-owned, so anything from a manual edit to a rival tool can strip
    /// our hooks — a periodic re-check is the cheapest way to notice.
    nonisolated static let healthCheckInterval: Duration = .seconds(600)

    private let installer: any HookInstalling

    private(set) var status: HookInstaller.InstallStatus
    private(set) var verification: HookInstaller.Verification
    private(set) var lastError: String?
    private(set) var isWorking: Bool = false

    private var healthCheckTask: Task<Void, Never>?

    init(installer: any HookInstalling = HookInstaller()) {
        self.installer = installer
        verification = installer.verify()
        status = installer.status()
    }

    func refresh() {
        verification = installer.verify()
        status = installer.status()
    }

    /// Start a background task that re-verifies every `healthCheckInterval`. Safe to
    /// call multiple times — a second call cancels the previous task and replaces it.
    func startHealthCheck(interval: Duration = HookInstallState.healthCheckInterval) {
        healthCheckTask?.cancel()
        healthCheckTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                self?.refresh()
            }
        }
    }

    func stopHealthCheck() {
        healthCheckTask?.cancel()
        healthCheckTask = nil
    }

    /// UI-facing "Reinstall hooks" action. Always runs `install()` (never uninstall),
    /// so it's safe to wire up to a health-check warning banner without worrying about
    /// the current status.
    func reinstall() {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        let installer = installer
        Task {
            defer { isWorking = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    _ = try installer.install()
                }.value
                refresh()
            } catch {
                Self.logger.error("Hook reinstall failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                refresh()
            }
        }
    }

    func toggleInstallation() {
        guard !isWorking else { return }
        isWorking = true
        lastError = nil
        let currentStatus = status
        let installer = installer
        Task {
            defer { isWorking = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    switch currentStatus {
                    case .installed:
                        _ = try installer.uninstall()
                    case .notInstalled, .partial:
                        _ = try installer.install()
                    }
                }.value
                refresh()
            } catch {
                Self.logger.error("Hook toggle failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                refresh()
            }
        }
    }
}
