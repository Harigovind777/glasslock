public enum FocusAction: Equatable, Sendable {
    case none
    case reclaim
    case giveUp
}

/// Checked on a timer while glass-locked: if the lock screen loses keyboard focus
/// (e.g. to Spotlight or another floating panel), take it back; if that keeps
/// failing, give up so the caller can fall back to the real macOS lock.
public struct FocusWatchdog: Sendable {
    public static let maxReclaimAttempts = 4
    private var misses = 0

    public init() {}

    public mutating func tick(hasFocus: Bool) -> FocusAction {
        guard !hasFocus else {
            misses = 0
            return .none
        }
        misses += 1
        return misses > Self.maxReclaimAttempts ? .giveUp : .reclaim
    }
}
