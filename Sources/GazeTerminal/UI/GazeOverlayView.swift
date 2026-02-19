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

    var body: some View {
        let midX = size.width / 2
        let midY = size.height / 2
        let smoothX = appState.smoothedGazePoint.x * size.width
        let smoothY = appState.smoothedGazePoint.y * size.height

        Circle()
            .fill(.blue.opacity(appState.subtleGazeOpacity))
            .frame(width: appState.subtleGazeSize, height: appState.subtleGazeSize)
            .position(x: smoothX, y: smoothY)

        ForEach(ScreenQuadrant.allCases) { quadrant in
            let isFocused = quadrant == appState.focusedQuadrant
            let isDwelling = quadrant == appState.dwellingQuadrant
            let progress = isDwelling ? appState.dwellProgress : 0

            // Dwell progress border
            if isDwelling && !isFocused && progress > 0 {
                let rect = quadrantRect(quadrant, midX: midX, midY: midY)
                Rectangle()
                    .strokeBorder(.green.opacity(0.4 * progress), lineWidth: 1 + 1 * progress)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

            // Confirmed flash border
            if isFocused {
                let rect = quadrantRect(quadrant, midX: midX, midY: midY)
                Rectangle()
                    .strokeBorder(.green.opacity(0.85), lineWidth: 2)
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
            let isDwelling = quadrant == appState.dwellingQuadrant
            let progress = isDwelling ? appState.dwellProgress : 0

            if isFocused {
                Rectangle()
                    .fill(.green.opacity(0.15))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.2), value: isFocused)
                Rectangle()
                    .strokeBorder(.cyan.opacity(0.4), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.2), value: isFocused)
                Text("Focused")
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.cyan.opacity(0.7), in: Capsule())
                    .position(x: rect.midX, y: rect.midY)
            } else if isActive {
                Rectangle()
                    .fill(.yellow.opacity(0.08))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.15), value: isActive)

                // Dwell countdown ring + percentage
                ZStack {
                    Circle()
                        .stroke(Color(white: 0.3).opacity(0.5), lineWidth: 3)
                        .frame(width: 40, height: 40)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(.yellow, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 40, height: 40)
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
                .position(x: rect.midX, y: rect.midY)
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

        let hw = appState.headWeight

        // Raw overlay layer
        if appState.showRawOverlay {
            let headPX = appState.headGazePoint.x * size.width
            let headPY = appState.headGazePoint.y * size.height
            let pupilPX = appState.pupilGazePoint.x * size.width
            let pupilPY = appState.pupilGazePoint.y * size.height

            Path { path in
                path.move(to: CGPoint(x: pupilPX, y: pupilPY))
                path.addLine(to: CGPoint(x: headPX, y: headPY))
            }
            .stroke(.red.opacity(0.3), lineWidth: appState.debugLineWidth)

            Image(systemName: "person.fill")
                .font(.system(size: 14))
                .foregroundStyle(.red.opacity(0.8))
                .scaleEffect(appState.overlayIconSize)
                .position(x: headPX, y: headPY)

            Image(systemName: "eye.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red.opacity(0.8))
                .scaleEffect(appState.overlayIconSize)
                .position(x: pupilPX, y: pupilPY)

            Circle()
                .fill(.black)
                .frame(width: appState.fusionDotSize, height: appState.fusionDotSize)
                .scaleEffect(appState.overlayIconSize)
                .position(x: rawX, y: rawY)

            Circle()
                .fill(.red.opacity(0.6))
                .frame(width: 6, height: 6)
                .scaleEffect(appState.overlayIconSize)
                .position(x: rawX, y: rawY)
        }

        // Calibrated overlay layer
        if appState.showCalibratedOverlay {
            let calHeadPX = appState.calibratedHeadGazePoint.x * size.width
            let calHeadPY = appState.calibratedHeadGazePoint.y * size.height
            let calPupilPX = appState.calibratedPupilGazePoint.x * size.width
            let calPupilPY = appState.calibratedPupilGazePoint.y * size.height

            Path { path in
                path.move(to: CGPoint(x: calPupilPX, y: calPupilPY))
                path.addLine(to: CGPoint(x: calHeadPX, y: calHeadPY))
            }
            .stroke(.green.opacity(0.3), lineWidth: appState.debugLineWidth)

            Image(systemName: "person.fill")
                .font(.system(size: 14))
                .foregroundStyle(.green.opacity(0.8))
                .scaleEffect(appState.overlayIconSize)
                .position(x: calHeadPX, y: calHeadPY)

            Image(systemName: "eye.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green.opacity(0.8))
                .scaleEffect(appState.overlayIconSize)
                .position(x: calPupilPX, y: calPupilPY)

            Circle()
                .fill(.black)
                .frame(width: appState.fusionDotSize, height: appState.fusionDotSize)
                .scaleEffect(appState.overlayIconSize)
                .position(x: calX, y: calY)

            Circle()
                .fill(.green.opacity(0.7))
                .frame(width: 8, height: 8)
                .scaleEffect(appState.overlayIconSize)
                .position(x: calX, y: calY)
        }

        // Smoothed overlay layer
        if appState.showSmoothedOverlay {
            Path { path in
                path.move(to: CGPoint(x: smoothX, y: 0))
                path.addLine(to: CGPoint(x: smoothX, y: size.height))
            }
            .stroke(.blue.opacity(0.3), lineWidth: appState.debugLineWidth)

            Path { path in
                path.move(to: CGPoint(x: 0, y: smoothY))
                path.addLine(to: CGPoint(x: size.width, y: smoothY))
            }
            .stroke(.blue.opacity(0.3), lineWidth: appState.debugLineWidth)

            Circle()
                .fill(.blue)
                .frame(width: appState.smoothedCircleSize, height: appState.smoothedCircleSize)
                .scaleEffect(appState.overlayIconSize)
                .position(x: smoothX, y: smoothY)
        }

        // HUD panel
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(.red)
                Text("Head: \(f(appState.headGazePoint.x)), \(f(appState.headGazePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "eye.fill").font(.system(size: 8)).foregroundStyle(.red)
                Text("Pupil: \(f(appState.pupilGazePoint.x)), \(f(appState.pupilGazePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(.green)
                Text("Cal Head: \(f(appState.calibratedHeadGazePoint.x)), \(f(appState.calibratedHeadGazePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "eye.fill").font(.system(size: 8)).foregroundStyle(.green)
                Text("Cal Pupil: \(f(appState.calibratedPupilGazePoint.x)), \(f(appState.calibratedPupilGazePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.red.opacity(0.6)).frame(width: 6, height: 6)
                Text("Fused: \(f(appState.rawGazePoint.x)), \(f(appState.rawGazePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.green.opacity(0.7)).frame(width: 6, height: 6)
                Text("Cal: \(f(appState.calibratedGazePoint.x)), \(f(appState.calibratedGazePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.blue).frame(width: 6, height: 6)
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
