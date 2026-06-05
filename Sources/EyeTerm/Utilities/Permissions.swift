import AVFoundation
import AppKit
import Speech
import ApplicationServices

enum PermissionStatus: String {
    case granted
    case denied
    case notDetermined
}

struct Permissions {
    static func checkCamera() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestCamera() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func checkMicrophone() -> PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    static func checkAccessibility() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static func openCameraSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    static func checkSpeechRecognition() -> PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    static func requestSpeechRecognition() async -> Bool {
        await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }

    static func openSpeechRecognitionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    // typeApplicationBundleID = 'bund' = 0x62756E64
    // typeWildCard             = '****' = 0x2A2A2A2A
    static func checkAutomation(bundleID: String) -> PermissionStatus {
        var targetDesc = AEDesc()
        guard let data = bundleID.data(using: .utf8) else { return .notDetermined }
        let created = data.withUnsafeBytes { buf in
            AECreateDesc(OSType(0x62756E64), buf.baseAddress, buf.count, &targetDesc)
        }
        guard created == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&targetDesc) }
        let status = AEDeterminePermissionToAutomateTarget(
            &targetDesc, OSType(0x2A2A2A2A), OSType(0x2A2A2A2A), false
        )
        switch status {
        case noErr:           return .granted
        case OSStatus(-1743): return .denied   // errAEEventNotPermitted
        default:              return .notDetermined
        }
    }

    static func requestAutomation(bundleID: String) {
        var targetDesc = AEDesc()
        guard let data = bundleID.data(using: .utf8) else { return }
        let created = data.withUnsafeBytes { buf in
            AECreateDesc(OSType(0x62756E64), buf.baseAddress, buf.count, &targetDesc)
        }
        guard created == noErr else { return }
        defer { AEDisposeDesc(&targetDesc) }
        _ = AEDeterminePermissionToAutomateTarget(
            &targetDesc, OSType(0x2A2A2A2A), OSType(0x2A2A2A2A), true
        )
    }

    static func requestAllPermissions() async -> (camera: Bool, microphone: Bool) {
        async let cam = requestCamera()
        async let mic = requestMicrophone()
        requestAccessibility()
        return (await cam, await mic)
    }
}
