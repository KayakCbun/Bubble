import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct ComposerCheck {
    static func main() {
        testHeight()
        testLargePaste()
        testIntake()
        testPayload()
        print("PASS: composer layout and paste")
    }

    static func testHeight() {
        let idle = OverlayComposer.composerHeight(
            draft: "",
            minHeight: 46,
            avatarSize: 28,
            workspaceChip: false,
            chipHeight: 32,
            attachmentCount: 0
        )
        expect(idle == 46, "idle composer stays the compact bar \(idle)")
        let three = OverlayComposer.composerHeight(
            draft: "a\nb\nc",
            minHeight: 46,
            avatarSize: 28,
            workspaceChip: false,
            chipHeight: 32,
            attachmentCount: 0
        )
        expect(three > idle, "three lines grow the bar \(three)")
        expect(OverlayComposer.visibleLineCount("a\nb\nc\nd\ne\nf\ng\nh") == 6, "visible lines cap at 6")
        let withImage = OverlayComposer.composerHeight(
            draft: "",
            minHeight: 46,
            avatarSize: 28,
            workspaceChip: false,
            chipHeight: 32,
            attachmentCount: 1
        )
        expect(withImage > idle, "pasted image grows the bar \(withImage)")
        let wrapped = "即使算上 AI oncall ，拦截率还是有明显的下降，是因为整体有效 case 变多"
        expect(
            OverlayComposer.visibleLineCount(wrapped) >= 2,
            "a long CJK line counts wrapped rows \(OverlayComposer.visibleLineCount(wrapped))"
        )
        let wrappedHeight = OverlayComposer.composerHeight(
            draft: wrapped,
            minHeight: 46,
            avatarSize: 28,
            workspaceChip: false,
            chipHeight: 32,
            attachmentCount: 0
        )
        expect(wrappedHeight > idle, "wrapped CJK grows the composer \(wrappedHeight)")
        let hello = OverlayComposer.composerHeight(
            draft: "hello",
            minHeight: 46,
            avatarSize: 28,
            workspaceChip: false,
            chipHeight: 32,
            attachmentCount: 0
        )
        let helloBang = OverlayComposer.composerHeight(
            draft: "hello!",
            minHeight: 46,
            avatarSize: 28,
            workspaceChip: false,
            chipHeight: 32,
            attachmentCount: 0
        )
        expect(hello == helloBang, "same-line typing must not resize composer chrome")
        expect(
            !OverlayComposer.chromeHeightNeedsUpdate(previous: hello, next: helloBang),
            "same-line typing must not invalidate overlay layout"
        )
        expect(
            OverlayComposer.chromeHeightNeedsUpdate(previous: idle, next: three),
            "adding lines still resizes composer chrome"
        )
        expect(
            OverlayComposer.attachmentChipMaxWidth(inputWidth: 520) == 496,
            "quote chips stay inside the composer padding"
        )
        expect(
            OverlayComposer.fieldWidth(inputWidth: 520, avatarSize: 28) == 424,
            "the field leaves room for the avatar and send button"
        )
        expect(
            OverlayComposer.trailingControlSize == 28,
            "send button keeps a reserved column"
        )
    }

    static func testLargePaste() {
        expect(!OverlayComposer.isLargePaste("hello\nworld"), "short multiline stays in the field")
        let log = (1...10).map { "line \($0)" }.joined(separator: "\n")
        expect(OverlayComposer.isLargePaste(log), "8+ lines become a clip")
        let wall = String(repeating: "汉", count: OverlayComposer.largePasteCharacters)
        expect(OverlayComposer.isLargePaste(wall), "long CJK paste becomes a clip")
    }

    static func testIntake() {
        let short = OverlayComposer.intake(text: "查一下这张表", imagePNG: nil)
        expect(short.insertText == "查一下这张表", "short paste inserts into the field")
        expect(short.clips.isEmpty, "short paste is not a clip")
        let log = (1...12).map { "error \($0)" }.joined(separator: "\n")
        let large = OverlayComposer.intake(text: log, imagePNG: nil)
        expect(large.insertText.isEmpty, "large paste does not dump into the field")
        expect(large.clips.count == 1, "large paste becomes one clip")
        expect(large.clips[0].contains("error 1"), "clip keeps the pasted body")
        let png = Data(repeating: 1, count: 32)
        let image = OverlayComposer.intake(text: "", imagePNG: png)
        expect(image.images.count == 1, "image paste attaches png")
        expect(image.insertText.isEmpty, "image-only paste does not insert a path")
        let both = OverlayComposer.intake(text: "看这张图", imagePNG: png)
        expect(both.insertText == "看这张图" && both.images.count == 1, "caption + image stay together")
    }

    static func testPayload() {
        let plain = OverlayComposer.sendPayload(draft: "hello", clips: [], imageCount: 0)
        expect(plain.display == "hello" && plain.prompt == "hello", "plain send is unchanged")
        let imageOnly = OverlayComposer.sendPayload(draft: "", clips: [], imageCount: 1)
        expect(imageOnly.display.isEmpty, "image-only bubble uses the thumbnail, not a text label")
        expect(imageOnly.prompt.contains("[Image attached]"), "image-only prompt marks the attachment")
        let clip = String(repeating: "a", count: 400)
        let pasted = OverlayComposer.sendPayload(
            draft: "看这段",
            clips: [DraftClip(text: clip, kind: .paste)],
            imageCount: 0
        )
        expect(pasted.display.contains("看这段"), "caption stays in the user bubble")
        expect(pasted.display.contains("400 characters"), "long clip is summarized in the bubble")
        expect(pasted.prompt.contains(clip), "the model still receives the full clip")
        expect(!pasted.display.contains(clip), "the user bubble does not dump the whole clip")
        let quote = OverlayComposer.promptFragment(
            for: DraftClip(text: "Git checkout 快进到", kind: .quote)
        )
        expect(quote.contains("Quoted from the conversation:"), "quotes are labeled for the model")
        expect(quote.contains("Git checkout 快进到"), "quotes keep the selected body")
        expect(
            OverlayComposer.clipLabel(DraftClip(text: "Git checkout 快进到", kind: .quote))
                == "Quote · Git checkout 快进到",
            "composer chip previews the quoted snippet"
        )
    }
}
