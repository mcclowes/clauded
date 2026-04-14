import Foundation
import os
import UserNotifications

/// Delivers notifications via `UNUserNotificationCenter`. Each post uses the session
/// id as its `UNNotificationRequest.identifier`, so a second post for the same
/// session replaces the first in Notification Center rather than stacking.
///
/// Registers a single category (`clauded.awaiting-input`) with a "Focus" action
/// that calls `TerminalFocuser` when tapped. The pid is threaded through the
/// request's `userInfo` so the delegate can resolve it without re-querying.
private let userNotificationLogger = Logger(
    subsystem: "com.mcclowes.clauded",
    category: "UserNotificationPoster"
)
private let awaitingInputCategoryIdentifier = "clauded.awaiting-input"
private let focusActionIdentifier = "clauded.focus"

@MainActor
final class UserNotificationPoster: NSObject, NotificationPosting, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    override init() {
        super.init()
        center.delegate = self
        registerCategory()
        requestAuthorization()
    }

    func post(title: String, body: String, sessionId: String, pid: Int32?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = awaitingInputCategoryIdentifier
        content.sound = .default
        if let pid {
            content.userInfo = ["pid": Int(pid), "sessionId": sessionId]
        } else {
            content.userInfo = ["sessionId": sessionId]
        }
        // Threading identifier groups banners from the same session in Notification
        // Center even if the system chooses not to replace them outright.
        content.threadIdentifier = sessionId

        let request = UNNotificationRequest(
            identifier: sessionId,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                userNotificationLogger.error("Notification post failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Show banners even when Clauded is frontmost — the menu bar doesn't
        // natively get user attention the way a banner does.
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let pid = (userInfo["pid"] as? Int).map { pid_t($0) }
        let action = response.actionIdentifier
        let isFocusAction = action == focusActionIdentifier
            || action == UNNotificationDefaultActionIdentifier
        if isFocusAction, let pid {
            Task { @MainActor in
                TerminalFocuser.focus(pid: pid)
            }
        }
        completionHandler()
    }

    private func registerCategory() {
        let focus = UNNotificationAction(
            identifier: focusActionIdentifier,
            title: "Focus terminal",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: awaitingInputCategoryIdentifier,
            actions: [focus],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
    }

    private func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                userNotificationLogger.error(
                    "Notification authorization failed: \(String(describing: error), privacy: .public)"
                )
            } else if !granted {
                userNotificationLogger.info("Notification authorization denied by user")
            }
        }
    }
}
