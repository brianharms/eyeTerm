import Foundation

final class DwellTimer {
    private var trackingSlot: Int?
    private var trackingStart: Date?
    private var hysteresisCleared = false
    private var confirmedSlot: Int?

    var dwellThreshold: TimeInterval
    var hysteresisDelay: TimeInterval
    var onDwellConfirmed: ((Int) -> Void)?
    var onDwellProgress: ((Int, Double) -> Void)?

    /// Total time from first gaze frame to confirmation.
    private var totalTime: TimeInterval { hysteresisDelay + dwellThreshold }

    init(dwellThreshold: TimeInterval = 1.0, hysteresisDelay: TimeInterval = 0.3) {
        self.dwellThreshold = dwellThreshold
        self.hysteresisDelay = hysteresisDelay
    }

    func update(slot: Int?) {
        guard let slot = slot else {
            reset()
            return
        }

        if slot == trackingSlot {
            // Same slot — report unified progress across hysteresis + dwell
            guard let start = trackingStart, slot != confirmedSlot else { return }
            let elapsed = Date().timeIntervalSince(start)
            let progress = min(elapsed / totalTime, 1.0)
            onDwellProgress?(slot, progress)

            if !hysteresisCleared && elapsed >= hysteresisDelay {
                hysteresisCleared = true
            }

            if elapsed >= totalTime {
                confirmedSlot = slot
                onDwellConfirmed?(slot)
            }
        } else {
            // New slot — start tracking immediately
            trackingSlot = slot
            trackingStart = Date()
            hysteresisCleared = false
            confirmedSlot = nil
            onDwellProgress?(slot, 0)
        }
    }

    func reset() {
        trackingSlot = nil
        trackingStart = nil
        hysteresisCleared = false
        confirmedSlot = nil
    }
}
