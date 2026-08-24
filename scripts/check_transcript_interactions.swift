import Foundation

private var failures: [String] = []

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { failures.append(message) }
}

@main
private enum TranscriptInteractionCheck {
    static func main() {
        expect(
            StartupTranscriptPolicy.isSetupCard("Set up Bubble\nPi — not found", isSystem: true),
            "a persisted setup card must be recognized after relaunch"
        )
        expect(
            !StartupTranscriptPolicy.isSetupCard("Bubble is ready.", isSystem: true),
            "ordinary system messages must survive startup cleanup"
        )
        expect(
            !StartupTranscriptPolicy.isSetupCard("Set up Bubble in this repo", isSystem: false),
            "user-authored messages with the setup prefix must survive relaunch"
        )
        expect(
            StartupTranscriptPolicy.shouldPresentAfterConnection(hasCredentials: false),
            "a connected runtime still needs setup guidance when no provider is signed in"
        )
        expect(
            !StartupTranscriptPolicy.shouldPresentAfterConnection(hasCredentials: true),
            "a ready signed-in runtime must not restore the stale setup card"
        )
        expect(
            !ConversationBranchControlsPolicy.showsInlineRow(isHovered: true, variantCount: 0),
            "hovering an unbranched user message must not insert a height-changing row"
        )
        expect(
            ConversationBranchControlsPolicy.showsInlineRow(isHovered: false, variantCount: 2),
            "existing branch variants keep their stable inline switcher"
        )
        expect(
            !TranscriptFollowPolicy.followsContentHeightChange(isBusy: false),
            "idle hover geometry must not force the transcript to the bottom"
        )
        expect(
            TranscriptFollowPolicy.followsContentHeightChange(isBusy: true),
            "streaming content growth should continue following the latest response"
        )
        if !failures.isEmpty {
            for failure in failures {
                FileHandle.standardError.write(Data("FAIL: \(failure)\n".utf8))
            }
            exit(1)
        }
        print("PASS: transcript interaction regressions")
    }
}
