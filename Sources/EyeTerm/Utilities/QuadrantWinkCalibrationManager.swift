import Foundation
import Observation

// MARK: - Result type

struct WinkThresholds {
    let closedThreshold: Double
    let openThreshold: Double
    let dipThreshold: Double
    let minDuration: Double
    let maxDuration: Double
    /// Number of winks detected when these thresholds are replayed against the recorded samples.
    let detectedWinks: Int
}

// MARK: - Manager

/// Collects raw eye-aperture samples while the user winks, then computes
/// thresholds from the distribution — no real-time dip detection required.
///
/// Strategy:
///   • The winking eye spends most of its time OPEN → high-percentile samples = resting level.
///   • The bottom percentile samples contain the wink minima.
///   • Thresholds are placed between those two levels, tuned to this user's baseline.
///   • After computing thresholds, they are replayed against the recorded samples to verify
///     ≥5 winks are detected. If not, thresholds are loosened iteratively until they are.
@Observable
final class WinkCalibrationManager {

    enum Eye { case right, left }

    enum Phase {
        case collecting
        case results(WinkThresholds)
        case done
    }

    // MARK: - Observed state

    private(set) var phase: Phase = .collecting
    /// Rough live wink count for UI feedback only — not used in computation.
    private(set) var detectedWinkCount: Int = 0

    // MARK: - Callbacks

    var onComplete: ((WinkThresholds) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Config

    let eye: Eye

    // MARK: - Raw sample storage

    private var winkingEyeSamples: [Double] = []  // winking eye aperture every frame
    private var otherEyeSamples:   [Double] = []  // non-winking eye every frame

    // MARK: - Live wink counter state (heuristic only)
    private let liveClosedLevel: Double = 0.35
    private let liveOpenLevel:   Double = 0.50
    private var liveInDip = false

    // MARK: - Init

    init(eye: Eye) {
        self.eye = eye
    }

    // MARK: - Lifecycle

    func finish() {
        guard case .collecting = phase else { return }
        let thresholds = computeThresholds()
        phase = .results(thresholds)
    }

    func cancel() {
        phase = .done
        onCancel?()
    }

    func acceptResults() {
        guard case .results(let t) = phase else { return }
        phase = .done
        onComplete?(t)
    }

    // MARK: - Aperture feed

    func update(leftAperture: Double, rightAperture: Double) {
        guard case .collecting = phase else { return }

        let winking = eye == .right ? rightAperture : leftAperture
        let other   = eye == .right ? leftAperture  : rightAperture

        winkingEyeSamples.append(winking)
        otherEyeSamples.append(other)

        // Heuristic live counter — purely for dot indicators in the UI.
        if !liveInDip && winking < liveClosedLevel {
            liveInDip = true
        } else if liveInDip && winking > liveOpenLevel {
            liveInDip = false
            detectedWinkCount += 1
        }
    }

    // MARK: - Threshold computation

    private func computeThresholds() -> WinkThresholds {
        guard winkingEyeSamples.count >= 10 else {
            return fallbackThresholds()
        }

        // Resting open level: p75 of all winking-eye samples.
        // The eye is open the vast majority of the time so this captures the open plateau.
        let openLevel = percentile(75, winkingEyeSamples)

        // Wink floor: p5 of all winking-eye samples.
        // These are the deepest moments during winks.
        let winkFloor = percentile(5, winkingEyeSamples)

        let gap = openLevel - winkFloor

        // Need a meaningful gap to compute useful thresholds.
        guard gap > 0.05 else { return fallbackThresholds() }

        // closedThreshold: 35% of the way from wink floor to open level.
        // Sits above the typical wink minimum, well below resting open.
        let rawClosed = winkFloor + gap * 0.35
        let closedThreshold = rawClosed.clamped(to: 0.07...0.55)

        // openThreshold: 75% of the way from wink floor to open level.
        // Eye must clearly re-open before the wink is considered finished.
        let rawOpen = winkFloor + gap * 0.75
        let openThreshold = max(closedThreshold + 0.05, rawOpen).clamped(to: 0.10...0.60)

        // dipThreshold: non-winking eye must stay ABOVE this during a wink.
        // This is a floor — if the other eye drops below it, both eyes are closing (a blink).
        // Must be BELOW openThreshold, not above it.
        let rawDip = percentile(15, otherEyeSamples) - 0.03
        let dipMax = max(0.20, openThreshold - 0.08)   // always below open threshold
        let dipThreshold = rawDip.clamped(to: 0.10...dipMax)

        let initial = WinkThresholds(
            closedThreshold: closedThreshold,
            openThreshold: openThreshold,
            dipThreshold: dipThreshold,
            minDuration: 0.10,
            maxDuration: 0.80,
            detectedWinks: 0
        )

        return autoAdjusted(initial)
    }

    private func fallbackThresholds() -> WinkThresholds {
        let t = WinkThresholds(
            closedThreshold: 0.15, openThreshold: 0.28,
            dipThreshold: 0.25, minDuration: 0.10, maxDuration: 0.80,
            detectedWinks: 0
        )
        return autoAdjusted(t)
    }

    // MARK: - Replay validation + auto-adjustment

    /// Replays the recorded samples through a simple state-machine wink detector
    /// using the given thresholds. Returns the number of valid winks detected.
    private func replayWinkCount(thresholds t: WinkThresholds, sampleRate: Double = 30.0) -> Int {
        let dt = 1.0 / sampleRate
        var count = 0
        var inWink = false
        var winkStartTime = 0.0
        var currentTime = 0.0

        for i in 0..<winkingEyeSamples.count {
            let w = winkingEyeSamples[i]
            let o = i < otherEyeSamples.count ? otherEyeSamples[i] : 1.0

            if !inWink {
                // Enter wink: winking eye closes AND other eye stays open
                if w < t.closedThreshold && o > t.dipThreshold {
                    inWink = true
                    winkStartTime = currentTime
                }
            } else {
                // Exit wink: winking eye re-opens
                if w > t.openThreshold {
                    let duration = currentTime - winkStartTime
                    if duration >= t.minDuration && duration <= t.maxDuration {
                        count += 1
                    }
                    inWink = false
                }
                // If other eye also dropped (bilateral blink), abort this wink
                else if o <= t.dipThreshold {
                    inWink = false
                }
            }
            currentTime += dt
        }
        return count
    }

    /// Iteratively loosens thresholds until ≥5 winks are detected in the replay,
    /// or gives up after 15 iterations and returns the best result found.
    private func autoAdjusted(_ initial: WinkThresholds) -> WinkThresholds {
        var t = initial
        var best = initial
        var bestCount = 0

        for _ in 0..<15 {
            let detected = replayWinkCount(thresholds: t)
            if detected > bestCount {
                bestCount = detected
                best = t
            }
            if detected >= 5 { break }

            // Loosen: raise closedThreshold (easier to enter closed state),
            // keep openThreshold paired above it, widen duration window.
            let newClosed = min(t.closedThreshold + 0.03, 0.65)
            let newOpen   = max(t.openThreshold - 0.02, newClosed + 0.05).clamped(to: 0.10...0.70)
            let newMin    = max(t.minDuration - 0.01, 0.04)
            let newMax    = min(t.maxDuration + 0.05, 1.5)

            t = WinkThresholds(
                closedThreshold: newClosed,
                openThreshold: newOpen,
                dipThreshold: t.dipThreshold,
                minDuration: newMin,
                maxDuration: newMax,
                detectedWinks: 0
            )
        }

        // Attach the final verified count to whichever thresholds won.
        let finalCount = replayWinkCount(thresholds: best)
        return WinkThresholds(
            closedThreshold: best.closedThreshold,
            openThreshold: best.openThreshold,
            dipThreshold: best.dipThreshold,
            minDuration: best.minDuration,
            maxDuration: best.maxDuration,
            detectedWinks: finalCount
        )
    }

    // MARK: - Stats

    private func percentile(_ p: Int, _ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0.5 }
        let sorted = values.sorted()
        let idx = Double(p) / 100.0 * Double(sorted.count - 1)
        let lo = Int(idx)
        let hi = min(lo + 1, sorted.count - 1)
        return sorted[lo] * (1.0 - (idx - Double(lo))) + sorted[hi] * (idx - Double(lo))
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
