import Foundation

/// Hook event names forwarded by `clauded-notify`. These map 1:1 to Claude Code's
/// hook events; Clauded installs hooks for the subset it cares about.
enum HookEventKind: String, Codable {
    case sessionStart = "session-start"
    case sessionEnd = "session-end"
    case notification
    case stop
    case userPromptSubmit = "prompt"
}

/// Wire format written by `clauded-notify` to the daemon socket. One JSON object per line.
///
/// The shim enriches the raw hook stdin JSON with the event kind, pid, project dir,
/// and a timestamp so the daemon doesn't need to trust clocks or re-derive context.
struct HookEvent: Codable {
    let kind: HookEventKind
    let sessionId: String
    let projectDir: String
    let pid: Int32?
    let timestamp: Date
    let message: String?

    enum CodingKeys: String, CodingKey {
        case kind
        case sessionId = "session_id"
        case projectDir = "project_dir"
        case pid
        case timestamp
        case message
    }
}
