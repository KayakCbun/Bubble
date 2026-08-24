import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
struct OverlayLayoutCheck {
    static func main() {
        expect(OverlayLayoutPolicy.transcriptHeight(isPresented: false, maximum: 640) == 0,
               "a hidden transcript must not reserve height")
        expect(OverlayLayoutPolicy.transcriptHeight(isPresented: true, maximum: 640) == 640,
               "a presented transcript must use the stable default height")
        expect(!OverlayLayoutPolicy.isTranscriptPresented(itemCount: 0, isStartingSession: false),
               "an idle empty conversation should only show the composer")
        expect(OverlayLayoutPolicy.isTranscriptPresented(itemCount: 0, isStartingSession: true),
               "session loading must keep the transcript visible")
        expect(OverlayLayoutPolicy.isTranscriptPresented(itemCount: 1, isStartingSession: false),
               "a ready message must keep the transcript visible")
        expect(OverlayLayoutPolicy.previewExtraWidth(0, gap: 8) == 0,
               "a closed preview must not grow the panel")
        expect(OverlayLayoutPolicy.previewExtraWidth(440, gap: 8) == 448,
               "an open preview grows the panel by width plus gap")
        expect(OverlayLayoutPolicy.contentWidth(chatWidth: 760, previewWidth: 440, gap: 8) == 1208,
               "content width is conversation plus preview extra")
        expect(OverlayLayoutPolicy.previewExtraWidth(760, gap: 8) == 768,
               "a workspace session pane grows the panel by default transcript width plus gap")
        expect(OverlayLayoutPolicy.contentWidth(chatWidth: 760, previewWidth: 760, gap: 8) == 1528,
               "workspace session stage sits beside the main transcript at default width")
        let fittedDefault = OverlayLayoutPolicy.fittedChatWidth(
            desired: 760,
            sideStageWidth: 560,
            visibleWidth: 1512,
            gap: 8,
            bleed: 36,
            minimum: 520
        )
        expect(fittedDefault == 760,
               "the default transcript stays full width on a 14-inch display")
        let fittedWide = OverlayLayoutPolicy.fittedChatWidth(
            desired: 1060,
            sideStageWidth: 560,
            visibleWidth: 1512,
            gap: 8,
            bleed: 36,
            minimum: 520
        )
        expect(fittedWide == 872,
               "wide mode contracts while a side stage is open")
        expect(
            OverlayLayoutPolicy.contentWidth(chatWidth: fittedWide, previewWidth: 560, gap: 8) + 72 <= 1512,
            "a unified side stage fits entirely on a 14-inch display"
        )

        let chrome = OverlayLayout(
            totalHeight: 614,
            transcriptHeight: 560,
            pickerHeight: 0,
            commandPaletteHeight: 0,
            transcriptWidth: 760,
            composerHeight: 46,
            previewWidth: 0
        )
        expect(!OverlayRenderPolicy.layoutNeedsApply(previous: chrome, next: chrome),
               "identical chrome must not retarget the panel")
        expect(OverlayRenderPolicy.layoutNeedsApply(previous: nil, next: chrome),
               "the first layout must apply")
        var grown = chrome
        grown.composerHeight = 66
        expect(OverlayRenderPolicy.layoutNeedsApply(previous: chrome, next: grown),
               "composer growth still resizes the panel")
        expect(!OverlayRenderPolicy.shouldPersistStreamChunk(isBusy: true, childBusy: false),
               "a live main turn must not write transcript.json on every token")
        expect(!OverlayRenderPolicy.shouldPersistStreamChunk(isBusy: false, childBusy: true),
               "a live workspace run must not write transcript.json on every tool")
        expect(OverlayRenderPolicy.shouldPersistStreamChunk(isBusy: false, childBusy: false),
               "idle turns still persist")
        expect(!OverlayRenderPolicy.shouldFlushStreamToUI(overlayVisible: false, isHiding: false),
               "hidden overlay must not rebuild SwiftUI on tokens")
        expect(!OverlayRenderPolicy.shouldFlushStreamToUI(overlayVisible: true, isHiding: true),
               "hide animation must not rebuild SwiftUI on tokens")
        expect(OverlayRenderPolicy.shouldFlushStreamToUI(overlayVisible: true, isHiding: false),
               "a visible overlay still streams")
        expect(!OverlayRenderPolicy.shouldResumeStream(panelVisible: true, isMoving: true),
               "show animation keeps accumulated stream work suspended")
        expect(OverlayRenderPolicy.shouldResumeStream(panelVisible: true, isMoving: false),
               "settled visible panel resumes accumulated stream work")
        let closedOrigin = OverlayLayoutPolicy.panelOriginX(centerX: 500, contentWidth: 760, bleed: 16)
        let openOrigin = OverlayLayoutPolicy.panelOriginX(centerX: 500, contentWidth: 760 + 448, bleed: 16)
        expect(closedOrigin == 500 - (760 + 32) / 2, "closed panel is centered on the composer")
        expect(openOrigin == closedOrigin - 224, "conversation slides left by half the preview extra")
        expect(
            openOrigin + (760 + 448 + 32) / 2 == closedOrigin + (760 + 32) / 2,
            "opening a preview must keep the visual center"
        )

        let mainVisibleFrame = CGRect(x: 0, y: 62, width: 2048, height: 1060)
        let previewExpandedFrame = CGRect(x: 396, y: 39, width: 1280, height: 868)
        let constrainedPreview = OverlayLayoutPolicy.constrainedFrame(
            previewExpandedFrame,
            to: mainVisibleFrame,
            constrainVertically: false
        )
        expect(
            constrainedPreview.minY == previewExpandedFrame.minY,
            "opening a width-only preview must preserve a user-positioned bottom edge"
        )
        let verticallyConstrained = OverlayLayoutPolicy.constrainedFrame(
            previewExpandedFrame,
            to: mainVisibleFrame
        )
        expect(
            verticallyConstrained.minY == mainVisibleFrame.minY,
            "height-changing layouts still remain inside the visible screen"
        )

        expect(OverlayPixel.align(100.25, scale: 2) == 100.5, "2x snaps to half points")
        expect(OverlayPixel.align(100.24, scale: 2) == 100, "2x rounds 0.24 down")
        expect(OverlayPixel.align(100.3, scale: 1) == 100, "1x snaps to whole points")
        let snapped = OverlayPixel.align(CGRect(x: 12.25, y: 8.75, width: 760, height: 46), scale: 2)
        expect(snapped.origin.x == 12.5 && snapped.origin.y == 9, "rect origin follows backing scale")
        expect(snapped.size.width == 760 && snapped.size.height == 46, "integer sizes stay put")

        var value: CGFloat = 0
        var velocity: CGFloat = 0
        OverlaySpring.step(value: &value, velocity: &velocity, target: 100, dt: 1.0 / 120.0)
        expect(value > 0 && value < 100, "a 120Hz spring step must move toward the target")
        expect(velocity > 0, "spring velocity starts toward the target")
        for _ in 0..<240 {
            OverlaySpring.step(value: &value, velocity: &velocity, target: 100, dt: 1.0 / 120.0)
        }
        expect(OverlaySpring.settled(value: value, velocity: velocity, target: 100), "spring settles within two seconds at 120Hz")
        expect(abs(value - 100) < 0.5, "settled value is on the target")

        print("PASS: overlay layout policy")
    }
}
