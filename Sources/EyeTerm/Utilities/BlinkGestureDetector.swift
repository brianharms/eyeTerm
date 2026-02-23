import Foundation

struct WinkDiagnosticEvent {
    enum Side { case left, right }
    enum Outcome {
        case fired
        case bilateralBlink
        case otherEyeNotOpen
        case otherEyeDipped(otherMin: Double)
        case tooShort(duration: Double)
        case tooLong(duration: Double)
        case cooldown(remaining: Double)
    }
    let side: Side
    let duration: Double
    let otherEyeMin: Double
    let outcome: Outcome
    let timestamp: Date
}

final class BlinkGestureDetector {

    // MARK: - Configuration

    var closedThreshold: Double = 0.15
    var openThreshold: Double = 0.25
    var minWinkDuration: TimeInterval = 0.2
    var maxWinkDuration: TimeInterval = 0.5
    var bilateralRejectWindow: TimeInterval = 0.15
    var cooldown: TimeInterval = 0.8

    // MARK: - Callbacks

    var onLeftWink: (() -> Void)?
    var onRightWink: (() -> Void)?
    var onDiagnosticEvent: ((WinkDiagnosticEvent) -> Void)?

    // MARK: - State

    private enum EyeState {
        case open
        case closing(since: Date)
        case closed(since: Date)
    }

    private var leftState: EyeState = .open
    private var rightState: EyeState = .open
    private var lastWinkTime: Date?
    private var bilateralRejected = false
    private var bilateralRejectedSince: Date? = nil

    /// Track the other eye's minimum aperture while one eye is closing/closed.
    /// If the other eye dips below openThreshold at any point, it's a blink, not a wink.
    private var otherEyeMinDuringLeftClose: Double = 1.0
    private var otherEyeMinDuringRightClose: Double = 1.0

    // MARK: - Update

    func update(leftAperture: Double?, rightAperture: Double?) {
        guard let left = leftAperture, let right = rightAperture else { return }

        let now = Date()
        let prevLeft = leftState
        let prevRight = rightState

        leftState = nextState(current: leftState, aperture: left, now: now)
        rightState = nextState(current: rightState, aperture: right, now: now)

        // Track other eye's minimum aperture while each eye is closing/closed
        switch leftState {
        case .closing, .closed:
            otherEyeMinDuringLeftClose = min(otherEyeMinDuringLeftClose, right)
        case .open:
            if case .open = prevLeft {} else {
                // Just transitioned to open — min will be checked in checkWink, then reset
            }
        }

        switch rightState {
        case .closing, .closed:
            otherEyeMinDuringRightClose = min(otherEyeMinDuringRightClose, left)
        case .open:
            if case .open = prevRight {} else {
                // Just transitioned to open — min will be checked in checkWink, then reset
            }
        }

        // Check bilateral rejection: both eyes entering closing within the reject window
        if case .closing(let lSince) = leftState, case .closing(let rSince) = rightState {
            if abs(lSince.timeIntervalSince(rSince)) < bilateralRejectWindow {
                bilateralRejected = true
                bilateralRejectedSince = now
            }
        }

        // Reset bilateral flag when both eyes return to open
        // Also expire the flag after maxWinkDuration * 2 to prevent permanent lock
        if bilateralRejected, let since = bilateralRejectedSince,
           now.timeIntervalSince(since) > maxWinkDuration * 2 {
            bilateralRejected = false
            bilateralRejectedSince = nil
        }
        if case .open = leftState, case .open = rightState {
            bilateralRejected = false
            bilateralRejectedSince = nil
        }

        // Detect wink: eye transitions from closed → open
        checkWink(prevState: prevLeft, newState: leftState, otherState: rightState,
                  otherEyeMin: otherEyeMinDuringLeftClose, isLeft: true, now: now)
        checkWink(prevState: prevRight, newState: rightState, otherState: leftState,
                  otherEyeMin: otherEyeMinDuringRightClose, isLeft: false, now: now)

        // Reset min tracking after wink check on transition to open
        if case .open = leftState {
            if case .closing = prevLeft { otherEyeMinDuringLeftClose = 1.0 }
            if case .closed = prevLeft { otherEyeMinDuringLeftClose = 1.0 }
        }
        if case .open = rightState {
            if case .closing = prevRight { otherEyeMinDuringRightClose = 1.0 }
            if case .closed = prevRight { otherEyeMinDuringRightClose = 1.0 }
        }
    }

    func reset() {
        leftState = .open
        rightState = .open
        lastWinkTime = nil
        bilateralRejected = false
        bilateralRejectedSince = nil
        otherEyeMinDuringLeftClose = 1.0
        otherEyeMinDuringRightClose = 1.0
    }

    // MARK: - Internals

    private func nextState(current: EyeState, aperture: Double, now: Date) -> EyeState {
        switch current {
        case .open:
            if aperture < closedThreshold {
                return .closing(since: now)
            }
            return .open

        case .closing(let since):
            if aperture >= openThreshold {
                return .open
            }
            if aperture < closedThreshold {
                return .closed(since: since)
            }
            return current

        case .closed:
            if aperture >= openThreshold {
                return .open
            }
            return current
        }
    }

    private func checkWink(prevState: EyeState, newState: EyeState, otherState: EyeState,
                           otherEyeMin: Double, isLeft: Bool, now: Date) {
        let side: WinkDiagnosticEvent.Side = isLeft ? .left : .right

        // Only trigger on closed → open transition
        guard case .closed(let closedSince) = prevState, case .open = newState else { return }
        let duration = now.timeIntervalSince(closedSince)

        // Reject if bilateral blink
        if bilateralRejected {
            onDiagnosticEvent?(WinkDiagnosticEvent(side: side, duration: duration, otherEyeMin: otherEyeMin, outcome: .bilateralBlink, timestamp: now))
            return
        }

        // Other eye must be open right now
        if case .closing = otherState {
            onDiagnosticEvent?(WinkDiagnosticEvent(side: side, duration: duration, otherEyeMin: otherEyeMin, outcome: .otherEyeNotOpen, timestamp: now))
            return
        }
        if case .closed = otherState {
            onDiagnosticEvent?(WinkDiagnosticEvent(side: side, duration: duration, otherEyeMin: otherEyeMin, outcome: .otherEyeNotOpen, timestamp: now))
            return
        }

        // Reject if the other eye dipped below openThreshold at any point during the wink.
        if otherEyeMin < openThreshold {
            onDiagnosticEvent?(WinkDiagnosticEvent(side: side, duration: duration, otherEyeMin: otherEyeMin, outcome: .otherEyeDipped(otherMin: otherEyeMin), timestamp: now))
            return
        }

        // Check duration
        if duration < minWinkDuration {
            onDiagnosticEvent?(WinkDiagnosticEvent(side: side, duration: duration, otherEyeMin: otherEyeMin, outcome: .tooShort(duration: duration), timestamp: now))
            return
        }
        if duration > maxWinkDuration {
            onDiagnosticEvent?(WinkDiagnosticEvent(side: side, duration: duration, otherEyeMin: otherEyeMin, outcome: .tooLong(duration: duration), timestamp: now))
            return
        }

        // Check cooldown
        if let last = lastWinkTime {
            let elapsed = now.timeIntervalSince(last)
            if elapsed < cooldown {
                onDiagnosticEvent?(WinkDiagnosticEvent(side: side, duration: duration, otherEyeMin: otherEyeMin, outcome: .cooldown(remaining: cooldown - elapsed), timestamp: now))
                return
            }
        }

        lastWinkTime = now
        onDiagnosticEvent?(WinkDiagnosticEvent(side: side, duration: duration, otherEyeMin: otherEyeMin, outcome: .fired, timestamp: now))
        if isLeft {
            onLeftWink?()
        } else {
            onRightWink?()
        }
    }
}
