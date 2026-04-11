import Foundation
import os

/// Delivers a synthetic "yes" keystroke when an armed instance is waiting on input.
///
/// The responder owns two pieces of state the registry deliberately doesn't:
///
/// 1. A per-session debounce table. Claude Code can fire `Notification` hooks in
///    quick succession (e.g. nested permission prompts); the user-configured
///    minimum interval prevents an auto-yes runaway from machine-gunning a
///    terminal that's no longer paying attention.
/// 2. A clock seam. Tests inject `now` so debounce behaviour is deterministic
///    without needing to advance real time.
///
/// All keystroke delivery is delegated to a `KeystrokeSender` so the AppleScript
/// side stays mockable.
@MainActor
final class AutoYesResponder {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "AutoYesResponder")

    private let sender: KeystrokeSender
    private let minimumInterval: TimeInterval
    private let now: () -> Date
    private var lastFiredAt: [String: Date] = [:]

    init(
        sender: KeystrokeSender,
        minimumInterval: TimeInterval = 4,
        now: @escaping () -> Date = Date.init
    ) {
        self.sender = sender
        self.minimumInterval = minimumInterval
        self.now = now
    }

    func handle(_ instance: ClaudeInstance) {
        let currentTime = now()
        if let last = lastFiredAt[instance.id],
           currentTime.timeIntervalSince(last) < minimumInterval
        {
            Self.logger.debug(
                "auto-yes debounced for session \(instance.id, privacy: .public)"
            )
            return
        }
        lastFiredAt[instance.id] = currentTime
        sender.sendAutoYes(to: instance)
    }
}
