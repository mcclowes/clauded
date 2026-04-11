@testable import Clauded
import Foundation
import XCTest

final class HookEventTests: XCTestCase {
    func testDecodesShimOutputWithFractionalSeconds() throws {
        let json = Data("""
        {
          "kind": "notification",
          "session_id": "abc-123",
          "project_dir": "/tmp/proj",
          "pid": 4242,
          "timestamp": "2026-04-10T12:00:00.000Z",
          "message": "Awaiting permission"
        }
        """.utf8)

        let event = try HookEvent.makeDecoder().decode(HookEvent.self, from: json)

        XCTAssertEqual(event.kind, .notification)
        XCTAssertEqual(event.sessionId, "abc-123")
        XCTAssertEqual(event.projectDir, "/tmp/proj")
        XCTAssertEqual(event.pid, 4242)
        XCTAssertEqual(event.message, "Awaiting permission")
    }

    func testDecodesShimOutputWithoutFractionalSeconds() throws {
        // Foundation's built-in `.iso8601` strategy does not support fractional seconds.
        // Our custom strategy must accept both forms, because different shim builds
        // (or future Claude Code versions) may emit either.
        let json = Data("""
        {
          "kind": "notification",
          "session_id": "abc-456",
          "project_dir": "/tmp/proj",
          "timestamp": "2026-04-10T12:00:00Z"
        }
        """.utf8)

        let event = try HookEvent.makeDecoder().decode(HookEvent.self, from: json)
        XCTAssertEqual(event.kind, .notification)
        XCTAssertEqual(event.sessionId, "abc-456")
    }

    func testDecoderRejectsMalformedTimestamp() {
        let json = Data("""
        {
          "kind": "stop",
          "session_id": "s1",
          "project_dir": "/",
          "timestamp": "yesterday"
        }
        """.utf8)

        XCTAssertThrowsError(try HookEvent.makeDecoder().decode(HookEvent.self, from: json))
    }

    func testDecodesMissingOptionalFields() throws {
        let json = Data("""
        {
          "kind": "session-start",
          "session_id": "s1",
          "project_dir": "/tmp",
          "timestamp": "2026-04-10T12:00:00.000Z"
        }
        """.utf8)

        let event = try HookEvent.makeDecoder().decode(HookEvent.self, from: json)

        XCTAssertEqual(event.kind, .sessionStart)
        XCTAssertNil(event.pid)
        XCTAssertNil(event.message)
    }

    func testEventKindRawValuesMatchShim() {
        XCTAssertEqual(HookEventKind.sessionStart.rawValue, "session-start")
        XCTAssertEqual(HookEventKind.sessionEnd.rawValue, "session-end")
        XCTAssertEqual(HookEventKind.notification.rawValue, "notification")
        XCTAssertEqual(HookEventKind.stop.rawValue, "stop")
        XCTAssertEqual(HookEventKind.userPromptSubmit.rawValue, "prompt")
    }
}
