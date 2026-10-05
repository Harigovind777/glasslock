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
