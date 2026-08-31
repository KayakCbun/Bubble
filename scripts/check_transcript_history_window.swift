import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum TranscriptHistoryWindowCheck {
    private enum RowKind {
        case user
        case output
    }

    private struct RestoreRow: Equatable {
        var id: Int
        var sourceKey: String?
        var text: String
    }

    static func main() {
        var rows = [RowKind.output]
        for _ in 0..<45 {
            rows.append(.user)
            rows.append(.output)
            rows.append(.output)
        }

        expect(
            TranscriptHistoryWindow.lowerBound(rows: rows, turnCapacity: 10, isUser: { $0 == .user }) == 106,
            "initial history window starts at the tenth user turn from the end"
        )
        expect(
            TranscriptHistoryWindow.lowerBound(rows: rows, turnCapacity: 30, isUser: { $0 == .user }) == 46,
            "loading earlier expands the projection by twenty user turns"
        )
        expect(
            TranscriptHistoryWindow.lowerBound(rows: rows, turnCapacity: 80, isUser: { $0 == .user }) == 0,
            "a capacity larger than the transcript reveals the complete prefix"
        )
        expect(
            TranscriptHistoryWindow.lowerBound(
                rows: [RowKind.output, .output],
                turnCapacity: 10,
                isUser: { $0 == .user }
            ) == 0,
            "system-only transcripts remain visible"
        )

        rows.append(.user)
        rows.append(.output)
        expect(
            TranscriptHistoryWindow.lowerBound(rows: rows, turnCapacity: 10, isUser: { $0 == .user }) == 109,
            "new turns keep the projection bounded at the live edge"
        )
        expect(
            TranscriptHistoryWindow.expandedCapacity(current: 10, totalTurns: 45) == 30,
            "one request loads twenty earlier turns"
        )
        expect(
            TranscriptHistoryWindow.expandedCapacity(current: 30, totalTurns: 45) == 45,
            "the final request clamps to the available history"
        )
        expect(
            TranscriptHistoryWindow.initialCapacity(environmentValue: "30") == 30,
            "the performance harness can open an expanded history window"
        )
        expect(
            TranscriptHistoryWindow.initialCapacity(environmentValue: "invalid") == 10,
            "invalid diagnostics keep the production ten-turn default"
        )

        let restored = [
            RestoreRow(id: 1, sourceKey: "assistant:entry-1", text: "persisted"),
            RestoreRow(id: 2, sourceKey: nil, text: "persisted local row"),
        ]
        let live = [
            RestoreRow(id: 99, sourceKey: "assistant:entry-1", text: "richer live row"),
            RestoreRow(id: 3, sourceKey: nil, text: "live local row"),
        ]
        let merged = TranscriptRestoreMerge.merge(
            restored: restored,
            live: live,
            id: \.id,
            stableKey: \.sourceKey
        )
        expect(
            merged == [restored[1], live[0], live[1]],
            "restore deduplicates source-backed rows by stable identity while preserving local rows"
        )

        setenv("BUBBLE_SCROLL_DIAGNOSTICS", "drive", 1)
        TranscriptHydrationTiming.startIfDiagnosing()
        expect(
            TranscriptHydrationTiming.diagnosticStartedAt != nil
                && !TranscriptHydrationTiming.diagnosticHydrationCompleted,
            "diagnostic hydration starts behind an explicit completion gate"
        )
        TranscriptHydrationTiming.completeIfDiagnosing()
        expect(
            TranscriptHydrationTiming.diagnosticHydrationCompleted,
            "diagnostic hydration completion releases the benchmark gate"
        )
        TranscriptHydrationTiming.clear()
        unsetenv("BUBBLE_SCROLL_DIAGNOSTICS")

        print("PASS: transcript history window")
    }
}
