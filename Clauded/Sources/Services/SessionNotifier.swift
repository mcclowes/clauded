import Foundation
import Observation
import os

/// Posts a notification for a session awaiting user input.
///
/// The real implementation (`UserNotificationPoster`) drives
/// `UNUserNotificationCenter` and uses the session id as the request identifier so a
/// second post for the same session replaces the first in Notification Center — no
/// stack of duplicate banners. Tests can inject a spy to avoid touching real OS APIs.
@MainActor
protocol NotificationPosting {
    func post(title: String, body: String, sessionId: String, pid: Int32?)
}

/// Fronts a `NotificationPosting` with per-session debouncing so a session that
/// fires several `Notification` hooks in rapid succession only wakes the user once.
///
/// Dedup is strictly per-session — two sessions hitting awaiting-input at the same
/// instant both get their own banner.
@MainActor
final class SessionNotifier {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "SessionNotifier")

    /// Minimum gap between two posts for the same session. Any notification falling
    /// inside the window is silently dropped — the row in the menu bar still updates,
    /// so the user loses no information.
    nonisolated static let defaultDedupWindow: TimeInterval = 5

    private let poster: NotificationPosting
    private let dedupWindow: TimeInterval
    private let now: () -> Date
    private var lastPostedAt: [String: Date] = [:]

    init(
        poster: NotificationPosting,
        dedupWindow: TimeInterval = SessionNotifier.defaultDedupWindow,
        now: @escaping () -> Date = { Date() }
    ) {
        self.poster = poster
        self.dedupWindow = dedupWindow
        self.now = now
    }

    func notifyAwaitingInput(_ instance: ClaudeInstance) {
        let current = now()
        if let last = lastPostedAt[instance.id], current.timeIntervalSince(last) < dedupWindow {
            Self.logger.debug("Suppressed duplicate notification for \(instance.id, privacy: .public)")
            return
        }
        lastPostedAt[instance.id] = current

        let title = instance.projectName
        let body = instance.lastMessage?.isEmpty == false
            ? (instance.lastMessage ?? "Waiting for input")
            : "Waiting for input"
        poster.post(title: title, body: body, sessionId: instance.id, pid: instance.pid)
    }

    /// Forgets the last-posted time for a session. Called when a session ends so that
    /// a recycled session id (different process, same id) doesn't inherit the prior
    /// dedup state and silently drop its first banner.
    func clear(sessionId: String) {
        lastPostedAt.removeValue(forKey: sessionId)
    }
}
