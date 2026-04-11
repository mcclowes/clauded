import Foundation
import Observation
import os
import SwiftUI

/// Holds the user-configurable mapping between `KeyBindingAction`s and the key
/// combos that trigger them. Persists to `UserDefaults` on every write.
///
/// Conflict policy: assigning a combo that's already claimed by another action
/// *steals* it — the previous owner loses its binding and shows up as "Unbound"
/// in settings until the user reassigns it. This avoids forcing a two-step
/// rebind dance (clear-then-set) or silently refusing a change the user clearly
/// intended.
@MainActor
@Observable
final class KeyBindingsStore {
    private static let logger = Logger(
        subsystem: "com.mcclowes.clauded",
        category: "KeyBindingsStore"
    )

    private static let persistenceKey = "com.mcclowes.clauded.keyBindings"

    static let defaults: [KeyBindingAction: KeyBinding] = [
        .selectPrevious: KeyBinding(characterString: "\u{F700}"),
        .selectNext: KeyBinding(characterString: "\u{F701}"),
        .activate: KeyBinding(characterString: "\r"),
        .toggleAutoYes: KeyBinding(characterString: " "),
    ]

    private(set) var bindings: [KeyBindingAction: KeyBinding]

    private let storage: UserDefaults

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        if let data = storage.data(forKey: Self.persistenceKey),
           let decoded = try? JSONDecoder().decode(
               [KeyBindingAction: KeyBinding].self,
               from: data
           )
        {
            bindings = decoded
        } else {
            bindings = Self.defaults
        }
    }

    /// The binding currently assigned to `action`, or `nil` if unbound.
    func binding(for action: KeyBindingAction) -> KeyBinding? {
        bindings[action]
    }

    /// Assigns `binding` to `action`. Any other action previously bound to the
    /// same combo is cleared (steal-on-conflict).
    func setBinding(_ binding: KeyBinding, for action: KeyBindingAction) {
        for (existing, value) in bindings where existing != action && value == binding {
            bindings.removeValue(forKey: existing)
        }
        bindings[action] = binding
        persist()
    }

    /// Clears the binding for `action` without touching others.
    func clearBinding(for action: KeyBindingAction) {
        bindings.removeValue(forKey: action)
        persist()
    }

    func resetToDefaults() {
        bindings = Self.defaults
        persist()
    }

    /// Reverse lookup: returns the action currently bound to the given key
    /// combo, or `nil` if no action claims it.
    func action(forCharacter character: Character, modifiers: EventModifiers) -> KeyBindingAction? {
        let incoming = KeyBinding(character: character, modifiers: modifiers)
        return bindings.first(where: { $0.value == incoming })?.key
    }

    private func persist() {
        do {
            let data = try JSONEncoder().encode(bindings)
            storage.set(data, forKey: Self.persistenceKey)
        } catch {
            Self.logger.error(
                "Failed to persist key bindings: \(String(describing: error), privacy: .public)"
            )
        }
    }
}
