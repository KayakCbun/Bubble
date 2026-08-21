import Foundation

struct AcpUpdateDelivery: Sendable {
    let sessionId: String
    let data: Data
    let receivedDuringReplay: Bool

    var shouldDeliverToTranscript: Bool {
        !receivedDuringReplay
    }
}
