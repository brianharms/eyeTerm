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
    /// Fires once when the Python process reports it has started, with (cameraIndex, cameraName, cameraUID).
    /// cameraUID is the AVFoundation uniqueID of the device OpenCV actually opened (empty if unavailable).
    var onStarted: ((Int, String, String) -> Void)?

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

    /// Camera device unique ID — empty string means system default.
    var selectedCameraDeviceID: String = ""

    /// Camera preview session (display only — MediaPipe Python process does actual tracking).
    var activeCaptureSession: AVCaptureSession? { previewSession }

    /// Camera actually being used by the Python process (set once startup message arrives).
    private(set) var actualTrackingCameraName: String = ""
    private(set) var actualTrackingCameraIndex: Int = -1

    /// Optional path to a venv Python executable. When set, used directly instead of `env python3`.
    var pythonExecutable: String? = nil

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var emaFilter = EyeTermEMAFilter()
    private var previewSession: AVCaptureSession?
    private let processingQueue = DispatchQueue(label: "com.eyeterm.mediapipe", qos: .userInteractive)
    /// Separate queue for preview session start/stop so they don't block behind readLoop on processingQueue.
    private let previewQueue = DispatchQueue(label: "com.eyeterm.preview", qos: .userInitiated)

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

        let cameraArg = String(cameraIndex(for: selectedCameraDeviceID))
        let cameraName = selectedCameraDeviceID.isEmpty
            ? ""
            : (AVCaptureDevice(uniqueID: selectedCameraDeviceID)?.localizedName ?? "")
        let cameraUID = selectedCameraDeviceID
        let proc = Process()
        if let venvPython = pythonExecutable {
            proc.executableURL = URL(fileURLWithPath: venvPython)
            proc.arguments = ["-u", scriptPath, "--camera", cameraArg, "--camera-name", cameraName, "--camera-uid", cameraUID]
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["python3", "-u", scriptPath, "--camera", cameraArg, "--camera-name", cameraName, "--camera-uid", cameraUID]
        }

        let pipe = Pipe()
        let stderrPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = stderrPipe

        proc.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else { return }
                let exitCode = proc.terminationStatus
                self.isRunning = false
                print("[MediaPipeBackend] Python process terminated (exit code \(exitCode))")
                if exitCode != 0 {
                    self.onError?("Python process exited unexpectedly (code \(exitCode))")
                }
            }
        }

        do {
            try proc.run()
        } catch {
            teardownPreviewSession()
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
        // Nil the handler before terminating so the stale async dispatch
        // doesn't reset isRunning=false after a subsequent startEyeTracking().
        // Don't call waitUntilExit() — it blocks and spins the main RunLoop, which
        // can trigger re-entrant pushAllSettings() calls or cause hangs if Python
        // doesn't respond to SIGTERM immediately. The readLoop exits naturally when
        // the pipe's write end closes (as soon as the process dies).
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        isRunning = false
        emaFilter.reset()
        teardownPreviewSession()
        actualTrackingCameraName = ""
        actualTrackingCameraIndex = -1
    }

    /// Like stop(), but waits on a background thread for the Python process to fully exit
    /// before calling completion on the main thread. This ensures the camera device is released
    /// before the next process tries to open it — critical for reliable camera switching.
    func stopAndWait(completion: @escaping () -> Void) {
        guard isRunning else {
            DispatchQueue.main.async { completion() }
            return
        }
        let dyingProcess = process
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        stdoutPipe = nil
        isRunning = false
        emaFilter.reset()
        teardownPreviewSession()
        actualTrackingCameraName = ""
        actualTrackingCameraIndex = -1

        DispatchQueue.global(qos: .userInitiated).async {
            // Poll up to 1.5s for a clean SIGTERM exit
            let deadline = Date().addingTimeInterval(1.5)
            while dyingProcess?.isRunning == true, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            // Second SIGTERM if still alive after timeout
            if dyingProcess?.isRunning == true {
                dyingProcess?.terminate()
                Thread.sleep(forTimeInterval: 0.3)
            }
            DispatchQueue.main.async { completion() }
        }
    }

    // MARK: - Preview Session

    private func setupPreviewSession() throws {
        let camera: AVCaptureDevice?
        if !selectedCameraDeviceID.isEmpty,
           let device = AVCaptureDevice(uniqueID: selectedCameraDeviceID) {
            camera = device
        } else {
            camera = opencvOrderedDevices().first
        }
        guard let camera else { return }
        previewSession = makePreviewSession(for: camera)
    }

    private func teardownPreviewSession() {
        let old = previewSession
        previewSession = nil
        previewQueue.async { old?.stopRunning() }
    }

    /// Builds an AVCaptureSession for the given device, starts it on the background queue,
    /// and calls onReady (on main thread) once startRunning() returns.
    private func makePreviewSession(for device: AVCaptureDevice, onReady: (() -> Void)? = nil) -> AVCaptureSession? {
        let session = AVCaptureSession()
        session.sessionPreset = .medium
        guard let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else { return nil }
        session.addInput(input)
        previewQueue.async {
            session.startRunning()
            if let onReady { DispatchQueue.main.async { onReady() } }
        }
        return session
    }

    /// Switches the preview session to an arbitrary device by uniqueID.
    /// onReady fires on the main thread after the new session is running.
    func switchPreviewToDevice(uniqueID: String, onReady: (() -> Void)? = nil) {
        guard let device = AVCaptureDevice(uniqueID: uniqueID) else { return }
        if let input = previewSession?.inputs.first as? AVCaptureDeviceInput,
           input.device.uniqueID == device.uniqueID { return }
        teardownPreviewSession()
        guard let session = makePreviewSession(for: device, onReady: onReady) else { return }
        previewSession = session
    }

    /// Called once Python reports back which camera it actually opened.
    /// Name is the authoritative signal — a UID from Python's post-open check
    /// can be wrong when the AVFoundation deprecated-API index doesn't align with
    /// OpenCV's internal ordering. We only accept a UID if the device name also matches.
    func syncPreviewToTrackingCamera(cameraName: String, opencvIndex: Int, verifiedUID: String = "", onReady: (() -> Void)? = nil) {
        var target: AVCaptureDevice?
        // 1. UID lookup — accepted only when name also confirms it's the right device.
        if !verifiedUID.isEmpty, let byUID = AVCaptureDevice(uniqueID: verifiedUID) {
            if cameraName.isEmpty
                || byUID.localizedName == cameraName
                || byUID.localizedName.localizedCaseInsensitiveContains(cameraName) {
                target = byUID
            }
            // If name doesn't match, the UID is stale/wrong — fall through to name match.
        }
        // 2. Name match — authoritative. Searches both AVFoundation orderings.
        if target == nil, !cameraName.isEmpty {
            let all = orderedVideoDevices() + opencvOrderedDevices()
            target = all.first(where: { $0.localizedName == cameraName })
                ?? all.first(where: { $0.localizedName.localizedCaseInsensitiveContains(cameraName) })
        }
        // 3. Index fallback — last resort when name is empty.
        if target == nil {
            let devices = opencvOrderedDevices()
            guard opencvIndex < devices.count else { return }
            target = devices[opencvIndex]
        }
        guard let target else { return }

        if let input = previewSession?.inputs.first as? AVCaptureDeviceInput,
           input.device.uniqueID == target.uniqueID {
            onReady?()  // Already on the right camera
            return
        }

        teardownPreviewSession()
        guard let session = makePreviewSession(for: target, onReady: onReady) else { return }
        previewSession = session
    }

    /// Forces the preview session to the camera matching `name`, regardless of UID or index.
    /// Used as a verification pass after syncPreviewToTrackingCamera to catch any mismatch.
    func syncPreviewByName(_ name: String, onReady: (() -> Void)? = nil) {
        guard !name.isEmpty else { return }
        let all = orderedVideoDevices() + opencvOrderedDevices()
        guard let target = all.first(where: { $0.localizedName == name })
                        ?? all.first(where: { $0.localizedName.localizedCaseInsensitiveContains(name) })
        else { return }

        if let input = previewSession?.inputs.first as? AVCaptureDeviceInput,
           input.device.uniqueID == target.uniqueID {
            onReady?()
            return
        }
        teardownPreviewSession()
        guard let session = makePreviewSession(for: target, onReady: onReady) else { return }
        previewSession = session
    }

    /// Returns video capture devices in OpenCV's enumeration order (external cameras first).
    /// OpenCV 4.x AVFoundation backend lists external cameras before built-in.
    ///
    /// IMPORTANT: macOS ignores the device type order in the DiscoverySession input array —
    /// it always returns built-in cameras first regardless of what order you request.
    /// We must manually sort the results to put external cameras first.
    private func opencvOrderedDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.external, .builtInWideAngleCamera]
        } else {
            types = [.externalUnknown, .builtInWideAngleCamera]
        }
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
        // macOS returns built-in first regardless of type array order — manually re-sort.
        if #available(macOS 14.0, *) {
            let ext = devices.filter { $0.deviceType == .external }
            let builtin = devices.filter { $0.deviceType != .external }
            return ext + builtin
        } else {
            let ext = devices.filter { $0.deviceType == .externalUnknown }
            let builtin = devices.filter { $0.deviceType != .externalUnknown }
            return ext + builtin
        }
    }

    /// Returns video capture devices in builtIn-first order (standard AVFoundation order).
    /// Used internally where the builtIn-first enumeration is appropriate.
    private func orderedVideoDevices() -> [AVCaptureDevice] {
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external]
        } else {
            types = [.builtInWideAngleCamera, .externalUnknown]
        }
        return AVCaptureDevice.DiscoverySession(
            deviceTypes: types,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// Maps an AVFoundation unique device ID to an OpenCV-compatible camera index.
    /// OpenCV 4.x AVFoundation backend lists EXTERNAL cameras before built-in —
    /// the opposite of the standard DiscoverySession order. We must match that here.
    /// Returns 0 when the ID is empty or not found.
    private func cameraIndex(for uniqueID: String) -> Int {
        guard !uniqueID.isEmpty else { return 0 }
        let devices = opencvOrderedDevices()
        return devices.firstIndex(where: { $0.uniqueID == uniqueID }) ?? 0
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
        if let status = json["status"] as? String {
            if status == "started" {
                let idx = json["camera_index"] as? Int ?? -1
                let name = json["camera_name"] as? String ?? ""
                let uid = json["camera_uid"] as? String ?? ""
                DispatchQueue.main.async { [weak self] in
                    self?.actualTrackingCameraIndex = idx
                    self?.actualTrackingCameraName = name
                    self?.onStarted?(idx, name, uid)
                }
            } else if status == "camera_diag" {
                // Diagnostic only — don't surface to UI. AVFoundation not available in mediapipe
                // venv (PyObjC not installed) is expected; Swift handles all camera resolution.
            }
            return
        }

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

        let meshContours: [[CGPoint]] = [
            convertPoints("face_oval"),
            convertPoints("left_eyebrow"),
            convertPoints("right_eyebrow"),
            convertPoints("nose_bridge"),
            convertPoints("lips_outer"),
            leftPts,
            rightPts,
        ].filter { !$0.isEmpty }

        return FaceObservationData(
            boundingBox: bboxRect,
            leftEyePoints: leftPts,
            rightEyePoints: rightPts,
            leftPupilCenter: convertPupil("left_pupil"),
            rightPupilCenter: convertPupil("right_pupil"),
            yaw: json["head_yaw"] as? Double,
            pitch: json["head_pitch"] as? Double,
            leftEyeAperture: FaceObservationData.eyeApertureRatio(leftPts),
            rightEyeAperture: FaceObservationData.eyeApertureRatio(rightPts),
            faceMeshContours: meshContours
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
