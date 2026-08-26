import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct QuoteSelectionCheck {
    static func main() {
        expect(QuoteSelectionPolicy.quotedText(from: "  \n") == nil, "blank selection is ignored")
        expect(QuoteSelectionPolicy.quotedText(from: "Git checkout") == "Git checkout", "plain selection is kept")
        expect(
            QuoteSelectionPolicy.quotedText(from: "  快进到  \n") == "快进到",
            "quoted text is trimmed"
        )
        let huge = String(repeating: "汉", count: OverlayComposer.maxClipCharacters + 40)
        let clipped = QuoteSelectionPolicy.quotedText(from: huge)
        expect(clipped != nil && clipped!.hasSuffix("…"), "oversized quotes are truncated")
        expect(
            QuoteSelectionPolicy.acceptsSource(isEditable: false, isSelectable: true),
            "transcript text can quote"
        )
        expect(
            !QuoteSelectionPolicy.acceptsSource(isEditable: true, isSelectable: true),
            "composer typing is not a quote source"
        )
        expect(
            QuoteSelectionPolicy.showsChip(mousePressed: true, quoted: "hi") == false,
            "chip waits until the mouse is released"
        )
        expect(
            QuoteSelectionPolicy.showsChip(mousePressed: false, quoted: "hi"),
            "chip appears after a settled selection"
        )

        let container = CGRect(x: 0, y: 0, width: 400, height: 300)
        let chip = CGSize(width: 124, height: 34)
        let mid = QuoteSelectionPolicy.chipCenter(
            selection: CGRect(x: 120, y: 140, width: 80, height: 18),
            chipSize: chip,
            container: container
        )
        expect(mid.x == 160, "chip centers on the selection")
        expect(mid.y < 140, "chip prefers to sit above the selection")

        let top = QuoteSelectionPolicy.chipCenter(
            selection: CGRect(x: 40, y: 4, width: 60, height: 16),
            chipSize: chip,
            container: container
        )
        expect(top.y > 20, "chip drops below when there is no room above")

        let left = QuoteSelectionPolicy.chipCenter(
            selection: CGRect(x: 0, y: 120, width: 20, height: 16),
            chipSize: chip,
            container: container
        )
        expect(left.x >= 8 + chip.width / 2, "chip stays inside the left edge")
        print("PASS: quote selection")
    }
}
