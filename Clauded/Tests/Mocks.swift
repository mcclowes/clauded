@testable import Clauded
import Foundation

/// Shared test fixtures. Keep mocks and factories here so individual test files stay focused
/// on the behaviour under test instead of boilerplate setup.
enum Mocks {
    /// Manufactures a temp directory for tests that write to disk. Caller is responsible
    /// for cleaning up in tearDown.
    ///
    /// Uses `/tmp` rather than `NSTemporaryDirectory()` because the latter lives under
    /// `/var/folders/.../T/`, which pushes a `daemon.sock` path past the 104-byte
    /// `sun_path` limit for Unix domain sockets and makes daemon tests fail in obscure
    /// ways. `/tmp` keeps paths short enough for every test that needs a socket.
    static func makeTempDirectory(prefix: String = "clauded-tests") -> URL {
        // Short UUID suffix (first 8 chars) so the full path stays well under the
        // 104-byte sun_path ceiling even after appending `/daemon.sock`.
        let suffix = UUID().uuidString.prefix(8)
        let url = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("\(prefix)-\(suffix)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Builds a HookEvent with sensible defaults so tests can override only the fields they care about.
    static func hookEvent(
        kind: HookEventKind = .sessionStart,
        sessionId: String = "session-\(UUID().uuidString)",
        projectDir: String = "/tmp/project",
        pid: Int32? = 1234,
        timestamp: Date = Date(),
        message: String? = nil
    ) -> HookEvent {
        HookEvent(
            kind: kind,
            sessionId: sessionId,
            projectDir: projectDir,
            pid: pid,
            timestamp: timestamp,
            message: message
        )
    }

    /// JSON payload in the wire format the notify shim writes. Matches the keys the
    /// daemon's custom decoder expects (snake_case + fractional-seconds ISO-8601).
    static func hookEventJSON(
        kind: String = "session-start",
        sessionId: String = "session-abc",
        projectDir: String = "/tmp/proj",
        pid: Int32 = 4242,
        timestamp: Date = Date(),
        message: String? = nil
    ) -> Data {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var root: [String: Any] = [
            "kind": kind,
            "session_id": sessionId,
            "project_dir": projectDir,
            "pid": Int(pid),
            "timestamp": formatter.string(from: timestamp),
        ]
        if let message {
            root["message"] = message
        }
        return (try? JSONSerialization.data(withJSONObject: root)) ?? Data()
    }
}
