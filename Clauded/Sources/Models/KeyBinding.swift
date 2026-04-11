import SwiftUI

/// User-rebindable actions exposed by the instance panel and settings.
enum KeyBindingAction: String, CaseIterable, Codable {
    case selectNext
    case selectPrevious
    case activate
    case toggleAutoYes

    var displayName: String {
        switch self {
        case .selectNext: "Select next instance"
        case .selectPrevious: "Select previous instance"
        case .activate: "Focus selected terminal"
        case .toggleAutoYes: "Toggle auto-yes on selection"
        }
    }
}

/// A key + modifier combo bound to a `KeyBindingAction`.
///
/// We persist the literal character (the unicode codepoint SwiftUI surfaces via
/// `KeyEquivalent.character` — named keys map to the private-use area, e.g.
/// `↑` → `\u{F700}`) and an explicit `EventModifiers` rawValue bitmask. Storing
/// the raw character keeps the on-disk shape stable even if Apple tweaks
/// KeyEquivalent's internals, and sidesteps having to special-case every named
/// key in the persistence layer.
struct KeyBinding: Codable, Equatable, Hashable {
    let character: String
    let modifiers: Int

    init(character: Character, modifiers: EventModifiers = []) {
        self.character = String(character)
        self.modifiers = modifiers.rawValue
    }

    init(characterString: String, modifiers: EventModifiers = []) {
        character = characterString
        self.modifiers = modifiers.rawValue
    }

    var eventModifiers: EventModifiers {
        EventModifiers(rawValue: modifiers)
    }

    var firstCharacter: Character? {
        character.first
    }
}
