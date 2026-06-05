import SwiftUI

struct CalibrationOverlayView: View {
    let calibrationManager: CalibrationManager
    let onDismiss: () -> Void

    @State private var currentPosition: CGPoint?
    @State private var targetProgress: Double = 0
    @State private var settling = true
    @State private var dotScale: CGFloat = 0.5

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.6)

                // Instructions
                VStack(spacing: 8) {
                    Text("Calibration")
                        .font(.title2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                    Text(settling ? "Hold your gaze steady..." : "Collecting...")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.8))
                    Text("Point \(calibrationManager.currentTargetIndex + 1) of \(calibrationManager.totalTargets)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.top, 2)
                }
                .padding()
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .position(x: geometry.size.width / 2, y: geometry.size.height * 0.15)

                // Target dot with progress ring
                if let pos = currentPosition {
                    ZStack {
                        // Progress ring
                        Circle()
                            .stroke(.white.opacity(0.2), lineWidth: 3)
                            .frame(width: 36, height: 36)

                        Circle()
                            .trim(from: 0, to: targetProgress)
                            .stroke(
                                settling ? Color.yellow : Color.green,
                                style: StrokeStyle(lineWidth: 3, lineCap: .round)
                            )
                            .frame(width: 36, height: 36)
                            .rotationEffect(.degrees(-90))

                        // Center dot
                        Circle()
                            .fill(.white)
                            .frame(width: 14, height: 14)
                            .shadow(color: .white.opacity(0.6), radius: 8)
                    }
                    .scaleEffect(dotScale)
                    .position(
                        x: pos.x * geometry.size.width,
                        y: pos.y * geometry.size.height
                    )
                }

                // Escape hint
                Text("Press Esc to cancel")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.4))
                    .position(x: geometry.size.width / 2, y: geometry.size.height - 30)
            }
        }
        .ignoresSafeArea()
        .onAppear {
            currentPosition = calibrationManager.currentTargetPosition
            wireUICallbacks()
            withAnimation(.easeOut(duration: 0.3)) {
                dotScale = 1.0
            }
        }
        .onKeyPress(.escape) {
            calibrationManager.reset()
            onDismiss()
            return .handled
        }
    }

    private func wireUICallbacks() {
        calibrationManager.onTargetChanged = { point in
            dotScale = 0.5
            targetProgress = 0
            settling = true
            withAnimation(.easeInOut(duration: 0.3)) {
                currentPosition = point
            }
            withAnimation(.easeOut(duration: 0.3).delay(0.1)) {
                dotScale = 1.0
            }
        }

        calibrationManager.onTargetProgressUpdate = { _, progress in
            withAnimation(.linear(duration: 0.05)) {
                targetProgress = progress
            }
            settling = calibrationManager.isSettling
        }
    }
}
