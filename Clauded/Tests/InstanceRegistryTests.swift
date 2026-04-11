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

    func testReapDetectsPidReuse() {
        // Session was registered when its pid had start-time T1. The reaper later sees
        // that pid alive, but its start-time is now T2 — so it's a different process
        // that happens to have the same pid. Should reap.
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "session", project: "/a", pid: 100))
        // Manually set a known processStartTime so the test is deterministic. Since
        // processStartTime defaults to `processStartTime(pid)` at registration, it's
        // likely nil for pid=100 here. We re-apply with a second event to trigger the
        // mutation path... actually easier: just drive the reaper with both closures
        // returning values that diverge from whatever we captured.

        // First, make sure the session has a known recorded start time by simulating
        // a registration that captures one.
        // We achieve this by directly mutating through apply(): if the captured start
        // time is nil, the "PID reuse" branch is skipped (conservative keep), so we
        // need a path to seed it. Cheapest: just assert the *conservative* behaviour
        // separately and verify the reaper does the right thing when both values are
        // present by using the injection point.

        // The reaper ignores instances whose recorded start time is nil, so if the
        // captured startTime for pid=100 was nil we can't test PID reuse via injection
        // alone. Skip this instance and use a fresh one created via direct injection
        // of a divergent start time in the closure.
        registry.clear()

        // Use our own pid — `processStartTime(pid_t(getpid()))` will return a real
        // value, so the registered instance will have a recorded start time.
        let livePid = pid_t(getpid())
        registry.apply(event: makeEvent(kind: .sessionStart, id: "live", project: "/b", pid: livePid))
        XCTAssertNotNil(registry.instances.first?.processStartTime)

        // Inject a start time that's very different from the recorded one to simulate
        // PID reuse.
        let divergentStart = Date().addingTimeInterval(-99999)
        registry.reapDeadInstances(
            isAlive: { _ in true },
            startTime: { _ in divergentStart }
        )
        XCTAssertTrue(registry.instances.isEmpty, "Divergent start time must be reaped as PID-reused")
    }

    func testReapKeepsInstanceWhenStartTimeMatches() {
        let registry = InstanceRegistry()
        let livePid = pid_t(getpid())
        registry.apply(event: makeEvent(kind: .sessionStart, id: "live", project: "/a", pid: livePid))

        let recorded = registry.instances.first?.processStartTime
        registry.reapDeadInstances(
            isAlive: { _ in true },
            startTime: { _ in recorded }
        )
        XCTAssertEqual(registry.instances.count, 1, "Matching start time must not reap")
    }

    func testLateEventsForReapedSessionsAreDropped() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "ghost", project: "/a", pid: 9001))
        registry.reapDeadInstances(isAlive: { _ in false })
        XCTAssertTrue(registry.instances.isEmpty)

        // A late Notification event for the reaped session arrives after reap. It
        // must not resurrect the row; otherwise we'd show a zombie until the next
        // reaper tick.
        registry.apply(event: makeEvent(kind: .notification, id: "ghost", project: "/a", pid: 9001))
        XCTAssertTrue(registry.instances.isEmpty, "Late events must not resurrect reaped sessions")
    }

    func testAutoYesDefaultsToFalseForNewInstances() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        XCTAssertFalse(registry.instances[0].autoYesEnabled)
    }

    func testSetAutoYesArmsTheNamedSession() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s2", project: "/b"))

        registry.setAutoYes(sessionId: "s1", enabled: true)

        XCTAssertTrue(registry.instances.first(where: { $0.id == "s1" })?.autoYesEnabled ?? false)
        XCTAssertFalse(registry.instances.first(where: { $0.id == "s2" })?.autoYesEnabled ?? true)
    }

    func testSetAutoYesIsNoopForUnknownSession() {
        let registry = InstanceRegistry()
        registry.setAutoYes(sessionId: "nope", enabled: true)
        XCTAssertTrue(registry.instances.isEmpty)
    }

    func testArmedInstanceTriggersCallbackOnNotification() {
        let registry = InstanceRegistry()
        var fired: [String] = []
        registry.onArmedAwaitingInput = { instance in fired.append(instance.id) }

        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.setAutoYes(sessionId: "s1", enabled: true)
        registry.apply(event: makeEvent(kind: .notification, id: "s1", project: "/a"))

        XCTAssertEqual(fired, ["s1"])
    }

    func testUnarmedInstanceDoesNotTriggerCallback() {
        let registry = InstanceRegistry()
        var fired: [String] = []
        registry.onArmedAwaitingInput = { instance in fired.append(instance.id) }

        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .notification, id: "s1", project: "/a"))

        XCTAssertTrue(fired.isEmpty)
    }

    func testCallbackDoesNotFireForNonNotificationEvents() {
        let registry = InstanceRegistry()
        var fired: [String] = []
        registry.onArmedAwaitingInput = { instance in fired.append(instance.id) }

        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.setAutoYes(sessionId: "s1", enabled: true)
        registry.apply(event: makeEvent(kind: .userPromptSubmit, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .stop, id: "s1", project: "/a"))

        XCTAssertTrue(fired.isEmpty)
    }

    func testCallbackFiresEveryTimeNotificationArrives() {
        // Two notifications in a row (e.g. user dismissed then a new prompt comes in)
        // should both fire — debouncing is the responder's job, not the registry's.
        let registry = InstanceRegistry()
        var fired: [String] = []
        registry.onArmedAwaitingInput = { instance in fired.append(instance.id) }

        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.setAutoYes(sessionId: "s1", enabled: true)
        registry.apply(event: makeEvent(kind: .notification, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .notification, id: "s1", project: "/a"))

        XCTAssertEqual(fired, ["s1", "s1"])
    }

    func testAutoYesSurvivesSubsequentEventsForSameSession() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.setAutoYes(sessionId: "s1", enabled: true)
        registry.apply(event: makeEvent(kind: .userPromptSubmit, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .notification, id: "s1", project: "/a"))
        XCTAssertTrue(registry.instances[0].autoYesEnabled)
    }

    func testStopEventTransitionsToFinished() {
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .userPromptSubmit, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .stop, id: "s1", project: "/a"))
        XCTAssertEqual(registry.instances[0].state, .finished)
    }

    // MARK: - Capacity enforcement

    func testEnforceCapacityEvictsFinishedBeforeWorkingEvenWhenNewer() {
        // 200 working sessions filling the cap, then a single FINISHED session whose
        // timestamp is *newer* than any working row. Adding it pushes us to 201, so the
        // eviction must drop the finished row even though by lastActivity alone it would
        // be the last to go.
        let registry = InstanceRegistry()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<200 {
            registry.apply(
                event: makeEvent(
                    kind: .userPromptSubmit,
                    id: "working-\(index)",
                    project: "/p",
                    at: base.addingTimeInterval(TimeInterval(index))
                )
            )
        }
        XCTAssertEqual(registry.instances.count, 200)

        registry.apply(
            event: makeEvent(
                kind: .sessionStart,
                id: "finished-newest",
                project: "/p",
                at: base.addingTimeInterval(10000)
            )
        )
        registry.apply(
            event: makeEvent(
                kind: .stop,
                id: "finished-newest",
                project: "/p",
                at: base.addingTimeInterval(10001)
            )
        )

        XCTAssertEqual(registry.instances.count, 200)
        XCTAssertNil(
            registry.instances.first(where: { $0.id == "finished-newest" }),
            "Finished session must be evicted ahead of working sessions"
        )
    }

    func testEnforceCapacityWithinSameClassEvictsOldestByActivity() {
        // All sessions are working — no evictable class to prefer — so the tiebreaker is
        // pure lastActivity oldest-first.
        let registry = InstanceRegistry()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<200 {
            registry.apply(
                event: makeEvent(
                    kind: .userPromptSubmit,
                    id: "s-\(index)",
                    project: "/p",
                    at: base.addingTimeInterval(TimeInterval(index + 1))
                )
            )
        }
        // 201st session has the OLDEST timestamp — it should be the one evicted.
        registry.apply(
            event: makeEvent(
                kind: .userPromptSubmit,
                id: "ancient",
                project: "/p",
                at: base
            )
        )

        XCTAssertEqual(registry.instances.count, 200)
        XCTAssertNil(
            registry.instances.first(where: { $0.id == "ancient" }),
            "Oldest-by-activity working session should be evicted within the same class"
        )
    }

    // MARK: - Recently-reaped grace window

    func testReapedGraceWindowExpiresAfterTwoMinutes() {
        // Reap a session, then advance the clock past the 120s grace window. A late
        // event for that session id should now be allowed through and re-register the
        // row instead of being silently dropped.
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let registry = InstanceRegistry(now: { clock })
        registry.apply(event: makeEvent(kind: .sessionStart, id: "ghost", project: "/a", pid: 9001))
        registry.reapDeadInstances(isAlive: { _ in false })
        XCTAssertTrue(registry.instances.isEmpty)

        // Within the grace window — must still be dropped.
        clock = clock.addingTimeInterval(60)
        registry.apply(event: makeEvent(kind: .notification, id: "ghost", project: "/a", pid: 9001))
        XCTAssertTrue(registry.instances.isEmpty, "Late event within grace window must be dropped")

        // Past the grace window — the recently-reaped entry should be pruned and the
        // session is free to register again.
        clock = clock.addingTimeInterval(121)
        registry.apply(event: makeEvent(kind: .sessionStart, id: "ghost", project: "/a", pid: 9002))
        XCTAssertEqual(
            registry.instances.map(\.id),
            ["ghost"],
            "After grace window expiry, the session id must be reusable"
        )
    }

    func testSessionEndDoesNotPoisonLaterFreshSessionWithSameId() {
        // Clean SessionEnd removes the row but should NOT put it in the recently-reaped
        // bucket — a subsequent SessionStart with the same id must register normally.
        // (This would matter if Claude Code ever recycled session ids or if a user
        // restarted a session in-place.)
        let registry = InstanceRegistry()
        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        registry.apply(event: makeEvent(kind: .sessionEnd, id: "s1", project: "/a"))
        XCTAssertTrue(registry.instances.isEmpty)

        registry.apply(event: makeEvent(kind: .sessionStart, id: "s1", project: "/a"))
        XCTAssertEqual(registry.instances.count, 1, "Fresh session must not be blocked by prior clean end")
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
