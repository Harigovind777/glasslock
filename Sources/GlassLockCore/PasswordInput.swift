public enum PasswordInput {
    /// Pressing Enter on an empty field must not use up an attempt.
    public static func isSubmittable(_ password: String) -> Bool {
        !password.isEmpty
    }

    public static func rejectionMessage(attemptsLeft: Int) -> String {
        guard attemptsLeft <= 3 else { return "Wrong password" }
        return "Wrong password — \(attemptsLeft) \(attemptsLeft == 1 ? "attempt" : "attempts") left"
    }
}
