import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct BubbleSlotCheck {
    static func main() {
        let record = BubbleSlotCatalog.slot(.record)
        expect(record.fileName == "record.json", "Record's slot is record.json")
        expect(record.posixPermissions == 0o600, "the Record slot is not world-readable")
        expect(record.template.contains(#""apiKey": """#), "the Record slot leaves apiKey empty")
        expect(record.template.contains(#""engine": "auto""#), "an empty Record slot stays on auto")
        expect(
            !record.template.contains("ark-"),
            "the Record slot template does not ship a real API key"
        )

        expect(BubbleSlotCatalog.slot(.settings).fileName == "config.json", "settings live in config.json")
        expect(BubbleSlotCatalog.slot(.mounts).fileName == "mounts.json", "mounts live in mounts.json")
        expect(BubbleSlotCatalog.slot(.agents).fileName == "AGENTS.md", "persona lives in AGENTS.md")
        expect(
            !BubbleSlotCatalog.slot(.agents).createsIfMissing,
            "AGENTS.md stays owned by the persona bootstrap, not the slot template"
        )

        let guide = BubbleSlotCatalog.agentGuide()
        expect(guide.contains("## Slots"), "the agent guide names Slots")
        expect(guide.contains("~/.bubble/record.json"), "the agent guide points Record at record.json")
        expect(guide.contains("~/.bubble/config.json"), "the agent guide points settings at config.json")
        expect(guide.contains("~/.bubble/mounts.json"), "the agent guide points Mounts at mounts.json")
        expect(guide.contains("~/.bubble/AGENTS.md"), "the agent guide points persona at AGENTS.md")
        expect(guide.contains("Do not commit slots"), "the agent guide keeps secrets out of git")

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bubble-slot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        BubbleSlotCatalog.ensureAll(in: root)
        let recordURL = record.url(in: root)
        expect(FileManager.default.fileExists(atPath: recordURL.path), "bootstrap creates the Record slot")
        expect(
            !FileManager.default.fileExists(atPath: BubbleSlotCatalog.slot(.agents).url(in: root).path),
            "bootstrap does not stub AGENTS.md"
        )
        let created = try! String(contentsOf: recordURL, encoding: .utf8)
        expect(created.contains(#""apiKey": """#), "a new Record slot has an empty apiKey")
        let attrs = try! FileManager.default.attributesOfItem(atPath: recordURL.path)
        let mode = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        expect(mode & 0o077 == 0, "a new Record slot is owner-only")

        try! #"{"engine":"seed-asr","apiKey":"keep-me"}"#.write(to: recordURL, atomically: true, encoding: .utf8)
        BubbleSlotCatalog.ensureAll(in: root)
        let kept = try! String(contentsOf: recordURL, encoding: .utf8)
        expect(kept.contains("keep-me"), "ensure never overwrites a filled Record slot")

        print("PASS: bubble slots")
    }
}
