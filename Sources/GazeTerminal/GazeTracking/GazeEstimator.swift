import Foundation
import Vision
import CoreGraphics

struct EyeTermDiagnostics {
    let headYaw: Double
    let headPitch: Double
    let pupilOffsetX: Double
    let pupilOffsetY: Double
    let headGazePoint: CGPoint
    let pupilGazePoint: CGPoint
    let calibratedHeadGazePoint: CGPoint
    let calibratedPupilGazePoint: CGPoint
}

struct EyeTermGazeResult {
    let rawPoint: CGPoint
    let calibratedPoint: CGPoint
    let confidence: Double
    let diagnostics: EyeTermDiagnostics
}

final class EyeTermEstimator {

    var headCalibrationTransform: CGAffineTransform?
    var pupilCalibrationTransform: CGAffineTransform?

    /// Balance between head pose (1.0) and pupil tracking (0.0). Default 0.85.
    var headWeight: Double = 0.85

    // MARK: - Public

    func estimateGaze(from observation: VNFaceObservation,
                      yawOverride: NSNumber? = nil,
                      pitchOverride: NSNumber? = nil) -> EyeTermGazeResult? {
        guard let landmarks = observation.landmarks else { return nil }
        guard let leftPupil = landmarks.leftPupil,
              let rightPupil = landmarks.rightPupil,
              let leftEye = landmarks.leftEye,
              let rightEye = landmarks.rightEye else { return nil }

        // --- Head pose (coarse gaze) ---
        // Prefer overrides from VNDetectFaceRectanglesRequest which reliably provides these.
        let yaw = (yawOverride ?? observation.yaw)?.doubleValue ?? 0
        let pitch = (pitchOverride ?? observation.pitch)?.doubleValue ?? 0

        // Map head rotation to normalised screen position.
        let headX = 0.5 - (yaw / 1.0)
        let headY = 0.5 + (pitch / 0.3)

        // --- Pupil offset within eye sockets (fine gaze) ---
        let leftOffset = pupilOffset(pupil: leftPupil, eye: leftEye, boundingBox: observation.boundingBox)
        let rightOffset = pupilOffset(pupil: rightPupil, eye: rightEye, boundingBox: observation.boundingBox)

        let avgPupilOffsetX = (leftOffset.x + rightOffset.x) / 2
        let avgPupilOffsetY = (leftOffset.y + rightOffset.y) / 2

        // Map pupil offset (0…1 within eye) to screen-space gaze (0…1).
        let pupilX = Double(1.0 - avgPupilOffsetX)
        let pupilY = Double(1.0 - avgPupilOffsetY)

        // --- Apply per-signal calibration ---
        var calHeadX = headX
        var calHeadY = headY
        if let t = headCalibrationTransform {
            let p = CGPoint(x: headX, y: headY).applying(t)
            calHeadX = clamp(Double(p.x), min: 0, max: 1)
            calHeadY = clamp(Double(p.y), min: 0, max: 1)
        }

        var calPupilX = pupilX
        var calPupilY = pupilY
        if let t = pupilCalibrationTransform {
            let p = CGPoint(x: pupilX, y: pupilY).applying(t)
            calPupilX = clamp(Double(p.x), min: 0, max: 1)
            calPupilY = clamp(Double(p.y), min: 0, max: 1)
        }

        // --- Fuse calibrated signals ---
        let eyeWeight = 1.0 - headWeight
        let rawX = clamp(headWeight * headX + eyeWeight * pupilX, min: 0, max: 1)
        let rawY = clamp(headWeight * headY + eyeWeight * pupilY, min: 0, max: 1)
        let rawPoint = CGPoint(x: rawX, y: rawY)

        let calX = clamp(headWeight * calHeadX + eyeWeight * calPupilX, min: 0, max: 1)
        let calY = clamp(headWeight * calHeadY + eyeWeight * calPupilY, min: 0, max: 1)
        let calibratedPoint = CGPoint(x: calX, y: calY)

        // --- Confidence ---
        let faceConf = Double(observation.confidence)
        let landmarkConf: Double = (leftPupil.pointCount > 0 && rightPupil.pointCount > 0) ? 1.0 : 0.5
        let hasHeadPose: Double = (observation.yaw != nil && observation.pitch != nil) ? 1.0 : 0.6
        let confidence = clamp(faceConf * landmarkConf * hasHeadPose, min: 0, max: 1)

        let diagnostics = EyeTermDiagnostics(
            headYaw: yaw,
            headPitch: pitch,
            pupilOffsetX: Double(avgPupilOffsetX),
            pupilOffsetY: Double(avgPupilOffsetY),
            headGazePoint: CGPoint(x: clamp(headX, min: 0, max: 1), y: clamp(headY, min: 0, max: 1)),
            pupilGazePoint: CGPoint(x: clamp(pupilX, min: 0, max: 1), y: clamp(pupilY, min: 0, max: 1)),
            calibratedHeadGazePoint: CGPoint(x: calHeadX, y: calHeadY),
            calibratedPupilGazePoint: CGPoint(x: calPupilX, y: calPupilY)
        )

        return EyeTermGazeResult(rawPoint: rawPoint, calibratedPoint: calibratedPoint, confidence: confidence, diagnostics: diagnostics)
    }

    // MARK: - Helpers

    /// Returns the relative position of the pupil within the eye region (0…1 each axis).
    private func pupilOffset(pupil: VNFaceLandmarkRegion2D,
                             eye: VNFaceLandmarkRegion2D,
                             boundingBox: CGRect) -> CGPoint {
        guard pupil.pointCount > 0, eye.pointCount >= 2 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let pupilPts = pupil.normalizedPoints
        let eyePts = eye.normalizedPoints

        // Pupil centre (averaged)
        let pupilCenter = average(of: pupilPts)

        // Eye bounding box within normalised face coordinates.
        let eyeMinX = eyePts.map(\.x).min() ?? 0
        let eyeMaxX = eyePts.map(\.x).max() ?? 1
        let eyeMinY = eyePts.map(\.y).min() ?? 0
        let eyeMaxY = eyePts.map(\.y).max() ?? 1

        let width = eyeMaxX - eyeMinX
        let height = eyeMaxY - eyeMinY

        guard width > 0.001, height > 0.001 else {
            return CGPoint(x: 0.5, y: 0.5)
        }

        let relX = (pupilCenter.x - eyeMinX) / width
        let relY = (pupilCenter.y - eyeMinY) / height

        return CGPoint(x: clamp(relX, min: 0, max: 1),
                       y: clamp(relY, min: 0, max: 1))
    }

    private func average(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return CGPoint(x: 0.5, y: 0.5) }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count),
                       y: sum.y / CGFloat(points.count))
    }

    private func clamp(_ value: Double, min lo: Double, max hi: Double) -> Double {
        Swift.min(hi, Swift.max(lo, value))
    }

    private func clamp(_ value: CGFloat, min lo: Double, max hi: Double) -> CGFloat {
        CGFloat(Swift.min(hi, Swift.max(lo, Double(value))))
    }
}
