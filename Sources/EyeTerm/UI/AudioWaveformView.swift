import SwiftUI

struct AudioWaveformView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let history = appState.audioLevelHistory
        let speaking = appState.isSpeaking

        HStack(spacing: 0) {
            Image(systemName: speaking ? "mic.fill" : "mic")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(speaking ? .green : .white.opacity(0.5))
                .frame(width: 18)

            HStack(alignment: .center, spacing: 1) {
                ForEach(Array(history.enumerated()), id: \.offset) { _, level in
                    let linear = min(Double(level) / 0.05, 1.0)
                    let normalized = pow(linear, 0.4) // compress dynamic range so quiet speech is visible
                    let barHeight = max(1.5, normalized * 18)
                    RoundedRectangle(cornerRadius: 0.75)
                        .fill(barColor(level: level, speaking: speaking))
                        .frame(width: 2, height: barHeight)
                }
            }
            .scaleEffect(x: 0.9, y: 1.0, anchor: .center)
            .frame(height: 20)
            .animation(.easeOut(duration: 0.03), value: history)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.black.opacity(0.8))
                .overlay(
                    Capsule()
                        .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                )
        )
    }

    private func barColor(level: Float, speaking: Bool) -> Color {
        if level > 0.04 {
            return .green
        } else if level > 0.01 {
            return speaking ? .green.opacity(0.7) : .white.opacity(0.4)
        } else {
            return .white.opacity(0.12)
        }
    }
}
