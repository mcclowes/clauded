@testable import Clauded
import Foundation
import XCTest

@MainActor
final class AutoYesResponderTests: XCTestCase {
    func testHandleSendsKeystrokeOnFirstCall() {
        let sender = SpyKeystrokeSender()
        let responder = makeResponder(sender: sender)

        responder.handle(makeInstance(id: "s1"))

        XCTAssertEqual(sender.delivered.map(\.id), ["s1"])
    }

    func testHandleDebouncesWithinInterval() {
        let sender = SpyKeystrokeSender()
        var clock = Date()
        let responder = makeResponder(sender: sender, now: { clock })

        responder.handle(makeInstance(id: "s1"))
        clock = clock.addingTimeInterval(3)
        responder.handle(makeInstance(id: "s1"))
        clock = clock.addingTimeInterval(3)
        responder.handle(makeInstance(id: "s1"))

        XCTAssertEqual(sender.delivered.count, 1, "Within 7s the second/third calls must be suppressed")
    }

    func testHandleFiresAgainAfterIntervalElapses() {
        let sender = SpyKeystrokeSender()
        var clock = Date()
        let responder = makeResponder(sender: sender, now: { clock })

        responder.handle(makeInstance(id: "s1"))
        clock = clock.addingTimeInterval(7.1)
        responder.handle(makeInstance(id: "s1"))

        XCTAssertEqual(sender.delivered.count, 2)
    }

    func testDebounceIsPerSession() {
        // s1 firing recently must not block s2 from firing immediately.
        let sender = SpyKeystrokeSender()
        let responder = makeResponder(sender: sender)

        responder.handle(makeInstance(id: "s1"))
        responder.handle(makeInstance(id: "s2"))

        XCTAssertEqual(sender.delivered.map(\.id), ["s1", "s2"])
    }

    func testHandleSkipsIdleWaitingNotification() {
        // The 60-second "Claude is waiting for your input" nudge fires the same
        // Notification hook as a permission prompt, but there's no numbered menu
        // to answer — typing `1` would submit a literal `1` as the user's next
        // message. Regression guard for #30.
        let sender = SpyKeystrokeSender()
        let responder = makeResponder(sender: sender)

        responder.handle(makeInstance(id: "s1", message: "Claude is waiting for your input"))

        XCTAssertTrue(sender.delivered.isEmpty)
    }

    func testHandleSkipsUnknownNotification() {
        // Safe default: anything we can't positively identify as a permission
        // prompt is treated as non-actionable. A missed auto-yes is recoverable
        // by the user; a phantom `1` submission is not.
        let sender = SpyKeystrokeSender()
        let responder = makeResponder(sender: sender)

        responder.handle(makeInstance(id: "s1", message: "Something weird happened"))
        responder.handle(makeInstance(id: "s2", message: nil))
        responder.handle(makeInstance(id: "s3", message: ""))

        XCTAssertTrue(sender.delivered.isEmpty)
    }

    func testHandleFiresOnPermissionPrompt() {
        let sender = SpyKeystrokeSender()
        let responder = makeResponder(sender: sender)

        responder.handle(makeInstance(id: "s1", message: "Claude needs your permission to use Bash"))

        XCTAssertEqual(sender.delivered.map(\.id), ["s1"])
    }

    func testSkippedMessageDoesNotConsumeDebounceSlot() {
        // An idle-notification skip must not start the debounce clock — otherwise
        // a legitimate permission prompt arriving seconds later would be swallowed.
        let sender = SpyKeystrokeSender()
        var clock = Date()
        let responder = makeResponder(sender: sender, now: { clock })

        responder.handle(makeInstance(id: "s1", message: "Claude is waiting for your input"))
        clock = clock.addingTimeInterval(1)
        responder.handle(makeInstance(id: "s1", message: "Claude needs your permission to use Bash"))

        XCTAssertEqual(sender.delivered.map(\.id), ["s1"])
    }

    func testRuleSkipSuppressesApprovalAndDoesNotStartDebounce() {
        // A rule-driven skip must behave like the classifier skip: no keystroke,
        // and no debounce slot consumed so a later non-skipped prompt fires promptly.
        let sender = SpyKeystrokeSender()
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        store.addGlobalRule(pattern: "rm -rf", action: .skip)
        var clock = Date()
        let responder = AutoYesResponder(sender: sender, rules: store, minimumInterval: 7, now: { clock })

        responder.handle(makeInstance(
            id: "s1",
            message: "Claude needs your permission to use Bash(rm -rf foo)"
        ))
        clock = clock.addingTimeInterval(1)
        responder.handle(makeInstance(
            id: "s1",
            message: "Claude needs your permission to use Bash(ls)"
        ))

        XCTAssertEqual(sender.delivered.map(\.id), ["s1"])
    }

    func testDisabledCodebaseSuppressesAutoYes() {
        let sender = SpyKeystrokeSender()
        let store = AutoYesRulesStore(storage: makeEphemeralDefaults())
        if let added = store.addCodebase(name: "payments") {
            store.setCodebaseEnabled(id: added.id, enabled: false)
        }
        let responder = makeResponder(sender: sender, store: store)

        responder.handle(makeInstance(id: "s1", projectDir: "/Users/me/work/payments"))

        XCTAssertTrue(sender.delivered.isEmpty)
    }

    private func makeResponder(
        sender: KeystrokeSender,
        store: AutoYesRulesStore? = nil,
        now: @escaping () -> Date = Date.init
    ) -> AutoYesResponder {
        AutoYesResponder(
            sender: sender,
            rules: store ?? AutoYesRulesStore(storage: makeEphemeralDefaults()),
            minimumInterval: 7,
            now: now
        )
    }

    private func makeInstance(
        id: String,
        message: String? = "Claude needs your permission to use Bash",
        projectDir: String = "/tmp/proj"
    ) -> ClaudeInstance {
        ClaudeInstance(
            id: id,
            projectDir: projectDir,
            pid: 1234,
            processStartTime: nil,
            state: .awaitingInput,
            lastActivity: Date(),
            lastMessage: message,
            autoYesEnabled: true
        )
    }
}

@MainActor
final class SpyKeystrokeSender: KeystrokeSender {
    var delivered: [ClaudeInstance] = []
    var quickReplies: [(String, ClaudeInstance)] = []

    func sendAutoYes(to instance: ClaudeInstance) {
        delivered.append(instance)
    }

    func sendQuickReply(_ text: String, to instance: ClaudeInstance) {
        quickReplies.append((text, instance))
    }
}

/// Isolated UserDefaults so tests don't pollute the user's real preferences.
func makeEphemeralDefaults(file: StaticString = #file, line: UInt = #line) -> UserDefaults {
    let suite = "com.mcclowes.clauded.tests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suite) else {
        fatalError("Unable to create UserDefaults suite \(suite)", file: file, line: line)
    }
    return defaults
}
