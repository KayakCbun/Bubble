import Foundation

enum AcpStopIntent {
    case shutdown
    case reload
}

enum AcpSessionRetentionPolicy {
    static func sessionID(
        afterResetting currentSessionID: String?,
        for intent: AcpStopIntent
    ) -> String? {
        switch intent {
        case .reload: currentSessionID
        case .shutdown: nil
        }
    }
}
