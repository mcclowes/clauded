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

    /// Soft cap to keep memory bounded even in the degenerate case where SessionEnd hooks
    /// never fire and PID reuse defeats the reaper. Oldest-finished rows beyond this are
    /// evicted first.
    private static let maxInstances = 200

    /// How long after reaping we continue to ignore events for a given session id. Late
    /// events arriving after reap shouldn't resurrect the row as a zombie.
    private static let reapedEventGraceWindow: TimeInterval = 120

    private(set) var instances: [ClaudeInstance] = []

    /// Sessions recently removed by the reaper. Events arriving for these ids within the
    /// grace window are dropped rather than resurrecting the row.
    @ObservationIgnored
    private var recentlyReaped: [String: Date] = [:]

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
        pruneRecentlyReaped()

        if let reapedAt = recentlyReaped[event.sessionId],
           Date().timeIntervalSince(reapedAt) < Self.reapedEventGraceWindow
        {
            Self.logger.debug("Dropping late event for reaped session: \(event.sessionId, privacy: .public)")
            return
        }

        let newState = state(for: event.kind)

        if let index = instances.firstIndex(where: { $0.id == event.sessionId }) {
            if event.kind == .sessionEnd {
                instances.remove(at: index)
                Self.logger.debug("Session ended: \(event.sessionId, privacy: .public)")
                return
            }
            // Mutate through a local copy and replace in one shot so Observation fires once.
            var updated = instances[index]
            updated.state = newState
            updated.lastActivity = event.timestamp
            if let pid = event.pid, updated.pid != pid {
                updated.pid = pid
                updated.processStartTime = Self.processStartTime(pid)
            } else if updated.pid == nil {
                updated.pid = event.pid
            }
            updated.projectDir = event.projectDir
            if let message = event.message {
                updated.lastMessage = message
            }
            instances[index] = updated
            return
        }

        guard event.kind != .sessionEnd else { return }
        let startTime = event.pid.flatMap(Self.processStartTime)
        instances.append(
            ClaudeInstance(
                id: event.sessionId,
                projectDir: event.projectDir,
                pid: event.pid,
                processStartTime: startTime,
                state: newState,
                lastActivity: event.timestamp,
                lastMessage: event.message
            )
        )
        Self.logger.debug("Session registered: \(event.sessionId, privacy: .public)")
        enforceCapacity()
    }

    func remove(sessionId: String) {
        instances.removeAll { $0.id == sessionId }
    }

    /// Arms or disarms auto-yes for a single session. No-op if the session is unknown.
    func setAutoYes(sessionId: String, enabled: Bool) {
        guard let index = instances.firstIndex(where: { $0.id == sessionId }) else { return }
        instances[index].autoYesEnabled = enabled
    }

    func clear() {
        instances.removeAll()
        recentlyReaped.removeAll()
    }

    /// Drops instances whose backing process no longer exists *or* whose backing process
    /// has been replaced by PID reuse.
    ///
    /// Claude Code fires `SessionEnd` on clean exit, but if the user closes the terminal
    /// tab/window abruptly the hook never runs and the entry sits in the registry forever.
    /// We reconcile by probing each known pid; anything that's gone — or whose start time
    /// no longer matches what we captured at registration — gets reaped.
    ///
    /// `isAlive` and `startTime` are injected so tests can drive them without real processes.
    func reapDeadInstances(
        isAlive: (pid_t) -> Bool = InstanceRegistry.processIsAlive,
        startTime: (pid_t) -> Date? = InstanceRegistry.processStartTime
    ) {
        let before = instances.count
        var reapedIds: [String] = []

        instances.removeAll { instance in
            guard let pid = instance.pid else { return false }
            if !isAlive(pid) {
                Self.logger.info("Reaping dead session: \(instance.id, privacy: .public) pid=\(pid)")
                reapedIds.append(instance.id)
                return true
            }
            // Alive — but is it still the same process? Detect PID reuse by comparing
            // the captured start time to the current one. If we don't have a recorded
            // start time we're conservative and keep the row.
            guard let currentStart = startTime(pid), let recorded = instance.processStartTime else {
                return false
            }
            // Allow a small tolerance for clock jitter between captures.
            if abs(currentStart.timeIntervalSince(recorded)) > 1.0 {
                Self.logger.info(
                    "Reaping PID-reused session: \(instance.id, privacy: .public) pid=\(pid)"
                )
                reapedIds.append(instance.id)
                return true
            }
            return false
        }

        let now = Date()
        for id in reapedIds {
            recentlyReaped[id] = now
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

    /// Wall-clock start time of the process identified by `pid`, or `nil` if the process
    /// no longer exists. Reads `kinfo_proc.kp_proc.p_starttime` via sysctl.
    nonisolated static func processStartTime(_ pid: pid_t) -> Date? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        let startTime = info.kp_proc.p_starttime
        let interval = TimeInterval(startTime.tv_sec) + TimeInterval(startTime.tv_usec) / 1_000_000
        return Date(timeIntervalSince1970: interval)
    }

    private func pruneRecentlyReaped() {
        let cutoff = Date().addingTimeInterval(-Self.reapedEventGraceWindow)
        recentlyReaped = recentlyReaped.filter { $0.value > cutoff }
    }

    private func enforceCapacity() {
        guard instances.count > Self.maxInstances else { return }
        // Evict finished/idle sessions first, oldest-by-activity.
        let excess = instances.count - Self.maxInstances
        let sorted = instances.enumerated().sorted { lhs, rhs in
            let lhsEvictable = lhs.element.state == .finished || lhs.element.state == .idle
            let rhsEvictable = rhs.element.state == .finished || rhs.element.state == .idle
            if lhsEvictable != rhsEvictable {
                return lhsEvictable
            }
            return lhs.element.lastActivity < rhs.element.lastActivity
        }
        let evictIndices = Set(sorted.prefix(excess).map(\.offset))
        instances = instances.enumerated()
            .filter { !evictIndices.contains($0.offset) }
            .map(\.element)
    }

    private func state(for kind: HookEventKind) -> InstanceState {
        switch kind {
        case .sessionStart: .idle
        case .userPromptSubmit: .working
        case .notification: .awaitingInput
        case .stop: .finished
        case .sessionEnd: .idle // unreachable: apply() handles sessionEnd before calling this
        }
    }
}
