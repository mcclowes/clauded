@testable import Clauded
import Foundation
import XCTest

@MainActor
final class AutoYesResponderTests: XCTestCase {
    func testHandleSendsKeystrokeOnFirstCall() {
        let sender = SpyKeystrokeSender()
        let responder = AutoYesResponder(sender: sender, minimumInterval: 7, now: { Date() })

        responder.handle(makeInstance(id: "s1"))

        XCTAssertEqual(sender.delivered.map(\.id), ["s1"])
    }

    func testHandleDebouncesWithinInterval() {
        let sender = SpyKeystrokeSender()
        var clock = Date()
        let responder = AutoYesResponder(sender: sender, minimumInterval: 7, now: { clock })

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
        let responder = AutoYesResponder(sender: sender, minimumInterval: 7, now: { clock })

        responder.handle(makeInstance(id: "s1"))
        clock = clock.addingTimeInterval(7.1)
        responder.handle(makeInstance(id: "s1"))

        XCTAssertEqual(sender.delivered.count, 2)
    }

    func testDebounceIsPerSession() {
        // s1 firing recently must not block s2 from firing immediately.
        let sender = SpyKeystrokeSender()
        let responder = AutoYesResponder(sender: sender, minimumInterval: 7, now: { Date() })

        responder.handle(makeInstance(id: "s1"))
        responder.handle(makeInstance(id: "s2"))

        XCTAssertEqual(sender.delivered.map(\.id), ["s1", "s2"])
    }

    private func makeInstance(id: String) -> ClaudeInstance {
        ClaudeInstance(
            id: id,
            projectDir: "/tmp/proj",
            pid: 1234,
            processStartTime: nil,
            state: .awaitingInput,
            lastActivity: Date(),
            lastMessage: nil,
            autoYesEnabled: true
        )
    }
}

@MainActor
final class SpyKeystrokeSender: KeystrokeSender {
    var delivered: [ClaudeInstance] = []

    func sendAutoYes(to instance: ClaudeInstance) {
        delivered.append(instance)
    }
}
