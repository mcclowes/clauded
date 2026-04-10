import Darwin
import Foundation
import Observation
import os

/// Live view of every Claude Code session Clauded currently knows about.
///
/// State transitions are driven by `HookEvent`s arriving from the daemon. The registry
/// is the single source of truth for the menu bar popover.
@MainActor
@Observable
final class InstanceRegistry {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "InstanceRegistry")

    private(set) var instances: [ClaudeInstance] = []

    /// Number of instances currently waiting on the user. Drives the menu bar badge.
    var needsAttentionCount: Int {
        instances.count(where: { $0.needsAttention })
    }

    var sortedInstances: [ClaudeInstance] {
        instances.sorted { lhs, rhs in
            if lhs.needsAttention != rhs.needsAttention {
                return lhs.needsAttention
            }
            return lhs.lastActivity > rhs.lastActivity
        }
    }

    func apply(event: HookEvent) {
        let newState = state(for: event.kind)
        if let index = instances.firstIndex(where: { $0.id == event.sessionId }) {
            if event.kind == .sessionEnd {
                instances.remove(at: index)
                Self.logger.info("Session ended: \(event.sessionId, privacy: .public)")
                return
            }
            instances[index].state = newState
            instances[index].lastActivity = event.timestamp
            instances[index].pid = event.pid ?? instances[index].pid
            instances[index].projectDir = event.projectDir
            if let message = event.message {
                instances[index].lastMessage = message
            }
        } else {
            guard event.kind != .sessionEnd else { return }
            instances.append(
                ClaudeInstance(
                    id: event.sessionId,
                    projectDir: event.projectDir,
                    pid: event.pid,
                    state: newState,
                    lastActivity: event.timestamp,
                    lastMessage: event.message
                )
            )
            Self.logger.info("Session registered: \(event.sessionId, privacy: .public)")
        }
    }

    func remove(sessionId: String) {
        instances.removeAll { $0.id == sessionId }
    }

    func clear() {
        instances.removeAll()
    }

    /// Drops instances whose backing process no longer exists.
    ///
    /// Claude Code fires `SessionEnd` on clean exit, but if the user closes the terminal
    /// tab/window abruptly the hook never runs and the entry sits in the registry forever.
    /// We reconcile by probing each known pid; anything that's gone gets reaped.
    ///
    /// `isAlive` is injected so tests can drive it without real processes.
    func reapDeadInstances(isAlive: (pid_t) -> Bool = InstanceRegistry.processIsAlive) {
        let before = instances.count
        instances.removeAll { instance in
            guard let pid = instance.pid else { return false }
            let alive = isAlive(pid)
            if !alive {
                Self.logger.info("Reaping dead session: \(instance.id, privacy: .public) pid=\(pid)")
            }
            return !alive
        }
        let removed = before - instances.count
        if removed > 0 {
            Self.logger.info("Reaper removed \(removed) instance(s)")
        }
    }

    /// `kill(pid, 0)` is the POSIX idiom for "does this process exist and can I signal it?"
    /// Returns 0 on success, or -1 with errno=ESRCH when the process is gone. EPERM means
    /// it exists but we're not allowed to touch it — still alive, so we treat it as such.
    nonisolated static func processIsAlive(_ pid: pid_t) -> Bool {
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func state(for kind: HookEventKind) -> InstanceState {
        switch kind {
        case .sessionStart: .idle
        case .userPromptSubmit: .working
        case .notification: .awaitingInput
        case .stop: .finished
        case .sessionEnd: .stopped
        }
    }
}
