import Foundation

func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct TypographyContractCheck {
    static func section(_ source: String, from start: String, to end: String) -> String {
        guard let startRange = source.range(of: start),
              let endRange = source.range(of: end, range: startRange.upperBound..<source.endIndex) else {
            return ""
        }
        return String(source[startRange.lowerBound..<endRange.lowerBound])
    }

    static func main() throws {
        let overlay = try String(
            contentsOfFile: "Sources/Bubble/OverlayView.swift",
            encoding: .utf8
        )
        let messageBody = try String(
            contentsOfFile: "Sources/Bubble/MessageBody.swift",
            encoding: .utf8
        )
        let transcriptProse = try String(
            contentsOfFile: "Sources/Bubble/TranscriptProse.swift",
            encoding: .utf8
        )
        let surface = try String(
            contentsOfFile: "Sources/Bubble/OverlaySurface.swift",
            encoding: .utf8
        )
        let transcript = try String(
            contentsOfFile: "Sources/Bubble/TranscriptSurface.swift",
            encoding: .utf8
        )
        require(
            overlay.contains("static let fontSize: CGFloat = 14"),
            "body copy stays 14pt Regular"
        )
        require(
            overlay.contains("static let bodyWeight: Font.Weight = .regular"),
            "body copy stays Regular"
        )
        require(
            overlay.contains("static var bodyFont: Font { font(size: fontSize, weight: bodyWeight) }"),
            "body copy uses the shared OverlayMetrics font token"
        )
        require(
            overlay.contains(".system(size: size, weight: weight, design: design)"),
            "conversation text uses the native macOS system family"
        )
        require(
            !overlay.contains("Font.custom(")
                && !overlay.contains("OverlayTypeface"),
            "the overlay does not route body copy through a bundled custom face"
        )
        require(
            transcript.contains("fontFamily: \".AppleSystemUIFont\""),
            "transcript cache keys follow the system family"
        )
        require(
            surface.contains("static let opaqueLabel = NSColor(name: \"bubble.opaqueLabel\""),
            "conversation ink is a solid sRGB label, not a vibrant system color"
        )
        require(
            surface.contains("srgbRed: 0.1529, green: 0.1529, blue: 0.1647, alpha: 1"),
            "light-mode body copy matches T3 zinc-800, not near-black"
        )
        require(
            !surface.contains("Color(nsColor: .labelColor)")
                && !surface.contains("Color(nsColor: .secondaryLabelColor)")
                && !surface.contains("Color.primary.opacity(0.88)"),
            "semantic or translucent labels wash out on the frosted panel"
        )
        require(
            surface.contains("static let proseLineHeightMultiple: CGFloat = 1.625"),
            "conversation leading stays open"
        )
        require(
            surface.contains("static let proseLineSpacing: CGFloat = 6"),
            "native prose keeps the open line box"
        )
        require(
            !overlay.contains(".font(.system(size: OverlayMetrics.fontSize, weight:"),
            "conversation, composer, and palette body copy must not bypass the shared token"
        )
        let palette = section(
            overlay,
            from: "private var slashPalette: some View",
            to: "private var appSearchField: some View"
        )
        require(
            palette.contains(".font(OverlayMetrics.bodyFont)")
                && palette.contains(".fontWeight(OverlayMetrics.bodyWeight)"),
            "the slash palette applies the shared body font and regular weight"
        )
        let composer = section(
            overlay,
            from: "private struct ComposerBar: View",
            to: "private var composerTrailingControl: some View"
        )
        require(
            composer.contains("TextField(\"\", text: $store.draft")
                && composer.contains(".font(OverlayMetrics.bodyFont)")
                && composer.contains(".fontWeight(OverlayMetrics.bodyWeight)"),
            "the active composer applies the shared body font and regular weight"
        )
        require(
            messageBody.contains(".font(OverlayMetrics.bodyFont)")
                && messageBody.contains("FontWeight(.regular)"),
            "classic conversation prose applies the shared regular body typography"
        )
        require(
            transcriptProse.contains("font: Font = OverlayMetrics.bodyFont"),
            "native conversation prose defaults to the shared body font"
        )
        print("PASS: shared body typography contract")
    }
}
