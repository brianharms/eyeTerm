import SwiftUI

struct EyeTermOverlayView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                if appState.overlayMode == .subtle {
                    SubtleOverlayContent(size: size)
                }
                if appState.overlayMode == .debug {
                    DebugOverlayContent(size: size)
                }
                // Shared features — active in both subtle and debug modes
                SharedOverlayContent(size: size)
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Subtle Overlay

private struct SubtleOverlayContent: View {
    let size: CGSize
    @Environment(AppState.self) private var appState

    var body: some View {
        let smoothX = appState.smoothedEyePoint.x * size.width
        let smoothY = appState.smoothedEyePoint.y * size.height

        if !appState.terminalSlots.isEmpty {
            Circle()
                .fill(.blue.opacity(appState.subtleEyeOpacity))
                .frame(width: appState.subtleEyeSize, height: appState.subtleEyeSize)
                .position(x: smoothX, y: smoothY)
        }

        ForEach(appState.terminalSlots) { slot in
            let isFocused = slot.id == appState.focusedSlot
            let isDwelling = slot.id == appState.dwellingSlot
            let progress = isDwelling ? appState.dwellProgress : 0

            // Always-on faint slot outline
            if appState.showQuadrantHighlighting {
                let rect = slotRect(slot, size: size)
                Rectangle()
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

            // Dwell progress border
            if isDwelling && !isFocused && progress > 0 && appState.showActiveState {
                let rect = slotRect(slot, size: size)
                Rectangle()
                    .strokeBorder(.green.opacity(0.4 * progress), lineWidth: 1 + 1 * progress)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }

            // Confirmed flash border
            if isFocused && appState.showQuadrantHighlighting {
                let rect = slotRect(slot, size: size)
                Rectangle()
                    .strokeBorder(.green.opacity(0.85), lineWidth: appState.quadrantBorderWidth)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeOut(duration: 0.2), value: isFocused)
            }
        }
    }

    private func slotRect(_ slot: TerminalSlot, size: CGSize) -> CGRect {
        CGRect(
            x: slot.normalizedRect.minX * size.width,
            y: slot.normalizedRect.minY * size.height,
            width: slot.normalizedRect.width * size.width,
            height: slot.normalizedRect.height * size.height
        )
    }
}

// MARK: - Debug Overlay

private struct DebugOverlayContent: View {
    let size: CGSize
    @Environment(AppState.self) private var appState

    var body: some View {
        let midX = size.width / 2
        let midY = size.height / 2

        // Dark backdrop layer (5a)
        if appState.showDebugBackdrop {
            Color(white: 0.15)
                .ignoresSafeArea()
        }

        let rawX = appState.rawEyePoint.x * size.width
        let rawY = appState.rawEyePoint.y * size.height
        let calX = appState.calibratedEyePoint.x * size.width
        let calY = appState.calibratedEyePoint.y * size.height
        let smoothX = appState.smoothedEyePoint.x * size.width
        let smoothY = appState.smoothedEyePoint.y * size.height

        // Slot fills — always rendered in debug mode regardless of showQuadrantHighlighting
        ForEach(appState.terminalSlots) { slot in
            let rect = slotRect(slot, size: size)
            let isActive = slot.id == appState.activeSlot
            let isFocused = slot.id == appState.focusedSlot
            let isDwelling = slot.id == appState.dwellingSlot
            let progress = isDwelling ? appState.dwellProgress : 0

            // Always-on faint outline so all quadrants are visible
            Rectangle()
                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

                if isFocused {
                    Rectangle()
                        .fill(.green.opacity(0.15))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .animation(.easeOut(duration: 0.2), value: isFocused)
                    Rectangle()
                        .strokeBorder(.cyan.opacity(0.4), lineWidth: appState.quadrantBorderWidth)
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
                    if appState.showActiveState {
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
            }

        // Quadrant grid lines (dashed) — only when tracking is active and terminals are adopted
        if appState.isEyeTrackingActive && !appState.terminalSlots.isEmpty {
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
        }

        // Gaze-point visuals — only when tracking is active and terminals are adopted
        if appState.isEyeTrackingActive && !appState.terminalSlots.isEmpty {

        let hw = appState.headWeight

        // Raw overlay layer
        if appState.showRawOverlay {
            let headPX = appState.headEyePoint.x * size.width
            let headPY = appState.headEyePoint.y * size.height
            let pupilPX = appState.pupilEyePoint.x * size.width
            let pupilPY = appState.pupilEyePoint.y * size.height

            Circle()
                .fill(.black)
                .frame(width: appState.fusionDotSize, height: appState.fusionDotSize)
                .scaleEffect(appState.overlayIconSize)
                .position(x: rawX, y: rawY)

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
                .fill(.red.opacity(0.6))
                .frame(width: 6, height: 6)
                .scaleEffect(appState.overlayIconSize)
                .position(x: rawX, y: rawY)
        }

        // Calibrated overlay layer
        if appState.showCalibratedOverlay {
            let calHeadPX = appState.calibratedHeadEyePoint.x * size.width
            let calHeadPY = appState.calibratedHeadEyePoint.y * size.height
            let calPupilPX = appState.calibratedPupilEyePoint.x * size.width
            let calPupilPY = appState.calibratedPupilEyePoint.y * size.height

            Circle()
                .fill(.black)
                .frame(width: appState.fusionDotSize, height: appState.fusionDotSize)
                .scaleEffect(appState.overlayIconSize)
                .position(x: calX, y: calY)

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

        } // end isEyeTrackingActive

        // HUD panel
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(.red)
                Text("Head: \(f(appState.headEyePoint.x)), \(f(appState.headEyePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "eye.fill").font(.system(size: 8)).foregroundStyle(.red)
                Text("Pupil: \(f(appState.pupilEyePoint.x)), \(f(appState.pupilEyePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "person.fill").font(.system(size: 8)).foregroundStyle(.green)
                Text("Cal Head: \(f(appState.calibratedHeadEyePoint.x)), \(f(appState.calibratedHeadEyePoint.y))")
            }
            HStack(spacing: 4) {
                Image(systemName: "eye.fill").font(.system(size: 8)).foregroundStyle(.green)
                Text("Cal Pupil: \(f(appState.calibratedPupilEyePoint.x)), \(f(appState.calibratedPupilEyePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.red.opacity(0.6)).frame(width: 6, height: 6)
                Text("Fused: \(f(appState.rawEyePoint.x)), \(f(appState.rawEyePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.green.opacity(0.7)).frame(width: 6, height: 6)
                Text("Cal: \(f(appState.calibratedEyePoint.x)), \(f(appState.calibratedEyePoint.y))")
            }
            HStack(spacing: 4) {
                Circle().fill(.blue).frame(width: 6, height: 6)
                Text("Smooth: \(f(appState.smoothedEyePoint.x)), \(f(appState.smoothedEyePoint.y))")
            }
            Text("Confidence: \(Int(appState.eyeConfidence * 100))%")
            Text("Yaw: \(fd(appState.headYaw))  Pitch: \(fd(appState.headPitch))")
            if let active = appState.activeSlot {
                Text("Looking: slot \(active + 1)")
                    .foregroundStyle(.yellow)
            }
            if let focused = appState.focusedSlot {
                Text("Focused: slot \(focused + 1)")
                    .foregroundStyle(.green)
            }
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.green)
        .padding(8)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .position(x: 100, y: 180)

    }

    private func slotRect(_ slot: TerminalSlot, size: CGSize) -> CGRect {
        CGRect(
            x: slot.normalizedRect.minX * size.width,
            y: slot.normalizedRect.minY * size.height,
            width: slot.normalizedRect.width * size.width,
            height: slot.normalizedRect.height * size.height
        )
    }

    private func f(_ value: CGFloat) -> String {
        String(format: "%.3f", value)
    }

    private func fd(_ value: Double) -> String {
        String(format: "%+.3f", value)
    }
}

// MARK: - Shared Overlay (subtle + debug)

private struct SharedOverlayContent: View {
    let size: CGSize
    @Environment(AppState.self) private var appState

    var body: some View {
        // Live dictation display — per-slot bubbles pinned to each slot's rect
        if appState.showDictationDisplay {
            ForEach(appState.terminalSlots) { slot in
                if let partial = appState.slotPartialTranscriptions[slot.id],
                   !partial.isEmpty {
                    let displayText = partial
                    let rect = slotRect(slot, size: size)
                    Text(displayText)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: rect.width - 80)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
                        .position(x: rect.midX, y: rect.maxY - 80)
                }
            }
        }

        // Wink action visualization
        if appState.showWinkOverlay, let winkText = appState.lastWinkDisplay {
            let focusedRect: CGRect = {
                if let slotID = appState.focusedSlot,
                   let slot = appState.terminalSlots.first(where: { $0.id == slotID }) {
                    return slotRect(slot, size: size)
                }
                return CGRect(x: 0, y: 0, width: size.width, height: size.height)
            }()
            Text(winkText)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                .position(x: focusedRect.midX, y: focusedRect.minY + 75)
                .animation(.easeOut(duration: 0.8), value: winkText)
        }

        // Gaze lock indicator — shown only when blockInteractionDuringSetup is on and setup is running
        if appState.blockInteractionDuringSetup && appState.gazeActivationLocked {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 8, height: 8)
                    .opacity(0.9)
                Text("Focus disabled — setting up terminals")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(.black.opacity(0.6), in: Capsule())
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .padding(.bottom, 20)
        }

        // Command flash visualization
        if appState.showCommandFlash, let flashText = appState.lastCommandFlash {
            let focusedRect: CGRect = {
                if let slotID = appState.focusedSlot,
                   let slot = appState.terminalSlots.first(where: { $0.id == slotID }) {
                    return slotRect(slot, size: size)
                }
                return CGRect(x: 0, y: 0, width: size.width, height: size.height)
            }()
            Text(flashText)
                .font(.system(size: 32, weight: .bold))
                .foregroundStyle(Color.green)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                .position(x: focusedRect.midX, y: focusedRect.midY + 60)
                .animation(.easeOut(duration: 0.8), value: flashText)
        }
    }

    private func slotRect(_ slot: TerminalSlot, size: CGSize) -> CGRect {
        CGRect(
            x: slot.normalizedRect.minX * size.width,
            y: slot.normalizedRect.minY * size.height,
            width: slot.normalizedRect.width * size.width,
            height: slot.normalizedRect.height * size.height
        )
    }
}
