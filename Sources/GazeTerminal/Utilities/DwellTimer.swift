import Foundation

final class DwellTimer {
    private var currentQuadrant: ScreenQuadrant?
    private var dwellStart: Date?
    private var hysteresisTimer: Timer?
    private var confirmedQuadrant: ScreenQuadrant?

    var dwellThreshold: TimeInterval
    var hysteresisDelay: TimeInterval
    var onDwellConfirmed: ((ScreenQuadrant) -> Void)?

    init(dwellThreshold: TimeInterval = 1.0, hysteresisDelay: TimeInterval = 0.3) {
        self.dwellThreshold = dwellThreshold
        self.hysteresisDelay = hysteresisDelay
    }

    func update(quadrant: ScreenQuadrant?) {
        guard let quadrant = quadrant else {
            reset()
            return
        }

        if quadrant == currentQuadrant {
            // Same quadrant — check if dwell threshold met
            if let start = dwellStart,
               quadrant != confirmedQuadrant,
               Date().timeIntervalSince(start) >= dwellThreshold {
                confirmedQuadrant = quadrant
                onDwellConfirmed?(quadrant)
            }
        } else {
            // Different quadrant — start hysteresis delay before switching
            hysteresisTimer?.invalidate()
            hysteresisTimer = Timer.scheduledTimer(withTimeInterval: hysteresisDelay, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.currentQuadrant = quadrant
                self.dwellStart = Date()
                self.confirmedQuadrant = nil
            }
        }
    }

    func reset() {
        hysteresisTimer?.invalidate()
        hysteresisTimer = nil
        currentQuadrant = nil
        dwellStart = nil
        confirmedQuadrant = nil
    }
}
