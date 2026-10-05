/// The ntfy topic name is the only secret: `glasslock-` + 32 base62 characters (~190 bits).
public enum Secret {
    public static let prefix = "glasslock-"
    public static let randomLength = 32
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    /// Uses the system CSPRNG.
    public static func makeTopic() -> String {
        var generator = SystemRandomNumberGenerator()
        let suffix = (0..<randomLength).map { _ in alphabet.randomElement(using: &generator)! }
        return prefix + String(suffix)
    }

    public static func isValidTopic(_ topic: String) -> Bool {
        guard topic.hasPrefix(prefix) else { return false }
        let suffix = topic.dropFirst(prefix.count)
        return suffix.count == randomLength && suffix.allSatisfy { alphabet.contains($0) }
    }
}
