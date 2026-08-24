import Foundation

enum MessageDeliveryState: String, Codable, Equatable {
    case waiting
    case steering
}

enum MessageDeliveryPolicy {
    static func shouldQueue(isBusy: Bool, isBranching: Bool) -> Bool {
        isBusy && !isBranching
    }

    static func composerSends(isBusy: Bool, hasPayload: Bool) -> Bool {
        isBusy && hasPayload
    }

    static func canSteer(_ state: MessageDeliveryState?, isBusy: Bool) -> Bool {
        isBusy && state == .waiting
    }

    static func steeringText(_ text: String, resourceURIs: [String]) -> String {
        resourceURIs.reduce(text) { result, uri in
            result + "\n[Context] \(uri)"
        }
    }
}
