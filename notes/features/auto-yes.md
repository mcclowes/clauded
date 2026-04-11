# Auto-yes feature

## What it does
When an instance the user has armed transitions to `awaitingInput` (Claude
Code's `Notification` hook fires), Clauded focuses the host terminal and
sends `1` then `Return` via AppleScript System Events — accepting the first
option in Claude Code's permission prompt without the user touching the
keyboard.

## Decisions (locked with user 2026-04-11)
1. Accessibility permission required — accepted as a one-time onboarding cost.
2. Keystroke is `"1"` then `Return` (explicit Yes). `Return`-only would
   accept whatever is highlighted, which isn't always Yes.
3. Per-instance toggle. **Defaults off.** State is in-memory only — resets
   on app restart. Matches the user's "just for the current session" intent.
4. 7-second per-session debounce. Protects against tight re-prompt loops.
5. Fire on any `Notification` event (no message-content filtering). The
   debounce is the safety net; we can add filtering later if it misbehaves.

## Architecture

```
HookDaemon ─event─▶ InstanceRegistry.apply
                          │
                          ├─ updates instance state
                          │
                          └─ if armed && transitioned to awaitingInput
                                  │
                                  ▼
                          onArmedAwaitingInput closure
                                  │
                                  ▼
                          AutoYesResponder.handle
                                  │
                                  ├─ debounce check (7s/session)
                                  │
                                  ▼
                          KeystrokeSender.sendAutoYes
                                  │
                                  ▼
                          TerminalFocuser.focus + AppleScript
                          (System Events → keystroke "1", keystroke return)
```

### Why a closure instead of @Observable observation
Registry already exposes a single `apply` chokepoint where we know the exact
state transition that just happened. A closure called from that chokepoint
gives perfect fire-once semantics without `withObservationTracking` ceremony.

### Why a separate AutoYesResponder
The debounce table + clock injection needs its own home; jamming it into the
registry would muddle the registry's "pure state machine" role and complicate
its tests. Responder is `@MainActor`, holds a `[sessionId: Date]` map.

### KeystrokeSender protocol
Lets us unit-test the debounce/dispatch logic with a spy. The real
`AppleScriptKeystrokeSender` is exercised manually — AppleScript injection
isn't worth mocking down to the script string.

## Implementation order (TDD)
1. `ClaudeInstance.autoYesEnabled` field + `InstanceRegistry.setAutoYes`
2. Registry fires `onArmedAwaitingInput` closure
3. `AutoYesResponder` handle / debounce
4. `AppleScriptKeystrokeSender` (manual smoke test only)
5. `InstanceRow` toggle UI
6. App boot wiring

## Open questions / future iterations
- Message-aware gating (skip non-permission notifications) — defer.
- Persistence across restart — explicitly not wanted now; revisit if UX demands.
- Visual indication that auto-yes just fired — nice-to-have.
- Auto-disarm when the user manually focuses the terminal — also nice-to-have.
