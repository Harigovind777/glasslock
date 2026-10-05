import Foundation

/// Builds the "Lock Mac" Shortcut: publish `lock`, wait, poll the ack topic,
/// and notify. The If checks for "locked:<id>", which also matches
/// "already-locked:<id>" — both mean the Mac is locked.
public enum ShortcutBuilder {
    public static let successText = "✅ Mac locked"
    public static let noReplyText = "⚠️ No reply — Mac may be asleep, lid closed, or offline"

    public static func publishURL(topic: String, relay: String = "https://ntfy.sh") -> String {
        "\(relay)/\(topic)/publish?message=lock"
    }

    public static func ackPollURL(topic: String, relay: String = "https://ntfy.sh") -> String {
        "\(relay)/\(topic)-ack/raw?poll=1&since=30s"
    }

    public static func workflow(
        topic: String,
        relay: String = "https://ntfy.sh",
        makeUUID: () -> String = { UUID().uuidString }
    ) -> [String: Any] {
        let publish = makeUUID()
        let idValue = makeUUID()
        let poll = makeUUID()
        let group = makeUUID()

        let actions: [[String: Any]] = [
            action("is.workflow.actions.downloadurl", [
                "UUID": publish,
                "WFURL": publishURL(topic: topic, relay: relay),
                "WFHTTPMethod": "GET",
            ]),
            action("is.workflow.actions.getvalueforkey", [
                "UUID": idValue,
                "WFDictionaryKey": "id",
                "WFInput": attachment(publish, "Contents of URL"),
            ]),
            action("is.workflow.actions.delay", ["WFDelayTime": 4]),
            action("is.workflow.actions.downloadurl", [
                "UUID": poll,
                "WFURL": ackPollURL(topic: topic, relay: relay),
                "WFHTTPMethod": "GET",
            ]),
            action("is.workflow.actions.conditional", [
                "GroupingIdentifier": group,
                "WFControlFlowMode": 0,
                "WFCondition": 99, // "contains"
                "WFInput": ["Type": "Variable", "Variable": attachment(poll, "Contents of URL")] as [String: Any],
                "WFConditionalActionString": text(prefix: "locked:", variable: idValue, name: "Dictionary Value"),
            ]),
            action("is.workflow.actions.notification", [
                "WFNotificationActionTitle": "GlassLock",
                "WFNotificationActionBody": successText,
            ]),
            action("is.workflow.actions.conditional", ["GroupingIdentifier": group, "WFControlFlowMode": 1]),
            action("is.workflow.actions.notification", [
                "WFNotificationActionTitle": "GlassLock",
                "WFNotificationActionBody": noReplyText,
            ]),
            action("is.workflow.actions.conditional", ["GroupingIdentifier": group, "WFControlFlowMode": 2]),
        ]

        return [
            "WFWorkflowActions": actions,
            "WFWorkflowClientVersion": "2607.0.1",
            "WFWorkflowMinimumClientVersion": 900,
            "WFWorkflowMinimumClientVersionString": "900",
            "WFWorkflowIcon": ["WFWorkflowIconStartColor": 255, "WFWorkflowIconGlyphNumber": 59511],
            "WFWorkflowImportQuestions": [Any](),
            "WFWorkflowInputContentItemClasses": [Any](),
            "WFWorkflowOutputContentItemClasses": [Any](),
            "WFWorkflowTypes": [Any](),
            "WFQuickActionSurfaces": [Any](),
            "WFWorkflowHasShortcutInputVariables": false,
        ]
    }

    /// Unsigned binary plist, ready for `shortcuts sign`.
    public static func data(topic: String) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: workflow(topic: topic), format: .binary, options: 0)
    }

    public static func manualInstructions(topic: String) -> String {
        """
        In the Shortcuts app, tap + and add these actions:
        1. Get Contents of URL: \(publishURL(topic: topic))
        2. Get Dictionary Value: key "id" in Contents of URL
        3. Wait: 4 seconds
        4. Get Contents of URL: \(ackPollURL(topic: topic))
        5. If Contents of URL contains "locked:" followed by Dictionary Value
             Show Notification: \(successText)
           Otherwise
             Show Notification: \(noReplyText)
           End If
        Name it "Lock Mac".
        """
    }

    private static func action(_ identifier: String, _ parameters: [String: Any]) -> [String: Any] {
        ["WFWorkflowActionIdentifier": identifier, "WFWorkflowActionParameters": parameters]
    }

    private static func output(_ uuid: String, _ name: String) -> [String: Any] {
        ["Type": "ActionOutput", "OutputUUID": uuid, "OutputName": name]
    }

    private static func attachment(_ uuid: String, _ name: String) -> [String: Any] {
        ["WFSerializationType": "WFTextTokenAttachment", "Value": output(uuid, name)]
    }

    /// Text with one variable appended after `prefix` (U+FFFC marks the variable's slot).
    private static func text(prefix: String, variable uuid: String, name: String) -> [String: Any] {
        [
            "WFSerializationType": "WFTextTokenString",
            "Value": [
                "string": prefix + "\u{FFFC}",
                "attachmentsByRange": ["{\(prefix.utf16.count), 1}": output(uuid, name)],
            ] as [String: Any],
        ]
    }
}
