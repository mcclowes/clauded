import Foundation
import Observation
import os
import ServiceManagement

/// Abstraction over `SMAppService.mainApp` so the controller is testable without
/// registering a real login item (which requires a signed app in `/Applications`).
@MainActor
protocol LaunchAtLoginBackend {
    func register() throws
    func unregister() throws
    func isEnabled() -> Bool
}

@MainActor
struct SystemLaunchAtLoginBackend: LaunchAtLoginBackend {
    func register() throws {
        try SMAppService.mainApp.register()
    }

    func unregister() throws {
        try SMAppService.mainApp.unregister()
    }

    func isEnabled() -> Bool {
        SMAppService.mainApp.status == .enabled
    }
}

/// Observable wrapper so SwiftUI can drive a `Toggle` against the system login-item state.
@MainActor
@Observable
final class LaunchAtLoginController {
    private static let logger = Logger(
        subsystem: "com.mcclowes.clauded",
        category: "LaunchAtLogin"
    )

    private let backend: any LaunchAtLoginBackend

    private(set) var isEnabled: Bool
    private(set) var lastError: String?

    init(backend: (any LaunchAtLoginBackend)? = nil) {
        let resolved = backend ?? SystemLaunchAtLoginBackend()
        self.backend = resolved
        isEnabled = resolved.isEnabled()
    }

    func refresh() {
        isEnabled = backend.isEnabled()
    }

    func setEnabled(_ newValue: Bool) {
        guard newValue != isEnabled else { return }
        lastError = nil
        do {
            if newValue {
                try backend.register()
            } else {
                try backend.unregister()
            }
        } catch {
            Self.logger.error(
                "Launch-at-login toggle failed: \(error.localizedDescription, privacy: .public)"
            )
            lastError = error.localizedDescription
        }
        isEnabled = backend.isEnabled()
    }
}
