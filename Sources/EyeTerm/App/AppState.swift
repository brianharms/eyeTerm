import SwiftUI
import AppKit
import AVFoundation
import CoreGraphics

@Observable
final class AppState {
    // MARK: - Eye Tracking
    var isEyeTrackingActive = false
    var activeSlot: Int? = nil
    var eyeConfidence: Double = 0
    var isCalibrated = false
    var calibrationSamples: Int = 0

    // MARK: - Voice
    var isVoiceActive = false
    var lastTranscription = ""
    var isProcessingVoice = false
    var audioLevel: Float = 0
    var isSpeaking = false
    var audioLevelHistory: [Float] = Array(repeating: 0, count: 27)
    var voiceModelState: VoiceModelState = .idle

    // MARK: - Terminal
    var isTerminalSetup = false
    var focusedSlot: Int? = nil
    var dwellingSlot: Int? = nil
    var terminalSlots: [TerminalSlot] = []
    var terminalGridColumns: Int = 2
    var terminalGridRows: Int = 2
    var preferredTerminal: PreferredTerminal = .iTerm2
    var terminalLaunchCommand: String = "claude --dangerously-skip-permissions"
    var terminalSetupMode: TerminalSetupMode = .adoptExisting
    var selectedProjectFolders: [URL] = []
    var claudeInitialPrompt: String = ""
    var claudeInitialPromptStagger: Double = 2.0
    var renameWindowsToProjectName: Bool = true

    // MARK: - Dwell Progress
    var dwellProgress: Double = 0

    // MARK: - Settings
    var trackingBackend: TrackingBackend = .mediaPipe
    var voiceBackend: VoiceBackend = .sfSpeech
    var dwellTimeThreshold: TimeInterval = 1.0
    var hysteresisDelay: TimeInterval = 0.3
    var whisperModel: String = "small.en"
    var enableTextNormalization = true
    var executeKeyword: String = "run it"
    var eyeSmoothing: Double = 0.3
    var headWeight: Double = 0.85
    var headPitchSensitivity: Double = 0.6
    var parallaxCorrX: Double = 0.0
    var parallaxCorrY: Double = 0.0
    var headAmplification: Double = 3.0
    var overlayMode: OverlayMode = .subtle
    var debugSmoothing: Double = 0.15
    var micSensitivity: Double = 0.01
    var selectedMicDeviceUID: String = ""   // empty = system default
    var availableMics: [(uid: String, name: String)] = []
    var selectedCameraDeviceID: String = ""  // empty = system default
    var availableCameras: [(uid: String, name: String)] = []
    var selectedDisplayID: CGDirectDisplayID = CGMainDisplayID()
    var availableDisplays: [(id: CGDirectDisplayID, name: String)] = []
    var overlayIconSize: Double = 1.0
    var fusionDotSize: Double = 6.0
    var smoothedCircleSize: Double = 12.0
    var showRawOverlay: Bool = true
    var showCalibratedOverlay: Bool = true
    var showSmoothedOverlay: Bool = true
    var showQuadrantHighlighting: Bool = true
    var showActiveState: Bool = true
    var debugLineWidth: Double = 1.0
    var subtleEyeSize: Double = 20.0
    var subtleEyeOpacity: Double = 0.25
    var quadrantBorderWidth: Double = 2.0
    var showDebugBackdrop: Bool = false
    var showDictationDisplay: Bool = false
    var showWinkOverlay: Bool = false
    var showCommandFlash: Bool = false

    // MARK: - Wink / Command Flash Display (not persisted beyond session)
    var lastWinkDisplay: String? = nil
    var lastCommandFlash: String? = nil

    // MARK: - Window Actions
    var windowActionsEnabled: Bool = true

    // MARK: - Blink Gestures
    var blinkGesturesEnabled: Bool = true
    var winkClosedThreshold: Double = 0.15
    var winkOpenThreshold: Double = 0.25
    var leftWinkAction: WinkAction = .doubleEscape
    var rightWinkAction: WinkAction = .enter
    var minWinkDuration: Double = 0.2
    var maxWinkDuration: Double = 0.5
    var bilateralRejectWindow: Double = 0.1
    var winkCooldown: Double = 0.8
    var winkDipThreshold: Double = 0.3

    // MARK: - Blink Gesture Diagnostics (not persisted)
    var leftEyeAperture: Double = 0
    var rightEyeAperture: Double = 0
    var lastWinkEvent: WinkEvent?
    var winkDiagnosticLog: [WinkDiagnosticEvent] = []

    // MARK: - Transcription History
    var slotPartialTranscriptions: [Int: String] = [:]
    var transcriptionHistory: [(text: String, cleaned: String, timestamp: Date)] = []

    /// Set or clear a partial transcription for a slot. Uses full reassignment
    /// so @Observable property setter fires and SwiftUI re-renders.
    func setPartial(_ text: String?, forSlot slot: Int) {
        var updated = slotPartialTranscriptions
        if let text, !text.isEmpty {
            updated[slot] = text
        } else {
            updated.removeValue(forKey: slot)
        }
        slotPartialTranscriptions = updated
    }

    func clearAllPartials() {
        slotPartialTranscriptions = [:]
    }

    // MARK: - Eye Tracking Points (for overlay)
    var rawEyePoint: CGPoint = .zero
    var calibratedEyePoint: CGPoint = .zero
    var smoothedEyePoint: CGPoint = .zero

    // MARK: - Eye Tracking Diagnostics
    var headYaw: Double = 0
    var headPitch: Double = 0
    var pupilOffsetX: Double = 0
    var pupilOffsetY: Double = 0
    var headEyePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var pupilEyePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var calibratedHeadEyePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var calibratedPupilEyePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)

    // MARK: - Camera Preview
    var isCameraPreviewVisible = false
    var faceObservationData: FaceObservationData?
    var showCameraEyeVisualization: Bool = true
    var showCameraDebugOverlay: Bool = false

    // MARK: - Status
    var statusMessage = "Idle"
    var errors: [String] = []

    func addError(_ message: String) {
        errors.append(message)
        if errors.count > 20 {
            errors.removeFirst()
        }
    }

    func clearErrors() {
        errors.removeAll()
    }

    func appendWinkDiagnostic(_ event: WinkDiagnosticEvent) {
        winkDiagnosticLog.append(event)
        if winkDiagnosticLog.count > 8 {
            winkDiagnosticLog.removeFirst(winkDiagnosticLog.count - 8)
        }
    }

    func refreshAvailableDisplays() {
        availableDisplays = NSScreen.screens.compactMap { screen in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            return (id: id, name: screen.localizedName)
        }
        if !availableDisplays.contains(where: { $0.id == selectedDisplayID }) {
            selectedDisplayID = CGMainDisplayID()
        }
    }

    func refreshAvailableCameras() {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        )
        availableCameras = session.devices.map { (uid: $0.uniqueID, name: $0.localizedName) }

        // If selected camera is not connected, fall back to built-in.
        let selectedExists = !selectedCameraDeviceID.isEmpty &&
            session.devices.contains(where: { $0.uniqueID == selectedCameraDeviceID })
        if !selectedExists,
           let builtin = session.devices.first(where: { $0.deviceType == .builtInWideAngleCamera }) {
            selectedCameraDeviceID = builtin.uniqueID
        }
    }

    /// Writes current tunable settings to a JSON file in the project source tree.
    /// Claude reads this file and patches the hardcoded defaults in AppState.swift.
    #if DEBUG
    func saveSettingsAsDefaults() {
        let settings: [String: Any] = [
            "trackingBackend": trackingBackend.rawValue,
            "voiceBackend": voiceBackend.rawValue,
            "dwellTimeThreshold": dwellTimeThreshold,
            "hysteresisDelay": hysteresisDelay,
            "whisperModel": whisperModel,
            "enableTextNormalization": enableTextNormalization,
            "executeKeyword": executeKeyword,
            "eyeSmoothing": eyeSmoothing,
            "headWeight": headWeight,
            "headPitchSensitivity": headPitchSensitivity,
            "parallaxCorrX": parallaxCorrX,
            "parallaxCorrY": parallaxCorrY,
            "headAmplification": headAmplification,
            "debugSmoothing": debugSmoothing,
            "micSensitivity": micSensitivity,
            "selectedMicDeviceUID": selectedMicDeviceUID,
            "overlayIconSize": overlayIconSize,
            "fusionDotSize": fusionDotSize,
            "smoothedCircleSize": smoothedCircleSize,
            "showRawOverlay": showRawOverlay,
            "showCalibratedOverlay": showCalibratedOverlay,
            "showSmoothedOverlay": showSmoothedOverlay,
            "showQuadrantHighlighting": showQuadrantHighlighting,
            "showActiveState": showActiveState,
            "subtleEyeSize": subtleEyeSize,
            "subtleEyeOpacity": subtleEyeOpacity,
            "quadrantBorderWidth": quadrantBorderWidth,
            "debugLineWidth": debugLineWidth,
            "preferredTerminal": preferredTerminal.rawValue,
            "terminalLaunchCommand": terminalLaunchCommand,
            "blinkGesturesEnabled": blinkGesturesEnabled,
            "winkClosedThreshold": winkClosedThreshold,
            "winkOpenThreshold": winkOpenThreshold,
            "leftWinkAction": leftWinkAction.rawValue,
            "rightWinkAction": rightWinkAction.rawValue,
            "minWinkDuration": minWinkDuration,
            "maxWinkDuration": maxWinkDuration,
            "bilateralRejectWindow": bilateralRejectWindow,
            "winkCooldown": winkCooldown,
            "windowActionsEnabled": windowActionsEnabled,
            "terminalSetupMode": terminalSetupMode.rawValue,
            "showDebugBackdrop": showDebugBackdrop,
            "showDictationDisplay": showDictationDisplay,
            "showWinkOverlay": showWinkOverlay,
            "showCommandFlash": showCommandFlash,
            "winkDipThreshold": winkDipThreshold,
            "selectedCameraDeviceID": selectedCameraDeviceID,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }

        let url = URL(fileURLWithPath: NSHomeDirectory() + "/Desktop/eyeTerm-saved-defaults.json")
        try? data.write(to: url)

        // Also persist to Application Support so settings survive rebuilds
        persistSettings()
    }
    #endif

    // MARK: - Runtime Persistence (Application Support)

    private static var settingsFileURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("eyeTerm")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json")
    }

    func persistSettings() {
        let settings: [String: Any] = [
            "trackingBackend": trackingBackend.rawValue,
            "voiceBackend": voiceBackend.rawValue,
            "dwellTimeThreshold": dwellTimeThreshold,
            "hysteresisDelay": hysteresisDelay,
            "whisperModel": whisperModel,
            "enableTextNormalization": enableTextNormalization,
            "executeKeyword": executeKeyword,
            "eyeSmoothing": eyeSmoothing,
            "headWeight": headWeight,
            "headPitchSensitivity": headPitchSensitivity,
            "parallaxCorrX": parallaxCorrX,
            "parallaxCorrY": parallaxCorrY,
            "headAmplification": headAmplification,
            "debugSmoothing": debugSmoothing,
            "micSensitivity": micSensitivity,
            "selectedMicDeviceUID": selectedMicDeviceUID,
            "overlayIconSize": overlayIconSize,
            "fusionDotSize": fusionDotSize,
            "smoothedCircleSize": smoothedCircleSize,
            "showRawOverlay": showRawOverlay,
            "showCalibratedOverlay": showCalibratedOverlay,
            "showSmoothedOverlay": showSmoothedOverlay,
            "showQuadrantHighlighting": showQuadrantHighlighting,
            "showActiveState": showActiveState,
            "subtleEyeSize": subtleEyeSize,
            "subtleEyeOpacity": subtleEyeOpacity,
            "quadrantBorderWidth": quadrantBorderWidth,
            "debugLineWidth": debugLineWidth,
            "preferredTerminal": preferredTerminal.rawValue,
            "terminalLaunchCommand": terminalLaunchCommand,
            "blinkGesturesEnabled": blinkGesturesEnabled,
            "winkClosedThreshold": winkClosedThreshold,
            "winkOpenThreshold": winkOpenThreshold,
            "leftWinkAction": leftWinkAction.rawValue,
            "rightWinkAction": rightWinkAction.rawValue,
            "minWinkDuration": minWinkDuration,
            "maxWinkDuration": maxWinkDuration,
            "bilateralRejectWindow": bilateralRejectWindow,
            "winkCooldown": winkCooldown,
            "windowActionsEnabled": windowActionsEnabled,
            "terminalSetupMode": terminalSetupMode.rawValue,
            "showDebugBackdrop": showDebugBackdrop,
            "showDictationDisplay": showDictationDisplay,
            "showWinkOverlay": showWinkOverlay,
            "showCommandFlash": showCommandFlash,
            "winkDipThreshold": winkDipThreshold,
            "selectedProjectFolders": selectedProjectFolders.map { $0.path },
            "claudeInitialPrompt": claudeInitialPrompt,
            "claudeInitialPromptStagger": claudeInitialPromptStagger,
            "renameWindowsToProjectName": renameWindowsToProjectName,
            "selectedCameraDeviceID": selectedCameraDeviceID,
        ]
        // Include calibration transforms from UserDefaults so they survive reinstalls.
        var mutable = settings
        let calibKeys = ["HeadCalibrationTransform", "PupilCalibrationTransform", "ParallaxCorrX", "ParallaxCorrY"]
        for key in calibKeys {
            if let v = UserDefaults.standard.object(forKey: key) { mutable[key] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: mutable, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: Self.settingsFileURL)
    }

    func loadPersistedSettings() {
        guard let data = try? Data(contentsOf: Self.settingsFileURL),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        if let v = dict["trackingBackend"] as? String, let e = TrackingBackend(rawValue: v) { trackingBackend = e }
        if let v = dict["voiceBackend"] as? String, let e = VoiceBackend(rawValue: v) { voiceBackend = e }
        if let v = dict["dwellTimeThreshold"] as? Double { dwellTimeThreshold = v }
        if let v = dict["hysteresisDelay"] as? Double { hysteresisDelay = v }
        if let v = dict["whisperModel"] as? String { whisperModel = v }
        if let v = dict["enableTextNormalization"] as? Bool { enableTextNormalization = v }
        if let v = dict["executeKeyword"] as? String { executeKeyword = v }
        if let v = dict["eyeSmoothing"] as? Double { eyeSmoothing = v }
        if let v = dict["headWeight"] as? Double { headWeight = v }
        if let v = dict["headPitchSensitivity"] as? Double { headPitchSensitivity = v }
        if let v = dict["parallaxCorrX"] as? Double { parallaxCorrX = v }
        if let v = dict["parallaxCorrY"] as? Double { parallaxCorrY = v }
        if let v = dict["headAmplification"] as? Double { headAmplification = v }
        if let v = dict["debugSmoothing"] as? Double { debugSmoothing = v }
        if let v = dict["micSensitivity"] as? Double { micSensitivity = v }
        if let v = dict["selectedMicDeviceUID"] as? String { selectedMicDeviceUID = v }
        if let v = dict["selectedCameraDeviceID"] as? String { selectedCameraDeviceID = v }
        if let v = dict["overlayIconSize"] as? Double { overlayIconSize = v }
        if let v = dict["fusionDotSize"] as? Double { fusionDotSize = v }
        if let v = dict["smoothedCircleSize"] as? Double { smoothedCircleSize = v }
        if let v = dict["showRawOverlay"] as? Bool { showRawOverlay = v }
        if let v = dict["showCalibratedOverlay"] as? Bool { showCalibratedOverlay = v }
        if let v = dict["showSmoothedOverlay"] as? Bool { showSmoothedOverlay = v }
        if let v = dict["showQuadrantHighlighting"] as? Bool { showQuadrantHighlighting = v }
        if let v = dict["showActiveState"] as? Bool { showActiveState = v }
        if let v = dict["subtleEyeSize"] as? Double { subtleEyeSize = v }
        if let v = dict["subtleEyeOpacity"] as? Double { subtleEyeOpacity = v }
        if let v = dict["quadrantBorderWidth"] as? Double { quadrantBorderWidth = v }
        if let v = dict["debugLineWidth"] as? Double { debugLineWidth = v }
        if let v = dict["preferredTerminal"] as? String, let e = PreferredTerminal(rawValue: v) { preferredTerminal = e }
        if let v = dict["terminalLaunchCommand"] as? String { terminalLaunchCommand = v }
        if let v = dict["blinkGesturesEnabled"] as? Bool { blinkGesturesEnabled = v }
        if let v = dict["winkClosedThreshold"] as? Double { winkClosedThreshold = v }
        if let v = dict["winkOpenThreshold"] as? Double { winkOpenThreshold = v }
        if let v = dict["leftWinkAction"] as? String, let e = WinkAction(rawValue: v) { leftWinkAction = e }
        if let v = dict["rightWinkAction"] as? String, let e = WinkAction(rawValue: v) { rightWinkAction = e }
        if let v = dict["minWinkDuration"] as? Double { minWinkDuration = v }
        if let v = dict["maxWinkDuration"] as? Double { maxWinkDuration = v }
        if let v = dict["bilateralRejectWindow"] as? Double { bilateralRejectWindow = v }
        if let v = dict["winkCooldown"] as? Double { winkCooldown = v }
        if let v = dict["windowActionsEnabled"] as? Bool { windowActionsEnabled = v }
        if let v = dict["terminalSetupMode"] as? String, let e = TerminalSetupMode(rawValue: v) { terminalSetupMode = e }
        if let v = dict["showDebugBackdrop"] as? Bool { showDebugBackdrop = v }
        if let v = dict["showDictationDisplay"] as? Bool { showDictationDisplay = v }
        if let v = dict["showWinkOverlay"] as? Bool { showWinkOverlay = v }
        if let v = dict["showCommandFlash"] as? Bool { showCommandFlash = v }
        if let v = dict["winkDipThreshold"] as? Double { winkDipThreshold = v }
        if let v = dict["selectedProjectFolders"] as? [String] { selectedProjectFolders = v.map { URL(fileURLWithPath: $0) } }
        if let v = dict["claudeInitialPrompt"] as? String { claudeInitialPrompt = v }
        if let v = dict["claudeInitialPromptStagger"] as? Double { claudeInitialPromptStagger = v }
        if let v = dict["renameWindowsToProjectName"] as? Bool { renameWindowsToProjectName = v }

        // Restore calibration transforms back to UserDefaults so CalibrationManager
        // picks them up on next launch (it reads from UserDefaults on init).
        if let v = dict["HeadCalibrationTransform"] { UserDefaults.standard.set(v, forKey: "HeadCalibrationTransform") }
        if let v = dict["PupilCalibrationTransform"] { UserDefaults.standard.set(v, forKey: "PupilCalibrationTransform") }
        if let v = dict["ParallaxCorrX"] as? Double { UserDefaults.standard.set(v, forKey: "ParallaxCorrX") }
        if let v = dict["ParallaxCorrY"] as? Double { UserDefaults.standard.set(v, forKey: "ParallaxCorrY") }
    }
}

struct TerminalSlot: Identifiable, Codable {
    let id: Int
    var normalizedRect: CGRect
    var label: String

    private enum CodingKeys: String, CodingKey {
        case id, normalizedRect, label
    }

    init(id: Int, normalizedRect: CGRect, label: String) {
        self.id = id
        self.normalizedRect = normalizedRect
        self.label = label
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        let arr = try c.decode([Double].self, forKey: .normalizedRect)
        normalizedRect = arr.count == 4
            ? CGRect(x: arr[0], y: arr[1], width: arr[2], height: arr[3])
            : .zero
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode([normalizedRect.origin.x, normalizedRect.origin.y,
                      normalizedRect.size.width, normalizedRect.size.height],
                     forKey: .normalizedRect)
    }
}

enum WinkAction: String, CaseIterable, Identifiable {
    case doubleEscape = "Double Escape"
    case enter = "Enter"
    case singleEscape = "Escape"
    case none = "None"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .doubleEscape: return "Esc Esc"
        case .enter: return "Enter"
        case .singleEscape: return "Esc"
        case .none: return "None"
        }
    }
}

enum TerminalSetupMode: String, CaseIterable, Identifiable {
    case launchNew = "Create New"
    case adoptExisting = "Use Existing"
    case chooseProjects = "Choose Projects"

    var id: String { rawValue }
}

struct WinkEvent {
    enum Side { case left, right }
    let side: Side
    let action: WinkAction
    let timestamp: Date
}
