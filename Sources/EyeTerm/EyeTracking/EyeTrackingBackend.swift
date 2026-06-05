import AVFoundation
import CoreGraphics

enum TrackingBackend: String, CaseIterable, Identifiable {
    case mediaPipe = "MediaPipe"
    case appleVision = "Apple Vision"

    var id: String { rawValue }
}

protocol EyeTrackingBackend: AnyObject {
    var isRunning: Bool { get }
    var activeCaptureSession: AVCaptureSession? { get }

    var onEyeUpdate: ((CGPoint?, Double) -> Void)? { get set }
    var onRawEyePoint: ((CGPoint) -> Void)? { get set }
    var onCalibratedEyePoint: ((CGPoint) -> Void)? { get set }
    var onSmoothedEyePoint: ((CGPoint) -> Void)? { get set }
    var onDiagnostics: ((EyeTermDiagnostics) -> Void)? { get set }
    var onFaceObservation: ((FaceObservationData?) -> Void)? { get set }

    var smoothingAlpha: Double { get set }
    var headWeight: Double { get set }
    var headPitchSensitivity: Double { get set }
    var parallaxCorrX: Double { get set }
    var parallaxCorrY: Double { get set }
    var headAmplification: Double { get set }
    var headCalibrationTransform: CGAffineTransform? { get set }
    var pupilCalibrationTransform: CGAffineTransform? { get set }

    func start() throws
    func stop()
}
