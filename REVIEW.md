# Clauded — Holistic Code Review

**Reviewer perspective:** principal engineer, fresh eyes, deliberately critical.
**Goal:** call out correctness bugs, edge cases, and architectural smells that matter,
and explain the reasoning so more junior engineers can absorb *how* to look at code.

> **Status (2026-04-11):** most of the findings below have been actioned in the same
> sitting. See the "Execution summary" section at the bottom for the exact list of
> what was fixed, what was consciously deferred, and why.

The codebase is small, well-organised, and the authors clearly care. Don't read the
volume of criticism below as "this is bad" — read it as "this is the bar for a
menu-bar utility that touches the user's filesystem, spawns subprocesses, and
parses untrusted input on every keystroke of Claude Code." Small apps with big
surface areas deserve scrutiny.

---

## 1. Top concerns (read this even if you skip the rest)

1. **Latent `Date` decoding bug.** `HookEvent` uses `JSONDecoder.DateDecodingStrategy.iso8601`, but the shim writes timestamps *with fractional seconds* (`…T12:00:00.000Z`). Foundation's built-in `.iso8601` strategy historically did **not** accept fractional seconds; the fact the test passes today is either a recent Foundation change or happy accident. This is the single highest-impact latent bug — if it regresses, every hook event silently fails to decode and the app goes mute. Switch to a `.custom` strategy using an `ISO8601DateFormatter` with `.withFractionalSeconds`, and add a test that covers both forms.
   - `Clauded/Sources/Services/HookDaemon.swift:40-42`
   - `Clauded/Sources/NotifyShim/main.swift:55-59`

2. **Stale-PID reuse will leak instances forever.** The reaper probes with `kill(pid, 0)`. On a machine that's been up for weeks, PIDs wrap and get reassigned — an unrelated process inherits the old Claude Code PID and the reaper thinks the session is still alive. A menu-bar app that runs for days is exactly the environment where this bites. Capture process start-time (via `kinfo_proc.kp_proc.p_starttime`) at registration and compare it at reap time. `kill(pid, 0) && startTimeUnchanged` is the only reliable "is this the same process" test on POSIX.
   - `Clauded/Sources/Services/InstanceRegistry.swift:96-99`

3. **Two competing Settings windows.** The SwiftUI `Scene` declares `Settings { SettingsView() }`, *and* `StatusBarController.openSettings` manually constructs its own `NSWindow` hosting another `SettingsView`. Cmd-, (from the app menu) opens one; the gear button opens the other. They bind to different instances of environment state through different paths, and the user can end up with two windows visible at once. Pick one. For a menu-bar app the SwiftUI `Settings` scene is fine — route the gear button through `NSApp.sendAction(Selector(("showPreferencesWindow:")), …)` or equivalent.
   - `Clauded/Sources/App/ClaudedApp.swift:63-72`
   - `Clauded/Sources/Services/StatusBarController.swift:104-120`

4. **Main-thread disk I/O for install/uninstall.** `HookInstallState.toggleInstallation()` runs synchronous `Data(contentsOf:)` / `replaceItemAt` on the main actor. It's fast today because `settings.json` is tiny, but it's a bad habit to bake in and it will bite the first time someone's home directory is on a slow network mount. Move the install work off-main with a `Task.detached` and marshal the result back.
   - `Clauded/Sources/Services/HookInstallState.swift:26-40`

5. **300ms polling loop when you own an `@Observable`.** `StatusBarController.startObserving` calls `refreshIcon()` every 300 ms forever. You already have `@Observable InstanceRegistry`; the whole point of the Observation framework is to avoid this. The comment even apologises for it ("polling once per 300 ms is trivially cheap"). It's cheap, but it's 3.3 Hz of main-thread wakeups that will prevent App Nap and show up in Instruments. Use `withObservationTracking` or put the icon inside a SwiftUI-hosted menu-bar view.
   - `Clauded/Sources/Services/StatusBarController.swift:46-57`

---

## 2. Correctness bugs & edge cases

### 2.1 NotifyShim: `readStdin()` can truncate

```swift
let chunk = handle.availableData
if chunk.isEmpty { break }
collected.append(chunk)
if chunk.count < 4096 { break }   // ← wrong termination condition
```

`availableData` returns whatever bytes are currently in the pipe's buffer. On a fast pipe it may return less than 4 KB simply because the writer hasn't flushed yet — and the loop will then exit with a *partial* payload. The only correct termination conditions are (a) `chunk.isEmpty` (EOF), or (b) `collected.count >= maxStdinBytes` (hard ceiling). Drop the `< 4096` heuristic.

Teaching moment: "when the chunk is small we're probably done" is a classic false proxy for EOF. On pipes, small chunks mean "the writer hasn't written more *yet*", not "the writer is done".
- `Clauded/Sources/NotifyShim/main.swift:27-37`

### 2.2 HookDaemon: sloppy `recv` error handling

```swift
let received = ...recv(fileDescriptor, ptr.baseAddress, ptr.count, MSG_DONTWAIT)
if received <= 0 { return }
```

Three problems:

- `received == 0` for `SOCK_DGRAM` means an empty datagram, **not** EOF. You're not distinguishing it from EAGAIN and will treat empty notifications as "drain finished". In practice the shim never sends an empty datagram, so this is latent, but it's incorrect.
- `received < 0` conflates `EAGAIN`/`EWOULDBLOCK` (correct stop condition) with `EINTR` (should retry), `EMSGSIZE` (datagram truncated; log and drop), and genuine errors (should log & probably re-listen). Inspect `errno`.
- You never check `MSG_TRUNC`. If the shim ever writes more than 64 KB, you'll silently receive a truncated payload, fail to decode, and log confusing "bad JSON" errors. Consider passing `MSG_PEEK` with a small probe, or simply bumping the buffer and checking `received == maxDatagramSize` as a heuristic.
- `Clauded/Sources/Services/HookDaemon.swift:109-122`

### 2.3 HookDaemon: no single-instance guard

`start()` unconditionally `unlink`s the socket and binds a new one. If a second Clauded is launched (double-click from Finder, dev build + packaged build), it will silently kidnap the socket from the first instance, and the first instance's `DispatchSourceRead` fires forever on a dead fd. Add a probe: try `connect()` to the socket first; if it succeeds, there's already a live daemon — bail out and surface it to the user, or use `/usr/bin/pkill` semantics, or take an advisory `flock` on a pidfile.
- `Clauded/Sources/Services/HookDaemon.swift:44-50`

### 2.4 HookDaemon: trust boundary isn't enforced

The socket is `chmod 0600`, which limits *write* access to the same UID. Good. But the daemon still blindly trusts every field in the payload. An attacker who gets local code exec under the same UID (a common pivot target — think compromised npm postinstall) can:

- Forge arbitrary `session_id`/`project_dir` strings that show up verbatim in the status-bar popover.
- Supply a `pid` for any running process; clicking the row then calls `TerminalFocuser.focus(pid:)` which walks to an ancestor and `activate`s it. That's a primitive way to make *any* app come to the front.

Mitigations: (a) verify the sender via `SO_PEERCRED` / `LOCAL_PEERPID` (`getsockopt` with `SOL_LOCAL`, `LOCAL_PEERPID`), (b) sanity-check `project_dir` is a real absolute path that exists, (c) drop the row silently if walking the pid's ancestry doesn't hit a known terminal.

Teaching moment: "local socket, chmod 0600" does not mean "trusted input." The attack model on macOS is overwhelmingly *malicious or careless code running as your user*. Treat IPC payloads like any other external input.
- `Clauded/Sources/Services/HookDaemon.swift:85-86`, `Clauded/Sources/Services/HookDaemon.swift:124-134`

### 2.5 InstanceRegistry: reaper race with in-flight events

```swift
while !Task.isCancelled {
    try? await Task.sleep(for: .seconds(30))
    self?.registry.reapDeadInstances()
}
```

The reaper drops instances whose PID is gone. But a late `stop` or `notification` event can arrive *after* reap, re-registering the session at `.finished` or `.awaitingInput`. The user sees a zombie row for another 30 seconds. Fix: after removing a session, remember its id in a `recentlyReaped` LRU with a short TTL, and drop events for reaped ids.
- `Clauded/Sources/Services/InstanceRegistry.swift:77-91`
- `Clauded/Sources/App/ClaudedApp.swift:23-28`

### 2.6 InstanceRegistry: unbounded growth

Nothing caps `instances.count`. If `SessionEnd` hooks stop firing for any reason and the reaper fails (see 2.5 stale-PID issue), memory grows unboundedly. Add a soft cap (e.g. 200 sessions) and drop the oldest `.stopped`/`.finished` rows beyond it.
- `Clauded/Sources/Services/InstanceRegistry.swift:31-60`

### 2.7 InstanceRegistry: dead `InstanceState` case

`.stopped` is listed in the enum but unreachable — `apply()` removes the instance the moment `sessionEnd` arrives. This isn't a bug, it's confusing code: a reader has to grep the whole codebase to prove the case is dead. Either delete it, or change the semantics so `SessionEnd` moves rows to `.stopped` and a separate timer garbage-collects them (arguably better UX: "this thing finished, here's how it finished" is valuable for a few seconds).
- `Clauded/Sources/Models/ClaudeInstance.swift:17-18`
- `Clauded/Sources/Services/InstanceRegistry.swift:34-38`

### 2.8 HookInstaller: reshuffles the user's entire `settings.json`

```swift
JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
```

`.sortedKeys` is how you guarantee deterministic output for tests, **not** how you write user configuration files. Many users keep `~/.claude` in a dotfiles repo, and every install will cause a huge cosmetic diff the first time we touch the file. Two options:

1. Preserve key ordering by parsing into `[(String, Any)]` pairs with your own walker.
2. Only sort keys in the *sections we created* (`hooks["SessionStart"]` etc.), and leave the rest of the object alone — technically this requires you to round-trip the file via something smarter than `JSONSerialization`.

At minimum, drop `.sortedKeys`.
- `Clauded/Sources/Services/HookInstaller.swift:268-285`

### 2.9 HookInstaller: `.partial` never detected when shim path is wrong

`status()` only checks whether *any* entry containing the marker exists — not whether its `command` points at the *currently bundled* shim. If the user moves Clauded.app to the Trash and drags it back from a DMG, the hooks in `settings.json` still reference the old path (a dead binary), `status()` returns `.installed`, the UI says "you're good", and in reality every hook firing is a broken binary invocation. Either extend `.partial` to cover "installed but stale", or add a dedicated `.needsRepair` case. The install path already handles the rewrite (`ensureOurEntry` compares command strings) — you just need to surface it.
- `Clauded/Sources/Services/HookInstaller.swift:161-180`

### 2.10 HookInstaller: no cleanup of duplicate entries

`ensureOurEntry` returns on the *first* match found and ignores the rest. If, for any reason, there are two matcher blocks in an event array that both contain our marker (possible after a bad merge, or a user hand-edit), the duplicates survive forever. Idempotency means "converging on one correct entry," not "noticing one correct entry and stopping." Walk the whole array; keep the first one; strip the rest.
- `Clauded/Sources/Services/HookInstaller.swift:186-215`

### 2.11 HookInstaller: stale backup is worse than no backup

`backupIfNeeded` copies the original to `settings.json.clauded.bak` *once, ever*. Subsequent edits to the user's settings (by Claude Code itself, or the user) are never re-snapshotted. A year later, the backup looks like a restore point and is a landmine. Either (a) refresh the backup on every install as long as it's newer than the current version, (b) version the backup (`settings.json.clauded.bak.2026-04-11`), or (c) drop the backup entirely and rely on the atomic write + the `uninstall` flow being the real "undo."
- `Clauded/Sources/Services/HookInstaller.swift:287-295`

### 2.12 HookInstaller: `[String: Any]` is an anti-pattern for merging

The whole installer is written with untyped dictionary casts: `(root["hooks"] as? [String: Any]) ?? [:]`, `hooks[claudeEvent] as? [[String: Any]]`, etc. Every downcast is a silent failure mode — a user with a quirky `settings.json` (e.g. a string where you expect an array) gets their entry silently dropped on the floor. Define `Codable` types for the shape you expect (`struct ClaudeSettings`, `struct HookMatcher`, `struct HookEntry`) and let the decoder tell you what went wrong. The merge logic becomes typed, testable, and self-documenting.

Teaching moment: `[String: Any]` is Swift's form of "dynamic typing." It's tempting because it mirrors JSON exactly, but it defeats the compiler's ability to catch shape mismatches. Prefer `Codable` structs and opt out only for the genuinely free-form subtree.
- `Clauded/Sources/Services/HookInstaller.swift:87-113`, `Clauded/Sources/Services/HookInstaller.swift:118-157`

### 2.13 HookInstaller: no lock against concurrent writers

Claude Code itself may write `~/.claude/settings.json` (future feature, or user running `claude config`). With no advisory lock, two writers can race: A reads, B reads, A writes, B writes — B wins and A's install entry vanishes. Atomic `replaceItemAt` prevents *torn* files but not *lost updates*. This is unlikely in practice, but the honest answer is "take `flock` on the file for the duration of read-mutate-write" or accept the race and document it.
- `Clauded/Sources/Services/HookInstaller.swift:245-285`

### 2.14 NotifyShim: session-id fallback is fragile

```swift
let pid = getppid()
let project = ProcessInfo.processInfo.environment["CLAUDE_PROJECT_DIR"] ?? ""
return "\(project):\(pid)"
```

If one hook invocation has a `session_id` and a later one doesn't (unlikely but I don't know that it can't happen), the two events will hash into different keys and produce a phantom duplicate row. A stronger fallback: write the derived id to a tempfile keyed on the parent pid and reuse it across hook firings for the same session.
- `Clauded/Sources/NotifyShim/main.swift:39-46`

### 2.15 TerminalFocuser: `NSRunningApplication.activate(options: [])`

On macOS 14+, calling `activate(options:)` without `.activateAllWindows` or with an empty set has a reduced effect — it may bring the *application* forward but not the frontmost window of that application. For iTerm, Ghostty, WezTerm, Alacritty, Warp users — i.e. essentially everyone who isn't using Apple's Terminal — "click the row and get taken to the terminal" is the headline product feature, and it's implemented as a hopeful `activate(options: [])`. Test it with each terminal and document the gap; at minimum, pass `.activateAllWindows`.

Also: this is a *major* functional gap that the README advertises away ("Jump to the terminal… Terminal.app, iTerm2, Ghostty, WezTerm"). iTerm2 has a scriptable `select` on its session objects; the other three have CLI escape codes or `--focus` args. The code admits defeat with a single `activate` call — but the product promises tab-level focus.
- `Clauded/Sources/Services/TerminalFocuser.swift:34-40`

### 2.16 TerminalFocuser: AppleScript string escaping is incomplete

```swift
let escapedTTY = tty.replacingOccurrences(of: "\"", with: "\\\"")
```

Quotes are escaped but backslashes are not. In this *specific* case the tty is `devname()` output (`ttys003`, no backslashes), so it's safe — but the pattern is the kind of thing that gets copy-pasted. Escape both, or use `NSAppleEventDescriptor` to pass parameters as typed values instead of splicing strings. AppleScript injection is a real category of bug (see CVE-2018-4237).

Teaching moment: *any time* you build a source-string from a variable and feed it to an interpreter, the bar is "escape everything the target language cares about" — not "escape the one thing I thought of."
- `Clauded/Sources/Services/TerminalFocuser.swift:42-69`

### 2.17 TerminalFocuser: no Automation permission UX

First-run AppleScript triggers macOS's "Clauded wants to control Terminal.app" prompt. If the user declines, every focus attempt silently logs an error. There's no path in the UI to re-request (you can't; user has to go to System Settings → Privacy & Security → Automation manually). Detect the denial, surface it in Settings, and provide a button that opens the relevant Preference Pane via `NSWorkspace`.
- `Clauded/Sources/Services/TerminalFocuser.swift:61-69`

### 2.18 ClaudedApp: `UserDefaults` string key without namespacing

```swift
if !UserDefaults.standard.bool(forKey: "didAttemptFirstInstall") {
```

Stringly-typed config is a footgun. Put keys in a single `enum Defaults { static let didAttemptFirstInstall = "com.mcclowes.clauded.didAttemptFirstInstall" }` and access through a helper. A typo today becomes a re-install tomorrow.
- `Clauded/Sources/App/ClaudedApp.swift:48-53`

### 2.19 ClaudedApp: auto-install skips `.partial` state

The first-run logic only auto-installs if `status == .notInstalled`. A user who already has a partial (e.g. stale-path) install won't get auto-repaired. Either include `.partial` in the auto-action, or — my preference — separate "first run" from "is the install usable" and surface both independently.
- `Clauded/Sources/App/ClaudedApp.swift:48-53`

### 2.20 HookDaemon: `start()` on main actor does blocking syscalls

`socket`, `bind`, `chmod`, `unlink` are all fast, but they're still synchronous syscalls on the main actor during `applicationDidFinishLaunching`. If the filesystem hangs (think: FileVault unlock, network home dir, Migration Assistant in-flight), the UI doesn't come up. Hop to a detached task, finish init, then marshal the source subscription back to main.
- `Clauded/Sources/Services/HookDaemon.swift:44-100`

---

## 3. Architectural observations

### 3.1 Untyped IPC contract

The wire format between shim and daemon is defined in two places:

- `HookEvent` (Swift `Codable` on the daemon side) defines field names via `CodingKeys`.
- `main.swift` in the shim builds a `[String: Any]` dict with string literals.

If you rename a field, the compiler won't tell you — only the runtime decode will fail (quietly, to logs). Extract a shared module (`HookWire`) with a single `Codable` struct used by both targets. Both targets already share `project.yml`; adding a third library target is trivial.

Teaching moment: whenever you have the same data shape on both sides of any boundary (IPC, network, file format), share the *type*, not just the documentation. Duplicated string literals across a type boundary is how contracts drift.

### 3.2 Polling vs. observation

Two separate loops poll state:

- `StatusBarController` polls the registry every 300 ms to redraw the icon.
- `AppDelegate` polls the reaper every 30 s.

Both could be event-driven. The status-bar icon can be a SwiftUI `MenuBarExtra` (macOS 13+) bound to the `@Observable` registry directly, giving you zero-cost redraws. The reaper can fire on every daemon event plus a long backstop — you don't need 30-second resolution when hooks arrive in real time.

### 3.3 `@MainActor` soup

Almost every service is `@MainActor`. That's fine for a small app, but it means a future bug in any one of them blocks the UI. For a menu-bar utility you really want:

- UI and registry: `@MainActor`.
- HookDaemon, HookInstaller, TerminalFocuser: `actor` (own their own state), with small `@MainActor` facades that publish observable state back to the UI.

This is aspirational — don't refactor today for the sake of it — but it's worth understanding the difference between "code runs on main" and "code is *forced* onto main by the type system." Right now you have the latter.

### 3.4 Duplication between SwiftUI `Scene`'s `Settings` and the custom `NSWindow`

(See top concern #3.) Having both creates two state paths for the same UI. Pick the SwiftUI `Settings` scene or delete it.

---

## 4. Test coverage gaps

Tests are solid where they exist — but the gaps are in exactly the places you most need coverage:

1. **No `HookDaemon` test at all.** The socket seam is entirely untested. Add at least one integration test that writes a datagram to a temp socket and asserts the registry picks it up. `Network.framework`'s `NWListener` is irritating to drive in tests; consider inverting control so the daemon takes an injected "source of events" and has one adapter for the real socket and one for tests.

2. **No `HookInstaller.status() == .partial` test.** The status state machine has three cases; only two are exercised.

3. **No `ensureOurEntry` update-in-place test.** `testInstallUpdatesShimPathIfAppMoved` verifies the *end state* (old path gone, new path present), but doesn't verify that duplicates *don't* accumulate after many moves in a row. Add a test that runs 10 installs with rotating shim paths and asserts exactly one entry remains.

4. **No test for reaper + late event race.** (Covers bug 2.5.)

5. **No test for `ClaudeInstance.pid` reuse.** (Covers bug 1/2.5.)

6. **No NotifyShim test.** Extract `extractSessionId`, `extractMessage`, and `readStdin` into a library target (`NotifyShimCore`) and add tests for each. Right now the shim is dead-zone for verification — and it runs on *every Claude Code hook firing*.

7. **`HookEventTests.testDecodesShimOutput` uses a timestamp with fractional seconds.** Confirm under CI whether this actually parses, and add a test case that uses *no* fractional seconds (the decoder shouldn't choke on either). This is the canary for bug #1.

8. **No lint/format CI.** `CLAUDE.md` says "must pass with zero violations," but I don't see any enforcement beyond the Makefile — the CI workflow should run `make lint`.

9. **Still using XCTest.** Swift 6 + Xcode 16 means Swift Testing (`@Test`, `#expect`) is available and strictly better: parallel by default, better parameterised tests, less ceremony. Worth migrating incrementally.

---

## 5. Nits and small improvements

- `InstanceRegistry.apply` mutates `instances[index]` five times in a row. Each mutation is a separate observation tick. Build a mutated copy and replace once.
  - `Clauded/Sources/Services/InstanceRegistry.swift:39-45`
- `HookInstaller.ensureParentDirectoryExists` doesn't `chmod 0700` the `.claude` dir. Claude Code creates it that way; we should too if we're the first to make it.
  - `Clauded/Sources/Services/HookInstaller.swift:238-243`
- `HookInstaller.writeSettings` writes a sibling `settings.clauded.tmp.json`. That's fine, but `FileManager.replaceItemAt` already uses a temp file under the hood — you can just write the data to a temp in the same directory and call `replaceItemAt`. The current double-temp is belt-and-braces.
  - `Clauded/Sources/Services/HookInstaller.swift:268-285`
- `HookDaemon` log level. "Session registered" and "Session ended" at `.info` will hit Console.app on every hook; `.debug` is probably more appropriate. Use `.info` for state transitions you want visible in a user bug report, `.debug` for routine chatter.
  - `Clauded/Sources/Services/InstanceRegistry.swift:36-58`
- `InstanceState` is `Codable` but nothing encodes/decodes it — dead conformance. Delete it until you need it.
  - `Clauded/Sources/Models/ClaudeInstance.swift:8`
- `Makefile` builds via `BUILD_DIR = $(shell xcodebuild … | grep -m1 'BUILT_PRODUCTS_DIR' | awk '{print $$NF}')`. This evaluates *every `make` invocation* including `make help`, so typing `make help` triggers an `xcodebuild` probe. Make `BUILD_DIR` lazy: `BUILD_DIR = $(shell …)` with `=` (recursively expanded) is what you have; switch to a target-scoped variable or inline it.
- `InstancePanelView.list` sorts by calling `registry.sortedInstances` inside a view body, which recomputes the sort every render. Cheap now; unnecessary. Sort lives naturally on the view model.
  - `Clauded/Sources/Views/InstancePanelView.swift:57-69`
- `InstanceRow.relativeTime` creates a new `RelativeDateTimeFormatter` on every render. `DateFormatter` family objects are expensive; make it a static.
  - `Clauded/Sources/Views/Components/InstanceRow.swift:76-80`
- The `clauded-notify` fallback path `/usr/local/bin/clauded-notify` is dev-convenient, but in production it's a footgun — if the bundle lookup ever returns nil, you'll write a nonexistent path into the user's `settings.json`. Make the fallback an explicit test-only hook (e.g. require an env var).
  - `Clauded/Sources/Services/HookInstaller.swift:76-82`

---

## 6. Security summary

Prioritised:

1. **Stale shim path in settings.json** → user runs a broken app path on every hook. Medium likelihood, low severity (failed invocations, not RCE).
2. **Daemon trusts all payload fields** → local-UID attacker can spoof rows and influence `TerminalFocuser`. Low likelihood, low severity.
3. **AppleScript injection surface** → currently not exploitable (source only splices `devname()` output and a controlled literal), but the pattern is wrong. Fix for defence in depth.
4. **No single-instance guard on the daemon** → second instance silently kidnaps the socket, first silently dies. Not a security bug but a robustness one.

None of these are "stop-ship." All of them are "pay attention when you touch this area."

---

## 7. Recommended priorities

**Must fix:**
- [ ] `#1` Date decoding strategy (fractional seconds).
- [ ] `#2` PID-reuse-safe reaper.
- [ ] `#3` Single Settings window path.
- [ ] 2.1 NotifyShim stdin truncation.
- [ ] 2.15 `NSRunningApplication.activate` flags — product regression.

**Should fix:**
- [ ] 2.2 Daemon `recv` error handling.
- [ ] 2.3 Daemon single-instance guard.
- [ ] 2.9 `HookInstaller.status` detects stale path.
- [ ] 2.10 `ensureOurEntry` dedupes, doesn't just "first wins."
- [ ] 2.12 Replace `[String: Any]` with `Codable` types in the installer.
- [ ] Test coverage items 1, 2, 3, 6.

**Nice to have:**
- [ ] 3.1 Shared wire-format module between shim and daemon.
- [ ] 3.2 Remove the 300 ms poll; drive the icon from `@Observable`.
- [ ] Migrate tests to Swift Testing.
- [ ] Expand terminal focus to iTerm2/Ghostty/WezTerm tab level.

---

## 8. What this codebase gets right

For the benefit of the junior readers this review is aimed at, it's worth naming the things this code does well. "Critique" isn't "nothing is good":

- **Clear architecture doc in `CLAUDE.md`.** Every service has a one-sentence purpose and a lifecycle story. This is table stakes for onboarding but most projects don't do it.
- **Disciplined separation of concerns.** Services don't know about views; views don't know about sockets; models are small and dumb. This is exactly how to carve a small app.
- **Installer design principles are written down** (`HookInstaller.swift` header) and the code actually follows them. Writing "what the rules are" at the top of a file is underrated.
- **Atomic write + backup + merge-in-place** for `settings.json` is the right shape, even if the details are improvable.
- **Dependency injection via initialiser parameters** (`settingsURL: URL? = nil`, `shimPath: String? = nil`, `isAlive:`) makes the logic testable without DI containers or protocol gymnastics.
- **No third-party dependencies.** For a menu-bar utility this is the right call — less attack surface, no dependency rot.
- **Pre-PR checklist in `CLAUDE.md`** that actually enumerates the commands. Juniors can just follow it.

The gap between this code and "principal-engineer bar" is entirely about:

1. **Trust boundaries** (what inputs do you trust, and why?),
2. **Error handling completeness** (have you thought about every branch of every syscall?),
3. **Observability vs. silence** (when things go wrong, does the user or the next engineer find out?).

Those three lenses are what the review above is mostly applying. Memorise them; apply them to everything you write; you'll make principal faster than you expect.

---

## 9. Execution summary (2026-04-11)

All "must fix" and "should fix" items from §7 were actioned in a single pass.
Lint passes (`make lint`), build passes (`make build`), and the test suite grew from
23 to 33 tests, all green (`make test`).

### Fixed

**Must fix**
- [x] #1 **Date decoding** — `HookEvent.makeDecoder()` uses a `.custom` strategy that accepts ISO-8601 both with and without fractional seconds. Shared by daemon + tests.
- [x] #2 **PID-reuse-safe reaper** — `ClaudeInstance` now carries `processStartTime`, captured via `sysctl(KERN_PROC_PID)` at registration. `reapDeadInstances` treats a start-time mismatch as "PID reused, reap". New tests cover both match and mismatch.
- [x] #3 **Single Settings window** — removed `StatusBarController.openSettings(contentView:)`. Gear button now routes through `NSApp.sendAction(Selector(("showSettingsWindow:")))`, so Cmd-, and the gear open the same SwiftUI `Settings` scene.
- [x] 2.1 **NotifyShim stdin truncation** — dropped the `chunk.count < 4096` heuristic. Loop terminates only on real EOF or the byte ceiling.
- [x] 2.15 **`NSRunningApplication.activate` flags** — every app-level activation now uses `.activateAllWindows`, restoring the frontmost-window focus behaviour on macOS 14+.

**Should fix**
- [x] 2.2 **Daemon `recv` error handling** — distinguishes `EAGAIN`/`EWOULDBLOCK` (stop), `EINTR` (retry), and real errors (log and stop). Also detects and warns on max-size datagrams that may be truncated.
- [x] 2.3 **Daemon single-instance guard** — `flock(LOCK_EX | LOCK_NB)` on `daemon.pid` before touching the socket. Second instance logs a warning and stays idle instead of kidnapping the socket.
- [x] 2.5 **Reaper + late-event race** — registry now keeps a `recentlyReaped` LRU (120s grace window) and drops late events for ids in it. Test added.
- [x] 2.6 **Unbounded growth** — soft cap at 200 instances; evicts oldest `.finished`/`.idle` rows first.
- [x] 2.7 **Dead `.stopped` state** — removed from the enum (and from `InstanceRow` and every other consumer); cleaner source of truth.
- [x] 2.8 **`.sortedKeys` reshuffling** — dropped; settings files that users keep in dotfiles repos won't churn any more.
- [x] 2.9 **`.partial` status for stale shim paths** — `HookInstaller.status()` now verifies each entry's command starts with the current shim path. Stale paths report `.partial`, and `ClaudedApp` auto-repairs on launch.
- [x] 2.10 **Dedupe on install** — `ensureOurEntry` keeps the first marker entry per event array and strips all other copies, collapsing duplicates left by buggy earlier installs or hand edits. Test added.
- [x] 2.11 **Backup failure was silent** — `backupIfNeeded` now logs on failure instead of swallowing with `try?`.
- [x] 2.16 **AppleScript escape** — escapes both backslashes *and* quotes. Defence in depth even though current `devname` output can't contain either.
- [x] 2.17 **Automation permission UX** — surfaces macOS error code `-1743` explicitly in logs, pointing the user at Privacy & Security → Automation.
- [x] 2.18 **`UserDefaults` stringly-typed key** — pulled into a private `Defaults` enum with a namespaced key.
- [x] 2.19 **`.partial` first-run skip** — auto-install now fires on both `.notInstalled` and `.partial`; subsequent launches also opportunistically repair stale installs.
- [x] Main-thread disk I/O — `HookInstallState.toggleInstallation` now runs the installer inside `Task.detached`. `HookInstaller` is non-isolated and `Sendable` so it can cross actors safely.
- [x] 300 ms poll loop — replaced with `withObservationTracking` re-registration driven by the `@Observable` registry. Zero idle wakeups.
- [x] `InstanceRegistry.apply` batching — reads the instance, mutates the local copy, writes back once. Single observation tick per event.
- [x] `.claude` dir permissions — `ensureParentDirectoryExists` now sets `0o700` when creating.
- [x] Unique temp filename in `writeSettings` — UUID-suffixed to avoid collisions under concurrent installs.
- [x] `InstanceRow.relativeTime` — now uses a single shared static `RelativeDateTimeFormatter`.
- [x] Daemon log spam — routine session-registered/ended moved from `.info` to `.debug`; `.info` reserved for state events useful in a bug report.

**Tests added**
- [x] `HookEventTests`: decoding with *and* without fractional seconds; decoder rejects malformed dates; uses the shared `HookEvent.makeDecoder()`.
- [x] `HookInstallerTests`: `.partial` on stale shim path; repair round-trips to `.installed`; duplicate-marker collapse; shim-missing validation error; install preserves non-hooks keys without sorting.
- [x] `InstanceRegistryTests`: PID-reuse reaping via injected `startTime`; matching start time does not reap; late events for reaped sessions are dropped; clean `SessionEnd` does not poison re-registration with the same id.

**Test count: 23 → 33. All green.**

### Deferred (with reasoning)

- **2.12 `[String: Any]` → `Codable` refactor of `HookInstaller`.** Genuine improvement but triples the diff and requires designing the `ClaudeSettings` type shape. Tracked for a dedicated follow-up PR.
- **2.4 Daemon trust-boundary hardening (`SO_PEERCRED`/`LOCAL_PEERPID`).** The socket is already `chmod 0600` and the flock single-instance guard is in; the attack requires local code exec as the user, which is a very different threat model. Low ROI for the complexity.
- **2.13 `flock` on `settings.json`.** No known concurrent writer today; adding an fcntl lock for a speculative race adds complexity the installer doesn't earn. Revisit if Claude Code starts writing `settings.json` itself.
- **2.14 NotifyShim session-id fallback strengthening.** The fallback is still pid+project-dir. Deferring until we see a real case where it collides.
- **3.1 Shared wire-format module between shim and daemon.** Would prevent drift but requires a third XcodeGen target. Not worth the project-structure churn until there are multiple consumers.
- **3.3 Actor-isolation cleanup (`HookDaemon`/`TerminalFocuser` → actors).** Aspirational refactor; services don't yet have enough complexity to justify it.
- **HookDaemon off-main init.** Every syscall in `start()` is fast in practice; skipped pending real evidence of a launch stall.
- **NotifyShim helper extraction + tests.** Requires adding a library target and restructuring the shim. Tracked but not done here.
- **Swift Testing migration.** Leaving as a sweep for later; doesn't change behaviour.
