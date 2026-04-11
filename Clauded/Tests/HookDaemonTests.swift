@testable import Clauded
import Foundation
import XCTest

final class HookDaemonTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = Mocks.makeTempDirectory(prefix: "clauded-daemon-tests")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - Path resolution

    func testSocketURLIsDerivedFromInjectedSupportDirectory() {
        let socket = HookDaemon.socketURL(in: tempDir)
        XCTAssertEqual(socket.lastPathComponent, "daemon.sock")
        XCTAssertEqual(socket.deletingLastPathComponent().path, tempDir.path)
    }

    func testPidFileURLIsDerivedFromInjectedSupportDirectory() {
        let pidFile = HookDaemon.pidFileURL(in: tempDir)
        XCTAssertEqual(pidFile.lastPathComponent, "daemon.pid")
        XCTAssertEqual(pidFile.deletingLastPathComponent().path, tempDir.path)
    }

    // MARK: - Ingest

    func testIngestDecodesValidDatagramAndUpdatesRegistry() async {
        let registry = await MainActor.run { InstanceRegistry() }
        let daemon = HookDaemon(registry: registry, supportDirectory: tempDir)

        let payload = Mocks.hookEventJSON(
            kind: "session-start",
            sessionId: "session-1",
            projectDir: "/tmp/a",
            pid: 999
        )
        await daemon.ingest(datagram: payload)

        let instances = await MainActor.run { registry.instances }
        XCTAssertEqual(instances.count, 1)
        XCTAssertEqual(instances.first?.id, "session-1")
        XCTAssertEqual(instances.first?.projectDir, "/tmp/a")
        XCTAssertEqual(instances.first?.pid, 999)
    }

    func testIngestHandlesStateTransitionsAcrossMultipleDatagrams() async {
        let registry = await MainActor.run { InstanceRegistry() }
        let daemon = HookDaemon(registry: registry, supportDirectory: tempDir)

        await daemon.ingest(
            datagram: Mocks.hookEventJSON(kind: "session-start", sessionId: "s1", projectDir: "/tmp/a")
        )
        await daemon.ingest(
            datagram: Mocks.hookEventJSON(kind: "notification", sessionId: "s1", projectDir: "/tmp/a")
        )

        let (count, attention) = await MainActor.run {
            (registry.instances.count, registry.needsAttentionCount)
        }
        XCTAssertEqual(count, 1)
        XCTAssertEqual(attention, 1, "Notification event should mark the session as awaiting input")
    }

    func testIngestDropsGarbagePayloadWithoutCrashing() async {
        let registry = await MainActor.run { InstanceRegistry() }
        let daemon = HookDaemon(registry: registry, supportDirectory: tempDir)

        // Malformed JSON — decoder should log and drop, registry stays empty.
        await daemon.ingest(datagram: Data("{not-json".utf8))
        let count = await MainActor.run { registry.instances.count }
        XCTAssertEqual(count, 0)
    }

    func testIngestDropsPayloadWithUnknownEventKind() async {
        let registry = await MainActor.run { InstanceRegistry() }
        let daemon = HookDaemon(registry: registry, supportDirectory: tempDir)

        let payload = Mocks.hookEventJSON(kind: "totally-unknown-event", sessionId: "s1")
        await daemon.ingest(datagram: payload)

        let count = await MainActor.run { registry.instances.count }
        XCTAssertEqual(count, 0, "Unknown event kinds should not register sessions")
    }

    func testIngestAcceptsTimestampWithoutFractionalSeconds() async throws {
        let registry = await MainActor.run { InstanceRegistry() }
        let daemon = HookDaemon(registry: registry, supportDirectory: tempDir)

        // Hand-roll a payload using the plain ISO-8601 shape (no `.000Z`) that some
        // hook shim versions might emit.
        let json: [String: Any] = [
            "kind": "session-start",
            "session_id": "plain-iso",
            "project_dir": "/tmp/p",
            "pid": 7,
            "timestamp": "2026-04-10T12:00:00Z",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        await daemon.ingest(datagram: data)

        let ids = await MainActor.run { registry.instances.map(\.id) }
        XCTAssertEqual(ids, ["plain-iso"])
    }

    // MARK: - Start / stop lifecycle

    func testStartCreatesSocketAndStopRemovesIt() async {
        let registry = await MainActor.run { InstanceRegistry() }
        let daemon = HookDaemon(registry: registry, supportDirectory: tempDir)

        await daemon.start()
        let socketPath = HookDaemon.socketURL(in: tempDir).path
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: socketPath),
            "start() should bind a socket at the injected path"
        )

        await daemon.stop()
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: socketPath),
            "stop() should unlink the socket"
        )
    }

    func testSecondDaemonOnSameDirectoryIsSkippedByFlockGuard() async {
        let registry = await MainActor.run { InstanceRegistry() }
        let first = HookDaemon(registry: registry, supportDirectory: tempDir)
        await first.start()

        // Second daemon on the same support dir must not kidnap the socket —
        // the flock on daemon.pid guards against it.
        let second = HookDaemon(registry: registry, supportDirectory: tempDir)
        await second.start()
        // After second.start() bails, the socket the first daemon bound should still exist.
        let socketPath = HookDaemon.socketURL(in: tempDir).path
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        await first.stop()
        await second.stop()
    }
}
