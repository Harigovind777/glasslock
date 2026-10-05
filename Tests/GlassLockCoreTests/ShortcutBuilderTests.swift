import Foundation
import Testing
@testable import GlassLockCore

@Suite struct ShortcutBuilderTests {
    let topic = "glasslock-" + String(repeating: "A", count: 32)

    func actions() throws -> [[String: Any]] {
        let data = try ShortcutBuilder.data(topic: topic)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as! [String: Any]
        return plist["WFWorkflowActions"] as! [[String: Any]]
    }

    func params(_ action: [String: Any]) -> [String: Any] {
        action["WFWorkflowActionParameters"] as! [String: Any]
    }

    @Test func hasExpectedActionSequence() throws {
        let ids = try actions().map { $0["WFWorkflowActionIdentifier"] as! String }
        #expect(ids == [
            "is.workflow.actions.downloadurl",
            "is.workflow.actions.getvalueforkey",
            "is.workflow.actions.delay",
            "is.workflow.actions.downloadurl",
            "is.workflow.actions.conditional",
            "is.workflow.actions.notification",
            "is.workflow.actions.conditional",
            "is.workflow.actions.notification",
            "is.workflow.actions.conditional",
        ])
    }

    @Test func urlsContainTheTopic() throws {
        let all = try actions()
        #expect(params(all[0])["WFURL"] as? String == "https://ntfy.sh/\(topic)/publish?message=lock")
        #expect(params(all[3])["WFURL"] as? String == "https://ntfy.sh/\(topic)-ack/raw?poll=1&since=30s")
    }

    @Test func variableReferencesPointAtRealActions() throws {
        let all = try actions()
        let publishUUID = params(all[0])["UUID"] as! String
        let idUUID = params(all[1])["UUID"] as! String
        let pollUUID = params(all[3])["UUID"] as! String

        let getValueInput = (params(all[1])["WFInput"] as! [String: Any])["Value"] as! [String: Any]
        #expect(getValueInput["OutputUUID"] as? String == publishUUID)

        let condition = params(all[4])
        let conditionInput = ((condition["WFInput"] as! [String: Any])["Variable"] as! [String: Any])["Value"] as! [String: Any]
        #expect(conditionInput["OutputUUID"] as? String == pollUUID)

        let text = (condition["WFConditionalActionString"] as! [String: Any])["Value"] as! [String: Any]
        #expect(text["string"] as? String == "locked:\u{FFFC}")
        let attachments = text["attachmentsByRange"] as! [String: Any]
        let attachment = attachments["{7, 1}"] as! [String: Any]
        #expect(attachment["OutputUUID"] as? String == idUUID)
    }

    @Test func ifOtherwiseEndShareOneGroup() throws {
        let all = try actions()
        let groups = [4, 6, 8].map { params(all[$0])["GroupingIdentifier"] as! String }
        let modes = [4, 6, 8].map { params(all[$0])["WFControlFlowMode"] as! Int }
        #expect(Set(groups).count == 1)
        #expect(modes == [0, 1, 2])
    }

    @Test func notificationsUseAgreedCopy() throws {
        let all = try actions()
        #expect(params(all[5])["WFNotificationActionBody"] as? String == "✅ Mac locked")
        #expect(params(all[7])["WFNotificationActionBody"] as? String == "⚠️ No reply — Mac may be asleep, lid closed, or offline")
    }

    @Test func manualInstructionsContainBothURLs() {
        let text = ShortcutBuilder.manualInstructions(topic: topic)
        #expect(text.contains("https://ntfy.sh/\(topic)/publish?message=lock"))
        #expect(text.contains("https://ntfy.sh/\(topic)-ack/raw?poll=1&since=30s"))
    }
}
