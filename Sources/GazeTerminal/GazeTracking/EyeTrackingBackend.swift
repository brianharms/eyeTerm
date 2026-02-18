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

    var onGazeUpdate: ((ScreenQuadrant?, Double) -> Void)? { get set }
    var onRawGazePoint: ((CGPoint) -> Void)? { get set }
    var onCalibratedGazePoint: ((CGPoint) -> Void)? { get set }
    var onSmoothedGazePoint: ((CGPoint) -> Void)? { get set }
    var onDiagnostics: ((EyeTermDiagnostics) -> Void)? { get set }
    var onFaceObservation: ((FaceObservationData?) -> Void)? { get set }

    var smoothingAlpha: Double { get set }
    var headWeight: Double { get set }
    var calibrationTransform: CGAffineTransform? { get set }

    func start() throws
    func stop()
}
