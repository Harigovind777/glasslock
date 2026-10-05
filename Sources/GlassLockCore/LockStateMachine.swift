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
