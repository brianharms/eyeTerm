import SwiftUI

struct EyeTermOverlayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if appState.overlayMode == .subtle || appState.overlayMode == .debug {
                    SubtleOverlayContent(size: size, appState: appState)
                }
                if appState.overlayMode == .debug {
                    DebugOverlayContent(size: size, appState: appState)
                }
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Subtle Overlay

private struct SubtleOverlayContent: View {
    let size: CGSize
    let appState: AppState

    private let bracketLength: CGFloat = 24
    private let bracketThickness: CGFloat = 2
    private let inset: CGFloat = 8

    var body: some View {
        let midX = size.width / 2
        let midY = size.height / 2

        ForEach(ScreenQuadrant.allCases) { quadrant in
            let isActive = quadrant == appState.activeQuadrant
            let isFocused = quadrant == appState.focusedQuadrant
            let isDwelling = quadrant == appState.dwellingQuadrant
            let progress = isDwelling ? appState.dwellProgress : 0
            let opacity = isFocused ? 1.0 : (isActive ? 0.7 : 0.25)

            cornerBrackets(for: quadrant, midX: midX, midY: midY)
                .foregroundStyle(.white.opacity(opacity))
                .animation(.easeOut(duration: 0.15), value: isActive)
                .animation(.easeOut(duration: 0.15), value: isFocused)

            // Dwell progress border
            if isDwelling && !isFocused && progress > 0 {
                let rect = quadrantRect(quadrant, midX: midX, midY: midY)
                Rectangle()
                    .strokeBorder(.cyan.opacity(0.4 * progress), lineWidth: 2 + 2 * progress)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

            // Confirmed flash border
            if isFocused {
                let rect = quadrantRect(quadrant, midX: midX, midY: midY)
                Rectangle()
                    .strokeBorder(.cyan.opacity(0.6), lineWidth: 3)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.2), value: isFocused)
            }
        }
    }

    private func quadrantRect(_ quadrant: ScreenQuadrant, midX: CGFloat, midY: CGFloat) -> CGRect {
        switch quadrant {
        case .topLeft: CGRect(x: 0, y: 0, width: midX, height: midY)
        case .topRight: CGRect(x: midX, y: 0, width: midX, height: midY)
        case .bottomLeft: CGRect(x: 0, y: midY, width: midX, height: midY)
        case .bottomRight: CGRect(x: midX, y: midY, width: midX, height: midY)
        }
    }

    @ViewBuilder
    private func cornerBrackets(for quadrant: ScreenQuadrant, midX: CGFloat, midY: CGFloat) -> some View {
        let corner = cornerPoint(for: quadrant, midX: midX, midY: midY)

        let hDir: CGFloat = (quadrant == .topLeft || quadrant == .bottomLeft) ? 1 : -1
        let vDir: CGFloat = (quadrant == .topLeft || quadrant == .topRight) ? 1 : -1

        // Horizontal arm
        Rectangle()
            .frame(width: bracketLength, height: bracketThickness)
            .position(
                x: corner.x + hDir * (bracketLength / 2 + inset),
                y: corner.y
            )

        // Vertical arm
        Rectangle()
            .frame(width: bracketThickness, height: bracketLength)
            .position(
                x: corner.x,
                y: corner.y + vDir * (bracketLength / 2 + inset)
            )
    }

    private func cornerPoint(for quadrant: ScreenQuadrant, midX: CGFloat, midY: CGFloat) -> CGPoint {
        switch quadrant {
        case .topLeft: CGPoint(x: 0, y: 0)
        case .topRight: CGPoint(x: size.width, y: 0)
        case .bottomLeft: CGPoint(x: 0, y: size.height)
        case .bottomRight: CGPoint(x: size.width, y: size.height)
        }
    }
}

// MARK: - Debug Overlay

private struct DebugOverlayContent: View {
    let size: CGSize
    let appState: AppState

    var body: some View {
        let midX = size.width / 2
        let midY = size.height / 2
        let rawX = appState.rawGazePoint.x * size.width
        let rawY = appState.rawGazePoint.y * size.height
        let calX = appState.calibratedGazePoint.x * size.width
        let calY = appState.calibratedGazePoint.y * size.height
        let smoothX = appState.smoothedGazePoint.x * size.width
        let smoothY = appState.smoothedGazePoint.y * size.height

        // Quadrant fills
        ForEach(ScreenQuadrant.allCases) { quadrant in
            let rect = quadrantRect(quadrant, midX: midX, midY: midY)
            let isActive = quadrant == appState.activeQuadrant
            let isFocused = quadrant == appState.focusedQuadrant

            if isFocused {
                Rectangle()
                    .fill(.green.opacity(0.15))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.2), value: isFocused)
            } else if isActive {
                Rectangle()
                    .fill(.yellow.opacity(0.08))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.15), value: isActive)
            }
        }

        // Quadrant grid lines (dashed)
        Path { path in
            path.move(to: CGPoint(x: midX, y: 0))
            path.addLine(to: CGPoint(x: midX, y: size.height))
        }
        .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        .foregroundStyle(.white.opacity(0.2))

        Path { path in
            path.move(to: CGPoint(x: 0, y: midY))
            path.addLine(to: CGPoint(x: size.width, y: midY))
        }
        .stroke(style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
        .foregroundStyle(.white.opacity(0.2))

        // Head gaze point (orange, head icon)
        let headPX = appState.headGazePoint.x * size.width
        let headPY = appState.headGazePoint.y * size.height
        // Pupil gaze point (green, eye icon)
        let pupilPX = appState.pupilGazePoint.x * size.width
        let pupilPY = appState.pupilGazePoint.y * size.height

        // Fusion line from eye to head
        Path { path in
            path.move(to: CGPoint(x: pupilPX, y: pupilPY))
            path.addLine(to: CGPoint(x: headPX, y: headPY))
        }
        .stroke(.white.opacity(0.25), lineWidth: 1)

        // Fusion point on the line (based on head weight slider)
        let hw = appState.headWeight
        let fusionLineX = pupilPX + (headPX - pupilPX) * hw
        let fusionLineY = pupilPY + (headPY - pupilPY) * hw
        Circle()
            .fill(.white.opacity(0.5))
            .frame(width: 6, height: 6)
            .position(x: fusionLineX, y: fusionLineY)

        Image(systemName: "person.fill")
            .font(.system(size: 14))
            .foregroundStyle(.orange.opacity(0.8))
            .position(x: headPX, y: headPY)

        Image(systemName: "eye.fill")
            .font(.system(size: 12))
            .foregroundStyle(.green.opacity(0.8))
            .position(x: pupilPX, y: pupilPY)

        // Calibrated head gaze point
        let calHeadPX = appState.calibratedHeadGazePoint.x * size.width
        let calHeadPY = appState.calibratedHeadGazePoint.y * size.height
        // Calibrated pupil gaze point
        let calPupilPX = appState.calibratedPupilGazePoint.x * size.width
        let calPupilPY = appState.calibratedPupilGazePoint.y * size.height

        // Calibrated fusion line from eye to head
        Path { path in
            path.move(to: CGPoint(x: calPupilPX, y: calPupilPY))
            path.addLine(to: CGPoint(x: calHeadPX, y: calHeadPY))
        }
        .stroke(.yellow.opacity(0.3), lineWidth: 1)

        // Calibrated fusion point on the line
        let calFusionX = calPupilPX + (calHeadPX - calPupilPX) * hw
        let calFusionY = calPupilPY + (calHeadPY - calPupilPY) * hw
        Circle()
            .fill(.yellow.opacity(0.5))
            .frame(width: 6, height: 6)
            .position(x: calFusionX, y: calFusionY)

        Image(systemName: "person")
            .font(.system(size: 14))
            .foregroundStyle(.orange.opacity(0.5))
            .position(x: calHeadPX, y: calHeadPY)

        Image(systemName: "eye")
            .font(.system(size: 12))
            .foregroundStyle(.green.opacity(0.5))
            .position(x: calPupilPX, y: calPupilPY)

        // Raw fused gaze point (red, small)
        Circle()
            .fill(.red.opacity(0.6))
            .frame(width: 6, height: 6)
            .position(x: rawX, y: rawY)

        // Calibrated gaze point (yellow)
        Circle()
            .fill(.yellow.opacity(0.7))
            .frame(width: 8, height: 8)
            .position(x: calX, y: calY)

        // Smoothed gaze point (cyan) with crosshairs
        Path { path in
            path.move(to: CGPoint(x: smoothX, y: 0))
            path.addLine(to: CGPoint(x: smoothX, y: size.height))
        }
        .stroke(.cyan.opacity(0.3), lineWidth: 0.5)

        Path { path in
            path.move(to: CGPoint(x: 0, y: smoothY))
            path.addLine(to: CGPoint(x: size.width, y: smoothY))
        }
        .stroke(.cyan.opacity(0.3), lineWidth: 0.5)

        Circle()
            .fill(.cyan)
            .frame(width: 12, height: 12)
            .position(x: smoothX, y: smoothY)

        // HUD panel
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(.orange)
                Text("Head: \(f(appState.headGazePoint.x)), \(f(appState.headGazePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "eye.fill").font(.system(size: 8)).foregroundStyle(.green)
                Text("Pupil: \(f(appState.pupilGazePoint.x)), \(f(appState.pupilGazePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "person").font(.system(size: 8)).foregroundStyle(.orange.opacity(0.5))
                Text("Cal Head: \(f(appState.calibratedHeadGazePoint.x)), \(f(appState.calibratedHeadGazePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "eye").font(.system(size: 8)).foregroundStyle(.green.opacity(0.5))
                Text("Cal Pupil: \(f(appState.calibratedPupilGazePoint.x)), \(f(appState.calibratedPupilGazePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.red.opacity(0.6)).frame(width: 6, height: 6)
                Text("Fused: \(f(appState.rawGazePoint.x)), \(f(appState.rawGazePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.yellow.opacity(0.7)).frame(width: 6, height: 6)
                Text("Cal: \(f(appState.calibratedGazePoint.x)), \(f(appState.calibratedGazePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.cyan).frame(width: 6, height: 6)
                Text("Smooth: \(f(appState.smoothedGazePoint.x)), \(f(appState.smoothedGazePoint.y))")
            }
            Text("Confidence: \(Int(appState.gazeConfidence * 100))%")
            Text("Yaw: \(fd(appState.headYaw))  Pitch: \(fd(appState.headPitch))")
            if let active = appState.activeQuadrant {
                Text("Looking: \(active.displayName)")
                    .foregroundStyle(.yellow)
            }
            if let focused = appState.focusedQuadrant {
                Text("Focused: \(focused.displayName)")
                    .foregroundStyle(.green)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.green)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .position(x: 100, y: 80)
    }

    private func quadrantRect(_ quadrant: ScreenQuadrant, midX: CGFloat, midY: CGFloat) -> CGRect {
        switch quadrant {
        case .topLeft: CGRect(x: 0, y: 0, width: midX, height: midY)
        case .topRight: CGRect(x: midX, y: 0, width: midX, height: midY)
        case .bottomLeft: CGRect(x: 0, y: midY, width: midX, height: midY)
        case .bottomRight: CGRect(x: midX, y: midY, width: midX, height: midY)
        }
    }

    private func f(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private func fd(_ value: Double) -> String {
        String(format: "%+.3f", value)
    }
}
