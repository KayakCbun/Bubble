import Foundation

@main
struct MessageDeliveryCheck {
    static func main() {
        expect(!MessageDeliveryPolicy.shouldQueue(isBusy: false, isBranching: false), "idle messages send immediately")
        expect(MessageDeliveryPolicy.shouldQueue(isBusy: true, isBranching: false), "busy messages wait by default")
        expect(!MessageDeliveryPolicy.shouldQueue(isBusy: true, isBranching: true), "branch sends stay immediate")
        expect(
            MessageDeliveryPolicy.composerSends(isBusy: true, hasPayload: true),
            "a filled composer sends while the agent is running"
        )
        expect(
            !MessageDeliveryPolicy.composerSends(isBusy: true, hasPayload: false),
            "an empty running composer keeps the stop action"
        )
        expect(
            MessageDeliveryPolicy.canSteer(.waiting, isBusy: true),
            "a waiting message can become steering during a run"
        )
        expect(
            !MessageDeliveryPolicy.canSteer(.steering, isBusy: true),
            "a steering message cannot be steered twice"
        )
        expect(
            !MessageDeliveryPolicy.canSteer(.waiting, isBusy: false),
            "steering closes when the active turn closes"
        )
        expect(
            MessageDeliveryPolicy.steeringText(
                "Inspect this",
                resourceURIs: ["file:///tmp/a.txt", "file:///tmp/b.txt"]
            ) == "Inspect this\n[Context] file:///tmp/a.txt\n[Context] file:///tmp/b.txt",
            "steering preserves resource-link context"
        )
        print("message delivery checks passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fputs("message delivery check failed: \(message)\n", stderr)
            exit(1)
        }
    }
}
