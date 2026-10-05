import Foundation

/// Shows the real macOS lock screen. SACLockScreenImmediate verified on macOS 27;
/// `pmset displaysleepnow` only locks if "require password" is set to immediately.
enum RealLock {
    private typealias LockFunction = @convention(c) () -> Int32

    @discardableResult
    static func engage() -> Bool {
        if let handle = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
           let symbol = dlsym(handle, "SACLockScreenImmediate") {
            let result = unsafeBitCast(symbol, to: LockFunction.self)()
            Log.write("real lock: SACLockScreenImmediate returned \(result)")
            if result == 0 { return true }
        }
        Log.write("real lock: falling back to pmset displaysleepnow")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["displaysleepnow"]
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            Log.write("real lock: pmset failed: \(error)")
            return false
        }
    }
}
