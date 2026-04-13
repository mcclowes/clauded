import AppKit
import ApplicationServices
import Observation

/// Tracks whether Clauded has the Accessibility permission needed to post
/// synthetic keystrokes via `System Events`. Without this grant, auto-yes is
/// a no-op — the AppleScript errors with code 1002 ("not allowed to send
/// keystrokes") or -1743 (TCC denial). We surface that state so the panel
/// can show a banner instead of silently dropping keystrokes.
@MainActor
@Observable
final class AccessibilityPermissionState {
    private(set) var isTrusted: Bool

    init() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Re-poll `AXIsProcessTrusted`. Cheap — a single TCC lookup.
    func refresh() {
        isTrusted = AXIsProcessTrusted()
    }

    /// Called by the keystroke sender when AppleScript reports a permission
    /// denial. Flips `isTrusted` to false so the banner appears immediately,
    /// before the next poll would catch it.
    func markDenied() {
        isTrusted = false
    }

    /// Deep-link into System Settings → Privacy & Security → Accessibility.
    func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        if let url {
            NSWorkspace.shared.open(url)
        }
    }
}
