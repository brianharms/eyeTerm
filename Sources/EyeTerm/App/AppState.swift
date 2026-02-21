import SwiftUI

@Observable
final class AppState {
    // MARK: - Eye Tracking
    var isEyeTrackingActive = false
    var activeQuadrant: ScreenQuadrant?
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
    var focusedQuadrant: ScreenQuadrant?
    var preferredTerminal: PreferredTerminal = .iTerm2
    var terminalLaunchCommand: String = "claude --dangerously-skip-permissions"
    var terminalSetupMode: TerminalSetupMode = .adoptExisting

    // MARK: - Dwell Progress
    var dwellingQuadrant: ScreenQuadrant?
    var dwellProgress: Double = 0

    // MARK: - Settings
    var trackingBackend: TrackingBackend = .mediaPipe
    var voiceBackend: VoiceBackend = .whisperKit
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
    var overlayMode: OverlayMode = .off
    var debugSmoothing: Double = 0.15
    var micSensitivity: Double = 0.01
    var selectedMicDeviceUID: String = ""   // empty = system default
    var availableMics: [(uid: String, name: String)] = []
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

    // MARK: - Blink Gesture Diagnostics (not persisted)
    var leftEyeAperture: Double = 0
    var rightEyeAperture: Double = 0
    var lastWinkEvent: WinkEvent?

    // MARK: - Transcription History
    var partialTranscription: String = ""
    var transcriptionHistory: [(text: String, cleaned: String, timestamp: Date)] = []

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

    /// Writes current tunable settings to a JSON file in the project source tree.
    /// Claude reads this file and patches the hardcoded defaults in AppState.swift.
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
            "overlayMode": overlayMode.rawValue,
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
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }

        let url = URL(fileURLWithPath: "/Users/brianharms/Desktop/Claude Projects/eyeTerm/Sources/EyeTerm/saved-defaults.json")
        try? data.write(to: url)
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

    var id: String { rawValue }
}

struct WinkEvent {
    enum Side { case left, right }
    let side: Side
    let action: WinkAction
    let timestamp: Date
}
