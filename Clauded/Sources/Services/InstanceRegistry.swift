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
