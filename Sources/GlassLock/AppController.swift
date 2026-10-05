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
            overlay.hide()
        case .engageRealLock:
            // Stop guarding focus and Touch ID so the real lock screen gets the keyboard and the finger.
            overlay.suspendForRealLock()
            if !RealLock.engage() { Log.write("real lock: request failed") }
        case .verifyRealLock:
            pollRealLock(until: Date().addingTimeInterval(3))
        case .passwordRejected(let attemptsLeft):
            overlay.showPasswordRejected(attemptsLeft: attemptsLeft)
        case .ack(let kind, let commandID):
            onAck(kind, commandID)
        }
    }

    /// Reports realLockConfirmed as soon as the system lock screen is up, or
    /// realLockFailed if it never comes up — then the glass lock stays on.
    private func pollRealLock(until deadline: Date) {
        if RealLock.isScreenLocked() {
            Log.write("real lock: confirmed")
            handle(.realLockConfirmed)
        } else if Date() >= deadline {
            Log.write("real lock: NOT confirmed — keeping the glass lock")
            handle(.realLockFailed)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.pollRealLock(until: deadline)
            }
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
