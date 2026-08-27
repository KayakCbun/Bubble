import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
private enum SessionReloadCheck {
    static func main() {
        expect(
            AcpSessionRetentionPolicy.sessionID(
                afterResetting: "session-a",
                for: .reload
            ) == "session-a",
            "/reload preserves the current main or side session identity"
        )
        expect(
            AcpSessionRetentionPolicy.sessionID(
                afterResetting: "session-a",
                for: .shutdown
            ) == nil,
            "normal shutdown still clears the in-memory session identity"
        )
        print("PASS: session reload identity")
    }
}
