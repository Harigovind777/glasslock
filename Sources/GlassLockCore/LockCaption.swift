public enum LockCaption {
    public static func text(for source: LockSource, time: String) -> String {
        switch source {
        case .remote: return "Locked from iPhone · \(time)"
        case .local: return "Locked from this Mac · \(time)"
        }
    }
}
