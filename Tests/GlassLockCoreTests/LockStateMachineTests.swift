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

    @Test func remoteLockWhileRealLockedAcksAndRechecksTheRealLock() {
        var machine = LockStateMachine(state: .realLocked)
        #expect(machine.handle(.lockRequested(.remote(commandID: "y"))) == [.ack(.alreadyLocked, commandID: "y"), .verifyRealLock])
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

    @Test func fifthWrongPasswordEscalatesButKeepsOverlayUntilRealLockIsConfirmed() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 4))
        let effects = machine.handle(.passwordFailed)
        #expect(machine.state == .realLocked)
        #expect(effects == [.engageRealLock, .verifyRealLock])
    }

    @Test func overlayFailureEscalatesButKeepsOverlayUntilRealLockIsConfirmed() {
        var machine = LockStateMachine(state: .glassLocked(failedAttempts: 0))
        let effects = machine.handle(.overlayFailed)
        #expect(machine.state == .realLocked)
        #expect(effects == [.engageRealLock, .verifyRealLock])
    }

    @Test func confirmedRealLockRemovesOverlayAndClearsCrashFlag() {
        var machine = LockStateMachine(state: .realLocked)
        #expect(machine.handle(.realLockConfirmed) == [.hideOverlay, .keepAwake(.systemOnly), .setCrashFlag(false)])
        #expect(machine.state == .realLocked)
    }

    @Test func failedRealLockFallsBackToGlassLock() {
        var machine = LockStateMachine(state: .realLocked)
        let effects = machine.handle(.realLockFailed)
        #expect(machine.state == .glassLocked(failedAttempts: LockStateMachine.maxPasswordAttempts - 1))
        #expect(effects == [.setCrashFlag(true), .keepAwake(.displayAndSystem), .showOverlay(.local)])
    }

    @Test func wrongPasswordAfterFailedRealLockTriesRealLockAgain() {
        var machine = LockStateMachine(state: .realLocked)
        _ = machine.handle(.realLockFailed)
        #expect(machine.handle(.passwordFailed) == [.engageRealLock, .verifyRealLock])
        #expect(machine.state == .realLocked)
    }

    @Test func crashFlagOnLaunchEngagesAndVerifiesRealLock() {
        var machine = LockStateMachine()
        let effects = machine.handle(.launchedWithCrashFlag)
        #expect(machine.state == .realLocked)
        #expect(effects == [.engageRealLock, .verifyRealLock, .keepAwake(.systemOnly)])
    }

    @Test func systemUnlockAfterRealLockRemovesOverlayAndReturnsToUnlocked() {
        var machine = LockStateMachine(state: .realLocked)
        #expect(machine.handle(.systemUnlocked) == [.hideOverlay, .keepAwake(.off), .setCrashFlag(false)])
        #expect(machine.state == .unlocked)
    }

    @Test func lateRealLockResultCannotTouchANewerGlassLock() {
        var machine = LockStateMachine(state: .realLocked)
        _ = machine.handle(.systemUnlocked)
        _ = machine.handle(.lockRequested(.remote(commandID: "new")))
        #expect(machine.handle(.realLockConfirmed) == [])
        #expect(machine.handle(.realLockFailed) == [])
        #expect(machine.state == .glassLocked(failedAttempts: 0))
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
