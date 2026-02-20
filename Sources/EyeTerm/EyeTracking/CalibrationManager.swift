import Foundation
import CoreGraphics

struct CalibrationResult {
    let headTransform: CGAffineTransform
    let pupilTransform: CGAffineTransform
    let parallaxCorrX: Double
    let parallaxCorrY: Double
}

final class CalibrationManager {

    // MARK: - Configuration

    private static let targetPositions: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5),    // center
        CGPoint(x: 0.05, y: 0.05),  // top-left
        CGPoint(x: 0.95, y: 0.05),  // top-right
        CGPoint(x: 0.05, y: 0.95),  // bottom-left
        CGPoint(x: 0.95, y: 0.95),  // bottom-right
        CGPoint(x: 0.5, y: 0.05),   // top-center
        CGPoint(x: 0.5, y: 0.95),   // bottom-center
        CGPoint(x: 0.05, y: 0.5),   // left-center
        CGPoint(x: 0.95, y: 0.5),   // right-center
    ]

    private static let samplesPerTarget = 45
    private static let settleFrames = 30
    private static let headDefaultsKey = "HeadCalibrationTransform"
    private static let pupilDefaultsKey = "PupilCalibrationTransform"
    private static let parallaxCorrXKey = "ParallaxCorrX"
    private static let parallaxCorrYKey = "ParallaxCorrY"

    // MARK: - Public state

    private(set) var isCalibrated = false
    private(set) var currentTargetIndex = 0
    private(set) var isSettling = true
    var totalTargets: Int { Self.targetPositions.count }

    var currentTargetPosition: CGPoint? {
        guard currentTargetIndex < totalTargets else { return nil }
        return Self.targetPositions[currentTargetIndex]
    }

    var progress: Double {
        let settleProgress = min(Double(settleCount) / Double(Self.settleFrames), 1.0)
        if settleProgress < 1.0 { return settleProgress * 0.4 }
        let sampleProgress = min(Double(currentHeadSamples.count) / Double(Self.samplesPerTarget), 1.0)
        return 0.4 + sampleProgress * 0.6
    }

    // Coordinator callbacks (set by AppCoordinator.wireCallbacks)
    var onNextTarget: ((CGPoint) -> Void)?
    var onCalibrationComplete: ((CalibrationResult) -> Void)?

    // UI-specific callbacks (set by CalibrationOverlayView)
    var onTargetChanged: ((CGPoint) -> Void)?
    var onTargetProgressUpdate: ((CGPoint, Double) -> Void)?

    // MARK: - Private state

    private var collectedHeadSamples: [[CGPoint]] = []
    private var collectedPupilSamples: [[CGPoint]] = []
    private var currentHeadSamples: [CGPoint] = []
    private var currentPupilSamples: [CGPoint] = []
    private var collectedHeadYawSamples: [[Double]] = []
    private var collectedHeadPitchSamples: [[Double]] = []
    private var currentHeadYawSamples: [Double] = []
    private var currentHeadPitchSamples: [Double] = []
    private var settleCount = 0
    private var headTransform: CGAffineTransform?
    private var pupilTransform: CGAffineTransform?
    private var savedParallaxCorrX: Double = 0.0
    private var savedParallaxCorrY: Double = 0.0

    // MARK: - Init

    init() {
        loadSavedCalibration()
    }

    // MARK: - Public API

    func startCalibration() {
        currentTargetIndex = 0
        collectedHeadSamples = []
        collectedPupilSamples = []
        currentHeadSamples = []
        currentPupilSamples = []
        collectedHeadYawSamples = []
        collectedHeadPitchSamples = []
        currentHeadYawSamples = []
        currentHeadPitchSamples = []
        settleCount = 0
        isSettling = true
        isCalibrated = false
        headTransform = nil
        pupilTransform = nil

        if let pos = currentTargetPosition {
            onNextTarget?(pos)
            onTargetChanged?(pos)
        }
    }

    func recordSample(headPoint: CGPoint, pupilPoint: CGPoint, headYaw: Double, headPitch: Double) {
        guard currentTargetIndex < totalTargets else { return }

        if settleCount < Self.settleFrames {
            settleCount += 1
            isSettling = true
            if let pos = currentTargetPosition {
                onTargetProgressUpdate?(pos, progress)
            }
            return
        }

        isSettling = false
        currentHeadSamples.append(headPoint)
        currentPupilSamples.append(pupilPoint)
        currentHeadYawSamples.append(headYaw)
        currentHeadPitchSamples.append(headPitch)

        if let pos = currentTargetPosition {
            onTargetProgressUpdate?(pos, progress)
        }

        if currentHeadSamples.count >= Self.samplesPerTarget {
            collectedHeadSamples.append(currentHeadSamples)
            collectedPupilSamples.append(currentPupilSamples)
            collectedHeadYawSamples.append(currentHeadYawSamples)
            collectedHeadPitchSamples.append(currentHeadPitchSamples)
            currentHeadSamples = []
            currentPupilSamples = []
            currentHeadYawSamples = []
            currentHeadPitchSamples = []
            settleCount = 0
            isSettling = true
            currentTargetIndex += 1

            if currentTargetIndex < totalTargets {
                if let pos = currentTargetPosition {
                    onNextTarget?(pos)
                    onTargetChanged?(pos)
                }
            } else {
                finishCalibration()
            }
        }
    }

    func reset() {
        isCalibrated = false
        headTransform = nil
        pupilTransform = nil
        currentTargetIndex = 0
        collectedHeadSamples = []
        collectedPupilSamples = []
        currentHeadSamples = []
        currentPupilSamples = []
        collectedHeadYawSamples = []
        collectedHeadPitchSamples = []
        currentHeadYawSamples = []
        currentHeadPitchSamples = []
        UserDefaults.standard.removeObject(forKey: Self.headDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.pupilDefaultsKey)
        UserDefaults.standard.removeObject(forKey: Self.parallaxCorrXKey)
        UserDefaults.standard.removeObject(forKey: Self.parallaxCorrYKey)
    }

    // MARK: - Parallax coefficient learning

    /// Compute parallax correction coefficients from within-target head drift.
    /// For each target, the user's gaze is fixed but head may drift slightly.
    /// The covariance of (headYaw, pupilX) within each target gives the parallax slope.
    /// Average slopes across all targets for a robust estimate.
    private func computeParallaxCoefficients() -> (corrX: Double, corrY: Double) {
        var slopesX: [Double] = []
        var slopesY: [Double] = []

        for i in 0..<collectedPupilSamples.count {
            let pupils = collectedPupilSamples[i]
            let yaws = collectedHeadYawSamples[i]
            let pitches = collectedHeadPitchSamples[i]
            let n = pupils.count
            guard n > 2 else { continue }

            // Compute slope of pupilX vs headYaw via cov/var
            let meanYaw = yaws.reduce(0, +) / Double(n)
            let meanPupilX = pupils.map { Double($0.x) }.reduce(0, +) / Double(n)
            var covXYaw = 0.0
            var varYaw = 0.0
            for j in 0..<n {
                let dy = yaws[j] - meanYaw
                let dpx = Double(pupils[j].x) - meanPupilX
                covXYaw += dy * dpx
                varYaw += dy * dy
            }
            if varYaw > 1e-12 {
                slopesX.append(covXYaw / varYaw)
            }

            // Compute slope of pupilY vs headPitch via cov/var
            let meanPitch = pitches.reduce(0, +) / Double(n)
            let meanPupilY = pupils.map { Double($0.y) }.reduce(0, +) / Double(n)
            var covYPitch = 0.0
            var varPitch = 0.0
            for j in 0..<n {
                let dp = pitches[j] - meanPitch
                let dpy = Double(pupils[j].y) - meanPupilY
                covYPitch += dp * dpy
                varPitch += dp * dp
            }
            if varPitch > 1e-12 {
                slopesY.append(covYPitch / varPitch)
            }
        }

        // The slope tells us how much pupil drifts per unit of head rotation.
        // To compensate, we negate it: compPupilX = pupilX + corrX * yaw
        // where corrX = -slope
        let corrX = slopesX.isEmpty ? 0.0 : -(slopesX.reduce(0, +) / Double(slopesX.count))
        let corrY = slopesY.isEmpty ? 0.0 : -(slopesY.reduce(0, +) / Double(slopesY.count))

        return (corrX, corrY)
    }

    // MARK: - Calibration math

    /// Compute affine transforms that map averaged gaze samples to target positions.
    /// First learns parallax coefficients, then compensates pupil data before fitting.
    private func finishCalibration() {
        guard collectedHeadSamples.count == totalTargets,
              collectedPupilSamples.count == totalTargets else { return }

        // Step 1: Learn parallax coefficients from raw data
        let parallax = computeParallaxCoefficients()
        let corrX = parallax.corrX
        let corrY = parallax.corrY

        // Step 2: Compensate pupil samples using learned coefficients
        var compensatedPupilSamples: [[CGPoint]] = []
        for i in 0..<collectedPupilSamples.count {
            let pupils = collectedPupilSamples[i]
            let yaws = collectedHeadYawSamples[i]
            let pitches = collectedHeadPitchSamples[i]
            var compensated: [CGPoint] = []
            for j in 0..<pupils.count {
                let cx = Double(pupils[j].x) + corrX * yaws[j]
                let cy = Double(pupils[j].y) + corrY * pitches[j]
                compensated.append(CGPoint(x: cx, y: cy))
            }
            compensatedPupilSamples.append(compensated)
        }

        // Step 3: Fit affine transforms on compensated data
        let headT = solveTransform(from: collectedHeadSamples) ?? .identity
        let pupilT = solveTransform(from: compensatedPupilSamples) ?? .identity

        self.headTransform = headT
        self.pupilTransform = pupilT
        self.savedParallaxCorrX = corrX
        self.savedParallaxCorrY = corrY
        self.isCalibrated = true
        saveCalibration(headT, key: Self.headDefaultsKey)
        saveCalibration(pupilT, key: Self.pupilDefaultsKey)
        UserDefaults.standard.set(corrX, forKey: Self.parallaxCorrXKey)
        UserDefaults.standard.set(corrY, forKey: Self.parallaxCorrYKey)
        print("[CalibrationManager] Parallax coefficients: corrX=\(corrX), corrY=\(corrY)")
        onCalibrationComplete?(CalibrationResult(
            headTransform: headT,
            pupilTransform: pupilT,
            parallaxCorrX: corrX,
            parallaxCorrY: corrY
        ))
    }

    private func solveTransform(from collectedSamples: [[CGPoint]]) -> CGAffineTransform? {
        var eyeAverages: [CGPoint] = []
        for samples in collectedSamples {
            eyeAverages.append(average(of: samples))
        }

        let targets = Self.targetPositions
        let n = targets.count

        var ata = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var atbX = [Double](repeating: 0, count: 3)
        var atbY = [Double](repeating: 0, count: 3)

        for i in 0..<n {
            let gx = Double(eyeAverages[i].x)
            let gy = Double(eyeAverages[i].y)
            let row = [gx, gy, 1.0]
            let tx = Double(targets[i].x)
            let ty = Double(targets[i].y)

            for r in 0..<3 {
                for c in 0..<3 {
                    ata[r][c] += row[r] * row[c]
                }
                atbX[r] += row[r] * tx
                atbY[r] += row[r] * ty
            }
        }

        guard let xParams = solve3x3(ata, atbX),
              let yParams = solve3x3(ata, atbY) else {
            return nil
        }

        return CGAffineTransform(a: CGFloat(xParams[0]),
                                 b: CGFloat(yParams[0]),
                                 c: CGFloat(xParams[1]),
                                 d: CGFloat(yParams[1]),
                                 tx: CGFloat(xParams[2]),
                                 ty: CGFloat(yParams[2]))
    }

    /// Solve a 3x3 linear system Ax = b using Cramer's rule.
    private func solve3x3(_ A: [[Double]], _ b: [Double]) -> [Double]? {
        func det3(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
            - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
            + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }

        let d = det3(A)
        guard abs(d) > 1e-12 else { return nil }

        var result = [Double](repeating: 0, count: 3)
        for col in 0..<3 {
            var modified = A
            for row in 0..<3 {
                modified[row][col] = b[row]
            }
            result[col] = det3(modified) / d
        }
        return result
    }

    // MARK: - Persistence

    private func saveCalibration(_ t: CGAffineTransform, key: String) {
        let values = [t.a, t.b, t.c, t.d, t.tx, t.ty].map { Double($0) }
        UserDefaults.standard.set(values, forKey: key)
    }

    private func loadSavedCalibration() {
        headTransform = loadTransform(key: Self.headDefaultsKey)
        pupilTransform = loadTransform(key: Self.pupilDefaultsKey)
        savedParallaxCorrX = UserDefaults.standard.double(forKey: Self.parallaxCorrXKey)
        savedParallaxCorrY = UserDefaults.standard.double(forKey: Self.parallaxCorrYKey)
        if headTransform != nil || pupilTransform != nil {
            isCalibrated = true
        }
    }

    private func loadTransform(key: String) -> CGAffineTransform? {
        guard let values = UserDefaults.standard.array(forKey: key) as? [Double],
              values.count == 6 else { return nil }
        return CGAffineTransform(a: CGFloat(values[0]),
                                 b: CGFloat(values[1]),
                                 c: CGFloat(values[2]),
                                 d: CGFloat(values[3]),
                                 tx: CGFloat(values[4]),
                                 ty: CGFloat(values[5]))
    }

    var savedCalibrationResult: CalibrationResult? {
        guard let h = headTransform, let p = pupilTransform else { return nil }
        return CalibrationResult(
            headTransform: h,
            pupilTransform: p,
            parallaxCorrX: savedParallaxCorrX,
            parallaxCorrY: savedParallaxCorrY
        )
    }

    // MARK: - Helpers

    private func average(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count),
                       y: sum.y / CGFloat(points.count))
    }
}
