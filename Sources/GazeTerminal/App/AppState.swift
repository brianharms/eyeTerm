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

    // MARK: - Terminal
    var isTerminalSetup = false
    var focusedQuadrant: ScreenQuadrant?

    // MARK: - Settings
    var trackingBackend: TrackingBackend = .mediaPipe
    var dwellTimeThreshold: TimeInterval = 1.0
    var hysteresisDelay: TimeInterval = 0.3
    var whisperModel: String = "small.en"
    var enableTextNormalization = true
    var executeKeyword: String = "run it"
    var gazeSmoothing: Double = 0.3
    var headWeight: Double = 0.85
    var overlayMode: OverlayMode = .off

    // MARK: - Eye Tracking Points (for overlay)
    var rawGazePoint: CGPoint = .zero
    var calibratedGazePoint: CGPoint = .zero
    var smoothedGazePoint: CGPoint = .zero

    // MARK: - Eye Tracking Diagnostics
    var headYaw: Double = 0
    var headPitch: Double = 0
    var pupilOffsetX: Double = 0
    var pupilOffsetY: Double = 0

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
}
