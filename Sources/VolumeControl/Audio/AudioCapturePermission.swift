import AppKit

/// Wraps the private TCC calls for the "Audio Recording" permission that process taps require.
/// There is no public API to check this permission ahead of time; if TCC can't be loaded we report `.unavailable`.
enum AudioCapturePermission {
    enum Status: Equatable {
        case authorized
        case denied
        case undetermined
        case unavailable
    }

    private typealias PreflightFunction = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias RequestFunction = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private nonisolated(unsafe) static let handle = dlopen(
        "/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC",
        RTLD_NOW
    )

    private static var service: CFString { "kTCCServiceAudioCapture" as CFString }

    static var status: Status {
        guard let handle, let symbol = dlsym(handle, "TCCAccessPreflight") else { return .unavailable }
        let preflight = unsafeBitCast(symbol, to: PreflightFunction.self)
        switch preflight(service, nil) {
        case 0: return .authorized
        case 1: return .denied
        default: return .undetermined
        }
    }

    static func request(completion: @escaping @Sendable (Bool) -> Void) {
        guard let handle, let symbol = dlsym(handle, "TCCAccessRequest") else {
            completion(true)
            return
        }
        let request = unsafeBitCast(symbol, to: RequestFunction.self)
        request(service, nil) { granted in completion(granted) }
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
        NSWorkspace.shared.open(url)
    }
}
