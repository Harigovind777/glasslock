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
