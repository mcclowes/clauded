@testable import Clauded
import Foundation
import XCTest

@MainActor
final class QuickReplyStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "com.mcclowes.clauded.quickReplyTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testDefaultsToDisabledWithCannedResponses() {
        let store = QuickReplyStore(storage: defaults)
        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.responses, ["yes", "no", "continue"])
    }

    func testEnablePersists() {
        let store = QuickReplyStore(storage: defaults)
        store.setEnabled(true)
        let reloaded = QuickReplyStore(storage: defaults)
        XCTAssertTrue(reloaded.enabled)
    }

    func testSetResponsesTrimsAndDedupes() {
        let store = QuickReplyStore(storage: defaults)
        store.setResponses([" yes ", "yes", "", "maybe"])
        XCTAssertEqual(store.responses, ["yes", "maybe"])
    }

    func testSetResponsesFallsBackToDefaultsWhenEmpty() {
        let store = QuickReplyStore(storage: defaults)
        store.setResponses(["  ", ""])
        XCTAssertEqual(store.responses, QuickReplyStore.defaultResponses)
    }

    func testResponsesPersist() {
        let store = QuickReplyStore(storage: defaults)
        store.setResponses(["approve", "reject"])
        let reloaded = QuickReplyStore(storage: defaults)
        XCTAssertEqual(reloaded.responses, ["approve", "reject"])
    }
}

@MainActor
final class QuickReplyControllerTests: XCTestCase {
    func testSendIgnoredWhenDisabled() {
        let store = QuickReplyStore(storage: ephemeralDefaults())
        let sender = SpyKeystrokeSender()
        let controller = QuickReplyController(store: store, sender: sender)

        controller.send("yes", to: makeInstance())
        XCTAssertTrue(sender.quickReplies.isEmpty)
    }

    func testSendForwardsToKeystrokeSenderWhenEnabled() {
        let store = QuickReplyStore(storage: ephemeralDefaults())
        store.setEnabled(true)
        let sender = SpyKeystrokeSender()
        let controller = QuickReplyController(store: store, sender: sender)
        let instance = makeInstance()

        controller.send("continue", to: instance)
        XCTAssertEqual(sender.quickReplies.count, 1)
        XCTAssertEqual(sender.quickReplies.first?.0, "continue")
        XCTAssertEqual(sender.quickReplies.first?.1.id, instance.id)
    }

    private func ephemeralDefaults() -> UserDefaults {
        let name = "com.mcclowes.clauded.quickReplyController.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            fatalError("Could not create ephemeral UserDefaults suite")
        }
        return defaults
    }

    private func makeInstance() -> ClaudeInstance {
        ClaudeInstance(
            id: "s1",
            projectDir: "/tmp/p",
            pid: 1,
            processStartTime: nil,
            state: .awaitingInput,
            lastActivity: Date(),
            lastMessage: nil,
            autoYesEnabled: false
        )
    }
}
