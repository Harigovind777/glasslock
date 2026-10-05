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
