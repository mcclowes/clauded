import Foundation

/// Abstraction over "type a yes-response into the terminal hosting this session."
///
/// Exists so the responder can be unit-tested with a spy. Real implementation
/// (`AppleScriptKeystrokeSender`) drives `TerminalFocuser` + System Events
/// AppleScript and is exercised manually.
@MainActor
protocol KeystrokeSender {
    func sendAutoYes(to instance: ClaudeInstance)
    /// Types `text` followed by Return into the terminal hosting `instance`. Used by
    /// the quick-reply feature (#10) to send canned strings like "yes" / "continue".
    func sendQuickReply(_ text: String, to instance: ClaudeInstance)
}
