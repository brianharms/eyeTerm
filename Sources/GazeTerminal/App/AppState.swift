import SwiftUI

@Observable
final class AppState {
    // MARK: - Eye Tracking
    var isEyeTrackingActive = false
    var activeQuadrant: ScreenQuadrant?
    var gazeConfidence: Double = 0
    var isCalibrated = false
    var calibrationSamples: Int = 0

    // MARK: - Voice
    var isVoiceActive = false
    var lastTranscription = ""
    var isProcessingVoice = false
    var audioLevel: Float = 0
    var isSpeaking = false
    var audioLevelHistory: [Float] = Array(repeating: 0, count: 21)
    var voiceModelState: VoiceModelState = .idle

    // MARK: - Terminal
    var isTerminalSetup = false
    var focusedQuadrant: ScreenQuadrant?
    var preferredTerminal: PreferredTerminal = .iTerm2
    var terminalLaunchCommand: String = "claude --dangerously-skip-permissions"

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
    var gazeSmoothing: Double = 0.3
    var headWeight: Double = 0.85
    var overlayMode: OverlayMode = .off
    var debugSmoothing: Double = 0.15
    var micSensitivity: Double = 0.01
    var overlayIconSize: Double = 1.0
    var fusionDotSize: Double = 6.0
    var smoothedCircleSize: Double = 12.0
    var showRawOverlay: Bool = true
    var showCalibratedOverlay: Bool = true
    var showSmoothedOverlay: Bool = true
    var debugLineWidth: Double = 1.0
    var subtleGazeSize: Double = 20.0
    var subtleGazeOpacity: Double = 0.25

    // MARK: - Transcription History
    var transcriptionHistory: [(text: String, timestamp: Date)] = []

    // MARK: - Eye Tracking Points (for overlay)
    var rawGazePoint: CGPoint = .zero
    var calibratedGazePoint: CGPoint = .zero
    var smoothedGazePoint: CGPoint = .zero

    // MARK: - Eye Tracking Diagnostics
    var headYaw: Double = 0
    var headPitch: Double = 0
    var pupilOffsetX: Double = 0
    var pupilOffsetY: Double = 0
    var headGazePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var pupilGazePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var calibratedHeadGazePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var calibratedPupilGazePoint: CGPoint = CGPoint(x: 0.5, y: 0.5)

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
            "gazeSmoothing": gazeSmoothing,
            "headWeight": headWeight,
            "overlayMode": overlayMode.rawValue,
            "debugSmoothing": debugSmoothing,
            "micSensitivity": micSensitivity,
            "overlayIconSize": overlayIconSize,
            "fusionDotSize": fusionDotSize,
            "smoothedCircleSize": smoothedCircleSize,
            "showRawOverlay": showRawOverlay,
            "showCalibratedOverlay": showCalibratedOverlay,
            "showSmoothedOverlay": showSmoothedOverlay,
            "subtleGazeSize": subtleGazeSize,
            "subtleGazeOpacity": subtleGazeOpacity,
            "debugLineWidth": debugLineWidth,
            "preferredTerminal": preferredTerminal.rawValue,
            "terminalLaunchCommand": terminalLaunchCommand,
        ]

        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys]) else { return }

        let url = URL(fileURLWithPath: "/Users/brianharms/Desktop/Remote Projects/GazeTerminal/Sources/GazeTerminal/saved-defaults.json")
        try? data.write(to: url)
    }
}
