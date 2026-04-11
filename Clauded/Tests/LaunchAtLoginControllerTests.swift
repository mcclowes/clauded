@testable import Clauded
import Foundation
import XCTest

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testReflectsInitialBackendState() {
        let backend = StubLaunchAtLoginBackend()
        backend.enabled = true

        let controller = LaunchAtLoginController(backend: backend)

        XCTAssertTrue(controller.isEnabled)
    }

    func testEnablingCallsRegister() {
        let backend = StubLaunchAtLoginBackend()
        let controller = LaunchAtLoginController(backend: backend)

        controller.setEnabled(true)

        XCTAssertEqual(backend.registerCallCount, 1)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.lastError)
    }

    func testDisablingCallsUnregister() {
        let backend = StubLaunchAtLoginBackend()
        backend.enabled = true
        let controller = LaunchAtLoginController(backend: backend)

        controller.setEnabled(false)

        XCTAssertEqual(backend.unregisterCallCount, 1)
        XCTAssertFalse(controller.isEnabled)
    }

    func testSettingSameValueIsNoop() {
        let backend = StubLaunchAtLoginBackend()
        let controller = LaunchAtLoginController(backend: backend)

        controller.setEnabled(false)

        XCTAssertEqual(backend.registerCallCount, 0)
        XCTAssertEqual(backend.unregisterCallCount, 0)
    }

    func testRegisterErrorSurfacesAndStateMatchesBackend() {
        let backend = StubLaunchAtLoginBackend()
        backend.registerError = TestError.boom
        let controller = LaunchAtLoginController(backend: backend)

        controller.setEnabled(true)

        XCTAssertEqual(controller.lastError, TestError.boom.localizedDescription)
        XCTAssertFalse(controller.isEnabled)
    }

    func testSuccessfulToggleClearsPriorError() {
        let backend = StubLaunchAtLoginBackend()
        backend.registerError = TestError.boom
        let controller = LaunchAtLoginController(backend: backend)

        controller.setEnabled(true)
        XCTAssertNotNil(controller.lastError)

        backend.registerError = nil
        controller.setEnabled(true)

        XCTAssertNil(controller.lastError)
        XCTAssertTrue(controller.isEnabled)
    }
}

private enum TestError: LocalizedError {
    case boom

    var errorDescription: String? {
        "boom"
    }
}

@MainActor
private final class StubLaunchAtLoginBackend: LaunchAtLoginBackend {
    var enabled = false
    var registerError: Error?
    var unregisterError: Error?
    var registerCallCount = 0
    var unregisterCallCount = 0

    func register() throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        enabled = true
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        enabled = false
    }

    func isEnabled() -> Bool {
        enabled
    }
}
