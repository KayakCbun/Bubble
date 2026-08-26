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

    try state.select(first)
    try state.setBusy(true, for: second)
    try state.markUpdated(second)
    expect(state.tabs[1].isBusy, "background busy state must be retained")
    expect(state.tabs[1].hasUnread, "background update must mark the tab unread")

    try state.select(second)
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
} catch {
    fputs("FAIL: unexpected error: \(error)\n", stderr)
    exit(1)
}

print("PASS: session tab state checks")
