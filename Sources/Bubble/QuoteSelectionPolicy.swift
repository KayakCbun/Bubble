import CoreGraphics
import Foundation

enum QuoteSelectionPolicy {
    static let minimumCharacters = 1
    static let chipGap: CGFloat = 8
    static let chipHeight: CGFloat = 34
    static let chipWidth: CGFloat = 124
    static let edgeInset: CGFloat = 8

    static func quotedText(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumCharacters else { return nil }
        if trimmed.count > OverlayComposer.maxClipCharacters {
            return String(trimmed.prefix(OverlayComposer.maxClipCharacters)) + "\n…"
        }
        return trimmed
    }

    static func acceptsSource(isEditable: Bool, isSelectable: Bool) -> Bool {
        isSelectable && !isEditable
    }

    static func showsChip(mousePressed: Bool, quoted: String?) -> Bool {
        !mousePressed && quoted != nil
    }

    /// `selection` and `container` share a top-left origin, matching SwiftUI.
    static func chipCenter(
        selection: CGRect,
        chipSize: CGSize,
        container: CGRect
    ) -> CGPoint {
        let halfW = chipSize.width / 2
        let halfH = chipSize.height / 2
        let minX = container.minX + edgeInset + halfW
        let maxX = container.maxX - edgeInset - halfW
        let x: CGFloat
        if minX > maxX {
            x = container.midX
        } else {
            x = min(max(selection.midX, minX), maxX)
        }

        let above = selection.minY - chipGap - halfH
        let below = selection.maxY + chipGap + halfH
        let minY = container.minY + edgeInset + halfH
        let maxY = container.maxY - edgeInset - halfH
        let y: CGFloat
        if above >= minY {
            y = above
        } else if below <= maxY {
            y = below
        } else {
            y = min(max(selection.minY - chipGap - halfH, minY), maxY)
        }
        return CGPoint(x: x, y: y)
    }
}
