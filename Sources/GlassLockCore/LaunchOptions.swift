/// Developer-only flags. The LaunchAgent never passes any of them.
public struct LaunchOptions: Equatable, Sendable {
    /// Every glass lock unlocks itself after this many seconds (safety net while developing).
    public var autoUnlockSeconds: Int?
    /// Glass-lock 2 seconds after launch.
    public var lockOnLaunch: Bool
    /// Render the lock screen to this PNG path and quit (for checking the layout).
    public var snapshotPath: String?

    public init(autoUnlockSeconds: Int? = nil, lockOnLaunch: Bool = false, snapshotPath: String? = nil) {
        self.autoUnlockSeconds = autoUnlockSeconds
        self.lockOnLaunch = lockOnLaunch
        self.snapshotPath = snapshotPath
    }

    public var isDevMode: Bool {
        autoUnlockSeconds != nil || lockOnLaunch || snapshotPath != nil
    }

    public static func parse(_ arguments: [String]) -> LaunchOptions {
        var options = LaunchOptions()
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--dev-auto-unlock":
                if index + 1 < arguments.count, let seconds = Int(arguments[index + 1]), seconds > 0 {
                    options.autoUnlockSeconds = seconds
                    index += 1
                }
            case "--dev-snapshot":
                if index + 1 < arguments.count {
                    options.snapshotPath = arguments[index + 1]
                    index += 1
                }
            case "--dev-lock-now":
                options.lockOnLaunch = true
            default:
                break
            }
            index += 1
        }
        if options.lockOnLaunch && options.autoUnlockSeconds == nil {
            options.autoUnlockSeconds = 30
        }
        return options
    }
}
