@testable import Clauded
import Foundation
import XCTest

@MainActor
final class HookInstallStateTests: XCTestCase {
    func testInitialStatusReflectsBackend() {
        let stub = StubHookInstaller(
            status: .partial,
            verification: .init(
                healthyEvents: ["SessionStart"],
                missingEvents: ["Stop"],
                staleEvents: []
            )
        )
        let state = HookInstallState(installer: stub)
        XCTAssertEqual(state.status, .partial)
        XCTAssertEqual(state.verification.healthyEvents, ["SessionStart"])
        XCTAssertEqual(state.verification.missingEvents, ["Stop"])
        XCTAssertNil(state.lastError)
        XCTAssertFalse(state.isWorking)
    }

    func testToggleFromNotInstalledCallsInstall() async {
        let stub = StubHookInstaller(status: .notInstalled)
        let state = HookInstallState(installer: stub)
        state.toggleInstallation()
        await waitForIdle(state)
        XCTAssertEqual(stub.installCalls, 1)
        XCTAssertEqual(stub.uninstallCalls, 0)
    }

    func testToggleFromInstalledCallsUninstall() async {
        let stub = StubHookInstaller(status: .installed)
        let state = HookInstallState(installer: stub)
        state.toggleInstallation()
        await waitForIdle(state)
        XCTAssertEqual(stub.uninstallCalls, 1)
        XCTAssertEqual(stub.installCalls, 0)
    }

    func testToggleFromPartialCallsInstallToRepair() async {
        let stub = StubHookInstaller(status: .partial)
        let state = HookInstallState(installer: stub)
        state.toggleInstallation()
        await waitForIdle(state)
        XCTAssertEqual(stub.installCalls, 1)
        XCTAssertEqual(stub.uninstallCalls, 0)
    }

    func testIsWorkingBlocksReentry() async {
        let stub = StubHookInstaller(status: .notInstalled)
        stub.installDelay = .milliseconds(50)
        let state = HookInstallState(installer: stub)
        state.toggleInstallation()
        // Second call while first is in-flight must be ignored.
        state.toggleInstallation()
        await waitForIdle(state)
        XCTAssertEqual(stub.installCalls, 1)
    }

    func testThrownErrorPopulatesLastErrorAndStillRefreshes() async {
        let stub = StubHookInstaller(status: .notInstalled)
        stub.installError = StubError.boom
        let state = HookInstallState(installer: stub)
        state.toggleInstallation()
        await waitForIdle(state)
        XCTAssertNotNil(state.lastError)
        XCTAssertGreaterThanOrEqual(stub.statusCalls, 2) // initial + post-failure refresh
    }

    func testSuccessfulToggleClearsPriorLastError() async {
        let stub = StubHookInstaller(status: .notInstalled)
        let state = HookInstallState(installer: stub)
        // Seed a lastError via a failing toggle.
        stub.installError = StubError.boom
        state.toggleInstallation()
        await waitForIdle(state)
        XCTAssertNotNil(state.lastError)

        // Now make the next install succeed.
        stub.installError = nil
        state.toggleInstallation()
        await waitForIdle(state)
        XCTAssertNil(state.lastError)
    }

    func testReinstallAlwaysCallsInstall() async {
        let stub = StubHookInstaller(status: .installed)
        let state = HookInstallState(installer: stub)
        state.reinstall()
        await waitForIdle(state)
        XCTAssertEqual(stub.installCalls, 1)
        XCTAssertEqual(stub.uninstallCalls, 0)
    }

    // MARK: - Helpers

    private func waitForIdle(_ state: HookInstallState, timeout: TimeInterval = 2.0) async {
        let deadline = Date().addingTimeInterval(timeout)
        while state.isWorking, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(state.isWorking, "HookInstallState did not return to idle within \(timeout)s")
    }
}

private enum StubError: Error { case boom }

private final class StubHookInstaller: HookInstalling, @unchecked Sendable {
    private let lock = NSLock()
    private var _status: HookInstaller.InstallStatus
    private var _verification: HookInstaller.Verification
    private(set) var installCalls = 0
    private(set) var uninstallCalls = 0
    private(set) var statusCalls = 0
    var installError: Error?
    var uninstallError: Error?
    var installDelay: Duration?

    init(
        status: HookInstaller.InstallStatus,
        verification: HookInstaller.Verification = .init(
            healthyEvents: [], missingEvents: [], staleEvents: []
        )
    ) {
        _status = status
        _verification = verification
    }

    func status() -> HookInstaller.InstallStatus {
        lock.lock(); defer { lock.unlock() }
        statusCalls += 1
        return _status
    }

    func verify() -> HookInstaller.Verification {
        lock.lock(); defer { lock.unlock() }
        return _verification
    }

    func install() throws -> [String] {
        if let installDelay {
            Thread.sleep(forTimeInterval: TimeInterval(installDelay.components.seconds) +
                Double(installDelay.components.attoseconds) / 1e18)
        }
        lock.lock()
        installCalls += 1
        let err = installError
        lock.unlock()
        if let err { throw err }
        return []
    }

    func uninstall() throws -> [String] {
        lock.lock()
        uninstallCalls += 1
        let err = uninstallError
        lock.unlock()
        if let err { throw err }
        return []
    }
}
