import Foundation
import OpenDirectory

/// Checks the current user's login password against the local directory.
/// Slow by design (the system may add delays) — call off the main thread.
enum PasswordVerifier {
    static func verify(_ password: String) -> Bool {
        do {
            let node = try ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes))
            let record = try node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
            try record.verifyPassword(password)
            return true
        } catch {
            return false
        }
    }
}
