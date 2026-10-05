import AppKit
import OpenDirectory

/// The logged-in user's name and account picture, for the lock screen.
enum UserAccount {
    static var displayName: String {
        let fullName = NSFullUserName()
        return fullName.isEmpty ? NSUserName() : fullName
    }

    /// The account picture from the local directory, if one is set.
    static func picture() -> NSImage? {
        guard let node = try? ODNode(session: ODSession.default(), type: ODNodeType(kODNodeTypeLocalNodes)),
              let record = try? node.record(withRecordType: kODRecordTypeUsers, name: NSUserName(), attributes: nil)
        else { return nil }
        if let data = (try? record.values(forAttribute: kODAttributeTypeJPEGPhoto))?.first as? Data,
           let image = NSImage(data: data) {
            return image
        }
        if let path = (try? record.values(forAttribute: kODAttributeTypePicture))?.first as? String {
            return NSImage(contentsOfFile: path)
        }
        return nil
    }
}
