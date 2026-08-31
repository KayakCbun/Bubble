import SwiftUI

enum TranscriptHostingSizingPolicy {
    /// Bubble owns the host frame, so min/max propagation is unnecessary.
    /// Intrinsic sizing must remain enabled because it is the authoritative
    /// multiline row-height measurement used by the transcript height index.
    static let options: NSHostingSizingOptions = [.intrinsicContentSize]

    /// Measures the renderer's ideal height at the transcript's fixed width.
    /// The mounted host frame is only an estimate and may be much shorter than
    /// restored content, so it must not participate in vertical measurement.
    static func contentHeight<Content: View>(
        of hostingController: NSHostingController<Content>,
        width: CGFloat
    ) -> CGFloat {
        let proposal = CGSize(
            width: max(1, width),
            height: CGFloat.greatestFiniteMagnitude
        )
        let height = hostingController.sizeThatFits(in: proposal).height
        return max(1, height.isFinite ? height : 1)
    }
}
