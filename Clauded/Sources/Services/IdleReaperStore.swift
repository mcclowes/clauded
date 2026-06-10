import Foundation
import Observation

/// What Clauded does with a session that has been idle past the threshold. Off by
/// default — the panel only changes once the user opts into cleanup.
enum IdleBehavior: String, CaseIterable, Identifiable {
    /// Leave idle sessions exactly where they are.
    case off
    /// Tuck idle sessions into a collapsed "Stale" group at the bottom of the panel.
    case collapse
    /// Send SIGTERM to idle sessions and drop them from the panel.
    case autoClose

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .off: "Leave them"
        case .collapse: "Collapse into a stale group"
        case .autoClose: "Close automatically (SIGTERM)"
        }
    }
}

/// Persisted configuration for the idle-session reaper (#4). Defaults to `.off` with a
/// 4-hour threshold so nothing is hidden or killed until the user explicitly asks for it.
@MainActor
@Observable
final class IdleReaperStore {
    private static let behaviorKey = "com.mcclowes.clauded.idleReaper.behavior"
    private static let thresholdKey = "com.mcclowes.clauded.idleReaper.threshold"

    static let defaultThreshold: TimeInterval = 4 * 60 * 60

    private(set) var behavior: IdleBehavior
    private(set) var threshold: TimeInterval

    private let storage: UserDefaults

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        if let raw = storage.string(forKey: Self.behaviorKey),
           let parsed = IdleBehavior(rawValue: raw)
        {
            behavior = parsed
        } else {
            behavior = .off
        }
        let stored = storage.double(forKey: Self.thresholdKey)
        threshold = stored > 0 ? stored : Self.defaultThreshold
    }

    func setBehavior(_ value: IdleBehavior) {
        behavior = value
        storage.set(value.rawValue, forKey: Self.behaviorKey)
    }

    func setThreshold(_ value: TimeInterval) {
        guard value > 0 else { return }
        threshold = value
        storage.set(value, forKey: Self.thresholdKey)
    }
}
