# Quick-reply spike (issue #10)

Two candidate mechanisms for sending a canned string into an awaiting Claude Code session from the menu bar:

## Option 1 — AppleScript keystroke injection

- Focus the terminal hosting the session (already implemented as `TerminalFocuser`).
- Drive `System Events` via `NSAppleScript` to type the literal text + Return.
- Requires macOS Accessibility permission (same grant we already request for auto-yes).

**Pros.** Works today, reuses the `AppleScriptKeystrokeSender` plumbing already proven in production for auto-yes. No dependency on Claude Code internals.

**Cons.** Fragile under window-focus races (mitigated with a small settle delay, as in auto-yes). Types into whatever app is frontmost if focus fails to land — so we must log and bail rather than retry blindly.

## Option 2 — Direct write to the session's input

Ideal: Claude Code exposes a control channel (named pipe, socket, stdin) Clauded could write to, delivering the canned string without round-tripping through the UI layer.

**Status.** No such channel exists in the public hook contract as of 2026-04. The hooks are one-way (Claude Code → shim). There is no supported IPC to inject prompts.

**Decision.** Defer until upstream adds a channel. If/when Claude Code ships a control socket, we revisit — the responder protocol already abstracts delivery, so swapping is a one-file change.

## Chosen approach

Ship Option 1 behind an explicit opt-in setting (default off). Reuse the existing `KeystrokeSender` protocol and Accessibility permission path. Keep the surface minimal: three canned replies (`yes`, `no`, `continue`) shown as chips on `.awaitingInput` rows.
