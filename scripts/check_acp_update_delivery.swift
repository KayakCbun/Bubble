import Foundation

@main
enum CheckAcpUpdateDelivery {
    static func main() {
        var replaying = true
        let update = AcpUpdateDelivery(
            sessionId: "session-1",
            data: Data("history".utf8),
            receivedDuringReplay: replaying
        )

        // session/load completes before the main queue consumes the update.
        replaying = false

        expect(!replaying, "the mutable client replay flag has already reset")
        expect(update.receivedDuringReplay, "the update preserves receipt-time replay state")
        expect(!update.shouldDeliverToTranscript, "history replay never reaches transcript routing")

        let live = AcpUpdateDelivery(
            sessionId: "session-1",
            data: Data("live".utf8),
            receivedDuringReplay: false
        )
        expect(live.shouldDeliverToTranscript, "live updates still reach transcript routing")

        print("acp update delivery checks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
