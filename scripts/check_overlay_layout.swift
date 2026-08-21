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
