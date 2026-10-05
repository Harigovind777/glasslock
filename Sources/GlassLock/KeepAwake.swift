import Foundation
import GlassLockCore
import IOKit.pwr_mgt

/// Holds IOKit power assertions so the Mac (and optionally the display) never idle-sleeps.
final class KeepAwake {
    private var assertions: [IOPMAssertionID] = []
    private(set) var level: KeepAwakeLevel = .off

    func set(_ level: KeepAwakeLevel) {
        guard level != self.level else { return }
        assertions.forEach { IOPMAssertionRelease($0) }
        assertions.removeAll()
        self.level = level
        switch level {
        case .off:
            break
        case .systemOnly:
            hold(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
        case .displayAndSystem:
            hold(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString)
            hold(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString)
        }
        Log.write("keep-awake: \(level)")
    }

    private func hold(_ type: CFString) {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type, IOPMAssertionLevel(kIOPMAssertionLevelOn), "GlassLock is keeping your work running" as CFString, &id)
        if result == kIOReturnSuccess {
            assertions.append(id)
        } else {
            Log.write("keep-awake: assertion \(type) failed (\(result))")
        }
    }
}
