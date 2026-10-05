import Testing
@testable import GlassLockCore

@Suite struct FocusWatchdogTests {
    @Test func focusedNeedsNothing() {
        var watchdog = FocusWatchdog()
        #expect(watchdog.tick(hasFocus: true) == .none)
    }

    @Test func lostFocusIsReclaimedThenGivenUpAfterFourTries() {
        var watchdog = FocusWatchdog()
        let actions = (0..<5).map { _ in watchdog.tick(hasFocus: false) }
        #expect(actions == [.reclaim, .reclaim, .reclaim, .reclaim, .giveUp])
    }

    @Test func regainingFocusResetsTheCount() {
        var watchdog = FocusWatchdog()
        _ = watchdog.tick(hasFocus: false)
        _ = watchdog.tick(hasFocus: false)
        _ = watchdog.tick(hasFocus: true)
        let actions = (0..<4).map { _ in watchdog.tick(hasFocus: false) }
        #expect(actions == [.reclaim, .reclaim, .reclaim, .reclaim])
    }
}
