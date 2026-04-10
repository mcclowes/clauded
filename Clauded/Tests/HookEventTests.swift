@testable import Clauded
import Foundation
import XCTest

final class HookEventTests: XCTestCase {
    func testDecodesShimOutput() throws {
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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(HookEvent.self, from: json)

        XCTAssertEqual(event.kind, .notification)
        XCTAssertEqual(event.sessionId, "abc-123")
        XCTAssertEqual(event.projectDir, "/tmp/proj")
        XCTAssertEqual(event.pid, 4242)
        XCTAssertEqual(event.message, "Awaiting permission")
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

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let event = try decoder.decode(HookEvent.self, from: json)

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
