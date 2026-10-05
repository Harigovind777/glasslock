# GlassLock — Design Spec (Phase 1)

Date: 2026-10-05
Status: Approved in conversation, pending written-spec review

## 1. Goal

Lock the MacBook from the iPhone, from anywhere, without pausing or killing
anything that is running (e.g. an opencode prompt). While locked, the screen
shows a live **frosted-glass blur**: you can tell the Mac is working, but no
content is readable. Only **Touch ID** or the **Mac login password**, entered at
the Mac, unlocks it.

### Success criteria

1. Tapping the "Lock Mac" Shortcut on the iPhone — on mobile data, away from
   home — glass-locks the Mac and the phone shows "✅ Mac locked".
2. A process running before the lock keeps running with no pause for the
   whole lock (verified with a timestamp counter showing no gaps over 10 min).
3. Text under the overlay is unreadable (verified by screenshot).
4. Keyboard/mouse input cannot reach any app while locked; Cmd+Tab, Force Quit,
   Dock, menu bar, logout/restart/shutdown menus are blocked.
5. Touch ID or the correct login password unlocks; nothing else does.
6. Failure modes fail *closed* (real macOS lock), never open.

### What the user specified vs. what was assumed

Specified by the user: iPhone + Mac; lock remotely; processes keep running;
unlock only by fingerprint or password on the Mac; screen blurred so work cannot
be seen; reachable from anywhere; Shortcut now, real iPhone app later; ntfy.sh
relay.

Assumed (confirmed in design review): "password" means the Mac login password;
5 wrong passwords escalate to the real macOS lock; display stays on while
glass-locked (battery cost accepted); lid must stay open (closing it sleeps the
Mac — not overridable on a MacBook Air on battery).

### Non-goals (Phase 1)

- Native iPhone app (Phase 2, separate spec, reuses the same relay protocol).
- Unlocking remotely — deliberately impossible.
- Sending screenshots/status details to the phone.
- Multiple Macs, multiple users, self-hosted ntfy.
- Preventing sleep when the lid is closed.

## 2. Environment constraints

- MacBook Air M4 (`Mac16,12`), macOS 27.0, Touch ID enrolled for unlock.
- **Xcode is not installed** — only Command Line Tools (Swift 6.4, macOS SDK).
  Verified present in the SDK: AppKit, LocalAuthentication,
  LocalAuthenticationEmbeddedUI, OpenDirectory, IOKit, ServiceManagement,
  private `login.framework`. `/usr/bin/shortcuts` CLI is available.
- Therefore: Swift Package Manager build, app bundle assembled by a script,
  ad-hoc code signing.

## 3. Architecture

```
 iPhone                        ntfy.sh                         MacBook Air
┌─────────────┐ POST "lock"  ┌──────────────────┐  JSON stream ┌────────────────────────┐
│ "Lock Mac"  │ ───────────▶ │ <topic>          │ ───────────▶ │ GlassLock (menu bar)   │
│  Shortcut   │              │                  │              │                        │
│             │ ◀─────────── │ <topic>-ack      │ ◀─────────── │ POST "locked:<id>"     │
└─────────────┘ poll for ack └──────────────────┘              └────────────────────────┘
```

GlassLock is a menu-bar-only app (`LSUIElement`), started at login by a
LaunchAgent that also restarts it after a crash.

### Package layout

```
glasslock/
  Package.swift
  Sources/
    GlassLockCore/        # pure logic, no AppKit — fully unit-tested
      LockStateMachine.swift
      RelayMessage.swift      # parse ntfy JSON lines → commands; staleness rule
      Backoff.swift
      Secret.swift            # topic generation
      ShortcutBuilder.swift   # builds the .shortcut plist for a topic
    GlassLock/            # AppKit executable — thin adapters around Core
      main.swift / AppDelegate.swift
      MenuBarController.swift
      RelayClient.swift       # URLSession streaming + ack publishing
      GlassOverlay.swift      # blur windows + kiosk presentation options
      Authenticator.swift     # Touch ID (embedded) + password verification
      KeepAwake.swift         # IOPM assertions
      RealLock.swift          # real macOS lock screen
      Persistence.swift       # secret file, crash flag, log
  Tests/GlassLockCoreTests/
  scripts/
    build-app.sh            # swift build → GlassLock.app → ad-hoc sign
    install.sh              # copy to /Applications, install LaunchAgent
  docs/
    manual-test-checklist.md
```

### Units

| Unit | Purpose | Depends on |
|---|---|---|
| **LockStateMachine** | States `unlocked`, `glassLocked(failedAttempts)`, `realLocked`. Events: `lockRequested`, `authSucceeded`, `passwordFailed`, `overlayFailed`, `launchedWithCrashFlag`, `systemUnlocked`. Outputs side-effect *intents* (show overlay, real-lock, ack, keep-awake on/off) that the app layer executes. | nothing |
| **RelayMessage** | Decode one ntfy JSON line; accept only `event == "message"` with body `lock`; reject if `now - time > 120 s`; dedupe by message id. | nothing |
| **Backoff** | Reconnect delays 1, 2, 4, 8 … capped at 60 s; reset on successful connect. | nothing |
| **Secret** | Generate topic `glasslock-` + 32 chars from a CSPRNG (base62). | `SystemRandomNumberGenerator` (CSPRNG) |
| **ShortcutBuilder** | Produce the Shortcut workflow plist with the topic embedded. | nothing |
| **RelayClient** | `GET https://ntfy.sh/<topic>/json?since=<last id or launch time>`, read lines, feed RelayMessage; publish acks to `<topic>-ack`; report connection status. | URLSession, Backoff |
| **GlassOverlay** | One borderless window per screen at shielding level, live blur + tint, unlock panel on the main screen; sets kiosk presentation options. | AppKit |
| **Authenticator** | Embedded Touch ID view (`LAAuthenticationView`) re-armed after failure; password verified against the local user record via OpenDirectory, off the main thread. | LocalAuthentication(EmbeddedUI), OpenDirectory |
| **KeepAwake** | Hold `PreventUserIdleDisplaySleep` + `PreventUserIdleSystemSleep` while glass-locked; hold system-sleep assertion only while real-locked until the system reports unlock. | IOKit |
| **RealLock** | Engage the real macOS lock via `SACLockScreenImmediate` (private `login.framework`, loaded with `dlopen`). | login.framework |
| **Persistence** | Secret file and crash flag in `~/Library/Application Support/GlassLock/` (mode 0600); log at `~/Library/Logs/GlassLock.log`. | Foundation |

## 4. Glass lock behaviour

### Locking

1. State machine enters `glassLocked(0)`; crash flag written **before** the
   overlay appears.
2. Overlay windows cover every screen above all other windows
   (`CGShieldingWindowLevel`), `canJoinAllSpaces`, and capture all mouse and
   keyboard events so none reach the apps underneath.
3. Background: `NSVisualEffectView`, `blendingMode = .behindWindow`,
   `state = .active`, strong material, plus a dark tint layer. Live — moving
   content shows as moving colour, text is unreadable. If the screenshot check
   shows readable text, increase strength (tint opacity, then a stronger blur
   radius via window-server blur) until it passes.
4. Unlock panel (main screen, bottom centre, frosted card): lock icon,
   "Locked from iPhone · <time>" (or "Locked from this Mac"), Touch ID view,
   secure password field.
5. App is activated and `NSApp.presentationOptions` set to
   `hideDock, hideMenuBar, disableProcessSwitching, disableForceQuit,
   disableSessionTermination, disableHideApplication, disableAppleMenu`.
   If an accessory (`LSUIElement`) app cannot hold these options, switch the
   activation policy to `.regular` while locked and back afterwards.
6. KeepAwake holds display + system assertions.
7. Ack `locked:<command id>` published (remote locks only).

### Unlocking

- Touch ID success → `authSucceeded`.
- Password: compared against the login password; success → `authSucceeded`;
  failure → `passwordFailed`, field shakes and clears, counter shown after the
  2nd failure ("3 attempts left").
- `authSucceeded`: remove overlay, restore presentation options and activation
  policy, release assertions, clear crash flag, state → `unlocked`.

### Extra safeguards

- One second after showing, the overlay checks it actually holds keyboard
  focus; if not, it reports failure → real lock.
- If another app takes focus while locked, the overlay takes it back.
- Connecting/disconnecting a display while locked rebuilds the windows so every
  screen stays covered.
- On escalation to the real lock, the overlay is removed 2 s after the real
  lock engages, so the screen is never briefly uncovered.
- While glass-locked the app refuses to quit (logout, AppleScript quit).

### Fail-closed rules

| Trigger | Action |
|---|---|
| 5th wrong password | RealLock, tear down overlay, state → `realLocked` |
| Overlay fails to build/show | RealLock, state → `realLocked` |
| App launches and crash flag is set | RealLock immediately, clear flag, state → `realLocked` |
| `realLocked` and `com.apple.screenIsUnlocked` received | release assertions, state → `unlocked` |
| `lock` received while `glassLocked` | ack `already-locked:<id>`, no change |
| `lock` received while `realLocked` | ack `already-locked:<id>`, no change |

Not preventable (documented, accepted): long-press power button, closing the lid.

## 5. Relay protocol (ntfy.sh)

- **Command topic** `<topic>`; **ack topic** `<topic>-ack`.
- **Phone → Mac:** `GET https://ntfy.sh/<topic>/publish?message=lock` (ntfy's
  GET publish form — a single Shortcut action with no request body). The
  response JSON contains the message `id`.
- **Mac → Phone:** `POST https://ntfy.sh/<topic>-ack` body
  `locked:<id>` or `already-locked:<id>`.
- **Mac subscription:** streaming `GET /<topic>/json`, `since=<last processed
  id>`, or — before any message has been seen — `since=<launch time>` (unix
  seconds). This means a `lock` sent before the app started is never replayed,
  so restarting the app right after an unlock cannot re-lock the Mac; a `lock`
  sent while the Mac was briefly offline is still delivered on reconnect. One
  filter is kept for the app's lifetime so duplicates are caught across
  reconnects.
  Lines with `event` `open`/`keepalive` are ignored.
- **Staleness:** commands with `time` older than 120 s are ignored (logged).
- **Unknown bodies:** ignored and logged.
- **Reconnect:** Backoff on any error or stream end; menu bar shows
  connected / reconnecting.
- **Security model:** the topic name is the only secret (≈190 bits). A leaked
  topic allows locking the Mac, nothing else. No unlock path exists on the
  network. Content sent: the word `lock` and acks only.

## 6. iPhone Shortcut ("Lock Mac")

Actions:
1. Get Contents of URL — `https://ntfy.sh/<topic>/publish?message=lock`.
2. Get Dictionary Value `id` from the result.
3. Wait 4 seconds.
4. Get Contents of URL — `https://ntfy.sh/<topic>-ack/raw?poll=1&since=30s`
   (plain-text message bodies, one per line).
5. If the result contains `locked:<id>` → show "✅ Mac locked" (this also
   matches `already-locked:<id>` — both mean the Mac is locked); otherwise →
   "⚠️ No reply — Mac may be asleep, lid closed, or offline".
6. Network failure in step 1 → Shortcuts' own error ("couldn't reach relay").

Delivery: GlassLock writes the workflow plist (ShortcutBuilder), signs it with
`shortcuts sign --mode anyone`, and opens it to import into Shortcuts on the
Mac; iCloud syncs it to the iPhone (AirDrop as fallback). If signing/import of
a generated file fails, the menu item shows the topic and step-by-step manual
instructions instead (also written to the README).

Works with home-screen icon, Siri ("Lock Mac"), Action Button, Back Tap, Lock
Screen widget — all native Shortcut features, no extra code.

## 7. Menu bar

- Status line: "Connected to relay" / "Reconnecting…" (icon reflects it).
- Glass Lock Now
- Install iPhone Shortcut…
- Reset Secret… (new topic + new Shortcut; confirms first)
- Open Log
- Quit GlassLock (clean exit; the LaunchAgent does not relaunch on clean exit)

## 8. Build and install

- `scripts/build-app.sh`: `swift build -c release`, assemble
  `GlassLock.app` (Info.plist with `LSUIElement`, bundle id
  `com.harigovind.glasslock`), `codesign --sign -` (ad-hoc).
- `scripts/install.sh`: copy to `/Applications`, write
  `~/Library/LaunchAgents/com.harigovind.glasslock.plist` with `RunAtLoad`
  and `KeepAlive = { SuccessfulExit = false }`, `launchctl bootstrap`.
- Secret stored in a 0600 file rather than Keychain, because ad-hoc rebuilds
  change the signature and would trigger Keychain access prompts.

## 8a. Developer safety flags

`--dev-auto-unlock <seconds>` unlocks every glass lock after N seconds;
`--dev-lock-now` glass-locks 2 s after launch and implies a 30 s auto-unlock.
Used only while building/testing so the developer is never trapped behind a
half-working overlay. The LaunchAgent never passes them; the menu shows
"Developer mode" when they are on.

## 9. Testing

### Automated (`swift test`, test-first)

- LockStateMachine: every transition in §4 including the fail-closed table,
  attempt counting, double lock, crash flag on launch, system-unlock event.
- RelayMessage: valid lock, stale (121 s) rejected, boundary (120 s) accepted,
  keepalive/open ignored, unknown body ignored, malformed JSON ignored,
  duplicate id ignored.
- Backoff: sequence 1,2,4,…,60,60; reset.
- Secret: prefix, length, alphabet, two calls differ.
- ShortcutBuilder: generated plist parses and contains both URLs with the topic.

### Manual (`docs/manual-test-checklist.md`, run together with the user)

1. Timestamp counter (`while true; do date +%s >> t.log; sleep 1; done`)
   during a 10-minute glass lock → no gaps.
2. Screenshot of the overlay over large terminal text → unreadable.
3. Escape attempts blocked: Cmd+Tab, Cmd+Opt+Esc, Cmd+Q, Cmd+Space,
   Mission Control swipe, hot corners, menu bar, Notification Center.
4. Touch ID unlock; password unlock.
5. Five wrong passwords → real macOS lock.
6. `kill -9` GlassLock while locked → real macOS lock appears.
7. iPhone on mobile data → Shortcut → "✅ Mac locked".
8. Lid closed → Shortcut → "⚠️ No reply".
9. External display (if available) is also blurred.

## 10. Risks to resolve early in implementation

1. **Kiosk options for a menu-bar app** — confirm presentation options hold;
   fallback: `.regular` activation policy while locked.
2. **Blur strength** — confirm text is unreadable; fallback: heavier tint /
   stronger blur radius.
3. **`SACLockScreenImmediate` on macOS 27** — confirm it exists and locks;
   fallback: `pmset displaysleepnow` with "require password immediately".
4. **Generated Shortcut import** — undocumented format; fallback: manual
   Shortcut instructions.
5. **Touch ID view inside a shielding-level window** — confirm the embedded
   view receives the fingerprint; fallback: password-only plus a
   "Use Touch ID" button that briefly lowers the window level for the system
   prompt.

These are spike-first tasks in the implementation plan: each is proven with a
small throwaway check before the dependent code is written.

## 11. Phase 2 (future, separate spec)

Native iPhone app (requires installing Xcode; free Apple ID → 7-day
re-signing) using the identical relay protocol in §5, plus whatever status
display is wanted then.
