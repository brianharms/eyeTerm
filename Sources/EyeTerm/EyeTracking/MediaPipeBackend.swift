import AVFoundation
import CoreGraphics
import Foundation

final class MediaPipeBackend: EyeTrackingBackend {

    var onEyeUpdate: ((CGPoint?, Double) -> Void)?
    var onRawEyePoint: ((CGPoint) -> Void)?
    var onCalibratedEyePoint: ((CGPoint) -> Void)?
    var onSmoothedEyePoint: ((CGPoint) -> Void)?
    var onDiagnostics: ((EyeTermDiagnostics) -> Void)?
    var onFaceObservation: ((FaceObservationData?) -> Void)?
    var onError: ((String) -> Void)?

    var smoothingAlpha: Double {
        get { emaFilter.alpha }
        set { emaFilter.alpha = newValue }
    }

    var headWeight: Double = 0.85
    var headPitchSensitivity: Double = 0.6
    var parallaxCorrX: Double = 0.0
    var parallaxCorrY: Double = 0.0
    var headAmplification: Double = 3.0

    var headCalibrationTransform: CGAffineTransform?
    var pupilCalibrationTransform: CGAffineTransform?

    private(set) var isRunning = false

    /// Camera preview session (display only — MediaPipe Python process does actual tracking).
    var activeCaptureSession: AVCaptureSession? { previewSession }

    /// Optional path to a venv Python executable. When set, used directly instead of `env python3`.
    var pythonExecutable: String? = nil

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var emaFilter = EyeTermEMAFilter()
    private var previewSession: AVCaptureSession?
    private let processingQueue = DispatchQueue(label: "com.eyeterm.mediapipe", qos: .userInteractive)

    // MARK: - Lifecycle

    func start() throws {
        guard !isRunning else { return }

        guard let scriptPath = Bundle.main.path(forResource: "eye_tracker", ofType: "py") else {
            throw MediaPipeError.scriptNotFound
        }

        // Ensure the app holds camera authorization so the child Python process
        // can access it (macOS TCC checks the responsible process).
        let cameraStatus = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                if granted {
                    DispatchQueue.main.async { try? self?.start() }
                } else {
                    DispatchQueue.main.async { self?.onError?("Camera access denied") }
                }
            }
            return
        } else if cameraStatus == .denied || cameraStatus == .restricted {
            throw MediaPipeError.launchFailed(
                NSError(domain: "MediaPipe", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Camera access denied. Enable in System Settings > Privacy & Security > Camera."])
            )
        }

        // Start preview session for camera feed display.
        // macOS allows multiple processes to share the camera.
        try setupPreviewSession()

        // Filter out noisy but harmless MediaPipe/TensorFlow warnings from stderr.
        let stderrNoise: Set<String> = [
            "WARNING:", "I0000", "W0000", "INFO:", "absl::InitializeLog",
            "inference_feedback_manager", "landmark_projection_calculator",
            "GL version", "TensorFlow Lite XNNPACK", "NORM_RECT"
        ]

        let proc = Process()
        if let venvPython = pythonExecutable {
            proc.executableURL = URL(fileURLWithPath: venvPython)
            proc.arguments = ["-u", scriptPath]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", "-u", scriptPath]
        }

        let pipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }

        do {
            try proc.run()
        } catch {
            throw MediaPipeError.launchFailed(error)
        }

        self.process = proc
        self.stdoutPipe = pipe
        isRunning = true

        // Read JSON lines on background queue.
        processingQueue.async { [weak self] in
            self?.readLoop(pipe: pipe)
        }

        // Surface Python stderr to onError callback, filtering harmless noise.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let handle = stderrPipe.fileHandleForReading
            var buffer = Data()
            while self?.isRunning == true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                while let range = buffer.range(of: Data([0x0A])) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                    if let line = String(data: lineData, encoding: .utf8), !line.isEmpty {
                        let isNoise = stderrNoise.contains { line.contains($0) }
                        if !isNoise {
                            DispatchQueue.main.async {
                                self?.onError?("[Python] \(line)")
                            }
                        }
                    }
                }
            }
        }
    }

    func stop() {
        guard isRunning else { return }
        process?.terminate()
        process?.waitUntilExit()
        process = nil
        stdoutPipe = nil
        isRunning = false
        emaFilter.reset()
        teardownPreviewSession()
    }

    // MARK: - Preview Session

    private func setupPreviewSession() throws {
        let session = AVCaptureSession()
        session.sessionPreset = .medium

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            // Not fatal — preview just won't work.
            return
        }

        guard let input = try? AVCaptureDeviceInput(device: camera),
              session.canAddInput(input) else {
            return
        }
        session.addInput(input)
        session.startRunning()
        previewSession = session
    }

    private func teardownPreviewSession() {
        previewSession?.stopRunning()
        previewSession = nil
    }

    // MARK: - JSON Line Reader

    private func readLoop(pipe: Pipe) {
        let handle = pipe.fileHandleForReading
        var buffer = Data()

        while isRunning {
            let chunk = handle.availableData
            if chunk.isEmpty { break }

            buffer.append(chunk)

            // Split on newlines and process complete lines.
            while let newlineRange = buffer.range(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<newlineRange.lowerBound)
                buffer.removeSubrange(buffer.startIndex...newlineRange.lowerBound)

                guard let line = String(data: lineData, encoding: .utf8),
                      !line.isEmpty else { continue }

                processLine(line)
            }
        }
    }

    private func processLine(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // Handle status messages.
        if json["status"] != nil { return }

        // Handle error messages — surface to UI via callback.
        if let error = json["error"] as? String {
            DispatchQueue.main.async { [weak self] in
                self?.onError?(error)
            }
            return
        }

        // No face detected.
        guard json["face_detected"] as? Bool == true else {
            DispatchQueue.main.async { [weak self] in
                self?.onEyeUpdate?(nil, 0)
                self?.onFaceObservation?(nil)
            }
            return
        }

        let confidence = json["confidence"] as? Double ?? 0
        let headYaw = json["head_yaw"] as? Double ?? 0
        let headPitch = json["head_pitch"] as? Double ?? 0
        let irisRatioX = json["iris_ratio_x"] as? Double ?? 0.5
        let irisRatioY = json["iris_ratio_y"] as? Double ?? 0.5

        // Compute fusion on Swift side so the head/eye slider works.
        let headX = 0.5 - (headYaw / 1.0)
        let headY = 0.5 - (headPitch / headPitchSensitivity)
        let pupilX = 1.0 - irisRatioX
        let pupilY = 1.0 - irisRatioY

        // Parallax compensation: remove head-rotation artifacts from pupil.
        let compPupilX = pupilX + parallaxCorrX * headYaw
        let compPupilY = pupilY + parallaxCorrY * headPitch

        // Head amplification: stretch small head movements.
        let ampHeadX = 0.5 + (headX - 0.5) * headAmplification
        let ampHeadY = 0.5 + (headY - 0.5) * headAmplification

        // Apply per-signal calibration.
        var calHeadX = ampHeadX
        var calHeadY = ampHeadY
        if let t = headCalibrationTransform {
            let p = CGPoint(x: ampHeadX, y: ampHeadY).applying(t)
            calHeadX = max(0, min(1, Double(p.x)))
            calHeadY = max(0, min(1, Double(p.y)))
        }

        var calPupilX = compPupilX
        var calPupilY = compPupilY
        if let t = pupilCalibrationTransform {
            let p = CGPoint(x: compPupilX, y: compPupilY).applying(t)
            calPupilX = max(0, min(1, Double(p.x)))
            calPupilY = max(0, min(1, Double(p.y)))
        }

        let eyeWeight = 1.0 - headWeight
        let fusedX = max(0, min(1, headWeight * headX + eyeWeight * pupilX))
        let fusedY = max(0, min(1, headWeight * headY + eyeWeight * pupilY))
        let rawEye = CGPoint(x: fusedX, y: fusedY)

        let calX = max(0, min(1, headWeight * calHeadX + eyeWeight * calPupilX))
        let calY = max(0, min(1, headWeight * calHeadY + eyeWeight * calPupilY))
        let calibratedPoint = CGPoint(x: calX, y: calY)

        let smoothedPoint = emaFilter.update(calibratedPoint)

        // Build face observation data for camera preview overlay.
        // Convert MediaPipe coords (top-left origin) to Vision-like coords (bottom-left origin)
        // so the existing CameraPreviewView overlay transforms work unchanged.
        let faceData = buildFaceObservationData(from: json)

        let diagnostics = EyeTermDiagnostics(
            headYaw: headYaw,
            headPitch: headPitch,
            pupilOffsetX: irisRatioX,
            pupilOffsetY: irisRatioY,
            headPoint: CGPoint(x: max(0, min(1, headX)), y: max(0, min(1, headY))),
            pupilPoint: CGPoint(x: max(0, min(1, pupilX)), y: max(0, min(1, pupilY))),
            calibratedHeadPoint: CGPoint(x: calHeadX, y: calHeadY),
            calibratedPupilPoint: CGPoint(x: calPupilX, y: calPupilY)
        )

        DispatchQueue.main.async { [weak self] in
            self?.onRawEyePoint?(rawEye)
            self?.onCalibratedEyePoint?(calibratedPoint)
            self?.onSmoothedEyePoint?(smoothedPoint)
            self?.onEyeUpdate?(smoothedPoint, confidence)
            self?.onDiagnostics?(diagnostics)
            self?.onFaceObservation?(faceData)
        }
    }

    // MARK: - Coordinate Conversion

    /// Convert MediaPipe face data to FaceObservationData using Vision-like coordinates.
    /// MediaPipe: origin top-left, y increases downward.
    /// Vision: origin bottom-left, y increases upward.
    /// We flip y so the existing CameraPreviewView overlay code works.
    private func buildFaceObservationData(from json: [String: Any]) -> FaceObservationData {
        let bbox = json["face_bbox"] as? [Double] ?? [0, 0, 1, 1]
        let bboxRect = CGRect(
            x: bbox[0],
            y: 1 - bbox[1] - bbox[3],  // flip y + adjust for height
            width: bbox[2],
            height: bbox[3]
        )

        func convertPoints(_ key: String) -> [CGPoint] {
            guard let pts = json[key] as? [[Double]] else { return [] }
            return pts.map { CGPoint(x: $0[0], y: 1 - $0[1]) }
        }

        func convertPupil(_ key: String) -> CGPoint? {
            guard let pt = json[key] as? [Double], pt.count == 2 else { return nil }
            return CGPoint(x: pt[0], y: 1 - pt[1])
        }

        let leftPts = convertPoints("left_eye_points")
        let rightPts = convertPoints("right_eye_points")

        return FaceObservationData(
            boundingBox: bboxRect,
            leftEyePoints: leftPts,
            rightEyePoints: rightPts,
            leftPupilCenter: convertPupil("left_pupil"),
            rightPupilCenter: convertPupil("right_pupil"),
            yaw: json["head_yaw"] as? Double,
            pitch: json["head_pitch"] as? Double,
            leftEyeAperture: FaceObservationData.eyeApertureRatio(leftPts),
            rightEyeAperture: FaceObservationData.eyeApertureRatio(rightPts)
        )
    }
}

// MARK: - Errors

enum MediaPipeError: LocalizedError {
    case scriptNotFound
    case launchFailed(Error)

    var errorDescription: String? {
        switch self {
        case .scriptNotFound:
            return "MediaPipe eye_tracker.py not found in app bundle."
        case .launchFailed(let error):
            return "Failed to launch MediaPipe process: \(error.localizedDescription)"
        }
    }
}
