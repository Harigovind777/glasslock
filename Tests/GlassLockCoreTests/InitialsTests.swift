import Testing
@testable import GlassLockCore

@Suite struct InitialsTests {
    @Test func firstLettersOfFirstTwoWords() {
        #expect(Initials.from("Hari Govind") == "HG")
        #expect(Initials.from("ada lovelace byron") == "AL")
    }

    @Test func singleWordGivesOneLetter() {
        #expect(Initials.from("harigovind") == "H")
    }

    @Test func extraWhitespaceIsIgnored() {
        #expect(Initials.from("  a   b ") == "AB")
    }

    @Test func emptyNameGivesPlaceholder() {
        #expect(Initials.from("") == "?")
        #expect(Initials.from("   ") == "?")
    }
}
