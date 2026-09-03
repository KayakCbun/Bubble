import AppKit
import SwiftUI

enum OverlaySurface {
    static var userFill: Color { Color.primary.opacity(0.045) }
    static var userCardFill: Color { Color(nsColor: .controlBackgroundColor) }
    static var userQueuedFill: Color { Color.primary.opacity(0.03) }
    static var chipFill: Color { Color.primary.opacity(0.04) }
    static var chipStroke: Color { Color.primary.opacity(0.10) }
    static var hairline: Color { Color.primary.opacity(0.10) }
    static var cardFill: Color { Color.primary.opacity(0.035) }
    static var cardStroke: Color { Color.primary.opacity(0.06) }
    /// T3 Code `--foreground: zinc-800` / dark `neutral-100`. Solid sRGB so
    /// the frosted panel cannot wash it via vibrant `labelColor`.
    static var conversationInk: Color { Color(nsColor: opaqueLabel) }

    static let opaqueLabel = NSColor(name: "bubble.opaqueLabel", dynamicProvider: { appearance in
        if appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua {
            return NSColor(srgbRed: 0.9608, green: 0.9608, blue: 0.9608, alpha: 1)
        }
        return NSColor(srgbRed: 0.1529, green: 0.1529, blue: 0.1647, alpha: 1)
    })
    static let userRadius: CGFloat = 22
    static let chipRadius: CGFloat = 7
    static let rowSpacing: CGFloat = 22
    static let proseLineHeightMultiple: CGFloat = 1.625
    static let proseLineSpacing: CGFloat = 6
    static let proseBlockSpacing: CGFloat = 10
    static let proseHeadingLineSpacingEm: CGFloat = 0.30
    static let proseLineSpacingEm: CGFloat = 0.625
}
