import Foundation

final class DwellTimer {
    private var trackingQuadrant: ScreenQuadrant?
    private var trackingStart: Date?
    private var hysteresisCleared = false
    private var confirmedQuadrant: ScreenQuadrant?

    var dwellThreshold: TimeInterval
    var hysteresisDelay: TimeInterval
    var onDwellConfirmed: ((ScreenQuadrant) -> Void)?
    var onDwellProgress: ((ScreenQuadrant, Double) -> Void)?

    /// Total time from first gaze frame to confirmation.
    private var totalTime: TimeInterval { hysteresisDelay + dwellThreshold }

    init(dwellThreshold: TimeInterval = 1.0, hysteresisDelay: TimeInterval = 0.3) {
        self.dwellThreshold = dwellThreshold
        self.hysteresisDelay = hysteresisDelay
    }

    func update(quadrant: ScreenQuadrant?) {
        guard let quadrant = quadrant else {
            reset()
            return
        }

        if quadrant == trackingQuadrant {
            // Same quadrant — report unified progress across hysteresis + dwell
            guard let start = trackingStart, quadrant != confirmedQuadrant else { return }
            let elapsed = Date().timeIntervalSince(start)
            let progress = min(elapsed / totalTime, 1.0)
            onDwellProgress?(quadrant, progress)

            if !hysteresisCleared && elapsed >= hysteresisDelay {
                hysteresisCleared = true
            }

            if elapsed >= totalTime {
                confirmedQuadrant = quadrant
                onDwellConfirmed?(quadrant)
            }
        } else {
            // New quadrant — start tracking immediately
            trackingQuadrant = quadrant
            trackingStart = Date()
            hysteresisCleared = false
            confirmedQuadrant = nil
            onDwellProgress?(quadrant, 0)
        }
    }

    func reset() {
        trackingQuadrant = nil
        trackingStart = nil
        hysteresisCleared = false
        confirmedQuadrant = nil
    }
}
