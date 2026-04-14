import Foundation
import Observation
import os

/// Glue between the UI and the keystroke sender for the quick-reply feature (#10).
///
/// Holds a reference to the store so the view layer can bind to `store.enabled`
/// / `store.responses` directly, and exposes a single `send` entry point that
/// no-ops when the feature is disabled. Keeping this check here (rather than in
/// the view) means a future hotkey trigger can't accidentally fire while the
/// user has the toggle off.
@MainActor
@Observable
final class QuickReplyController {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "QuickReplyController")

    let store: QuickReplyStore

    @ObservationIgnored
    private let sender: KeystrokeSender

    init(store: QuickReplyStore, sender: KeystrokeSender) {
        self.store = store
        self.sender = sender
    }

    func send(_ text: String, to instance: ClaudeInstance) {
        guard store.enabled else {
            Self.logger.info("Ignoring quick-reply: feature disabled")
            return
        }
        sender.sendQuickReply(text, to: instance)
    }
}
