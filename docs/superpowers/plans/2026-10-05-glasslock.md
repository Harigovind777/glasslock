# GlassLock Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that, on a `lock` command from an iPhone Shortcut via ntfy.sh, covers every screen with a live frosted-glass blur that blocks all input — keeping every process running — until Touch ID or the login password is entered at the Mac.

**Architecture:** A Swift package with a pure-logic library (`GlassLockCore`: state machine, relay message filter, backoff, secret, persistence, Shortcut builder — all unit-tested) and a thin AppKit executable (`GlassLock`: overlay windows, Touch ID/password, keep-awake, real-lock fallback, ntfy streaming client, menu bar). The state machine emits effects; the app layer only executes them.

**Tech Stack:** Swift 6.4 toolchain (Command Line Tools, **no Xcode**), Swift language mode 5, Swift Testing, AppKit, LocalAuthentication + LocalAuthenticationEmbeddedUI, OpenDirectory, IOKit power assertions, private `login.framework` (`SACLockScreenImmediate`), `/usr/bin/shortcuts sign`, ntfy.sh.

**Spec:** `docs/superpowers/specs/2026-10-05-glasslock-design.md`

## Global Constraints

- Build with `swift build` / `swift test` only — Command Line Tools, no Xcode. Deployment target `macOS 14`; developed on macOS 27.0, MacBook Air M4.
- No third-party dependencies.
- Swift language mode 5 for the whole package (`swiftLanguageModes: [.v5]`).
- App name `GlassLock`; bundle id `com.harigovind.glasslock`; Shortcut name `Lock Mac`.
- Relay base `https://ntfy.sh`; topic = `glasslock-` + 32 base62 chars; ack topic = `<topic>-ack`.
- Command body `lock` (trimmed, case-insensitive). Acks: `locked:<id>` / `already-locked:<id>`.
- Commands older than **120 s** are ignored. Reconnect backoff 1, 2, 4 … capped at **60 s**. **5** wrong passwords → real macOS lock.
- Support directory `~/Library/Application Support/GlassLock/` (mode 0700), topic file mode 0600. Log `~/Library/Logs/GlassLock.log`. Never log passwords or the topic.
- UI copy, verbatim: `Locked from iPhone · <time>`, `Locked from this Mac · <time>`, `✅ Mac locked`, `⚠️ No reply — Mac may be asleep, lid closed, or offline`, `Wrong password — N attempts left` (shown when N ≤ 3, otherwise `Wrong password`).
- Fail closed: any failure to secure the screen ends in the real macOS lock, never in an unlocked Mac.
- Every commit message ends with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Developer safety:** any run that shows the overlay during development uses `--dev-auto-unlock <seconds>` (and `--dev-lock-now` implies 30 s), and the user is told before the screen is covered. `pkill -x GlassLock` from a shell is the emergency exit; afterwards `rm "$HOME/Library/Application Support/GlassLock/glass-locked"` clears the crash flag.

## Review Focus

1. **Enter on an empty password field** must not use up one of the 5 attempts → Task 3 test `emptyPasswordIsNotSubmittable`; Task 7 `submit()` guards on it.
2. **Lock body with stray whitespace or capitals** (`"Lock\n"` from a hand-built Shortcut) must still lock → Task 2 test `lockBodyIsTrimmedAndCaseInsensitive`.
3. **Topic file with a trailing newline** (opened and saved in an editor) must keep the same topic, not silently regenerate one and break the phone → Task 4 test `trailingNewlineKeepsSameTopic`.
4. **App restart or relay reconnect shortly after an unlock** must not replay the old `lock` and re-lock the Mac → Task 2 tests `resumeTokenStartsAtLaunchTime` / `resumeTokenFollowsLastMessage`; Task 9 keeps one filter across reconnects.
5. **External display plugged in, or Mac woken from sleep, while GlassLock runs** — the new screen must be blurred and the relay must reconnect at once → Task 7 rebuilds windows on screen changes; Task 9 restarts the stream on wake; Task 11 checklist items 10–11 verify both.

---

## File Map

```
glasslock/
  Package.swift                                  Task 1 (executable added in Task 7)
  .gitignore                                     Task 1
  Sources/GlassLockCore/
    LockStateMachine.swift                       Task 1
    RelayMessageFilter.swift                     Task 2
    Backoff.swift                                Task 3
    Secret.swift                                 Task 3
    PasswordInput.swift                          Task 3
    LockCaption.swift                            Task 3
    LaunchOptions.swift                          Task 3
    Persistence.swift                            Task 4
    ShortcutBuilder.swift                        Task 5
  Tests/GlassLockCoreTests/
    LockStateMachineTests.swift                  Task 1
    RelayMessageFilterTests.swift                Task 2
    HelpersTests.swift                           Task 3
    PersistenceTests.swift                       Task 4
    ShortcutBuilderTests.swift                   Task 5
  Sources/GlassLock/
    main.swift                                   Task 7 (demo), replaced in Task 8
    Log.swift                                    Task 7
    GlassOverlay.swift                           Task 7
    UnlockPanel.swift                            Task 7
    PasswordVerifier.swift                       Task 7
    KeepAwake.swift                              Task 8
    RealLock.swift                               Task 8
    AppController.swift                          Task 8
    MenuBarController.swift                      Task 8, extended Task 9, 10
    AppDelegate.swift                            Task 8, extended Task 9, 10
    RelayClient.swift                            Task 9
    ShortcutInstaller.swift                      Task 10
  packaging/Info.plist                           Task 7
  scripts/build-app.sh                           Task 7
  scripts/install.sh                             Task 11
  docs/manual-test-checklist.md                  Task 11
  README.md                                      Task 11
```

---

### Task 1: Package scaffold and LockStateMachine

**Files:**
- Create: `Package.swift`, `.gitignore`
- Create: `Sources/GlassLockCore/LockStateMachine.swift`
- Test: `Tests/GlassLockCoreTests/LockStateMachineTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LockSource { remote(commandID: String), local }`, `LockState { unlocked, glassLocked(failedAttempts: Int), realLocked }`, `LockEvent { lockRequested(LockSource), authSucceeded, passwordFailed, overlayFailed, launchedWithCrashFlag, systemUnlocked }`, `KeepAwakeLevel { off, systemOnly, displayAndSystem }`, `AckKind: String { locked = "locked", alreadyLocked = "already-locked" }`, `LockEffect { setCrashFlag(Bool), keepAwake(KeepAwakeLevel), showOverlay(LockSource), hideOverlay, engageRealLock, passwordRejected(attemptsLeft: Int), ack(AckKind, commandID: String) }`, `struct LockStateMachine { static let maxPasswordAttempts = 5; private(set) var state: LockState; init(state:); mutating func handle(_:) -> [LockEffect] }`.

- [ ] **Step 1: Create the package files**

`Package.swift`:
```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GlassLock",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "GlassLockCore"),
        .testTarget(name: "GlassLockCoreTests", dependencies: ["GlassLockCore"]),
    ],
    swiftLanguageModes: [.v5]
)
```

`.gitignore`:
```
.build/
build/
.swiftpm/
*.xcodeproj
```

- [ ] **Step 2: Write the failing tests**

`Tests/GlassLockCoreTests/LockStateMachineTests.swift`:
```swift
import Testing
@testable import GlassLockCore

@Suite struct LockStateMachineTests {
    @Test func remoteLockFromUnlockedShowsOverlayThenAcks() {
        var machine = LockStateMachine()
        let effects = machine.handle(.lockRequested(.remote(commandID: "abc")))
        #expect(machine.state == .glassLocked(failedAttempts: 0))
        #expect(effects == [
            .setCrashFlag(true),
            .keepAwake(.displayAndSystem),
            .showOverlay(.remote(commandID: "abc")),
            .ack(.locked, commandID: "abc"),
        ])
    }

    @Test func localLockDoesNotAck() {
        var machine = LockStateMachine()
        let effects = machine.handle(.lockRequested(.local))
        #expect(effects == [.setCrashFlag(true), .keepAwake(.displayAndSystem), .showOverlay(.local)])
    }

    @Test func remoteLockWhileGlassLockedAcksAlreadyLocked() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 2))
        let effects = machine.handle(.lockRequested(.remote(commandID: "x")))
        #expect(machine.state == .glassLocked(failedAttempts: 2))
        #expect(effects == [.ack(.alreadyLocked, commandID: "x")])
    }

    @Test func localLockWhileGlassLockedDoesNothing() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 0))
        #expect(machine.handle(.lockRequested(.local)) == [])
    }

    @Test func remoteLockWhileRealLockedAcksAlreadyLocked() {
        var machine = LockStateMachine(state: .realLocked)
        #expect(machine.handle(.lockRequested(.remote(commandID: "y"))) == [.ack(.alreadyLocked, commandID: "y")])
        #expect(machine.state == .realLocked)
    }

    @Test func authSuccessUnlocks() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 3))
        let effects = machine.handle(.authSucceeded)
        #expect(machine.state == .unlocked)
        #expect(effects == [.hideOverlay, .keepAwake(.off), .setCrashFlag(false)])
    }

    @Test func wrongPasswordsCountDown() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 0))
        for expectedLeft in [4, 3, 2, 1] {
            #expect(machine.handle(.passwordFailed) == [.passwordRejected(attemptsLeft: expectedLeft)])
        }
        #expect(machine.state == .glassLocked(failedAttempts: 4))
    }

    @Test func fifthWrongPasswordEscalatesToRealLock() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 4))
        let effects = machine.handle(.passwordFailed)
        #expect(machine.state == .realLocked)
        #expect(effects == [.engageRealLock, .hideOverlay, .keepAwake(.systemOnly), .setCrashFlag(false)])
    }

    @Test func overlayFailureEscalatesToRealLock() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 0))
        let effects = machine.handle(.overlayFailed)
        #expect(machine.state == .realLocked)
        #expect(effects == [.engageRealLock, .hideOverlay, .keepAwake(.systemOnly), .setCrashFlag(false)])
    }

    @Test func crashFlagOnLaunchEngagesRealLock() {
        var machine = LockStateMachine()
        let effects = machine.handle(.launchedWithCrashFlag)
        #expect(machine.state == .realLocked)
        #expect(effects == [.engageRealLock, .keepAwake(.systemOnly), .setCrashFlag(false)])
    }

    @Test func systemUnlockAfterRealLockReturnsToUnlocked() {
        var machine = LockStateMachine(state: .realLocked)
        #expect(machine.handle(.systemUnlocked) == [.keepAwake(.off)])
        #expect(machine.state == .unlocked)
    }

    @Test func systemUnlockWhileGlassLockedIsIgnored() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 1))
        #expect(machine.handle(.systemUnlocked) == [])
        #expect(machine.state == .glassLocked(failedAttempts: 1))
    }

    @Test func eventsThatDoNotApplyWhileUnlockedAreIgnored() {
        var machine = LockStateMachine()
        for event in [LockEvent.authSucceeded, .passwordFailed, .overlayFailed, .systemUnlocked] {
            #expect(machine.handle(event) == [])
            #expect(machine.state == .unlocked)
        }
    }

    @Test func attemptCounterResetsAfterUnlock() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 3))
        _ = machine.handle(.authSucceeded)
        _ = machine.handle(.lockRequested(.local))
        #expect(machine.handle(.passwordFailed) == [.passwordRejected(attemptsLeft: 4)])
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -5`
Expected: build failure — `cannot find 'LockStateMachine' in scope`.

- [ ] **Step 4: Write the implementation**

`Sources/GlassLockCore/LockStateMachine.swift`:
```swift
/// Who asked for the lock.
public enum LockSource: Equatable, Sendable {
    case remote(commandID: String)
    case local
}

public enum LockState: Equatable, Sendable {
    case unlocked
    case glassLocked(failedAttempts: Int)
    case realLocked
}

public enum LockEvent: Equatable, Sendable {
    case lockRequested(LockSource)
    case authSucceeded
    case passwordFailed
    case overlayFailed
    case launchedWithCrashFlag
    case systemUnlocked
}

public enum KeepAwakeLevel: Equatable, Sendable {
    case off
    case systemOnly
    case displayAndSystem
}

public enum AckKind: String, Equatable, Sendable {
    case locked = "locked"
    case alreadyLocked = "already-locked"
}

/// Side effects the app layer must perform, in order.
public enum LockEffect: Equatable, Sendable {
    case setCrashFlag(Bool)
    case keepAwake(KeepAwakeLevel)
    case showOverlay(LockSource)
    case hideOverlay
    case engageRealLock
    case passwordRejected(attemptsLeft: Int)
    case ack(AckKind, commandID: String)
}

/// The lock rules. Pure: no UI, no I/O — it only returns effects.
public struct LockStateMachine: Sendable {
    public static let maxPasswordAttempts = 5

    public private(set) var state: LockState

    public init(state: LockState = .unlocked) {
        self.state = state
    }

    public mutating func handle(_ event: LockEvent) -> [LockEffect] {
        switch (state, event) {
        case (.unlocked, .lockRequested(let source)):
            state = .glassLocked(failedAttempts: 0)
            // Crash flag first, so a crash while the overlay appears still fails closed.
            var effects: [LockEffect] = [.setCrashFlag(true), .keepAwake(.displayAndSystem), .showOverlay(source)]
            if case .remote(let id) = source {
                effects.append(.ack(.locked, commandID: id))
            }
            return effects

        case (.glassLocked, .lockRequested(let source)), (.realLocked, .lockRequested(let source)):
            if case .remote(let id) = source {
                return [.ack(.alreadyLocked, commandID: id)]
            }
            return []

        case (.glassLocked, .authSucceeded):
            state = .unlocked
            return [.hideOverlay, .keepAwake(.off), .setCrashFlag(false)]

        case (.glassLocked(let failed), .passwordFailed):
            let total = failed + 1
            if total >= Self.maxPasswordAttempts {
                return escalate()
            }
            state = .glassLocked(failedAttempts: total)
            return [.passwordRejected(attemptsLeft: Self.maxPasswordAttempts - total)]

        case (.glassLocked, .overlayFailed):
            return escalate()

        case (_, .launchedWithCrashFlag):
            state = .realLocked
            return [.engageRealLock, .keepAwake(.systemOnly), .setCrashFlag(false)]

        case (.realLocked, .systemUnlocked):
            state = .unlocked
            return [.keepAwake(.off)]

        default:
            return []
        }
    }

    /// Hand over to the real macOS lock screen. The real lock is engaged before
    /// the overlay is removed so the screen is never left open.
    private mutating func escalate() -> [LockEffect] {
        state = .realLocked
        return [.engageRealLock, .hideOverlay, .keepAwake(.systemOnly), .setCrashFlag(false)]
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -5`
Expected: `Test run with 14 tests ... passed`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift .gitignore Sources Tests
git commit -m "Add package scaffold and lock state machine" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: RelayMessageFilter

**Files:**
- Create: `Sources/GlassLockCore/RelayMessageFilter.swift`
- Test: `Tests/GlassLockCoreTests/RelayMessageFilterTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum RelayDecision: Equatable { lock(commandID: String), ignore(reason: String) }`; `struct RelayMessageFilter { static let maxAge: TimeInterval = 120; init(startedAt: Date = Date()); private(set) var lastProcessedID: String?; var resumeToken: String; mutating func decide(line: String, now: Date) -> RelayDecision }`. Ignore reasons, exactly: `"malformed"`, `"event:<name>"`, `"duplicate"`, `"stale:<seconds>s"`, `"unknown body"`.

- [ ] **Step 1: Write the failing tests**

`Tests/GlassLockCoreTests/RelayMessageFilterTests.swift`:
```swift
import Foundation
import Testing
@testable import GlassLockCore

@Suite struct RelayMessageFilterTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func line(id: String = "m1", time: Int64 = 1_000_000, event: String = "message", message: String? = "lock") -> String {
        var object: [String: Any] = ["id": id, "time": time, "event": event, "topic": "t"]
        if let message { object["message"] = message }
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(data: data, encoding: .utf8)!
    }

    @Test func freshLockIsAccepted() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: line(), now: now) == .lock(commandID: "m1"))
        #expect(filter.lastProcessedID == "m1")
    }

    @Test func lockBodyIsTrimmedAndCaseInsensitive() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: line(message: " Lock\n"), now: now) == .lock(commandID: "m1"))
    }

    @Test func olderThan120SecondsIsIgnored() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: line(time: 1_000_000 - 121), now: now) == .ignore(reason: "stale:121s"))
    }

    @Test func exactly120SecondsIsAccepted() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: line(time: 1_000_000 - 120), now: now) == .lock(commandID: "m1"))
    }

    @Test func futureTimestampFromClockSkewIsAccepted() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: line(time: 1_000_000 + 30), now: now) == .lock(commandID: "m1"))
    }

    @Test func keepaliveAndOpenAreIgnoredWithoutMovingCursor() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: line(id: "k", event: "keepalive", message: nil), now: now) == .ignore(reason: "event:keepalive"))
        #expect(filter.decide(line: line(id: "o", event: "open", message: nil), now: now) == .ignore(reason: "event:open"))
        #expect(filter.lastProcessedID == nil)
    }

    @Test func unknownBodyIsIgnoredButCursorMoves() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: line(id: "u", message: "unlock"), now: now) == .ignore(reason: "unknown body"))
        #expect(filter.lastProcessedID == "u")
    }

    @Test func missingMessageIsIgnored() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: line(message: nil), now: now) == .ignore(reason: "unknown body"))
    }

    @Test func malformedLinesAreIgnored() {
        var filter = RelayMessageFilter(startedAt: now)
        #expect(filter.decide(line: "not json", now: now) == .ignore(reason: "malformed"))
        #expect(filter.decide(line: "", now: now) == .ignore(reason: "malformed"))
        #expect(filter.decide(line: "{\"id\":\"x\"}", now: now) == .ignore(reason: "malformed"))
    }

    @Test func duplicateIDIsIgnored() {
        var filter = RelayMessageFilter(startedAt: now)
        _ = filter.decide(line: line(id: "d"), now: now)
        #expect(filter.decide(line: line(id: "d"), now: now) == .ignore(reason: "duplicate"))
    }

    @Test func resumeTokenStartsAtLaunchTime() {
        let filter = RelayMessageFilter(startedAt: now)
        #expect(filter.resumeToken == "1000000")
    }

    @Test func resumeTokenFollowsLastMessage() {
        var filter = RelayMessageFilter(startedAt: now)
        _ = filter.decide(line: line(id: "abc"), now: now)
        _ = filter.decide(line: line(id: "k", event: "keepalive", message: nil), now: now)
        #expect(filter.resumeToken == "abc")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RelayMessageFilterTests 2>&1 | tail -5`
Expected: build failure — `cannot find 'RelayMessageFilter' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/GlassLockCore/RelayMessageFilter.swift`:
```swift
import Foundation

public enum RelayDecision: Equatable, Sendable {
    case lock(commandID: String)
    case ignore(reason: String)
}

/// Turns ntfy JSON-stream lines into lock commands.
/// Keep one instance for the app's lifetime so duplicates are caught across reconnects.
public struct RelayMessageFilter: Sendable {
    public static let maxAge: TimeInterval = 120
    private static let rememberedIDs = 200

    public private(set) var lastProcessedID: String?
    private let startedAt: Date
    private var seenIDs: [String] = []

    public init(startedAt: Date = Date()) {
        self.startedAt = startedAt
    }

    /// Value for ntfy's `since` parameter: after the last message seen, or — before
    /// any message — from launch time, so a `lock` sent before this launch (and
    /// possibly already handled) is never replayed.
    public var resumeToken: String {
        lastProcessedID ?? String(Int(startedAt.timeIntervalSince1970))
    }

    private struct Line: Decodable {
        let id: String
        let time: Int64
        let event: String
        let message: String?
    }

    public mutating func decide(line: String, now: Date) -> RelayDecision {
        guard let data = line.data(using: .utf8),
              let message = try? JSONDecoder().decode(Line.self, from: data) else {
            return .ignore(reason: "malformed")
        }
        guard message.event == "message" else {
            return .ignore(reason: "event:\(message.event)")
        }
        guard !seenIDs.contains(message.id) else {
            return .ignore(reason: "duplicate")
        }
        seenIDs.append(message.id)
        if seenIDs.count > Self.rememberedIDs {
            seenIDs.removeFirst()
        }
        lastProcessedID = message.id

        let age = now.timeIntervalSince1970 - TimeInterval(message.time)
        guard age <= Self.maxAge else {
            return .ignore(reason: "stale:\(Int(age))s")
        }
        let body = (message.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard body == "lock" else {
            return .ignore(reason: "unknown body")
        }
        return .lock(commandID: message.id)
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (26).

- [ ] **Step 5: Commit**

```bash
git add Sources/GlassLockCore/RelayMessageFilter.swift Tests/GlassLockCoreTests/RelayMessageFilterTests.swift
git commit -m "Add relay message filter with staleness, dedupe and resume token" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Core helpers — Backoff, Secret, PasswordInput, LockCaption, LaunchOptions

**Files:**
- Create: `Sources/GlassLockCore/Backoff.swift`, `Secret.swift`, `PasswordInput.swift`, `LockCaption.swift`, `LaunchOptions.swift`
- Test: `Tests/GlassLockCoreTests/HelpersTests.swift`

**Interfaces:**
- Consumes: `LockSource` (Task 1).
- Produces:
  - `struct Backoff { static let maxDelay: TimeInterval = 60; init(); mutating func nextDelay() -> TimeInterval; mutating func reset() }`
  - `enum Secret { static let prefix = "glasslock-"; static let randomLength = 32; static func makeTopic() -> String; static func isValidTopic(_:) -> Bool }`
  - `enum PasswordInput { static func isSubmittable(_:) -> Bool; static func rejectionMessage(attemptsLeft:) -> String }`
  - `enum LockCaption { static func text(for: LockSource, time: String) -> String }`
  - `struct LaunchOptions { var autoUnlockSeconds: Int?; var lockOnLaunch: Bool; var isDevMode: Bool; static func parse(_ arguments: [String]) -> LaunchOptions }`

- [ ] **Step 1: Write the failing tests**

`Tests/GlassLockCoreTests/HelpersTests.swift`:
```swift
import Testing
@testable import GlassLockCore

@Suite struct BackoffTests {
    @Test func doublesThenCapsAtSixty() {
        var backoff = Backoff()
        let delays = (0..<8).map { _ in backoff.nextDelay() }
        #expect(delays == [1, 2, 4, 8, 16, 32, 60, 60])
    }

    @Test func resetStartsOver() {
        var backoff = Backoff()
        _ = backoff.nextDelay(); _ = backoff.nextDelay()
        backoff.reset()
        #expect(backoff.nextDelay() == 1)
    }
}

@Suite struct SecretTests {
    @Test func topicHasPrefixLengthAndAlphabet() {
        let topic = Secret.makeTopic()
        #expect(topic.hasPrefix("glasslock-"))
        #expect(topic.count == "glasslock-".count + 32)
        #expect(Secret.isValidTopic(topic))
    }

    @Test func topicsDiffer() {
        #expect(Secret.makeTopic() != Secret.makeTopic())
    }

    @Test func invalidTopicsAreRejected() {
        #expect(!Secret.isValidTopic("glasslock-short"))
        #expect(!Secret.isValidTopic("other-" + String(repeating: "a", count: 32)))
        #expect(!Secret.isValidTopic("glasslock-" + String(repeating: "a", count: 31) + "/"))
        #expect(!Secret.isValidTopic(""))
    }
}

@Suite struct PasswordInputTests {
    @Test func emptyPasswordIsNotSubmittable() {
        #expect(!PasswordInput.isSubmittable(""))
        #expect(PasswordInput.isSubmittable(" "))
        #expect(PasswordInput.isSubmittable("hunter2"))
    }

    @Test func attemptsShownOnlyWhenThreeOrFewerLeft() {
        #expect(PasswordInput.rejectionMessage(attemptsLeft: 4) == "Wrong password")
        #expect(PasswordInput.rejectionMessage(attemptsLeft: 3) == "Wrong password — 3 attempts left")
        #expect(PasswordInput.rejectionMessage(attemptsLeft: 1) == "Wrong password — 1 attempt left")
    }
}

@Suite struct LockCaptionTests {
    @Test func captionNamesTheSource() {
        #expect(LockCaption.text(for: .remote(commandID: "x"), time: "2:14 PM") == "Locked from iPhone · 2:14 PM")
        #expect(LockCaption.text(for: .local, time: "2:14 PM") == "Locked from this Mac · 2:14 PM")
    }
}

@Suite struct LaunchOptionsTests {
    @Test func noFlagsMeansNormalMode() {
        let options = LaunchOptions.parse(["GlassLock"])
        #expect(options == LaunchOptions())
        #expect(!options.isDevMode)
    }

    @Test func autoUnlockParsesSeconds() {
        #expect(LaunchOptions.parse(["GlassLock", "--dev-auto-unlock", "20"]).autoUnlockSeconds == 20)
    }

    @Test func badAutoUnlockValueIsIgnored() {
        #expect(LaunchOptions.parse(["GlassLock", "--dev-auto-unlock", "abc"]).autoUnlockSeconds == nil)
        #expect(LaunchOptions.parse(["GlassLock", "--dev-auto-unlock", "0"]).autoUnlockSeconds == nil)
        #expect(LaunchOptions.parse(["GlassLock", "--dev-auto-unlock"]).autoUnlockSeconds == nil)
    }

    @Test func lockNowImpliesThirtySecondSafetyUnlock() {
        let options = LaunchOptions.parse(["GlassLock", "--dev-lock-now"])
        #expect(options.lockOnLaunch)
        #expect(options.autoUnlockSeconds == 30)
    }

    @Test func lockNowKeepsExplicitAutoUnlock() {
        let options = LaunchOptions.parse(["GlassLock", "--dev-lock-now", "--dev-auto-unlock", "15"])
        #expect(options.autoUnlockSeconds == 15)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test 2>&1 | tail -5`
Expected: build failure — `cannot find 'Backoff' in scope` (and the other new types).

- [ ] **Step 3: Write the implementations**

`Sources/GlassLockCore/Backoff.swift`:
```swift
import Foundation

/// Reconnect delays: 1, 2, 4, … seconds, capped at 60.
public struct Backoff: Sendable {
    public static let maxDelay: TimeInterval = 60
    private var attempt = 0

    public init() {}

    public mutating func nextDelay() -> TimeInterval {
        let delay = min(Self.maxDelay, pow(2, Double(attempt)))
        if delay < Self.maxDelay {
            attempt += 1
        }
        return delay
    }

    public mutating func reset() {
        attempt = 0
    }
}
```

`Sources/GlassLockCore/Secret.swift`:
```swift
/// The ntfy topic name is the only secret: `glasslock-` + 32 base62 characters (~190 bits).
public enum Secret {
    public static let prefix = "glasslock-"
    public static let randomLength = 32
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// Uses the system CSPRNG.
    public static func makeTopic() -> String {
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<randomLength).map { _ in alphabet.randomElement(using: &generator)! }
        return prefix + String(suffix)
    }

    public static func isValidTopic(_ topic: String) -> Bool {
        guard topic.hasPrefix(prefix) else { return false }
        let suffix = topic.dropFirst(prefix.count)
        return suffix.count == randomLength && suffix.allSatisfy { alphabet.contains($0) }
    }
}
```

`Sources/GlassLockCore/PasswordInput.swift`:
```swift
public enum PasswordInput {
    /// Pressing Enter on an empty field must not use up an attempt.
    public static func isSubmittable(_ password: String) -> Bool {
        !password.isEmpty
    }

    public static func rejectionMessage(attemptsLeft: Int) -> String {
        guard attemptsLeft <= 3 else { return "Wrong password" }
        return "Wrong password — \(attemptsLeft) \(attemptsLeft == 1 ? "attempt" : "attempts") left"
    }
}
```

`Sources/GlassLockCore/LockCaption.swift`:
```swift
public enum LockCaption {
    public static func text(for source: LockSource, time: String) -> String {
        switch source {
        case .remote: return "Locked from iPhone · \(time)"
        case .local: return "Locked from this Mac · \(time)"
        }
    }
}
```

`Sources/GlassLockCore/LaunchOptions.swift`:
```swift
/// Developer-only flags. The LaunchAgent never passes any of them.
public struct LaunchOptions: Equatable, Sendable {
    /// Every glass lock unlocks itself after this many seconds (safety net while developing).
    public var autoUnlockSeconds: Int?
    /// Glass-lock 2 seconds after launch.
    public var lockOnLaunch: Bool

    public init(autoUnlockSeconds: Int? = nil, lockOnLaunch: Bool = false) {
        self.autoUnlockSeconds = autoUnlockSeconds
        self.lockOnLaunch = lockOnLaunch
    }

    public var isDevMode: Bool {
        autoUnlockSeconds != nil || lockOnLaunch
    }

    public static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--dev-auto-unlock":
                if index + 1 < arguments.count, let seconds = Int(arguments[index + 1]), seconds > 0 {
                    options.autoUnlockSeconds = seconds
                    index += 1
                }
            case "--dev-lock-now":
                options.lockOnLaunch = true
            default:
                break
            }
            index += 1
        }
        if options.lockOnLaunch && options.autoUnlockSeconds == nil {
            options.autoUnlockSeconds = 30
        }
        return options
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (39).

- [ ] **Step 5: Commit**

```bash
git add Sources/GlassLockCore Tests/GlassLockCoreTests/HelpersTests.swift
git commit -m "Add backoff, secret, password input, caption and launch option helpers" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Persistence — TopicStore, CrashFlag, AppPaths

**Files:**
- Create: `Sources/GlassLockCore/Persistence.swift`
- Test: `Tests/GlassLockCoreTests/PersistenceTests.swift`

**Interfaces:**
- Consumes: `Secret.makeTopic()`, `Secret.isValidTopic(_:)` (Task 3).
- Produces: `enum AppPaths { static var supportDirectory: URL; static var logFile: URL }`; `struct TopicStore { init(directory: URL); func loadOrCreate() throws -> String; @discardableResult func reset() throws -> String }`; `struct CrashFlag { init(directory: URL); var isSet: Bool; func set(_ on: Bool) throws }`.

- [ ] **Step 1: Write the failing tests**

`Tests/GlassLockCoreTests/PersistenceTests.swift`:
```swift
import Foundation
import Testing
@testable import GlassLockCore

@Suite struct PersistenceTests {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("glasslock-tests-\(UUID().uuidString)")

    @Test func createsTopicWhenMissingWithPrivatePermissions() throws {
        let store = TopicStore(directory: directory)
        let topic = try store.loadOrCreate()
        #expect(Secret.isValidTopic(topic))
        let fileMode = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? Int
        #expect(fileMode == 0o600)
        let dirMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        #expect(dirMode == 0o700)
    }

    @Test func returnsSameTopicOnReload() throws {
        let first = try TopicStore(directory: directory).loadOrCreate()
        let second = try TopicStore(directory: directory).loadOrCreate()
        #expect(first == second)
    }

    @Test func trailingNewlineKeepsSameTopic() throws {
        let store = TopicStore(directory: directory)
        let topic = try store.loadOrCreate()
        try Data((topic + "\n").utf8).write(to: store.fileURL)
        #expect(try store.loadOrCreate() == topic)
    }

    @Test func invalidContentIsReplaced() throws {
        let store = TopicStore(directory: directory)
        _ = try store.loadOrCreate()
        try Data("garbage".utf8).write(to: store.fileURL)
        let topic = try store.loadOrCreate()
        #expect(Secret.isValidTopic(topic))
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == topic)
    }

    @Test func resetChangesTopic() throws {
        let store = TopicStore(directory: directory)
        let old = try store.loadOrCreate()
        let new = try store.reset()
        #expect(old != new)
        #expect(try store.loadOrCreate() == new)
    }

    @Test func crashFlagSetsAndClears() throws {
        let flag = CrashFlag(directory: directory)
        #expect(!flag.isSet)
        try flag.set(true)
        #expect(flag.isSet)
        try flag.set(false)
        #expect(!flag.isSet)
        try flag.set(false)
        #expect(!flag.isSet)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter PersistenceTests 2>&1 | tail -5`
Expected: build failure — `cannot find 'TopicStore' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/GlassLockCore/Persistence.swift`:
```swift
import Foundation

public enum AppPaths {
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GlassLock", isDirectory: true)
    }

    public static var logFile: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/GlassLock.log")
    }
}

func ensurePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

/// The ntfy topic, kept in a 0600 file (not the Keychain: ad-hoc re-signing on
/// every rebuild would trigger Keychain access prompts).
public struct TopicStore {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("topic")
    }

    /// Returns the saved topic, creating a new one only if none is saved or it is invalid.
    public func loadOrCreate() throws -> String {
        if let raw = try? String(contentsOf: fileURL, encoding: .utf8) {
            let topic = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if Secret.isValidTopic(topic) {
                return topic
            }
        }
        return try reset()
    }

    @discardableResult
    public func reset() throws -> String {
        let topic = Secret.makeTopic()
        try ensurePrivateDirectory(fileURL.deletingLastPathComponent())
        try Data(topic.utf8).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        return topic
    }
}

/// Present while a glass lock is up. Found at launch → the app crashed mid-lock.
public struct CrashFlag {
    public let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("glass-locked")
    }

    public var isSet: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    public func set(_ on: Bool) throws {
        if on {
            try ensurePrivateDirectory(fileURL.deletingLastPathComponent())
            try Data().write(to: fileURL)
        } else if isSet {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (45).

- [ ] **Step 5: Commit**

```bash
git add Sources/GlassLockCore/Persistence.swift Tests/GlassLockCoreTests/PersistenceTests.swift
git commit -m "Add topic store and crash flag persistence" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: ShortcutBuilder

The Shortcut format is undocumented. A plist with this structure was generated and accepted by `shortcuts sign --mode anyone` on this Mac during planning; whether the actions are wired correctly after import is verified by hand in Task 10.

**Files:**
- Create: `Sources/GlassLockCore/ShortcutBuilder.swift`
- Test: `Tests/GlassLockCoreTests/ShortcutBuilderTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum ShortcutBuilder { static let successText: String; static let noReplyText: String; static func publishURL(topic:relay:) -> String; static func ackPollURL(topic:relay:) -> String; static func workflow(topic:relay:makeUUID:) -> [String: Any]; static func data(topic:) throws -> Data; static func manualInstructions(topic:) -> String }`.

- [ ] **Step 1: Write the failing tests**

`Tests/GlassLockCoreTests/ShortcutBuilderTests.swift`:
```swift
import Foundation
import Testing
@testable import GlassLockCore

@Suite struct ShortcutBuilderTests {
    let topic = "glasslock-" + String(repeating: "A", count: 32)

    func actions() throws -> [[String: Any]] {
        let data = try ShortcutBuilder.data(topic: topic)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        return plist["WFWorkflowActions"] as! [[String: Any]]
    }

    func params(_ action: [String: Any]) -> [String: Any] {
        action["WFWorkflowActionParameters"] as! [String: Any]
    }

    @Test func hasExpectedActionSequence() throws {
        let ids = try actions().map { $0["WFWorkflowActionIdentifier"] as! String }
        #expect(ids == [
            "is.workflow.actions.downloadurl",
            "is.workflow.actions.getvalueforkey",
            "is.workflow.actions.delay",
            "is.workflow.actions.downloadurl",
            "is.workflow.actions.conditional",
            "is.workflow.actions.notification",
            "is.workflow.actions.conditional",
            "is.workflow.actions.notification",
            "is.workflow.actions.conditional",
        ])
    }

    @Test func urlsContainTheTopic() throws {
        let all = try actions()
        #expect(params(all[0])["WFURL"] as? String == "https://ntfy.sh/\(topic)/publish?message=lock")
        #expect(params(all[3])["WFURL"] as? String == "https://ntfy.sh/\(topic)-ack/raw?poll=1&since=30s")
    }

    @Test func variableReferencesPointAtRealActions() throws {
        let all = try actions()
        let publishUUID = params(all[0])["UUID"] as! String
        let idUUID = params(all[1])["UUID"] as! String
        let pollUUID = params(all[3])["UUID"] as! String

        let getValueInput = (params(all[1])["WFInput"] as! [String: Any])["Value"] as! [String: Any]
        #expect(getValueInput["OutputUUID"] as? String == publishUUID)

        let condition = params(all[4])
        let conditionInput = ((condition["WFInput"] as! [String: Any])["Variable"] as! [String: Any])["Value"] as! [String: Any]
        #expect(conditionInput["OutputUUID"] as? String == pollUUID)

        let text = (condition["WFConditionalActionString"] as! [String: Any])["Value"] as! [String: Any]
        #expect(text["string"] as? String == "locked:\u{FFFC}")
        let attachments = text["attachmentsByRange"] as! [String: Any]
        let attachment = attachments["{7, 1}"] as! [String: Any]
        #expect(attachment["OutputUUID"] as? String == idUUID)
    }

    @Test func ifOtherwiseEndShareOneGroup() throws {
        let all = try actions()
        let groups = [4, 6, 8].map { params(all[$0])["GroupingIdentifier"] as! String }
        let modes = [4, 6, 8].map { params(all[$0])["WFControlFlowMode"] as! Int }
        #expect(Set(groups).count == 1)
        #expect(modes == [0, 1, 2])
    }

    @Test func notificationsUseAgreedCopy() throws {
        let all = try actions()
        #expect(params(all[5])["WFNotificationActionBody"] as? String == "✅ Mac locked")
        #expect(params(all[7])["WFNotificationActionBody"] as? String == "⚠️ No reply — Mac may be asleep, lid closed, or offline")
    }

    @Test func manualInstructionsContainBothURLs() {
        let text = ShortcutBuilder.manualInstructions(topic: topic)
        #expect(text.contains("https://ntfy.sh/\(topic)/publish?message=lock"))
        #expect(text.contains("https://ntfy.sh/\(topic)-ack/raw?poll=1&since=30s"))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter ShortcutBuilderTests 2>&1 | tail -5`
Expected: build failure — `cannot find 'ShortcutBuilder' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/GlassLockCore/ShortcutBuilder.swift`:
```swift
import Foundation

/// Builds the "Lock Mac" Shortcut: publish `lock`, wait, poll the ack topic,
/// and notify. The If checks for "locked:<id>", which also matches
/// "already-locked:<id>" — both mean the Mac is locked.
public enum ShortcutBuilder {
    public static let successText = "✅ Mac locked"
    public static let noReplyText = "⚠️ No reply — Mac may be asleep, lid closed, or offline"

    public static func publishURL(topic: String, relay: String = "https://ntfy.sh") -> String {
        "\(relay)/\(topic)/publish?message=lock"
    }

    public static func ackPollURL(topic: String, relay: String = "https://ntfy.sh") -> String {
        "\(relay)/\(topic)-ack/raw?poll=1&since=30s"
    }

    public static func workflow(
        topic: String,
        relay: String = "https://ntfy.sh",
        makeUUID: () -> String = { UUID().uuidString }
    ) -> [String: Any] {
        let publish = makeUUID()
        let idValue = makeUUID()
        let poll = makeUUID()
        let group = makeUUID()

        let actions: [[String: Any]] = [
            action("is.workflow.actions.downloadurl", [
                "UUID": publish,
                "WFURL": publishURL(topic: topic, relay: relay),
                "WFHTTPMethod": "GET",
            ]),
            action("is.workflow.actions.getvalueforkey", [
                "UUID": idValue,
                "WFDictionaryKey": "id",
                "WFInput": attachment(publish, "Contents of URL"),
            ]),
            action("is.workflow.actions.delay", ["WFDelayTime": 4]),
            action("is.workflow.actions.downloadurl", [
                "UUID": poll,
                "WFURL": ackPollURL(topic: topic, relay: relay),
                "WFHTTPMethod": "GET",
            ]),
            action("is.workflow.actions.conditional", [
                "GroupingIdentifier": group,
                "WFControlFlowMode": 0,
                "WFCondition": 99, // "contains"
                "WFInput": ["Type": "Variable", "Variable": attachment(poll, "Contents of URL")] as [String: Any],
                "WFConditionalActionString": text(prefix: "locked:", variable: idValue, name: "Dictionary Value"),
            ]),
            action("is.workflow.actions.notification", [
                "WFNotificationActionTitle": "GlassLock",
                "WFNotificationActionBody": successText,
            ]),
            action("is.workflow.actions.conditional", ["GroupingIdentifier": group, "WFControlFlowMode": 1]),
            action("is.workflow.actions.notification", [
                "WFNotificationActionTitle": "GlassLock",
                "WFNotificationActionBody": noReplyText,
            ]),
            action("is.workflow.actions.conditional", ["GroupingIdentifier": group, "WFControlFlowMode": 2]),
        ]

        return [
            "WFWorkflowActions": actions,
            "WFWorkflowClientVersion": "2607.0.1",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 255, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowHasShortcutInputVariables": false,
        ]
    }

    /// Unsigned binary plist, ready for `shortcuts sign`.
    public static func data(topic: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: workflow(topic: topic), format: .binary, options: 0)
    }

    public static func manualInstructions(topic: String) -> String {
        """
        In the Shortcuts app, tap + and add these actions:
        1. Get Contents of URL: \(publishURL(topic: topic))
        2. Get Dictionary Value: key "id" in Contents of URL
        3. Wait: 4 seconds
        4. Get Contents of URL: \(ackPollURL(topic: topic))
        5. If Contents of URL contains "locked:" followed by Dictionary Value
             Show Notification: \(successText)
           Otherwise
             Show Notification: \(noReplyText)
           End If
        Name it "Lock Mac".
        """
    }

    private static func action(_ identifier: String, _ parameters: [String: Any]) -> [String: Any] {
        ["WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": parameters]
    }

    private static func output(_ uuid: String, _ name: String) -> [String: Any] {
        ["Type": "ActionOutput", "OutputUUID": uuid, "OutputName": name]
    }

    private static func attachment(_ uuid: String, _ name: String) -> [String: Any] {
        ["WFSerializationType": "WFTextTokenAttachment", "Value": output(uuid, name)]
    }

    /// Text with one variable appended after `prefix` (U+FFFC marks the variable's slot).
    private static func text(prefix: String, variable uuid: String, name: String) -> [String: Any] {
        [
            "WFSerializationType": "WFTextTokenString",
            "Value": [
                "string": prefix + "\u{FFFC}",
                "attachmentsByRange": ["{\(prefix.utf16.count), 1}": output(uuid, name)],
            ] as [String: Any],
        ]
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test 2>&1 | tail -3`
Expected: all tests pass (51).

- [ ] **Step 5: Commit**

```bash
git add Sources/GlassLockCore/ShortcutBuilder.swift Tests/GlassLockCoreTests/ShortcutBuilderTests.swift
git commit -m "Add Lock Mac Shortcut builder and manual instructions" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Spike — real macOS lock on macOS 27 (throwaway)

Proves risk #3 before `RealLock` depends on it. Nothing from this task is committed.

**Files:** scratch only (`$TMPDIR/reallock-spike.swift`).

**Interfaces:**
- Consumes: nothing. Produces: a decision recorded in Task 8 — primary method `SACLockScreenImmediate`, or fallback `pmset displaysleepnow`.

- [ ] **Step 1: Tell the user** the screen will lock for real and they unlock with Touch ID as usual. Wait for "ok".

- [ ] **Step 2: Start a counter, write and run the spike**

```bash
SPIKE="$TMPDIR/reallock-spike"; mkdir -p "$SPIKE"
( for i in $(seq 1 60); do date +%s >> "$SPIKE/counter.log"; sleep 1; done ) &
cat > "$SPIKE/spike.swift" <<'EOF'
import Foundation
typealias LockFn = @convention(c) () -> Int32
guard let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY) else {
    print("dlopen failed"); exit(1)
}
guard let symbol = dlsym(handle, "SACLockScreenImmediate") else {
    print("dlsym failed"); exit(1)
}
print("SACLockScreenImmediate returned", unsafeBitCast(symbol, to: LockFn.self)())
EOF
swift "$SPIKE/spike.swift"
```
Expected: prints `returned 0` and the real lock screen appears at once.

- [ ] **Step 3: After the user unlocks, confirm the counter had no gaps**

```bash
awk 'NR>1 && $1-prev>2 {print "GAP", prev, $1} {prev=$1} END {print NR, "ticks"}' "$TMPDIR/reallock-spike/counter.log"
sysadminctl -screenLock status 2>&1
```
Expected: no `GAP` lines. `screenLock` status recorded (needed if the fallback is ever used — `pmset displaysleepnow` only locks when the password is required immediately).

- [ ] **Step 4: Record the decision** in the Task 8 commit message: "RealLock: SACLockScreenImmediate verified on macOS 27" — or, if it failed, swap the order in `RealLock.engage()` so `pmset displaysleepnow` is primary, and tell the user to set *Require password immediately* in System Settings › Lock Screen.

---

### Task 7: Frosted overlay, unlock panel, password check, app bundle — and verify risks 1, 2, 5

**Files:**
- Modify: `Package.swift` (add executable target and product)
- Create: `Sources/GlassLock/main.swift` (demo entry point, replaced in Task 8)
- Create: `Sources/GlassLock/Log.swift`, `GlassOverlay.swift`, `UnlockPanel.swift`, `PasswordVerifier.swift`
- Create: `packaging/Info.plist`, `scripts/build-app.sh`

**Interfaces:**
- Consumes: `AppPaths.logFile` (Task 4), `PasswordInput` (Task 3), `LaunchOptions` (Task 3).
- Produces: `enum Log { static func write(_:) }`; `@MainActor final class GlassOverlay { static let tintAlpha: CGFloat; var onUnlocked: () -> Void; var onPasswordFailed: () -> Void; var onFailure: (String) -> Void; var isVisible: Bool; func show(caption: String); func hide(); func showPasswordRejected(attemptsLeft: Int) }`; `enum PasswordVerifier { static func verify(_:) -> Bool }`; `scripts/build-app.sh` → `build/GlassLock.app`.

- [ ] **Step 1: Add the executable target**

Replace `Package.swift` with:
```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "GlassLock",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "GlassLock", targets: ["GlassLock"]),
    ],
    targets: [
        .target(name: "GlassLockCore"),
        .executableTarget(name: "GlassLock", dependencies: ["GlassLockCore"]),
        .testTarget(name: "GlassLockCoreTests", dependencies: ["GlassLockCore"]),
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Write Log and PasswordVerifier**

`Sources/GlassLock/Log.swift`:
```swift
import Foundation
import GlassLockCore

/// Appends timestamped lines to ~/Library/Logs/GlassLock.log. Never pass passwords or the topic.
enum Log {
    static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        let url = AppPaths.logFile
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(line.utf8).write(to: url)
        }
    }
}
```

`Sources/GlassLock/PasswordVerifier.swift`:
```swift
import Foundation
import OpenDirectory

/// Checks the current user's login password against the local directory.
/// Slow by design (the system may add delays) — call off the main thread.
enum PasswordVerifier {
    static func verify(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}
```

- [ ] **Step 3: Write UnlockPanel**

`Sources/GlassLock/UnlockPanel.swift`:
```swift
import AppKit
import GlassLockCore
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// Frosted card: lock icon, caption, embedded Touch ID prompt, password field, status line.
@MainActor
final class UnlockPanel: NSVisualEffectView {
    var onUnlocked: () -> Void = {}
    var onPasswordFailed: () -> Void = {}

    let passwordField = NSSecureTextField()
    private let statusLabel = NSTextField(labelWithString: "Touch ID or enter your password")
    private let touchIDSlot = NSView()
    private var context: LAContext?
    private var verifying = false

    init(caption: String) {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 18
        layer?.masksToBounds = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Locked")!)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 28, weight: .semibold)
        icon.contentTintColor = .white

        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        captionLabel.textColor = .white

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.white.withAlphaComponent(0.8)

        passwordField.placeholderString = "Mac password"
        passwordField.target = self
        passwordField.action = #selector(submit)
        passwordField.translatesAutoresizingMaskIntoConstraints = false
        passwordField.widthAnchor.constraint(equalToConstant: 240).isActive = true

        touchIDSlot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            touchIDSlot.widthAnchor.constraint(equalToConstant: 64),
            touchIDSlot.heightAnchor.constraint(equalToConstant: 64),
        ])

        let stack = NSStackView(views: [icon, captionLabel, touchIDSlot, passwordField, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 32, bottom: 24, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("UnlockPanel is created in code only")
    }

    // MARK: Touch ID

    func startTouchID() {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            touchIDSlot.isHidden = true
            statusLabel.stringValue = "Touch ID unavailable — enter your password"
            Log.write("touch id unavailable: \(error?.localizedDescription ?? "unknown")")
            return
        }
        self.context = context
        let view = LAAuthenticationView(context: context, controlSize: .large)
        view.translatesAutoresizingMaskIntoConstraints = false
        touchIDSlot.subviews.forEach { $0.removeFromSuperview() }
        touchIDSlot.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: touchIDSlot.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: touchIDSlot.centerYAnchor),
        ])
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "unlock GlassLock") { success, error in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.context === context else { return }
                if success {
                    Log.write("touch id accepted")
                    self.onUnlocked()
                    return
                }
                let code = (error as? LAError)?.code
                Log.write("touch id ended: \(code.map { String(describing: $0) } ?? "unknown")")
                if code == .biometryLockout || code == .biometryNotAvailable || code == .biometryNotEnrolled {
                    self.touchIDSlot.isHidden = true
                    self.statusLabel.stringValue = "Touch ID locked — enter your password"
                    return
                }
                // Finger not recognised or prompt interrupted: offer Touch ID again.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    guard let self, self.context === context else { return }
                    self.startTouchID()
                }
            }
        }
    }

    func stopTouchID() {
        let context = self.context
        self.context = nil
        context?.invalidate()
    }

    // MARK: Password

    func showRejected(attemptsLeft: Int) {
        statusLabel.stringValue = PasswordInput.rejectionMessage(attemptsLeft: attemptsLeft)
    }

    @objc private func submit() {
        let password = passwordField.stringValue
        guard PasswordInput.isSubmittable(password), !verifying else { return }
        verifying = true
        passwordField.isEnabled = false
        statusLabel.stringValue = "Checking…"
        DispatchQueue.global(qos: .userInitiated).async {
            let accepted = PasswordVerifier.verify(password)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.verifying = false
                self.passwordField.isEnabled = true
                self.passwordField.stringValue = ""
                self.window?.makeFirstResponder(self.passwordField)
                if accepted {
                    Log.write("password accepted")
                    self.onUnlocked()
                } else {
                    Log.write("password rejected")
                    self.statusLabel.stringValue = "Wrong password"
                    self.shake()
                    self.onPasswordFailed()
                }
            }
        }
    }

    private func shake() {
        let animation = CAKeyframeAnimation(keyPath: "position.x")
        animation.values = [0, -10, 10, -6, 6, 0]
        animation.isAdditive = true
        animation.duration = 0.35
        layer?.add(animation, forKey: "shake")
    }
}
```

- [ ] **Step 4: Write GlassOverlay**

`Sources/GlassLock/GlassOverlay.swift`:
```swift
import AppKit

/// Borderless window that may take keyboard focus.
final class ShieldWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Frosted-glass lock: one live-blurred window per screen above everything,
/// the unlock panel on the main screen, and kiosk options that block app
/// switching, Force Quit, the Dock and the menu bar.
@MainActor
final class GlassOverlay {
    /// Darkening over the blur. Raise it if text under the overlay is readable.
    static let tintAlpha: CGFloat = 0.35

    static let kioskOptions: NSApplication.PresentationOptions = [
        .hideDock, .hideMenuBar, .disableProcessSwitching, .disableForceQuit,
        .disableSessionTermination, .disableHideApplication, .disableAppleMenu,
    ]

    var onUnlocked: () -> Void = {}
    var onPasswordFailed: () -> Void = {}
    /// The screen could not be secured — the caller must fail closed.
    var onFailure: (String) -> Void = { _ in }

    private var windows: [ShieldWindow] = []
    private var panel: UnlockPanel?
    private var appObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var savedOptions: NSApplication.PresentationOptions = []

    var isVisible: Bool { panel != nil }

    func show(caption: String) {
        guard !isVisible else { return }
        guard !NSScreen.screens.isEmpty else {
            onFailure("no screens")
            return
        }
        let panel = UnlockPanel(caption: caption)
        panel.onUnlocked = { [weak self] in self?.onUnlocked() }
        panel.onPasswordFailed = { [weak self] in self?.onPasswordFailed() }
        self.panel = panel

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        layoutWindows()
        savedOptions = NSApp.presentationOptions
        NSApp.presentationOptions = Self.kioskOptions
        startGuarding()
        panel.startTouchID()
        Log.write("overlay shown on \(windows.count) screen(s)")

        // Fail closed: without keyboard focus, keystrokes would reach the apps underneath.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.panel === panel else { return }
            if !NSApp.isActive || !(panel.window?.isKeyWindow ?? false) {
                self.onFailure("could not take keyboard focus")
            }
        }
    }

    func hide() {
        guard let panel else { return }
        stopGuarding()
        panel.stopTouchID()
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        self.panel = nil
        NSApp.presentationOptions = savedOptions
        NSApp.setActivationPolicy(.accessory)
        Log.write("overlay hidden")
    }

    func showPasswordRejected(attemptsLeft: Int) {
        panel?.showRejected(attemptsLeft: attemptsLeft)
    }

    // MARK: Windows

    /// (Re)builds one window per connected screen and puts the panel on the main one.
    private func layoutWindows() {
        guard let panel else { return }
        windows.forEach { $0.orderOut(nil) }
        windows = NSScreen.screens.map { Self.makeWindow(for: $0) }
        let mainScreen = NSScreen.main ?? NSScreen.screens[0]
        let host = windows.first(where: { $0.screen == mainScreen }) ?? windows[0]
        let content = host.contentView!
        panel.removeFromSuperview()
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel)
        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            panel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -96),
        ])
        windows.forEach { $0.orderFrontRegardless() }
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(panel.passwordField)
    }

    private static func makeWindow(for screen: NSScreen) -> ShieldWindow {
        let window = ShieldWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.setFrame(screen.frame, display: false)
        window.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        let blur = NSVisualEffectView()
        blur.material = .fullScreenUI
        blur.blendingMode = .behindWindow
        blur.state = .active
        let tint = NSView(frame: blur.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(tintAlpha).cgColor
        blur.addSubview(tint)
        window.contentView = blur
        return window
    }

    // MARK: Guarding

    private func startGuarding() {
        let center = NotificationCenter.default
        let workspace = NSWorkspace.shared.notificationCenter
        appObservers = [
            center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclaimFocus() }
            },
            center.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.write("screens changed; rebuilding overlay")
                    self?.layoutWindows()
                }
            },
        ]
        workspaceObservers = [
            workspace.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reclaimFocus() }
            },
        ]
    }

    private func stopGuarding() {
        appObservers.forEach { NotificationCenter.default.removeObserver($0) }
        workspaceObservers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        appObservers.removeAll()
        workspaceObservers.removeAll()
    }

    /// Another app tried to take focus while locked: take it back.
    private func reclaimFocus() {
        guard let panel, let host = panel.window else { return }
        NSApp.activate(ignoringOtherApps: true)
        windows.forEach { $0.orderFrontRegardless() }
        host.makeKeyAndOrderFront(nil)
        host.makeFirstResponder(panel.passwordField)
    }
}
```

- [ ] **Step 5: Write the demo entry point**

`Sources/GlassLock/main.swift` (temporary — replaced in Task 8):
```swift
import AppKit
import GlassLockCore

// Demo: glass-lock 2 s after launch; quits on unlock or after the safety timeout.
MainActor.assumeIsolated {
    let options = LaunchOptions.parse(CommandLine.arguments)
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let overlay = GlassOverlay()
    var attemptsLeft = 5
    overlay.onUnlocked = {
        Log.write("demo: unlocked")
        overlay.hide()
        NSApp.terminate(nil)
    }
    overlay.onPasswordFailed = {
        attemptsLeft -= 1
        overlay.showPasswordRejected(attemptsLeft: attemptsLeft)
    }
    overlay.onFailure = { reason in
        Log.write("demo: OVERLAY FAILURE — \(reason)")
        overlay.hide()
        NSApp.terminate(nil)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        overlay.show(caption: LockCaption.text(for: .local, time: "demo"))
    }
    let safety = options.autoUnlockSeconds ?? 30
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(safety)) {
        Log.write("demo: safety auto-unlock after \(safety)s")
        overlay.hide()
        NSApp.terminate(nil)
    }
    app.run()
}
```

- [ ] **Step 6: Write the bundle files**

`packaging/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.harigovind.glasslock</string>
    <key>CFBundleName</key>
    <string>GlassLock</string>
    <key>CFBundleDisplayName</key>
    <string>GlassLock</string>
    <key>CFBundleExecutable</key>
    <string>GlassLock</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
```

`scripts/build-app.sh`:
```bash
#!/bin/bash
# Builds build/GlassLock.app (release, ad-hoc signed). No Xcode required.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product GlassLock
BIN="$(swift build -c release --show-bin-path)/GlassLock"
APP="build/GlassLock.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/GlassLock"
cp packaging/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built $APP"
```

Run: `chmod +x scripts/build-app.sh && ./scripts/build-app.sh 2>&1 | tail -3`
Expected: `Built build/GlassLock.app` (deprecation warnings for `activate(ignoringOtherApps:)` are acceptable).

- [ ] **Step 7: Verify risks 1, 2 and 5 with the user**

Tell the user first: "Your screen will be covered by the blur for up to 30 seconds. Try typing, Cmd+Tab and Cmd+Opt+Esc, then unlock with Touch ID." Wait for "ok".

Run (background), with Terminal frontmost:
```bash
open -n build/GlassLock.app --args --dev-lock-now --dev-auto-unlock 30
```
About 6 s later, capture the screen:
```bash
screencapture -x "$TMPDIR/glass-check.png"
```
Then read `$TMPDIR/glass-check.png` (Read tool) and inspect it.

Pass criteria — record each result:
1. **Focus/kiosk (risk 1):** `tail -5 ~/Library/Logs/GlassLock.log` has no `OVERLAY FAILURE`; keys typed by the user did not appear in Terminal; Cmd+Tab and Cmd+Opt+Esc did nothing.
2. **Blur (risk 2):** no text in the screenshot is readable. If any is (or the capture shows the desktop *without* the overlay, in which case ask the user to judge by eye), raise `GlassOverlay.tintAlpha` to `0.55`, rebuild, re-run; then `0.7`.
3. **Touch ID (risk 5):** the user's finger on the Touch ID key unlocked it and the log shows `touch id accepted`.
4. Run once more and unlock with the **password**: log shows `password accepted`. Once more: Enter on an empty field changes nothing; one wrong password shows `Wrong password`.

If (1) or (3) fails, **stop and report to the user** with the fallback from spec §10 — these change the design and need their decision.

Emergency exit if anything goes wrong: `pkill -x GlassLock`.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources/GlassLock packaging scripts/build-app.sh
git commit -m "Add frosted glass overlay with Touch ID and password unlock" -m "Verified: focus/kiosk, blur readability, embedded Touch ID (record results here)." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: AppController, KeepAwake, RealLock, menu bar — local lock end to end

**Files:**
- Create: `Sources/GlassLock/KeepAwake.swift`, `RealLock.swift`, `AppController.swift`, `MenuBarController.swift`, `AppDelegate.swift`
- Modify: `Sources/GlassLock/main.swift` (replace demo)

**Interfaces:**
- Consumes: `LockStateMachine`, `LockEvent`, `LockEffect`, `LockState`, `KeepAwakeLevel`, `AckKind` (Task 1); `LockCaption`, `LaunchOptions` (Task 3); `CrashFlag`, `AppPaths` (Task 4); `GlassOverlay`, `Log` (Task 7); decision from Task 6.
- Produces: `@MainActor final class AppController { var onAck: (AckKind, String) -> Void; var state: LockState; init(devAutoUnlockSeconds: Int?); func start(); func handle(_ event: LockEvent) }`; `@MainActor final class MenuBarController: NSObject { var onLockNow: () -> Void; init(devMode: Bool); func setStatus(_ text: String, connected: Bool) }`; `@MainActor final class AppDelegate: NSObject, NSApplicationDelegate { init(options: LaunchOptions) }`.

- [ ] **Step 1: Write KeepAwake and RealLock**

`Sources/GlassLock/KeepAwake.swift`:
```swift
import Foundation
import GlassLockCore
import IOKit.pwr_mgt

/// Holds IOKit power assertions so the Mac (and optionally the display) never idle-sleeps.
final class KeepAwake {
    private var assertions: [IOPMAssertionID] = []
    private(set) var level: KeepAwakeLevel = .off

    func set(_ level: KeepAwakeLevel) {
        guard level != self.level else { return }
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
        self.level = level
        switch level {
        case .off:
            break
        case .systemOnly:
            hold(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
        case .displayAndSystem:
            hold(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString)
            hold(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
        }
        Log.write("keep-awake: \(level)")
    }

    private func hold(_ type: CFString) {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "GlassLock is keeping your work running" as CFString, &id)
        if result == kIOReturnSuccess {
            assertions.append(id)
        } else {
            Log.write("keep-awake: assertion \(type) failed (\(result))")
        }
    }
}
```

`Sources/GlassLock/RealLock.swift` (order as decided in Task 6):
```swift
import Foundation

/// Shows the real macOS lock screen.
enum RealLock {
    private typealias LockFunction = @convention(c) () -> Int32

    @discardableResult
    static func engage() -> Bool {
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            let result = unsafeBitCast(symbol, to: LockFunction.self)()
            Log.write("real lock: SACLockScreenImmediate returned \(result)")
            if result == 0 { return true }
        }
        Log.write("real lock: falling back to pmset displaysleepnow")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Log.write("real lock: pmset failed: \(error)")
            return false
        }
    }
}
```

- [ ] **Step 2: Write AppController**

`Sources/GlassLock/AppController.swift`:
```swift
import AppKit
import GlassLockCore

/// Feeds events to the state machine and performs the effects it returns.
@MainActor
final class AppController {
    var onAck: (AckKind, String) -> Void = { _, _ in }

    private var machine = LockStateMachine()
    private let overlay = GlassOverlay()
    private let keepAwake = KeepAwake()
    private let crashFlag = CrashFlag(directory: AppPaths.supportDirectory)
    private let devAutoUnlockSeconds: Int?
    private var lockGeneration = 0

    var state: LockState { machine.state }

    init(devAutoUnlockSeconds: Int?) {
        self.devAutoUnlockSeconds = devAutoUnlockSeconds
        overlay.onUnlocked = { [weak self] in self?.handle(.authSucceeded) }
        overlay.onPasswordFailed = { [weak self] in self?.handle(.passwordFailed) }
        overlay.onFailure = { [weak self] reason in
            Log.write("overlay failure: \(reason)")
            self?.handle(.overlayFailed)
        }
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handle(.systemUnlocked) }
        }
    }

    /// Call once at launch: a leftover crash flag means we died mid-lock.
    func start() {
        if crashFlag.isSet {
            Log.write("crash flag found at launch")
            handle(.launchedWithCrashFlag)
        }
    }

    func handle(_ event: LockEvent) {
        let effects = machine.handle(event)
        Log.write("event \(event) -> \(machine.state)")
        effects.forEach(perform)
    }

    private func perform(_ effect: LockEffect) {
        switch effect {
        case .setCrashFlag(let on):
            do { try crashFlag.set(on) } catch { Log.write("crash flag write failed: \(error)") }
        case .keepAwake(let level):
            keepAwake.set(level)
        case .showOverlay(let source):
            let time = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .short)
            overlay.show(caption: LockCaption.text(for: source, time: time))
            lockGeneration += 1
            if let seconds = devAutoUnlockSeconds {
                scheduleDevAutoUnlock(after: seconds, generation: lockGeneration)
            }
        case .hideOverlay:
            if machine.state == .realLocked {
                // Give the real lock screen time to cover the display first.
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.overlay.hide() }
            } else {
                overlay.hide()
            }
        case .engageRealLock:
            if !RealLock.engage() { Log.write("REAL LOCK FAILED") }
        case .passwordRejected(let attemptsLeft):
            overlay.showPasswordRejected(attemptsLeft: attemptsLeft)
        case .ack(let kind, let commandID):
            onAck(kind, commandID)
        }
    }

    private func scheduleDevAutoUnlock(after seconds: Int, generation: Int) {
        Log.write("DEV: auto-unlock in \(seconds)s")
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
            guard let self, self.lockGeneration == generation, case .glassLocked = self.machine.state else { return }
            Log.write("DEV: auto-unlocking")
            self.handle(.authSucceeded)
        }
    }
}
```

- [ ] **Step 3: Write MenuBarController**

`Sources/GlassLock/MenuBarController.swift`:
```swift
import AppKit
import GlassLockCore

@MainActor
final class MenuBarController: NSObject {
    var onLockNow: () -> Void = {}

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let menu = NSMenu()

    init(devMode: Bool) {
        super.init()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        if devMode {
            let dev = NSMenuItem(title: "Developer mode (auto-unlock on)", action: nil, keyEquivalent: "")
            dev.isEnabled = false
            menu.addItem(dev)
        }
        menu.addItem(.separator())
        menu.addItem(makeItem("Glass Lock Now", #selector(lockNow)))
        menu.addItem(makeItem("Open Log", #selector(openLog)))
        menu.addItem(.separator())
        menu.addItem(makeItem("Quit GlassLock", #selector(quit)))
        item.menu = menu
        setStatus("Starting…", connected: false)
    }

    func setStatus(_ text: String, connected: Bool) {
        statusLine.title = text
        item.button?.image = NSImage(
            systemSymbolName: connected ? "lock.fill" : "lock.slash",
            accessibilityDescription: "GlassLock")
    }

    /// Inserts an item just above "Open Log". Used by later features.
    func insertItem(_ title: String, action: Selector, target: AnyObject) {
        let newItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        newItem.target = target
        let index = menu.indexOfItem(withTitle: "Open Log")
        menu.insertItem(newItem, at: index)
    }

    private func makeItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: "")
        menuItem.target = self
        return menuItem
    }

    @objc private func lockNow() { onLockNow() }

    @objc private func openLog() {
        NSWorkspace.shared.open(AppPaths.logFile)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
```

- [ ] **Step 4: Write AppDelegate and replace main.swift**

`Sources/GlassLock/AppDelegate.swift`:
```swift
import AppKit
import GlassLockCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options: LaunchOptions
    private let controller: AppController
    private var menu: MenuBarController!

    init(options: LaunchOptions) {
        self.options = options
        self.controller = AppController(devAutoUnlockSeconds: options.autoUnlockSeconds)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.write("launched\(options.isDevMode ? " (developer mode)" : "")")
        menu = MenuBarController(devMode: options.isDevMode)
        menu.onLockNow = { [weak self] in self?.controller.handle(.lockRequested(.local)) }
        menu.setStatus("Relay not connected", connected: false)
        controller.start()
        if options.lockOnLaunch {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.controller.handle(.lockRequested(.local))
            }
        }
    }

    /// Refuse to quit (logout, AppleScript, …) while the glass lock is up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .glassLocked = controller.state {
            Log.write("quit refused while glass-locked")
            return .terminateCancel
        }
        return .terminateNow
    }
}
```

Replace `Sources/GlassLock/main.swift` with:
```swift
import AppKit
import GlassLockCore

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate(options: LaunchOptions.parse(CommandLine.arguments))
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
```

- [ ] **Step 5: Build**

Run: `swift test 2>&1 | tail -1 && ./scripts/build-app.sh 2>&1 | tail -1`
Expected: tests pass; `Built build/GlassLock.app`.

- [ ] **Step 6: Verify with the user** (tell them first; each run auto-unlocks after 30 s)

Launch: `open -n build/GlassLock.app --args --dev-auto-unlock 30`

1. Menu bar shows the `lock.slash` icon with "Relay not connected". Click **Glass Lock Now** → overlay appears with "Locked from this Mac · <time>".
2. While locked: `pmset -g assertions | grep -i glasslock` shows both `PreventUserIdleDisplaySleep` and `PreventUserIdleSystemSleep`; `ls "$HOME/Library/Application Support/GlassLock/glass-locked"` exists.
3. Unlock with Touch ID → assertions gone, crash flag gone.
4. Lock again; enter 5 wrong passwords → after the 2nd: "Wrong password — 3 attempts left"; after the 5th the **real** lock screen appears, then the overlay disappears behind it. Unlock normally; log shows `systemUnlocked -> unlocked`, and `pmset -g assertions | grep -i glasslock` is empty.
5. Lock again, then from a shell: `pkill -9 -x GlassLock`. Relaunch `open -n build/GlassLock.app` → the real lock screen appears immediately (crash flag). Unlock.
6. Quit from the menu → app exits.

- [ ] **Step 7: Commit**

```bash
git add Sources/GlassLock
git commit -m "Wire state machine to overlay, keep-awake, real lock and menu bar" -m "RealLock: <Task 6 decision>." -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: RelayClient — lock from anywhere, acks, reconnect on wake

**Files:**
- Create: `Sources/GlassLock/RelayClient.swift`
- Modify: `Sources/GlassLock/AppDelegate.swift`

**Interfaces:**
- Consumes: `RelayMessageFilter`, `RelayDecision` (Task 2); `Backoff` (Task 3); `TopicStore`, `AppPaths` (Task 4); `AckKind` (Task 1); `AppController.onAck`, `AppController.handle(_:)`, `MenuBarController.setStatus(_:connected:)` (Task 8).
- Produces: `@MainActor final class RelayClient { enum Status: Equatable { connecting, connected, waiting(seconds: Int) }; var onStatus: (Status) -> Void; var onLock: (String) -> Void; init(topic: String, base: URL); func start(); func stop(); func change(topic: String); func sendAck(_ kind: AckKind, commandID: String) }`; `AppDelegate.topicStore`, `AppDelegate.relay` (used in Task 10).

- [ ] **Step 1: Write RelayClient**

`Sources/GlassLock/RelayClient.swift`:
```swift
import AppKit
import GlassLockCore

/// Streams the ntfy topic, turns `lock` messages into callbacks, and publishes acks.
@MainActor
final class RelayClient {
    enum Status: Equatable {
        case connecting
        case connected
        case waiting(seconds: Int)
    }

    var onStatus: (Status) -> Void = { _ in }
    var onLock: (String) -> Void = { _ in }

    private let base: URL
    private var topic: String
    private let session: URLSession
    /// One filter for the app's lifetime: dedupe and resume point survive reconnects.
    private var filter = RelayMessageFilter()
    private var loop: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(topic: String, base: URL = URL(string: "https://ntfy.sh")!) {
        self.topic = topic
        self.base = base
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 90 // ntfy sends a keepalive every ~45 s
        config.timeoutIntervalForResource = 60 * 60 * 24 * 365
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func start() {
        restartLoop()
        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    Log.write("relay: woke from sleep, reconnecting")
                    self?.restartLoop()
                }
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
    }

    func change(topic: String) {
        self.topic = topic
        filter = RelayMessageFilter()
        restartLoop()
    }

    func sendAck(_ kind: AckKind, commandID: String) {
        var request = URLRequest(url: base.appendingPathComponent("\(topic)-ack"))
        request.httpMethod = "POST"
        request.httpBody = Data("\(kind.rawValue):\(commandID)".utf8)
        let session = self.session
        Task {
            for attempt in 1...2 {
                do {
                    let (_, response) = try await session.data(for: request)
                    if (response as? HTTPURLResponse)?.statusCode == 200 {
                        Log.write("relay: ack \(kind.rawValue) \(commandID)")
                        return
                    }
                } catch {
                    Log.write("relay: ack attempt \(attempt) failed: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func restartLoop() {
        loop?.cancel()
        loop = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        var backoff = Backoff()
        while !Task.isCancelled {
            onStatus(.connecting)
            do {
                let (bytes, response) = try await session.bytes(for: streamRequest())
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw URLError(.badServerResponse)
                }
                onStatus(.connected)
                Log.write("relay: connected")
                backoff.reset()
                for try await line in bytes.lines {
                    switch filter.decide(line: line, now: Date()) {
                    case .lock(let id):
                        Log.write("relay: lock \(id)")
                        onLock(id)
                    case .ignore(let reason):
                        if !reason.hasPrefix("event:") {
                            Log.write("relay: ignored (\(reason))")
                        }
                    }
                }
                Log.write("relay: stream ended")
            } catch {
                if Task.isCancelled { return }
                Log.write("relay: \(error.localizedDescription)")
            }
            if Task.isCancelled { return }
            let delay = backoff.nextDelay()
            onStatus(.waiting(seconds: Int(delay)))
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
    }

    private func streamRequest() -> URLRequest {
        var components = URLComponents(url: base.appendingPathComponent("\(topic)/json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "since", value: filter.resumeToken)]
        return URLRequest(url: components.url!)
    }
}
```

- [ ] **Step 2: Wire the relay into AppDelegate**

In `Sources/GlassLock/AppDelegate.swift`, add these properties under `private var menu: MenuBarController!`:
```swift
    let topicStore = TopicStore(directory: AppPaths.supportDirectory)
    var relay: RelayClient?
```

Replace the line `menu.setStatus("Relay not connected", connected: false)` with `startRelay()`, and add these methods to the class:
```swift
    private func startRelay() {
        let topic: String
        do {
            topic = try topicStore.loadOrCreate()
        } catch {
            Log.write("could not load or create topic: \(error)")
            menu.setStatus("Setup error — see log", connected: false)
            return
        }
        let relay = RelayClient(topic: topic)
        relay.onStatus = { [weak self] status in
            let (text, connected) = Self.describe(status)
            self?.menu.setStatus(text, connected: connected)
        }
        relay.onLock = { [weak self] id in
            self?.controller.handle(.lockRequested(.remote(commandID: id)))
        }
        controller.onAck = { [weak relay] kind, id in
            relay?.sendAck(kind, commandID: id)
        }
        relay.start()
        self.relay = relay
    }

    private static func describe(_ status: RelayClient.Status) -> (String, Bool) {
        switch status {
        case .connecting: return ("Connecting to relay…", false)
        case .connected: return ("Ready — lock from your iPhone", true)
        case .waiting(let seconds): return ("Offline — retrying in \(seconds)s", false)
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift test 2>&1 | tail -1 && ./scripts/build-app.sh 2>&1 | tail -1`
Expected: tests pass; `Built build/GlassLock.app`.

- [ ] **Step 4: Verify remote lock and ack** (tell the user first; auto-unlock 30 s)

```bash
open -n build/GlassLock.app --args --dev-auto-unlock 30
TOPIC=$(cat "$HOME/Library/Application Support/GlassLock/topic")
curl -s -d lock "https://ntfy.sh/$TOPIC"          # prints JSON with "id"
```
Expected: menu bar icon is `lock.fill` with "Ready — lock from your iPhone" before the curl; the overlay appears within ~1 s with "Locked from iPhone · <time>". Then:
```bash
curl -s "https://ntfy.sh/$TOPIC-ack/raw?poll=1&since=1m"
```
Expected: `locked:<the id from the publish>`. Send `lock` again while locked → a second line `already-locked:<new id>`.

- [ ] **Step 5: Verify staleness and resilience**

1. Wait for auto-unlock. Quit and relaunch the app → it must **not** re-lock (the earlier `lock` is before launch time).
2. Turn Wi-Fi off for ~20 s → menu shows "Offline — retrying in …"; publish `lock` while offline; turn Wi-Fi on → Mac locks within the backoff delay and the ack arrives.
3. `grep -c "$TOPIC" ~/Library/Logs/GlassLock.log` → `0` (topic never logged).

- [ ] **Step 6: Commit**

```bash
git add Sources/GlassLock/RelayClient.swift Sources/GlassLock/AppDelegate.swift
git commit -m "Add ntfy relay client with acks, backoff and wake reconnect" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Install the iPhone Shortcut and reset the secret from the menu

**Files:**
- Create: `Sources/GlassLock/ShortcutInstaller.swift`
- Modify: `Sources/GlassLock/AppDelegate.swift`

**Interfaces:**
- Consumes: `ShortcutBuilder.data(topic:)`, `ShortcutBuilder.manualInstructions(topic:)` (Task 5); `AppPaths` (Task 4); `AppDelegate.topicStore`, `AppDelegate.relay`, `RelayClient.change(topic:)` (Task 9); `MenuBarController.insertItem(_:action:target:)` (Task 8).
- Produces: `enum ShortcutInstaller { static func install(topic: String) throws -> URL }`; menu items "Install iPhone Shortcut…" and "Reset Secret…".

- [ ] **Step 1: Write ShortcutInstaller**

`Sources/GlassLock/ShortcutInstaller.swift`:
```swift
import AppKit
import GlassLockCore

/// Builds "Lock Mac.shortcut" for the topic, signs it with /usr/bin/shortcuts and opens it to import.
enum ShortcutInstaller {
    enum InstallError: Error {
        case signingFailed(String)
    }

    @discardableResult
    static func install(topic: String) throws -> URL {
        let directory = AppPaths.supportDirectory
        let unsigned = directory.appendingPathComponent("unsigned.shortcut")
        let signed = directory.appendingPathComponent("Lock Mac.shortcut")
        try ShortcutBuilder.data(topic: topic).write(to: unsigned, options: .atomic)
        try? FileManager.default.removeItem(at: signed)
        defer { try? FileManager.default.removeItem(at: unsigned) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["sign", "--mode", "anyone", "--input", unsigned.path, "--output", signed.path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: signed.path) else {
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError.signingFailed(text)
        }
        NSWorkspace.shared.open(signed)
        return signed
    }
}
```

- [ ] **Step 2: Add the menu items and handlers to AppDelegate**

In `applicationDidFinishLaunching`, after `menu.onLockNow = …`, add:
```swift
        menu.insertItem("Install iPhone Shortcut…", action: #selector(installShortcut), target: self)
        menu.insertItem("Reset Secret…", action: #selector(resetSecret), target: self)
```

Add these methods to `AppDelegate`:
```swift
    @objc private func installShortcut() {
        guard let topic = try? topicStore.loadOrCreate() else { return }
        NSApp.activate(ignoringOtherApps: true)
        do {
            let file = try ShortcutInstaller.install(topic: topic)
            Log.write("shortcut signed and opened")
            let alert = NSAlert()
            alert.messageText = "Add the “Lock Mac” Shortcut"
            alert.informativeText = """
                Shortcuts is opening — click “Add Shortcut”. It syncs to your iPhone through iCloud \
                (iPhone Settings › Apps › Shortcuts › iCloud Sync). You can also AirDrop the file to your iPhone.
                """
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Show File for AirDrop")
            if alert.runModal() == .alertSecondButtonReturn {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            }
        } catch {
            Log.write("shortcut install failed: \(error)")
            showManualInstructions(topic: topic)
        }
    }

    private func showManualInstructions(topic: String) {
        let alert = NSAlert()
        alert.messageText = "Set up the Shortcut by hand"
        alert.informativeText = ShortcutBuilder.manualInstructions(topic: topic)
        alert.addButton(withTitle: "Copy Instructions")
        alert.addButton(withTitle: "Close")
        if alert.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(alert.informativeText, forType: .string)
        }
    }

    @objc private func resetSecret() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Reset the secret?"
        alert.informativeText = "Your current iPhone Shortcut will stop working. You'll install a new one next."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            let topic = try topicStore.reset()
            relay?.change(topic: topic)
            Log.write("secret reset")
            installShortcut()
        } catch {
            Log.write("secret reset failed: \(error)")
        }
    }
```

- [ ] **Step 3: Build**

Run: `swift test 2>&1 | tail -1 && ./scripts/build-app.sh 2>&1 | tail -1`
Expected: tests pass; `Built build/GlassLock.app`.

- [ ] **Step 4: Verify the Shortcut end to end with the user**

1. Launch `open -n build/GlassLock.app --args --dev-auto-unlock 30`; menu → **Install iPhone Shortcut…** → Shortcuts opens with "Lock Mac". User clicks **Add Shortcut**.
2. In Shortcuts on the Mac, open "Lock Mac" and check: step 2 reads from step 1's "Contents of URL"; the If tests step 4's output for "locked:" + "Dictionary Value". If wiring is wrong, fix `ShortcutBuilder` (and its tests), or fall back to the manual instructions alert — tell the user which.
3. On the **iPhone, Wi-Fi off, mobile data on**: run "Lock Mac" (allow the ntfy.sh connection when asked) → Mac glass-locks; phone shows **"✅ Mac locked"**.
4. **Reset Secret…** → confirm → a new Shortcut installs; the old Shortcut on the phone now shows "⚠️ No reply…"; delete the old one.

- [ ] **Step 5: Commit**

```bash
git add Sources/GlassLock/ShortcutInstaller.swift Sources/GlassLock/AppDelegate.swift
git commit -m "Install signed Lock Mac Shortcut and reset secret from menu" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Install at login, crash relaunch, README and the full manual checklist

**Files:**
- Create: `scripts/install.sh`, `docs/manual-test-checklist.md`, `README.md`

**Interfaces:**
- Consumes: `scripts/build-app.sh` (Task 7); the whole app.
- Produces: `/Applications/GlassLock.app`, `~/Library/LaunchAgents/com.harigovind.glasslock.plist`.

- [ ] **Step 1: Write the install script**

`scripts/install.sh`:
```bash
#!/bin/bash
# Builds GlassLock, installs it to /Applications and starts it at login.
# launchd relaunches it after a crash (but not after "Quit GlassLock").
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build-app.sh

LABEL="com.harigovind.glasslock"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
pkill -x GlassLock 2>/dev/null || true

rm -rf /Applications/GlassLock.app
cp -R build/GlassLock.app /Applications/

mkdir -p "$HOME/Library/LaunchAgents"
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/Applications/GlassLock.app/Contents/MacOS/GlassLock</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ThrottleInterval</key>
    <integer>1</integer>
    <key>ProcessType</key>
    <string>Interactive</string>
</dict>
</plist>
EOF

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "GlassLock installed and running. Look for the lock icon in the menu bar."
```

Run: `chmod +x scripts/install.sh && ./scripts/install.sh 2>&1 | tail -2`
Expected: `GlassLock installed and running.`; `launchctl print gui/$(id -u)/com.harigovind.glasslock | grep state` → `state = running`.

- [ ] **Step 2: Write the manual checklist**

`docs/manual-test-checklist.md`:
```markdown
# GlassLock manual test checklist

Run on the installed app (`./scripts/install.sh`). Mark each ✅ / ❌ with notes.

| # | Check | How | Expected |
|---|---|---|---|
| 1 | Work keeps running | `while true; do date +%s >> ~/t.log; sleep 1; done` in Terminal; lock from iPhone; wait 10 min; unlock; `awk 'NR>1 && $1-p>2 {print "GAP",p,$1} {p=$1}' ~/t.log` | No GAP lines |
| 2 | Content unreadable | Large terminal text on screen; lock; photo or screenshot | No text readable |
| 3 | Escapes blocked | Cmd+Tab, Cmd+Opt+Esc, Cmd+Q, Cmd+Space, Mission Control swipe, hot corners, menu bar, Notification Center | Nothing reachable; typing never reaches apps |
| 4 | Touch ID unlocks | Finger on Touch ID key | Unlocks |
| 5 | Password unlocks | Type login password, Enter | Unlocks |
| 6 | Empty Enter | Press Enter with empty field | No attempt used, no message change |
| 7 | 5 wrong passwords | Type wrong password 5× | "3 attempts left" after 2nd; real lock screen after 5th |
| 8 | Crash while locked | Lock, then from another Mac/SSH or before locking schedule `sleep 20; pkill -9 -x GlassLock` | Real lock screen within ~2 s |
| 9 | iPhone on mobile data | Wi-Fi off on phone, run "Lock Mac" | Mac locks; "✅ Mac locked" |
| 10 | Lid closed | Close lid, run "Lock Mac" | "⚠️ No reply — Mac may be asleep, lid closed, or offline" |
| 11 | Wake reconnect | Open lid; within 10 s run "Lock Mac" | Locks; log shows "woke from sleep, reconnecting" |
| 12 | External display | Plug a display in while locked (if available) | New screen is blurred too |
| 13 | Already locked | Run "Lock Mac" twice | Second also shows "✅ Mac locked"; log shows already-locked ack |
| 14 | Quit stays quit | Menu → Quit GlassLock; wait 10 s | App does not come back until next login |
| 15 | Topic never logged | `grep -c "$(cat ~/Library/Application\ Support/GlassLock/topic)" ~/Library/Logs/GlassLock.log` | 0 |
```

- [ ] **Step 3: Write the README**

`README.md`:
```markdown
# GlassLock

Lock your Mac from your iPhone — from anywhere — without stopping anything that is
running. The screen becomes frosted glass: you can see it is alive, but nothing is
readable and no keys or clicks get through. Only Touch ID or your Mac password
(at the Mac) unlocks it.

## Install

    ./scripts/install.sh

Builds the app (Command Line Tools are enough — no Xcode), copies it to
`/Applications`, and starts it at every login. A lock icon appears in the menu bar.

## Set up your iPhone

Menu bar → **Install iPhone Shortcut…** → click **Add Shortcut**. It syncs to your
iPhone through iCloud (or AirDrop the file). Put it on your home screen, the
Action Button, Back Tap, or ask Siri "Lock Mac".

## Using it

- Run **Lock Mac** on your phone → the Mac glass-locks, the phone shows ✅.
- Unlock at the Mac with **Touch ID** or your **login password**.
- 5 wrong passwords → the real macOS lock screen takes over.
- **Keep the lid open.** Closing it sleeps the Mac and pauses your work.
- Menu bar → **Glass Lock Now** locks from the Mac itself.

## Security

The relay is ntfy.sh. Your secret channel name (in
`~/Library/Application Support/GlassLock/topic`) is the only secret. Anyone who
learns it can *lock* your Mac — never unlock it or see anything. If you think it
leaked: menu bar → **Reset Secret…**.

## Troubleshooting

- Log: menu bar → **Open Log** (`~/Library/Logs/GlassLock.log`).
- Phone says "No reply": the Mac is asleep, the lid is closed, or it is offline.
- Developer flags: `--dev-lock-now` (lock 2 s after launch) and
  `--dev-auto-unlock <seconds>` (unlock itself; safety net while developing).

## Uninstall

    launchctl bootout gui/$(id -u)/com.harigovind.glasslock
    rm ~/Library/LaunchAgents/com.harigovind.glasslock.plist
    rm -rf /Applications/GlassLock.app ~/Library/Application\ Support/GlassLock
```

- [ ] **Step 4: Verify crash relaunch under launchd**

Tell the user, then: Glass Lock Now from the menu (installed app — **no** dev auto-unlock, so the user unlocks it), then from the shell `pkill -9 -x GlassLock`.
Expected: launchd relaunches within ~1–2 s, the real lock screen appears, log shows `crash flag found at launch`. User unlocks with Touch ID.

- [ ] **Step 5: Run the full checklist with the user**, recording ✅/❌ in `docs/manual-test-checklist.md`. Any ❌ → fix in the owning task's file, rebuild with `./scripts/install.sh`, re-check.

- [ ] **Step 6: Commit**

```bash
git add scripts/install.sh docs/manual-test-checklist.md README.md
git commit -m "Add login install, README and manual test checklist" -m "Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```
