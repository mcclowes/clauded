import Foundation

/// Abstraction over `HookInstaller` so UI-bridge state (`HookInstallState`) and tests
/// can stand in a stub that doesn't touch the disk.
protocol HookInstalling: Sendable {
    func status() -> HookInstaller.InstallStatus
    func verify() -> HookInstaller.Verification
    @discardableResult func install() throws -> [String]
    @discardableResult func uninstall() throws -> [String]
}

extension HookInstaller: HookInstalling {}
