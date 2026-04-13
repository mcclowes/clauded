import Darwin
import Foundation

/// Pure helpers shared between the `clauded-notify` CLI and the main app/test target.
///
/// These live in their own folder so they can be compiled into both `clauded-notify`
/// (via the tool target) and `Clauded` (so `ClaudedTests` can exercise them). The CLI
/// runs on every Claude Code hook fire — these helpers must stay allocation-light and
/// side-effect-free.
enum NotifyShimCore {
    static let socketPathSuffix = "Library/Application Support/Clauded/daemon.sock"

    static func socketPath(home: String? = nil) -> String {
        let resolvedHome = home
            ?? ProcessInfo.processInfo.environment["HOME"]
            ?? NSHomeDirectory()
        return "\(resolvedHome)/\(socketPathSuffix)"
    }

    /// Resolution order:
    /// 1. `session_id` (snake_case, the canonical Claude Code field)
    /// 2. `sessionId` (camelCase, future-proof)
    /// 3. `<CLAUDE_PROJECT_DIR>:<ppid>` so we still emit a stable key when the hook
    ///    payload is missing both id fields.
    static func extractSessionId(
        from stdinJSON: [String: Any],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        parentPid: Int32 = getppid()
    ) -> String {
        if let id = stdinJSON["session_id"] as? String, !id.isEmpty { return id }
        if let id = stdinJSON["sessionId"] as? String, !id.isEmpty { return id }
        let project = environment["CLAUDE_PROJECT_DIR"] ?? ""
        return "\(project):\(parentPid)"
    }

    /// Resolution order:
    /// 1. `message` (already a presentable string)
    /// 2. `prompt` truncated to 200 characters (UserPromptSubmit payloads)
    /// 3. `reason` only when `kind == "notification"` — the Notification hook's payload
    ///    uses `reason` for the user-facing copy.
    static func extractMessage(
        from stdinJSON: [String: Any],
        kind: String,
        promptCharacterLimit: Int = 200
    ) -> String? {
        if let msg = stdinJSON["message"] as? String { return msg }
        if let prompt = stdinJSON["prompt"] as? String {
            return String(prompt.prefix(promptCharacterLimit))
        }
        if kind == "notification", let reason = stdinJSON["reason"] as? String {
            return reason
        }
        return nil
    }

    /// ISO-8601 timestamp with fractional seconds. Matches the format
    /// `HookEvent.makeDecoder()` parses, so events flow round-trip cleanly.
    static func isoNow(date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
