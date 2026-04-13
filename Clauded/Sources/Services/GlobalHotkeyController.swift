import AppKit
import os
import SwiftUI

/// Installs a system-wide hotkey monitor. When the configured combo is pressed
/// from any app, `onTrigger` fires on the main actor.
///
/// Uses `NSEvent` global + local monitors rather than Carbon's
/// `RegisterEventHotKey`. Tradeoff: global monitors require Accessibility
/// permission (which Clauded already needs for auto-yes), but the
/// implementation stays in pure Swift. The local monitor covers the case where
/// one of Clauded's own windows (e.g. Settings) is key — global monitor skips
/// those.
@MainActor
final class GlobalHotkeyController {
    private static let logger = Logger(
        subsystem: "com.mcclowes.clauded",
        category: "GlobalHotkeyController"
    )

    var onTrigger: (() -> Void)?

    private var binding: KeyBinding?
    private var globalMonitor: Any?
    private var localMonitor: Any?

    func update(binding: KeyBinding?) {
        self.binding = binding
        stop()
        guard binding != nil else { return }
        start()
    }

    private func start() {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Extract Sendable value types from NSEvent synchronously — NSEvent
            // itself is non-Sendable under Swift 6 strict concurrency, so we
            // cannot carry it across the actor hop.
            let character = event.charactersIgnoringModifiers?.first
            let modifiers = Self.eventModifiers(from: event.modifierFlags)
            MainActor.assumeIsolated {
                guard let self, self.matches(character: character, modifiers: modifiers) else { return }
                self.onTrigger?()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let character = event.charactersIgnoringModifiers?.first
            let modifiers = Self.eventModifiers(from: event.modifierFlags)
            let didMatch: Bool = MainActor.assumeIsolated {
                guard let self, self.matches(character: character, modifiers: modifiers) else {
                    return false
                }
                self.onTrigger?()
                return true
            }
            return didMatch ? nil : event
        }
    }

    private func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
            self.localMonitor = nil
        }
    }

    private func matches(character: Character?, modifiers: EventModifiers) -> Bool {
        guard let target = binding, let character else { return false }
        return character == target.firstCharacter && modifiers == target.eventModifiers
    }

    nonisolated static func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var mods: EventModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        return mods
    }
}
