import Foundation

private struct FixtureItem: Codable {
    var id = UUID()
    var kind: String
    var text: String
    var toolId: String? = nil
    var toolStatus: String? = nil
    var toolKind: String? = nil
    var toolInput: String? = nil
    var toolOutput: String? = nil
    var sourceEntryId: String? = nil
    var sourceBranchable: Bool? = nil
}

private struct FixtureEnvelope: Codable {
    var version = 1
    var sessionId: String
    var selectedLeafId: String? = nil
    var items: [FixtureItem]
    var richItems: [FixtureItem]? = nil
}

@main
private enum TranscriptPerfFixture {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard let homeIndex = arguments.firstIndex(of: "--home"), homeIndex + 1 < arguments.count else {
            FileHandle.standardError.write(Data("usage: make_transcript_perf_fixture --home PATH [--turns N]\n".utf8))
            exit(2)
        }
        let home = URL(fileURLWithPath: arguments[homeIndex + 1], isDirectory: true)
        let turns: Int = {
            guard let index = arguments.firstIndex(of: "--turns"), index + 1 < arguments.count else {
                return 600
            }
            return Int(arguments[index + 1]) ?? 600
        }()
        let sessionID = "bubble-perf-600-turns"
        let root = home.appendingPathComponent(".bubble", isDirectory: true)
        let transcripts = root.appendingPathComponent("transcripts", isDirectory: true)
        try FileManager.default.createDirectory(at: transcripts, withIntermediateDirectories: true)

        var items: [FixtureItem] = []
        items.reserveCapacity(turns * 3)
        for turn in 0..<turns {
            items.append(FixtureItem(
                kind: "user",
                text: "Turn \(turn): inspect a long-context rendering scenario without losing the visible scroll anchor.",
                sourceEntryId: "user-entry-\(turn)",
                sourceBranchable: true
            ))
            if turn.isMultiple(of: 3) {
                items.append(FixtureItem(
                    kind: "thought",
                    text: Array(repeating: "Considering layout, stable identity, and viewport anchoring for turn \(turn).", count: 5)
                        .joined(separator: "\n")
                ))
            }
            if turn.isMultiple(of: 5) {
                items.append(FixtureItem(
                    kind: "tool",
                    text: "Read performance fixture \(turn)",
                    toolId: "tool-\(turn)",
                    toolStatus: "completed",
                    toolKind: "read",
                    toolInput: #"{"path":"Sources/Bubble/OverlayView.swift"}"#,
                    toolOutput: "Read completed"
                ))
            }

            let paragraphCount = turn.isMultiple(of: 20) ? 180 : 10
            var answer = Array(repeating: "**Turn \(turn).** This paragraph exercises proportional text, `inline chips`, 中文换行，以及 stable dynamic row heights.", count: paragraphCount)
                .joined(separator: "\n\n")
            if turn.isMultiple(of: 41) {
                answer += "\n\n```swift\n" + Array(repeating: "let renderedRow = \(turn)", count: 80).joined(separator: "\n") + "\n```"
            }
            if turn.isMultiple(of: 73) {
                answer += "\n\nsequenceDiagram\nUser->>Bubble: Scroll history\nBubble-->>User: Preserve the anchor"
            }
            items.append(FixtureItem(
                kind: "assistant",
                text: answer,
                sourceEntryId: "assistant-entry-\(turn)",
                sourceBranchable: true
            ))
        }

        let envelope = FixtureEnvelope(sessionId: sessionID, items: items)
        let encoder = JSONEncoder()
        let data = try encoder.encode(envelope)
        try Data(sessionID.utf8).write(to: root.appendingPathComponent("session-id"), options: .atomic)
        try data.write(to: root.appendingPathComponent("transcript.json"), options: .atomic)
        try data.write(to: transcripts.appendingPathComponent("\(sessionID).json"), options: .atomic)
        print("Wrote \(items.count) items / \(data.count) bytes to \(root.path)")
    }
}
