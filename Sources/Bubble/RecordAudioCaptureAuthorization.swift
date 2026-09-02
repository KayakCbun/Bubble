import Darwin
import Foundation

enum RecordAudioCaptureAuthorization {
    enum Status: Equatable, CustomStringConvertible {
        case authorized
        case denied
        case undetermined
        case unavailable

        var description: String {
            switch self {
            case .authorized: "authorized"
            case .denied: "denied"
            case .undetermined: "undetermined"
            case .unavailable: "unavailable"
            }
        }
    }

    enum Decision: Equatable {
        case allow
        case deny
        case prompt
    }

    static let serviceName = "kTCCServiceAudioCapture"
    static let rememberedGrantKey = "bubble.record.systemAudioGranted"

    static func decision(preflight: Status, rememberedAuthorized: Bool) -> Decision {
        switch preflight {
        case .authorized, .unavailable:
            return .allow
        case .denied:
            return .deny
        case .undetermined:
            return rememberedAuthorized ? .allow : .prompt
        }
    }

    static func preflight() -> Status {
        guard let preflight = preflightSPI else { return .unavailable }
        switch preflight(serviceName as CFString, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    static func ensure() async -> Status {
        let current = preflight()
        switch decision(preflight: current, rememberedAuthorized: rememberedAuthorized) {
        case .allow:
            if current == .authorized {
                rememberedAuthorized = true
            }
            return current == .unavailable ? .unavailable : .authorized
        case .deny:
            rememberedAuthorized = false
            return .denied
        case .prompt:
            let granted = await request()
            if granted {
                rememberedAuthorized = true
                return .authorized
            }
            let after = preflight()
            if after == .authorized {
                rememberedAuthorized = true
                return .authorized
            }
            if after == .denied {
                rememberedAuthorized = false
                return .denied
            }
            return .undetermined
        }
    }

    static func rememberAuthorized() {
        rememberedAuthorized = true
    }

    static func forgetAuthorized() {
        rememberedAuthorized = false
    }

    static var rememberedAuthorized: Bool {
        get { UserDefaults.standard.bool(forKey: rememberedGrantKey) }
        set { UserDefaults.standard.set(newValue, forKey: rememberedGrantKey) }
    }

    static func request() async -> Bool {
        if preflight() == .authorized { return true }
        guard let request = requestSPI else { return false }
        return await withCheckedContinuation { continuation in
            let resume: (Bool) -> Void = { granted in
                continuation.resume(returning: granted)
            }
            let work = {
                var resumed = false
                request(serviceName as CFString, nil) { granted in
                    guard !resumed else { return }
                    resumed = true
                    resume(granted)
                }
            }
            if Thread.isMainThread {
                work()
            } else {
                DispatchQueue.main.async {
                    work()
                }
            }
        }
    }

    private typealias PreflightSPI = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestSPI = @convention(c) (CFString, CFDictionary?, @escaping (Bool) -> Void) -> Void

    private static let handle: UnsafeMutableRawPointer? = {
        dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    }()

    private static let preflightSPI: PreflightSPI? = symbol("TCCAccessPreflight")
    private static let requestSPI: RequestSPI? = symbol("TCCAccessRequest")

    private static func symbol<T>(_ name: String) -> T? {
        guard let handle, let sym = dlsym(handle, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}
