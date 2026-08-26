import Foundation
import BubbleSessions

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

do {
    let first = UUID()
    var state = SessionTabsState(primaryID: first)
    expect(!state.showsTabs, "one session must not show tabs")

    let second = UUID()
    _ = try state.createSideSession(id: second)
    expect(state.showsTabs, "two sessions must show tabs")
    expect(state.selectedID == second, "new side session must be selected")
    expect(state.tabs.map(\.ordinal) == [1, 2], "tabs must keep stable ordinals")

    try state.requestSelection(first)
    expect(state.selectedID == second, "requesting a switch must keep the current transcript for the loading frame")
    expect(state.presentedSelectedID == first, "the requested tab must highlight immediately")
    expect(state.isSwitching, "requesting a switch must show the loading mask immediately")
    expect(state.commitRequestedSelection() == first, "the next frame must commit the requested session")
    expect(state.selectedID == first, "committing must activate the requested session")
    expect(state.isSwitching, "loading must remain while the new transcript renders")
    try state.requestSelection(first)
    expect(state.isSwitching, "re-clicking the rendering tab must not dismiss loading")
    state.finishSelection(first)
    expect(!state.isSwitching, "the new transcript's first frame must dismiss loading")
    try state.setBusy(true, for: second)
    try state.markUpdated(second)
    expect(state.tabs[1].isBusy, "background busy state must be retained")
    expect(state.tabs[1].hasUnread, "background update must mark the tab unread")

    try state.requestSelection(second)
    _ = state.commitRequestedSelection()
    state.finishSelection(second)
    expect(state.tabs[1].isBusy, "selection must not clear busy state")
    expect(!state.tabs[1].hasUnread, "selection must clear unread state")

    for _ in 0..<3 {
        _ = try state.createSideSession(id: UUID())
    }
    expect(state.tabs.count == 5, "session count must reach five")
    do {
        _ = try state.createSideSession(id: UUID())
        expect(false, "sixth session must fail")
    } catch {
        expect(error as? SessionTabsError == .limitReached(maximum: 5), "sixth session must report the limit")
    }

    let hitRegions = SessionTabLayout.hitRegions(
        count: 2,
        transcriptOriginY: 36,
        trailingX: 36
    )
    expect(hitRegions == [
        CGRect(x: 4, y: 60, width: 32, height: 32),
        CGRect(x: 4, y: 100, width: 32, height: 32),
    ], "physical hit regions must match the rendered tab strip")
    expect(
        SessionTabLayout.index(
            at: CGPoint(x: 29, y: 76),
            count: 2,
            transcriptOriginY: 36,
            trailingX: 36
        ) == 0,
        "a physical click on the first visible tab must resolve to the main session"
    )
    expect(
        SessionTabLayout.index(
            at: CGPoint(x: 29, y: 116),
            count: 2,
            transcriptOriginY: 36,
            trailingX: 36
        ) == 1,
        "a physical click on the second visible tab must resolve to the side session"
    )
} catch {
    fputs("FAIL: unexpected error: \(error)\n", stderr)
    exit(1)
}

print("PASS: session tab state checks")
