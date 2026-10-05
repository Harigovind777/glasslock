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
    /// The system reports the real lock screen is up.
    case realLockConfirmed
    /// The real lock was asked for but the screen never locked.
    case realLockFailed
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
    /// Check that the real lock screen actually came up; report realLockConfirmed / realLockFailed.
    case verifyRealLock
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

        case (.glassLocked, .lockRequested(let source)):
            if case .remote(let id) = source {
                return [.ack(.alreadyLocked, commandID: id)]
            }
            return []

        case (.realLocked, .lockRequested(let source)):
            // Re-check: if the real lock is somehow not up, verification falls back to the glass lock.
            if case .remote(let id) = source {
                return [.ack(.alreadyLocked, commandID: id), .verifyRealLock]
            }
            return [.verifyRealLock]

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
            // The crash flag stays set until the real lock is confirmed.
            state = .realLocked
            return [.engageRealLock, .verifyRealLock, .keepAwake(.systemOnly)]

        case (.realLocked, .realLockConfirmed):
            return [.hideOverlay, .keepAwake(.systemOnly), .setCrashFlag(false)]

        case (.realLocked, .realLockFailed):
            // Never leave the Mac open: back to the glass lock, one wrong password from retrying.
            state = .glassLocked(failedAttempts: Self.maxPasswordAttempts - 1)
            return [.setCrashFlag(true), .keepAwake(.displayAndSystem), .showOverlay(.local)]

        case (.realLocked, .systemUnlocked):
            state = .unlocked
            return [.hideOverlay, .keepAwake(.off), .setCrashFlag(false)]

        default:
            return []
        }
    }

    /// Hand over to the real macOS lock screen. The overlay, keep-awake and crash flag
    /// stay as they are until the real lock is confirmed, so the screen is never left open.
    private mutating func escalate() -> [LockEffect] {
        state = .realLocked
        return [.engageRealLock, .verifyRealLock]
    }
}
