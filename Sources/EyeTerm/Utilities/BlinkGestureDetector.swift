import Foundation

final class BlinkGestureDetector {

    // MARK: - Configuration

    var closedThreshold: Double = 0.15
    var openThreshold: Double = 0.25
    var minWinkDuration: TimeInterval = 0.2
    var maxWinkDuration: TimeInterval = 0.5
    var bilateralRejectWindow: TimeInterval = 0.1
    var cooldown: TimeInterval = 0.8

    // MARK: - Callbacks

    var onLeftWink: (() -> Void)?
    var onRightWink: (() -> Void)?

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

    // MARK: - Update

    func update(leftAperture: Double?, rightAperture: Double?) {
        guard let left = leftAperture, let right = rightAperture else { return }

        let now = Date()
        let prevLeft = leftState
        let prevRight = rightState

        leftState = nextState(current: leftState, aperture: left, now: now)
        rightState = nextState(current: rightState, aperture: right, now: now)

        // Check bilateral rejection: both eyes entering closing within the reject window
        if case .closing(let lSince) = leftState, case .closing(let rSince) = rightState {
            if abs(lSince.timeIntervalSince(rSince)) < bilateralRejectWindow {
                bilateralRejected = true
            }
        }

        // Reset bilateral flag when both eyes return to open
        if case .open = leftState, case .open = rightState {
            bilateralRejected = false
        }

        // Detect wink: eye transitions from closed → open
        checkWink(prevState: prevLeft, newState: leftState, otherState: rightState, isLeft: true, now: now)
        checkWink(prevState: prevRight, newState: rightState, otherState: leftState, isLeft: false, now: now)
    }

    func reset() {
        leftState = .open
        rightState = .open
        lastWinkTime = nil
        bilateralRejected = false
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

        case .closed(let since):
            if aperture >= openThreshold {
                // Transitioning back to open — the caller checks for wink
                return .open
            }
            // Still closed
            return .closed(since: since)
        }
    }

    private func checkWink(prevState: EyeState, newState: EyeState, otherState: EyeState, isLeft: Bool, now: Date) {
        // Only trigger on closed → open transition
        guard case .closed(let closedSince) = prevState, case .open = newState else { return }

        // Reject if bilateral blink
        guard !bilateralRejected else { return }

        // Other eye must be open
        guard case .open = otherState else { return }

        // Check duration
        let duration = now.timeIntervalSince(closedSince)
        guard duration >= minWinkDuration && duration <= maxWinkDuration else { return }

        // Check cooldown
        if let last = lastWinkTime, now.timeIntervalSince(last) < cooldown { return }

        lastWinkTime = now
        if isLeft {
            onLeftWink?()
        } else {
            onRightWink?()
        }
    }
}
