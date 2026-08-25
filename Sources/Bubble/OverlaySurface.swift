import SwiftUI

enum OverlaySurface {
    static var userFill: Color { Color.primary.opacity(0.045) }
    static var userQueuedFill: Color { Color.primary.opacity(0.03) }
    static var chipFill: Color { Color.primary.opacity(0.04) }
    static var chipStroke: Color { Color.primary.opacity(0.10) }
    static var hairline: Color { Color.primary.opacity(0.10) }
    static var cardFill: Color { Color.primary.opacity(0.035) }
    static var cardStroke: Color { Color.primary.opacity(0.06) }
    static var conversationInk: Color { Color.primary.opacity(0.88) }
    static let userRadius: CGFloat = 22
    static let chipRadius: CGFloat = 7
    static let rowSpacing: CGFloat = 22
    /// T3 Code `ChatMarkdown`: `text-sm leading-relaxed` (14px / 1.625).
    /// Extra SwiftUI spacing so wrapped SF Pro 14pt rows land on that line box.
    static let proseLineHeightMultiple: CGFloat = 1.625
    static let proseLineSpacing: CGFloat = 6
    /// T3 `.chat-markdown p` margin `0.65rem`.
    static let proseBlockSpacing: CGFloat = 10
    /// T3 heading `line-height: 1.3`.
    static let proseHeadingLineSpacingEm: CGFloat = 0.30
    /// T3 body leading extra over 1em (`1.625 - 1`).
    static let proseLineSpacingEm: CGFloat = 0.625
}
