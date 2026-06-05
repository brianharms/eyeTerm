import CoreGraphics

struct EyeTermEMAFilter {
    var alpha: Double

    private var smoothedX: Double?
    private var smoothedY: Double?

    init(alpha: Double = 0.3) {
        self.alpha = alpha
    }

    mutating func update(_ point: CGPoint) -> CGPoint {
        guard let sx = smoothedX, let sy = smoothedY else {
            smoothedX = point.x
            smoothedY = point.y
            return point
        }

        let newX = alpha * point.x + (1.0 - alpha) * sx
        let newY = alpha * point.y + (1.0 - alpha) * sy
        smoothedX = newX
        smoothedY = newY
        return CGPoint(x: newX, y: newY)
    }

    mutating func reset() {
        smoothedX = nil
        smoothedY = nil
    }
}
