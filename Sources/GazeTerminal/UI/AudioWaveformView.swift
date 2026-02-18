import SwiftUI

struct AudioWaveformView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let history = appState.audioLevelHistory
        let speaking = appState.isSpeaking

        HStack(spacing: 0) {
            // Mic icon
            Image(systemName: speaking ? "mic.fill" : "mic")
                .font(.system(size: 14))
                .foregroundStyle(speaking ? .green : .white.opacity(0.6))
                .frame(width: 24)

            // Waveform bars
            HStack(alignment: .center, spacing: 1.5) {
                ForEach(Array(history.enumerated()), id: \.offset) { index, level in
                    let normalized = min(Double(level) / 0.05, 1.0)
                    let barHeight = max(2, normalized * 36)
                    RoundedRectangle(cornerRadius: 1)
                        .fill(barColor(level: level, speaking: speaking))
                        .frame(width: 3, height: barHeight)
                }
            }
            .frame(height: 40)
            .animation(.easeOut(duration: 0.06), value: history)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.black.opacity(0.75))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.1), lineWidth: 1)
                )
        )
    }

    private func barColor(level: Float, speaking: Bool) -> Color {
        if level > 0.04 {
            return .green
        } else if level > 0.01 {
            return speaking ? .green.opacity(0.7) : .white.opacity(0.5)
        } else {
            return .white.opacity(0.2)
        }
    }
}
