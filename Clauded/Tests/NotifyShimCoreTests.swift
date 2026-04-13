@testable import Clauded
import Foundation
import XCTest

final class NotifyShimCoreTests: XCTestCase {
    // MARK: - extractSessionId

    func testExtractSessionIdPrefersSnakeCase() {
        let id = NotifyShimCore.extractSessionId(
            from: ["session_id": "abc", "sessionId": "xyz"],
            environment: ["CLAUDE_PROJECT_DIR": "/tmp/foo"],
            parentPid: 99
        )
        XCTAssertEqual(id, "abc")
    }

    func testExtractSessionIdFallsBackToCamelCase() {
        let id = NotifyShimCore.extractSessionId(
            from: ["sessionId": "xyz"],
            environment: ["CLAUDE_PROJECT_DIR": "/tmp/foo"],
            parentPid: 99
        )
        XCTAssertEqual(id, "xyz")
    }

    func testExtractSessionIdFallsBackToProjectAndPid() {
        let id = NotifyShimCore.extractSessionId(
            from: [:],
            environment: ["CLAUDE_PROJECT_DIR": "/tmp/foo"],
            parentPid: 42
        )
        XCTAssertEqual(id, "/tmp/foo:42")
    }

    func testExtractSessionIdHandlesEmptyProjectDir() {
        let id = NotifyShimCore.extractSessionId(
            from: [:],
            environment: [:],
            parentPid: 7
        )
        XCTAssertEqual(id, ":7")
    }

    func testExtractSessionIdSkipsEmptyStringId() {
        // An empty session_id is worse than no session_id: it would collapse every
        // session into the same registry key. Treat as missing and fall through.
        let id = NotifyShimCore.extractSessionId(
            from: ["session_id": ""],
            environment: ["CLAUDE_PROJECT_DIR": "/p"],
            parentPid: 9
        )
        XCTAssertEqual(id, "/p:9")
    }

    // MARK: - extractMessage

    func testExtractMessagePrefersMessageField() {
        let msg = NotifyShimCore.extractMessage(
            from: ["message": "hello", "prompt": "ignored", "reason": "ignored"],
            kind: "notification"
        )
        XCTAssertEqual(msg, "hello")
    }

    func testExtractMessageFallsBackToPromptTruncatedAt200() {
        let longPrompt = String(repeating: "x", count: 500)
        let msg = NotifyShimCore.extractMessage(
            from: ["prompt": longPrompt],
            kind: "user_prompt_submit"
        )
        XCTAssertEqual(msg?.count, 200)
        XCTAssertEqual(msg, String(repeating: "x", count: 200))
    }

    func testExtractMessageReasonFallbackOnlyForNotification() {
        let notif = NotifyShimCore.extractMessage(
            from: ["reason": "needs input"],
            kind: "notification"
        )
        XCTAssertEqual(notif, "needs input")

        let other = NotifyShimCore.extractMessage(
            from: ["reason": "needs input"],
            kind: "stop"
        )
        XCTAssertNil(other)
    }

    func testExtractMessageReturnsNilWhenNoSource() {
        XCTAssertNil(NotifyShimCore.extractMessage(from: [:], kind: "stop"))
    }

    // MARK: - isoNow

    func testIsoNowParsesViaHookEventDecoder() throws {
        let stamp = NotifyShimCore.isoNow()
        let payload = """
        {"kind":"stop","session_id":"s","project_dir":"/p","pid":1,"timestamp":"\(stamp)"}
        """
        let data = try XCTUnwrap(payload.data(using: .utf8))
        let decoder = HookEvent.makeDecoder()
        XCTAssertNoThrow(try decoder.decode(HookEvent.self, from: data))
    }

    // MARK: - socketPath

    func testSocketPathHonorsExplicitHome() {
        let path = NotifyShimCore.socketPath(home: "/tmp/fakehome")
        XCTAssertEqual(path, "/tmp/fakehome/Library/Application Support/Clauded/daemon.sock")
    }
}
