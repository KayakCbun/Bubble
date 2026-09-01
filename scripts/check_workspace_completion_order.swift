import Foundation

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}

@main
enum WorkspaceCompletionOrderCheck {
    static func main() throws {
        let source = try String(contentsOfFile: "Sources/Bubble/ChatStore.swift", encoding: .utf8)
        guard let functionStart = source.range(of: "    private func awaitChildPrompt(")?.lowerBound,
              let functionEnd = source.range(
                of: "\n    private func finishChildRun(",
                range: functionStart..<source.endIndex
              )?.lowerBound else {
            fail("could not locate the workspace completion path")
        }
        let body = source[functionStart..<functionEnd]
        guard let promptReturned = body.range(of: "let stop = try await client.prompt")?.lowerBound,
              let terminalized = body.range(of: "finishChildRun(")?.lowerBound else {
            fail("workspace prompt completion must terminalize through finishChildRun")
        }
        if let treeLookup = body.range(of: "client.conversationTree")?.lowerBound,
           treeLookup > promptReturned,
           treeLookup < terminalized {
            fail("workspace card remains running while a post-prompt conversation-tree lookup is pending")
        }
        print("PASS: workspace terminal state is not blocked by final-response enrichment")
    }
}
