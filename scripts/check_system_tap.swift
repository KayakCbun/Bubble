import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(1)
    }
}

@main
enum SystemTapCheck {
    static func main() {
        expect(
            RecordAudioCaptureAuthorization.serviceName == "kTCCServiceAudioCapture",
            "system-audio TCC is kTCCServiceAudioCapture, not Screen Recording"
        )
        let status = RecordAudioCaptureAuthorization.preflight()
        expect(
            status == .authorized
                || status == .denied
                || status == .undetermined
                || status == .unavailable,
            "preflight returns a known status"
        )

        let capture = try! String(contentsOfFile: "Sources/Bubble/RecordCapture.swift", encoding: .utf8)
        expect(
            capture.contains("RecordAudioCaptureAuthorization.ensure"),
            "Record asks for system-audio TCC before creating the tap"
        )
        expect(
            !capture.contains("kAudioAggregateDeviceMainSubDeviceKey"),
            "Record must not attach the default output as the aggregate main device; that IO proc reads silence"
        )
        expect(
            !capture.contains("kAudioAggregateDeviceSubDeviceListKey"),
            "Record must not put the default output in the aggregate sub-device list"
        )
        expect(
            capture.contains("kAudioAggregateDeviceTapListKey"),
            "Record wraps the process tap in a tap-only aggregate"
        )

        expect(
            RecordAudioCaptureAuthorization.decision(
                preflight: .authorized,
                rememberedAuthorized: false
            ) == .allow,
            "an authorized Mac does not prompt again"
        )
        expect(
            RecordAudioCaptureAuthorization.decision(
                preflight: .undetermined,
                rememberedAuthorized: true
            ) == .allow,
            "a remembered grant does not prompt on the next Record"
        )
        expect(
            RecordAudioCaptureAuthorization.decision(
                preflight: .undetermined,
                rememberedAuthorized: false
            ) == .prompt,
            "the first Record prompts for system-audio TCC"
        )
        expect(
            RecordAudioCaptureAuthorization.decision(
                preflight: .denied,
                rememberedAuthorized: true
            ) == .deny,
            "a denied Mac does not re-prompt; it fails"
        )
        expect(
            RecordAudioCaptureAuthorization.rememberedGrantKey == "bubble.record.systemAudioGranted",
            "the remembered grant lives in Bubble defaults"
        )
        print("system tap checks passed preflight=\(status)")
    }
}
