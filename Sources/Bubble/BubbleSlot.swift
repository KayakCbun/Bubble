import Foundation

enum BubbleSlotKind: String, CaseIterable, Equatable, Sendable {
    case record
    case settings
    case mounts
    case agents
}

struct BubbleSlot: Equatable, Sendable {
    var kind: BubbleSlotKind
    var feature: String
    var fileName: String
    var template: String
    var posixPermissions: Int?
    var createsIfMissing: Bool
    var editHint: String

    func url(in root: URL) -> URL {
        root.appendingPathComponent(fileName)
    }
}

enum BubbleSlotCatalog {
    static let all: [BubbleSlot] = [
        BubbleSlot(
            kind: .record,
            feature: "Record",
            fileName: "record.json",
            template: """
            {
              "engine": "auto",
              "apiKey": "",
              "appId": "",
              "accessToken": "",
              "resourceId": "volc.seedasr.sauc.duration",
              "endpoint": "wss://openspeech.bytedance.com/api/v3/plan/sauc/bigmodel_async"
            }
            """,
            posixPermissions: 0o600,
            createsIfMissing: true,
            editHint: "Put the Volcengine Seed ASR API key in apiKey. Leave it empty to keep Apple Speech."
        ),
        BubbleSlot(
            kind: .settings,
            feature: "Model and thinking",
            fileName: "config.json",
            template: """
            {
            }
            """,
            posixPermissions: nil,
            createsIfMissing: true,
            editHint: "Prefer /model and /thinking. This file stores the current model and thinking level."
        ),
        BubbleSlot(
            kind: .mounts,
            feature: "Mounts",
            fileName: "mounts.json",
            template: """
            {
              "active": null,
              "mounts": [],
              "recent": []
            }
            """,
            posixPermissions: nil,
            createsIfMissing: true,
            editHint: "Prefer /mounts. This file is the mount address book."
        ),
        BubbleSlot(
            kind: .agents,
            feature: "Persona",
            fileName: "AGENTS.md",
            template: "",
            posixPermissions: nil,
            createsIfMissing: false,
            editHint: "Prefer /agents. This file is Bubble's persona."
        ),
    ]

    static func slot(_ kind: BubbleSlotKind) -> BubbleSlot {
        all.first { $0.kind == kind }!
    }

    static func slot(fileName: String) -> BubbleSlot? {
        all.first { $0.fileName == fileName }
    }

    static func ensureAll(in root: URL, fileManager: FileManager = .default) {
        for slot in all {
            ensure(slot, in: root, fileManager: fileManager)
        }
    }

    static func ensure(
        _ slot: BubbleSlot,
        in root: URL,
        fileManager: FileManager = .default
    ) {
        guard slot.createsIfMissing else { return }
        let url = slot.url(in: root)
        if fileManager.fileExists(atPath: url.path) { return }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        guard let data = slot.template.data(using: .utf8) else { return }
        guard fileManager.createFile(atPath: url.path, contents: data) else { return }
        if let mode = slot.posixPermissions {
            try? fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: url.path
            )
        }
    }

    static func agentGuide(homeDisplay: String = "~/.bubble") -> String {
        let lines = all.map { slot in
            "- \(slot.feature): `\(homeDisplay)/\(slot.fileName)` — \(slot.editHint)"
        }
        return """
        ## Slots

        Bubble-native features keep a slot under `\(homeDisplay)/`. Secrets stay empty until the user fills them. Do not commit slots or copy them into git. When the user asks to configure a feature, edit that slot:

        \(lines.joined(separator: "\n"))
        """
    }
}
