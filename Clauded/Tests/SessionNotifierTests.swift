@testable import Clauded
import Foundation
import XCTest

@MainActor
final class SessionNotifierTests: XCTestCase {
    func testPostsFirstNotification() {
        let spy = SpyNotificationPoster()
        let notifier = SessionNotifier(poster: spy)
        notifier.notifyAwaitingInput(makeInstance(id: "s1", project: "/a"))
        XCTAssertEqual(spy.posts.count, 1)
        XCTAssertEqual(spy.posts.first?.sessionId, "s1")
        XCTAssertEqual(spy.posts.first?.title, "a")
    }

    func testDedupsWithinWindow() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let spy = SpyNotificationPoster()
        let notifier = SessionNotifier(poster: spy, dedupWindow: 5, now: { clock })

        notifier.notifyAwaitingInput(makeInstance(id: "s1", project: "/a"))
        clock = clock.addingTimeInterval(2)
        notifier.notifyAwaitingInput(makeInstance(id: "s1", project: "/a"))

        XCTAssertEqual(spy.posts.count, 1, "Second post inside window must be dropped")
    }

    func testPostsAgainAfterWindowExpires() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let spy = SpyNotificationPoster()
        let notifier = SessionNotifier(poster: spy, dedupWindow: 5, now: { clock })

        notifier.notifyAwaitingInput(makeInstance(id: "s1", project: "/a"))
        clock = clock.addingTimeInterval(6)
        notifier.notifyAwaitingInput(makeInstance(id: "s1", project: "/a"))

        XCTAssertEqual(spy.posts.count, 2)
    }

    func testDedupIsPerSession() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let spy = SpyNotificationPoster()
        let notifier = SessionNotifier(poster: spy, dedupWindow: 5, now: { clock })

        notifier.notifyAwaitingInput(makeInstance(id: "s1", project: "/a"))
        clock = clock.addingTimeInterval(1)
        notifier.notifyAwaitingInput(makeInstance(id: "s2", project: "/b"))

        XCTAssertEqual(spy.posts.count, 2, "Different sessions must each get their own banner")
    }

    func testClearResetsDedup() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        let spy = SpyNotificationPoster()
        let notifier = SessionNotifier(poster: spy, dedupWindow: 60, now: { clock })

        notifier.notifyAwaitingInput(makeInstance(id: "s1", project: "/a"))
        notifier.clear(sessionId: "s1")
        clock = clock.addingTimeInterval(1)
        notifier.notifyAwaitingInput(makeInstance(id: "s1", project: "/a"))

        XCTAssertEqual(spy.posts.count, 2)
    }

    func testUsesLastMessageAsBodyWhenPresent() {
        let spy = SpyNotificationPoster()
        let notifier = SessionNotifier(poster: spy)
        var instance = makeInstance(id: "s1", project: "/a")
        instance.lastMessage = "Claude needs permission to edit"
        notifier.notifyAwaitingInput(instance)
        XCTAssertEqual(spy.posts.first?.body, "Claude needs permission to edit")
    }

    private func makeInstance(id: String, project: String) -> ClaudeInstance {
        ClaudeInstance(
            id: id,
            projectDir: project,
            pid: 1234,
            processStartTime: nil,
            state: .awaitingInput,
            lastActivity: Date(),
            lastMessage: nil,
            autoYesEnabled: false
        )
    }
}

@MainActor
final class SpyNotificationPoster: NotificationPosting {
    struct Post {
        let title: String
        let body: String
        let sessionId: String
        let pid: Int32?
    }

    var posts: [Post] = []

    func post(title: String, body: String, sessionId: String, pid: Int32?) {
        posts.append(Post(title: title, body: body, sessionId: sessionId, pid: pid))
    }
}
