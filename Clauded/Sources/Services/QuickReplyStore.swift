import Foundation
import Observation
import os

/// Persisted state for the quick-reply feature (#10). Opt-in: default `enabled = false`
/// so no keystrokes can be sent from the menu bar until the user flips the toggle in
/// Settings. Responses are stored as a plain string array because the set is small
/// and hand-editable from the UI.
@MainActor
@Observable
final class QuickReplyStore {
    private static let logger = Logger(subsystem: "com.mcclowes.clauded", category: "QuickReplyStore")
    private static let enabledKey = "com.mcclowes.clauded.quickReply.enabled"
    private static let responsesKey = "com.mcclowes.clauded.quickReply.responses"

    static let defaultResponses: [String] = ["yes", "no", "continue"]

    private(set) var enabled: Bool
    private(set) var responses: [String]

    private let storage: UserDefaults

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        enabled = storage.bool(forKey: Self.enabledKey)
        if let saved = storage.stringArray(forKey: Self.responsesKey), !saved.isEmpty {
            responses = saved
        } else {
            responses = Self.defaultResponses
        }
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        storage.set(value, forKey: Self.enabledKey)
    }

    func setResponses(_ values: [String]) {
        // Reject empties and duplicates so the UI never has to guard against them when
        // rendering chips. Preserve order for user intent.
        var seen = Set<String>()
        let clean = values
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
        responses = clean.isEmpty ? Self.defaultResponses : clean
        storage.set(responses, forKey: Self.responsesKey)
    }
}
