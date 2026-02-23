import Foundation
import Observation

struct WinkCalibrationResult {
    var closedThreshold: Double
    var openThreshold: Double
    var minWinkDuration: Double
    var maxWinkDuration: Double
    var bilateralRejectWindow: Double
}

@Observable
final class WinkCalibrationManager {

    enum Step: Int, CaseIterable {
        case intro
        case eyesOpen
        case eyesClosed
        case naturalBlinks
        case leftWinkPractice
        case rightWinkPractice
        case results
    }

    // MARK: - Public State
    var currentStep: Step = .intro
    var progress: Double = 0          // 0–1 within the current collection step
    var statusMessage: String = ""
    var completedWinks: Int = 0       // for practice steps
    var requiredWinks: Int = 3        // for practice steps
    var result: WinkCalibrationResult? = nil

    // MARK: - Callbacks
    var onComplete: ((WinkCalibrationResult) -> Void)?
    var onCancel: (() -> Void)?

    // MARK: - Aperture source (set by AppCoordinator)
    var getLeftAperture: (() -> Double) = { 0 }
    var getRightAperture: (() -> Double) = { 0 }

    // MARK: - Private
    private var timer: Timer?
    private let targetFrames = 60
    private var openSamples: [Double] = []
    private var closedSamples: [Double] = []
    private var blinkDurations: [Double] = []
    private var winkDurations: [Double] = []

    // Blink/wink state tracking
    private var leftClosedStart: Date? = nil
    private var rightClosedStart: Date? = nil
    private var bothClosedStart: Date? = nil
    private var pendingBlinkClose: Date? = nil

    // MARK: - Navigation
    func advance() {
        stopTimer()
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
        startCurrentStep()
    }

    func cancel() {
        stopTimer()
        onCancel?()
    }

    func applyResult() {
        guard let r = result else { return }
        onComplete?(r)
    }

    // MARK: - Step Execution
    private func startCurrentStep() {
        progress = 0
        completedWinks = 0
        statusMessage = ""

        switch currentStep {
        case .intro:
            break
        case .eyesOpen:
            openSamples = []
            statusMessage = "Keep both eyes fully open."
            startCollectionTimer { [weak self] in
                guard let self else { return }
                let l = getLeftAperture()
                let r = getRightAperture()
                openSamples.append(l)
                openSamples.append(r)
            } onDone: { [weak self] in
                self?.advance()
            }
        case .eyesClosed:
            closedSamples = []
            statusMessage = "Close both eyes completely."
            startCollectionTimer { [weak self] in
                guard let self else { return }
                let l = getLeftAperture()
                let r = getRightAperture()
                closedSamples.append(l)
                closedSamples.append(r)
            } onDone: { [weak self] in
                self?.advance()
            }
        case .naturalBlinks:
            blinkDurations = []
            bothClosedStart = nil
            statusMessage = "Blink normally 5 times."
            startBlinkDetection(targetCount: 5, bilateral: true) { [weak self] in
                self?.advance()
            }
        case .leftWinkPractice:
            winkDurations = []
            leftClosedStart = nil
            statusMessage = "Wink your LEFT eye 3 times."
            startBlinkDetection(targetCount: 3, bilateral: false, side: .left) { [weak self] in
                self?.advance()
            }
        case .rightWinkPractice:
            winkDurations = []
            rightClosedStart = nil
            statusMessage = "Wink your RIGHT eye 3 times."
            startBlinkDetection(targetCount: 3, bilateral: false, side: .right) { [weak self] in
                self?.computeResult()
                self?.currentStep = .results
            }
        case .results:
            break
        }
    }

    // MARK: - Collection Timer (fixed frame count)
    private func startCollectionTimer(onFrame: @escaping () -> Void, onDone: @escaping () -> Void) {
        var framesCollected = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            onFrame()
            framesCollected += 1
            progress = Double(framesCollected) / Double(targetFrames)
            if framesCollected >= targetFrames {
                stopTimer()
                onDone()
            }
        }
    }

    // MARK: - Blink/Wink Detection Timer
    private enum WinkSide { case left, right }

    private func startBlinkDetection(targetCount: Int, bilateral: Bool, side: WinkSide? = nil, onDone: @escaping () -> Void) {
        let closedThresholdEstimate = closedSamples.isEmpty ? 0.15 : percentile(closedSamples, p: 0.5)
        let openThresholdEstimate = openSamples.isEmpty ? 0.25 : percentile(openSamples, p: 0.75)
        let midpoint = (closedThresholdEstimate + openThresholdEstimate) / 2.0

        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            let l = getLeftAperture()
            let r = getRightAperture()
            let leftClosed = l < midpoint
            let rightClosed = r < midpoint
            let now = Date()

            if bilateral {
                // Both eyes closed = natural blink
                if leftClosed && rightClosed {
                    if bothClosedStart == nil { bothClosedStart = now }
                } else {
                    if let start = bothClosedStart {
                        let duration = now.timeIntervalSince(start)
                        if duration >= 0.05 && duration <= 0.5 {
                            blinkDurations.append(duration)
                            completedWinks = blinkDurations.count
                            progress = min(Double(completedWinks) / Double(targetCount), 1.0)
                            if completedWinks >= targetCount {
                                stopTimer()
                                onDone()
                            }
                        }
                        bothClosedStart = nil
                    }
                }
            } else {
                // Wink detection: one eye closed, other stays open
                let targetClosed = side == .left ? leftClosed : rightClosed
                let otherOpen = side == .left ? !rightClosed : !leftClosed

                if targetClosed && otherOpen {
                    let start: Date?
                    if side == .left {
                        start = leftClosedStart
                        if leftClosedStart == nil { leftClosedStart = now }
                    } else {
                        start = rightClosedStart
                        if rightClosedStart == nil { rightClosedStart = now }
                    }
                    _ = start
                } else {
                    let startRef: Date?
                    if side == .left {
                        startRef = leftClosedStart
                        leftClosedStart = nil
                    } else {
                        startRef = rightClosedStart
                        rightClosedStart = nil
                    }
                    if let start = startRef {
                        let duration = now.timeIntervalSince(start)
                        if duration >= 0.08 && duration <= 1.5 {
                            winkDurations.append(duration)
                            completedWinks = winkDurations.count
                            progress = min(Double(completedWinks) / Double(targetCount), 1.0)
                            if completedWinks >= targetCount {
                                stopTimer()
                                onDone()
                            }
                        }
                    }
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Result Computation
    private func computeResult() {
        let closed = percentile(closedSamples.isEmpty ? [0.10] : closedSamples, p: 0.5)
        let open = percentile(openSamples.isEmpty ? [0.35] : openSamples, p: 0.75)

        let minWink = max(0.08, winkDurations.min() ?? 0.15)
        let maxWink = min(1.5, winkDurations.max() ?? 0.6)
        let bilateralWindow = blinkDurations.isEmpty ? 0.1 : blinkDurations.reduce(0, +) / Double(blinkDurations.count)

        result = WinkCalibrationResult(
            closedThreshold: closed,
            openThreshold: open,
            minWinkDuration: minWink,
            maxWinkDuration: maxWink,
            bilateralRejectWindow: bilateralWindow
        )
    }

    // MARK: - Stats
    private func percentile(_ samples: [Double], p: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let idx = max(0, min(sorted.count - 1, Int((p * Double(sorted.count - 1)).rounded())))
        return sorted[idx]
    }
}
