@testable import Clauded
import Foundation
import XCTest

@MainActor
final class InstanceRegistryTests: XCTestCase {
    func testSessionStartRegistersInstance() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/tmp/proj-a"))
        XCTAssertEqual(registry.instances.count, 1)
        XCTAssertEqual(registry.instances[0].state, .idle)
    }

    func testPromptSubmitTransitionsToWorking() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/tmp"))
        registry.apply(event: makeEvent(kind: .userPromptSubmit, id: "s1", project: "/tmp"))
        XCTAssertEqual(registry.instances[0].state, .working)
    }

    func testNotificationMarksAwaitingInput() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/tmp"))
        registry.apply(event: makeEvent(kind: .notification, id: "s1", project: "/tmp"))
        XCTAssertEqual(registry.instances[0].state, .awaitingInput)
        XCTAssertEqual(registry.needsAttentionCount, 1)
    }

    func testSessionEndRemovesInstance() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/tmp"))
        registry.apply(event: makeEvent(kind: .sessionEnd, id: "s1", project: "/tmp"))
        XCTAssertTrue(registry.instances.isEmpty)
    }

    func testNeedsAttentionCountAcrossMultipleInstances() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s2", project: "/b"))
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s3", project: "/c"))
        registry.apply(event: makeEvent(kind: .notification, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .notification, id: "s3", project: "/c"))
        XCTAssertEqual(registry.needsAttentionCount, 2)
    }

    func testSortedInstancesPutsAttentionFirst() {
        let registry = InstanceRegistry()
        let now = Date()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "old", project: "/a", at: now))
        registry.apply(
            event: makeEvent(kind: .sessionStart, id: "recent", project: "/b", at: now.addingTimeInterval(5))
        )
        registry.apply(
            event: makeEvent(kind: .notification, id: "old", project: "/a", at: now.addingTimeInterval(10))
        )
        let sorted = registry.sortedInstances
        XCTAssertEqual(sorted.first?.id, "old", "Awaiting-input instance should sort first")
    }

    func testReapDeadInstancesRemovesSessionsWhoseProcessIsGone() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "alive", project: "/a", pid: 100))
        registry.apply(event: makeEvent(kind: .sessionStart, id: "dead", project: "/b", pid: 200))

        registry.reapDeadInstances(isAlive: { pid in pid == 100 })

        XCTAssertEqual(registry.instances.map(\.id), ["alive"])
    }

    func testReapDeadInstancesKeepsInstancesWithNoPid() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "nopid", project: "/a", pid: nil))

        registry.reapDeadInstances(isAlive: { _ in false })

        XCTAssertEqual(registry.instances.count, 1, "Instances without a pid should be left alone")
    }

    func testReapDeadInstancesIsNoopWhenAllAlive() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a", pid: 1))
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s2", project: "/b", pid: 2))

        registry.reapDeadInstances(isAlive: { _ in true })

        XCTAssertEqual(registry.instances.count, 2)
    }

    func testProjectNameUsesLastPathComponent() {
        let registry = InstanceRegistry()
        registry.apply(
            event: makeEvent(kind: .sessionStart, id: "s1", project: "/Users/alice/Development/my-app")
        )
        XCTAssertEqual(registry.instances[0].projectName, "my-app")
    }

    private func makeEvent(
        kind: HookEventKind,
        id: String,
        project: String,
        at date: Date = Date(),
        pid: Int32? = 1234
    ) -> HookEvent {
        HookEvent(
            kind: kind,
            sessionId: id,
            projectDir: project,
            pid: pid,
            timestamp: date,
            message: nil
        )
    }
}
