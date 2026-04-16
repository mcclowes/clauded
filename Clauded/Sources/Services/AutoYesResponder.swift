import Foundation
import os

/// Delivers a synthetic "yes" keystroke when an armed instance is waiting on input.
///
/// The responder owns three pieces of policy the registry deliberately doesn't:
///
/// 1. A message classifier. Claude Code's `Notification` hook fires for both
///    numbered permission prompts *and* idle "waiting for your input" nudges.
///    Typing `1` is only meaningful for the former — for the latter it drops a
///    literal `1` into the composer and submits it. The classifier gates the
///    send so only permission-style messages trigger the keystroke, with
///    unrecognised messages skipped on the "missed auto-yes is cheaper than a
///    spurious submission" principle.
/// 2. A per-session debounce table. Claude Code can fire `Notification` hooks in
///    quick succession (e.g. nested permission prompts); the user-configured
///    minimum interval prevents an auto-yes runaway from machine-gunning a
///    terminal that's no longer paying attention.
/// 3. A clock seam. Tests inject `now` so debounce behaviour is deterministic
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
        guard Self.isPermissionPrompt(message: instance.lastMessage) else {
            Self.logger.debug(
                "auto-yes skipped for session \(instance.id, privacy: .public) — not a permission prompt"
            )
            return
        }
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

    /// Classifies a Notification-hook message as a numbered permission prompt.
    ///
    /// Claude Code's `Notification` hook is documented to carry either
    /// `"Claude needs your permission to use <tool>"` (permission prompts, with
    /// a 1/2/3 menu in the terminal) or `"Claude is waiting for your input"`
    /// (60-second idle nudge, no menu). Only the former is answerable with `1`
    /// + Return. Anything we don't recognise is treated as non-actionable so we
    /// never fabricate a user message.
    static func isPermissionPrompt(message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        let lowercased = message.lowercased()
        if lowercased.contains("waiting for your input") { return false }
        return lowercased.contains("permission")
    }
}
