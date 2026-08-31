import SwiftUI

enum TranscriptHostingSizingPolicy {
    /// Bubble owns the host frame, so min/max propagation is unnecessary.
    /// Intrinsic sizing must remain enabled because it is the authoritative
    /// multiline row-height measurement used by the transcript height index.
    static let options: NSHostingSizingOptions = [.intrinsicContentSize]
}
