import Foundation
import CoreGraphics

final class CalibrationManager {

    // MARK: - Configuration

    private static let targetPositions: [CGPoint] = [
        CGPoint(x: 0.5, y: 0.5),   // center
        CGPoint(x: 0.15, y: 0.15), // near top-left
        CGPoint(x: 0.85, y: 0.15), // near top-right
        CGPoint(x: 0.15, y: 0.85), // near bottom-left
        CGPoint(x: 0.85, y: 0.85)  // near bottom-right
    ]

    private static let samplesPerTarget = 45
    private static let settleFrames = 30
    private static let defaultsKey = "CalibrationTransform"

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
        let sampleProgress = min(Double(currentSamples.count) / Double(Self.samplesPerTarget), 1.0)
        return 0.4 + sampleProgress * 0.6
    }

    // Coordinator callbacks (set by AppCoordinator.wireCallbacks)
    var onNextTarget: ((CGPoint) -> Void)?
    var onCalibrationComplete: ((CGAffineTransform) -> Void)?

    // UI-specific callbacks (set by CalibrationOverlayView)
    var onTargetChanged: ((CGPoint) -> Void)?
    var onTargetProgressUpdate: ((CGPoint, Double) -> Void)?

    // MARK: - Private state

    private var collectedSamples: [[CGPoint]] = []
    private var currentSamples: [CGPoint] = []
    private var settleCount = 0
    private var transform: CGAffineTransform?

    // MARK: - Init

    init() {
        loadSavedCalibration()
    }

    // MARK: - Public API

    func startCalibration() {
        currentTargetIndex = 0
        collectedSamples = []
        currentSamples = []
        settleCount = 0
        isSettling = true
        isCalibrated = false
        transform = nil

        if let pos = currentTargetPosition {
            onNextTarget?(pos)
            onTargetChanged?(pos)
        }
    }

    func recordSample(gazePoint: CGPoint) {
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
        currentSamples.append(gazePoint)

        if let pos = currentTargetPosition {
            onTargetProgressUpdate?(pos, progress)
        }

        if currentSamples.count >= Self.samplesPerTarget {
            collectedSamples.append(currentSamples)
            currentSamples = []
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

    func applyCorrection(to point: CGPoint) -> CGPoint {
        guard let t = transform else { return point }
        var corrected = point.applying(t)
        corrected.x = min(1, max(0, corrected.x))
        corrected.y = min(1, max(0, corrected.y))
        return corrected
    }

    func reset() {
        isCalibrated = false
        transform = nil
        currentTargetIndex = 0
        collectedSamples = []
        currentSamples = []
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    // MARK: - Calibration math

    /// Compute an affine transform that maps averaged gaze samples → target positions.
    ///
    /// An affine transform in 2D has 6 parameters (a, b, tx, c, d, ty):
    ///   targetX = a * gazeX + b * gazeY + tx
    ///   targetY = c * gazeX + d * gazeY + ty
    ///
    /// With 5 point pairs (overdetermined), solve via least-squares (normal equations).
    private func finishCalibration() {
        guard collectedSamples.count == totalTargets else { return }

        var gazeAverages: [CGPoint] = []
        for samples in collectedSamples {
            let avg = average(of: samples)
            gazeAverages.append(avg)
        }

        let targets = Self.targetPositions

        // Solve for X params:  targetX_i = a * gX_i + b * gY_i + tx
        // Solve for Y params:  targetY_i = c * gX_i + d * gY_i + ty
        // Build A matrix (n×3) and b vectors.
        let n = targets.count

        // A^T A (3×3) and A^T b (3×1) — solve independently for x and y targets.
        var ata = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 3)
        var atbX = [Double](repeating: 0, count: 3)
        var atbY = [Double](repeating: 0, count: 3)

        for i in 0..<n {
            let gx = Double(gazeAverages[i].x)
            let gy = Double(gazeAverages[i].y)
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
            onCalibrationComplete?(.identity)
            return
        }

        // CGAffineTransform:
        //   x' = a*x + c*y + tx
        //   y' = b*x + d*y + ty
        // Our solution: targetX = xParams[0]*gx + xParams[1]*gy + xParams[2]
        //               targetY = yParams[0]*gx + yParams[1]*gy + yParams[2]
        // So:  a = xParams[0], c = xParams[1], tx = xParams[2]
        //      b = yParams[0], d = yParams[1], ty = yParams[2]
        let result = CGAffineTransform(a: CGFloat(xParams[0]),
                                       b: CGFloat(yParams[0]),
                                       c: CGFloat(xParams[1]),
                                       d: CGFloat(yParams[1]),
                                       tx: CGFloat(xParams[2]),
                                       ty: CGFloat(yParams[2]))

        self.transform = result
        self.isCalibrated = true
        saveCalibration(result)
        onCalibrationComplete?(result)
    }

    /// Solve a 3×3 linear system Ax = b using Cramer's rule.
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

    private func saveCalibration(_ t: CGAffineTransform) {
        let values = [t.a, t.b, t.c, t.d, t.tx, t.ty].map { Double($0) }
        UserDefaults.standard.set(values, forKey: Self.defaultsKey)
    }

    private func loadSavedCalibration() {
        guard let values = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [Double],
              values.count == 6 else { return }

        let t = CGAffineTransform(a: CGFloat(values[0]),
                                  b: CGFloat(values[1]),
                                  c: CGFloat(values[2]),
                                  d: CGFloat(values[3]),
                                  tx: CGFloat(values[4]),
                                  ty: CGFloat(values[5]))
        self.transform = t
        self.isCalibrated = true
    }

    // MARK: - Helpers

    private func average(of points: [CGPoint]) -> CGPoint {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count),
                       y: sum.y / CGFloat(points.count))
    }
}
