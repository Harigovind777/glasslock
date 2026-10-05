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
