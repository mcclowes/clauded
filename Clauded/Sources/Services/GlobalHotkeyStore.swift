import Foundation
import Observation
import os
import SwiftUI

/// Persists the single "jump to next attention-needing session" global hotkey.
///
/// Kept distinct from `KeyBindingsStore` because global hotkeys have different
/// semantics (system-wide capture, single binding) and different UX (can be
/// cleared, not just rebound). A `nil` binding means the hotkey is disabled.
@MainActor
@Observable
final class GlobalHotkeyStore {
    private static let logger = Logger(
        subsystem: "com.mcclowes.clauded",
        category: "GlobalHotkeyStore"
    )

    private static let persistenceKey = "com.mcclowes.clauded.globalHotkey.jumpToAttention"
    private static let didSetKey = "com.mcclowes.clauded.globalHotkey.jumpToAttention.didSet"

    static let defaultBinding = KeyBinding(
        characterString: "j",
        modifiers: [.control, .option, .command]
    )

    private(set) var jumpToAttention: KeyBinding?

    private let storage: UserDefaults

    init(storage: UserDefaults = .standard) {
        self.storage = storage
        if storage.bool(forKey: Self.didSetKey) {
            if let data = storage.data(forKey: Self.persistenceKey),
               let decoded = try? JSONDecoder().decode(KeyBinding.self, from: data)
            {
                jumpToAttention = decoded
            } else {
                jumpToAttention = nil
            }
        } else {
            jumpToAttention = Self.defaultBinding
        }
    }

    func setJumpToAttention(_ binding: KeyBinding?) {
        jumpToAttention = binding
        storage.set(true, forKey: Self.didSetKey)
        if let binding {
            do {
                let data = try JSONEncoder().encode(binding)
                storage.set(data, forKey: Self.persistenceKey)
            } catch {
                Self.logger.error(
                    "Failed to persist global hotkey: \(String(describing: error), privacy: .public)"
                )
            }
        } else {
            storage.removeObject(forKey: Self.persistenceKey)
        }
    }

    func resetToDefault() {
        storage.removeObject(forKey: Self.didSetKey)
        storage.removeObject(forKey: Self.persistenceKey)
        jumpToAttention = Self.defaultBinding
    }
}
