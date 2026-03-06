import AVFoundation
import Vision
import CoreGraphics

struct FaceObservationData {
    let boundingBox: CGRect
    let leftEyePoints: [CGPoint]
    let rightEyePoints: [CGPoint]
    let leftPupilCenter: CGPoint?
    let rightPupilCenter: CGPoint?
    let yaw: Double?
    let pitch: Double?
    let leftEyeAperture: Double?
    let rightEyeAperture: Double?
    /// Ordered groups of face mesh contour polylines (face oval, eyebrows, nose, lips).
    /// Empty for the Apple Vision backend; populated by MediaPipe.
    let faceMeshContours: [[CGPoint]]

    init(boundingBox: CGRect,
         leftEyePoints: [CGPoint],
         rightEyePoints: [CGPoint],
         leftPupilCenter: CGPoint?,
         rightPupilCenter: CGPoint?,
         yaw: Double?,
         pitch: Double?,
         leftEyeAperture: Double?,
         rightEyeAperture: Double?,
         faceMeshContours: [[CGPoint]] = []) {
        self.boundingBox = boundingBox
        self.leftEyePoints = leftEyePoints
        self.rightEyePoints = rightEyePoints
        self.leftPupilCenter = leftPupilCenter
        self.rightPupilCenter = rightPupilCenter
        self.yaw = yaw
        self.pitch = pitch
        self.leftEyeAperture = leftEyeAperture
        self.rightEyeAperture = rightEyeAperture
        self.faceMeshContours = faceMeshContours
    }

    /// Compute Eye Aperture Ratio from contour points: vertical extent / horizontal extent.
    static func eyeApertureRatio(_ points: [CGPoint]) -> Double? {
        guard points.count >= 4 else { return nil }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let width = Double(xs.max()! - xs.min()!)
        guard width > 0 else { return nil }
        let height = Double(ys.max()! - ys.min()!)
        return height / width
    }
}

final class EyeTermTracker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, EyeTrackingBackend {

    var onEyeUpdate: ((CGPoint?, Double) -> Void)?
    var onRawEyePoint: ((CGPoint) -> Void)?
    var onCalibratedEyePoint: ((CGPoint) -> Void)?
    var onSmoothedEyePoint: ((CGPoint) -> Void)?
    var onDiagnostics: ((EyeTermDiagnostics) -> Void)?
    var onFaceObservation: ((FaceObservationData?) -> Void)?

    var smoothingAlpha: Double {
        get { emaFilter.alpha }
        set { emaFilter.alpha = newValue }
    }

    var headWeight: Double {
        get { estimator.headWeight }
        set { estimator.headWeight = newValue }
    }

    var headPitchSensitivity: Double {
        get { estimator.headPitchSensitivity }
        set { estimator.headPitchSensitivity = newValue }
    }

    var parallaxCorrX: Double {
        get { estimator.parallaxCorrX }
        set { estimator.parallaxCorrX = newValue }
    }

    var parallaxCorrY: Double {
        get { estimator.parallaxCorrY }
        set { estimator.parallaxCorrY = newValue }
    }

    var headAmplification: Double {
        get { estimator.headAmplification }
        set { estimator.headAmplification = newValue }
    }

    /// Directly-resolved camera device set by AppCoordinator via DiscoverySession lookup.
    /// When nil, start() falls back to the built-in front camera only (no external fallback).
    var selectedCaptureDevice: AVCaptureDevice?

    private(set) var isRunning = false

    /// Read-only access to the capture session for camera preview.
    var activeCaptureSession: AVCaptureSession? { captureSession }

    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "com.eyeterm.tracker", qos: .userInteractive)
    private let estimator = EyeTermEstimator()
    private var emaFilter = EyeTermEMAFilter()

    // MARK: - Calibration

    var headCalibrationTransform: CGAffineTransform? {
        get { estimator.headCalibrationTransform }
        set { estimator.headCalibrationTransform = newValue }
    }

    var pupilCalibrationTransform: CGAffineTransform? {
        get { estimator.pupilCalibrationTransform }
        set { estimator.pupilCalibrationTransform = newValue }
    }

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        // Use the coordinator-resolved device object.
        // If none was provided, find the built-in front camera — deliberately NO fallback to
        // AVCaptureDevice.default(for:) which would silently pick an external camera (e.g. Logitech).
        let camera: AVCaptureDevice
        if let preset = selectedCaptureDevice {
            camera = preset
        } else {
            guard let builtin =
                AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
                ?? AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
            else {
                throw EyeTermTrackerError.cameraNotAvailable
            }
            camera = builtin
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: camera)
        } catch {
            throw EyeTermTrackerError.cameraAccessDenied(error)
        }

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .medium

        guard captureSession.canAddInput(input) else {
            captureSession.commitConfiguration()
            throw EyeTermTrackerError.cameraNotAvailable
        }
        captureSession.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)

        guard captureSession.canAddOutput(videoOutput) else {
            captureSession.commitConfiguration()
            throw EyeTermTrackerError.cameraNotAvailable
        }
        captureSession.addOutput(videoOutput)

        // Attempt to cap at 30 fps.
        if let connection = videoOutput.connection(with: .video) {
            connection.isEnabled = true
        }
        do {
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            camera.unlockForConfiguration()
        } catch {
            // Non-fatal — continue with default frame rate.
        }

        captureSession.commitConfiguration()
        captureSession.startRunning()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        captureSession.stopRunning()

        captureSession.beginConfiguration()
        captureSession.inputs.forEach { captureSession.removeInput($0) }
        captureSession.outputs.forEach { captureSession.removeOutput($0) }
        captureSession.commitConfiguration()

        isRunning = false
        emaFilter.reset()
    }

    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .up, options: [:])

        // Step 1: Detect face rectangles (reliably provides yaw/pitch).
        let faceRectsRequest = VNDetectFaceRectanglesRequest()
        do {
            try handler.perform([faceRectsRequest])
        } catch {
            reportUpdate(point: nil, confidence: 0)
            reportFaceObservation(nil)
            return
        }

        guard let faceRects = faceRectsRequest.results, !faceRects.isEmpty else {
            reportUpdate(point: nil, confidence: 0)
            reportFaceObservation(nil)
            return
        }

        // Step 2: Detect landmarks using the face observations from step 1.
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.inputFaceObservations = faceRects
        do {
            try handler.perform([landmarksRequest])
        } catch {
            reportUpdate(point: nil, confidence: 0)
            reportFaceObservation(nil)
            return
        }

        guard let results = landmarksRequest.results, let face = results.first else {
            reportUpdate(point: nil, confidence: 0)
            reportFaceObservation(nil)
            return
        }

        // Carry yaw/pitch from the face rectangles result since the landmarks
        // result may not populate them.
        let faceRect = faceRects.first
        let yawOverride = faceRect?.yaw
        let pitchOverride = faceRect?.pitch

        // Extract face observation data for camera preview overlay
        let faceData = extractFaceData(from: face)

        guard let result = estimator.estimateEye(from: face, yawOverride: yawOverride, pitchOverride: pitchOverride) else {
            reportUpdate(point: nil, confidence: 0)
            reportFaceObservation(faceData)
            return
        }

        let smoothedPoint = emaFilter.update(result.calibratedPoint)

        DispatchQueue.main.async { [weak self] in
            self?.onRawEyePoint?(result.rawPoint)
            self?.onCalibratedEyePoint?(result.calibratedPoint)
            self?.onSmoothedEyePoint?(smoothedPoint)
            self?.onEyeUpdate?(smoothedPoint, result.confidence)
            self?.onDiagnostics?(result.diagnostics)
            self?.onFaceObservation?(faceData)
        }
    }

    // MARK: - Helpers

    private func reportUpdate(point: CGPoint?, confidence: Double) {
        DispatchQueue.main.async { [weak self] in
            self?.onEyeUpdate?(point, confidence)
        }
    }

    private func reportFaceObservation(_ data: FaceObservationData?) {
        DispatchQueue.main.async { [weak self] in
            self?.onFaceObservation?(data)
        }
    }

    private func extractFaceData(from face: VNFaceObservation) -> FaceObservationData {
        let landmarks = face.landmarks
        let bbox = face.boundingBox

        func absolutePoints(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] {
            guard let region else { return [] }
            return region.normalizedPoints.map { pt in
                CGPoint(x: bbox.origin.x + pt.x * bbox.width,
                        y: bbox.origin.y + pt.y * bbox.height)
            }
        }

        func pupilCenter(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let region, region.pointCount > 0 else { return nil }
            let pts = region.normalizedPoints
            let sum = pts.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
            let avg = CGPoint(x: sum.x / CGFloat(pts.count), y: sum.y / CGFloat(pts.count))
            return CGPoint(x: bbox.origin.x + avg.x * bbox.width,
                           y: bbox.origin.y + avg.y * bbox.height)
        }

        let leftPts = absolutePoints(landmarks?.leftEye)
        let rightPts = absolutePoints(landmarks?.rightEye)

        return FaceObservationData(
            boundingBox: bbox,
            leftEyePoints: leftPts,
            rightEyePoints: rightPts,
            leftPupilCenter: pupilCenter(landmarks?.leftPupil),
            rightPupilCenter: pupilCenter(landmarks?.rightPupil),
            yaw: face.yaw?.doubleValue,
            pitch: face.pitch?.doubleValue,
            leftEyeAperture: FaceObservationData.eyeApertureRatio(leftPts),
            rightEyeAperture: FaceObservationData.eyeApertureRatio(rightPts)
        )
    }
}

// MARK: - Errors

enum EyeTermTrackerError: LocalizedError {
    case cameraNotAvailable
    case cameraAccessDenied(Error)

    var errorDescription: String? {
        switch self {
        case .cameraNotAvailable:
            return "No front-facing camera found."
        case .cameraAccessDenied(let underlying):
            return "Camera access denied: \(underlying.localizedDescription)"
        }
    }
}
