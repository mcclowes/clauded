import AppKit
import Foundation
import os

/// Real keystroke delivery: focus the terminal hosting the session, then drive
/// AppleScript System Events to type `1` followed by Return.
///
/// Why `1` + Return rather than just Return: Claude Code's permission prompts
/// number their options ("1. Yes ...", "2. Yes, and don't ask again", "3. No").
/// Pressing Return alone accepts whatever happens to be highlighted, which is
/// usually but not always Yes. Typing the literal `1` then Return picks the
/// first option deterministically.
///
/// Requires Accessibility permission (System Settings → Privacy & Security →
/// Accessibility) the first time it runs. macOS shows the user a prompt; if
/// denied, the AppleScript fails and we just log it — Claude Code is unaffected
/// because we never block its terminal.
@MainActor
final class AppleScriptKeystrokeSender: KeystrokeSender {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "AppleScriptKeystrokeSender")

    /// Delay between focusing the terminal and sending the keystroke. Without this,
    /// the keystroke arrives before the focus change has been picked up by the
    /// terminal and gets dropped on the floor (or, worse, types into whatever app
    /// happened to be frontmost).
    private static let focusSettleDelay: TimeInterval = 0.15

    private let permissionState: AccessibilityPermissionState?

    init(permissionState: AccessibilityPermissionState? = nil) {
        self.permissionState = permissionState
    }

    func sendAutoYes(to instance: ClaudeInstance) {
        guard let pid = instance.pid else {
            Self.logger.info("Skipping auto-yes for session with no pid: \(instance.id, privacy: .public)")
            return
        }
        TerminalFocuser.focus(pid: pid)
        // Schedule the keystroke onto the next runloop tick + a small settle delay
        // so the focus change has time to land before we type into it.
        let permissionState = permissionState
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusSettleDelay) {
            Self.runKeystrokeScript(sessionId: instance.id, permissionState: permissionState)
        }
    }

    private static func runKeystrokeScript(
        sessionId: String,
        permissionState: AccessibilityPermissionState?
    ) {
        let source = """
        tell application "System Events"
            keystroke "1"
            delay 0.15
            keystroke return
        end tell
        """
        Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
            guard let error else { return }
            // Logger inlined here so it doesn't cross the MainActor boundary;
            // matches the pattern used in TerminalFocuser.
            let logger = Logger(subsystem: "com.mcclowes.clauded", category: "AppleScriptKeystrokeSender")
            let code = (error["NSAppleScriptErrorNumber"] as? Int) ?? 0
            // -1743: TCC denial before AppleScript even runs.
            //  1002: System Events ran but Clauded lacks Accessibility ("not allowed to send keystrokes").
            // Both mean the same user-facing fix, so treat them identically.
            if code == -1743 || code == 1002 {
                logger.error(
                    """
                    Auto-yes failed: Accessibility permission denied. \
                    Grant access in System Settings → Privacy & Security → Accessibility \
                    for session \(sessionId, privacy: .public).
                    """
                )
                if let permissionState {
                    Task { @MainActor in permissionState.markDenied() }
                }
            } else {
                let errorDescription = String(describing: error)
                logger.error(
                    """
                    Auto-yes AppleScript failed for session \(sessionId, privacy: .public): \
                    \(errorDescription, privacy: .public)
                    """
                )
            }
        }
    }
}
