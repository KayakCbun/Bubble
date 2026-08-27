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
        require(
            overlay.contains("static let bodyWeight: Font.Weight = .regular"),
            "Bubble body copy has one explicit regular weight token"
        )
        require(
            !overlay.contains(".font(.system(size: OverlayMetrics.fontSize, weight: .regular))"),
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
