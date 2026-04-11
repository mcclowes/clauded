import Foundation

/// Lifecycle state of a single Claude Code session as understood by Clauded.
///
/// The source of truth is the stream of hook events fired by Claude Code itself.
/// We never poll the process directly — states transition purely in response to
/// events from the notify shim.
enum InstanceState {
    /// Session has started but no prompt has been submitted yet.
    case idle
    /// A prompt was submitted and the agent is working.
    case working
    /// The agent has fired a Notification hook — waiting on the user (permission prompt or idle input).
    case awaitingInput
    /// Agent finished its turn (Stop hook) but session is still alive.
    case finished
}

struct ClaudeInstance: Identifiable, Equatable {
    let id: String
    var projectDir: String
    var pid: Int32?
    /// Wall-clock start time of the session's owning process, captured the first time we
    /// learn its pid. Used to distinguish "still running" from "PID was recycled by another
    /// process" in the reaper — `kill(pid, 0)` alone cannot tell those apart.
    var processStartTime: Date?
    var state: InstanceState
    var lastActivity: Date
    var lastMessage: String?
    /// Per-session opt-in: when true, Clauded auto-responds to permission prompts on
    /// the user's behalf. In-memory only — resets on app restart by design.
    var autoYesEnabled: Bool = false

    var projectName: String {
        (projectDir as NSString).lastPathComponent
    }

    var needsAttention: Bool {
        state == .awaitingInput
    }
}
