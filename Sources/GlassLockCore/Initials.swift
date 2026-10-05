/// Avatar fallback when the account has no picture: "Hari Govind" → "HG".
public enum Initials {
    public static func from(_ name: String) -> String {
        let letters = name
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
            .compactMap { $0.first.map { String($0).uppercased() } }
            .joined()
        return letters.isEmpty ? "?" : letters
    }
}
