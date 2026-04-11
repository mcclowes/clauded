import Foundation
import Observation
import os

/// Observable wrapper around `HookInstaller` so SwiftUI can show current install status
/// without touching the disk on every render.
@MainActor
@Observable
final class HookInstallState {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "HookInstallState")

    private let installer: HookInstaller

    private(set) var status: HookInstaller.InstallStatus
    private(set) var lastError: String?
    private(set) var isWorking: Bool = false

    init(installer: HookInstaller = HookInstaller()) {
        self.installer = installer
        status = installer.status()
    }

    func refresh() {
        status = installer.status()
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
