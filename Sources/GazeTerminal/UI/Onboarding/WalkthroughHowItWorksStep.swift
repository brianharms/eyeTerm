import SwiftUI

struct WalkthroughHowItWorksStep: View {
    private let concepts: [(icon: String, title: String, description: String)] = [
        ("eye.trianglebadge.exclamationmark", "Eye Tracking", "Camera watches where you look across 4 screen quadrants"),
        ("timer", "Dwell Focus", "Hold your gaze and that terminal gets keyboard focus"),
        ("waveform", "Voice Input", "Speak naturally, words are typed into the focused terminal"),
        ("play.fill", "Execute", "Say \"run it\" (configurable) and the command runs")
    ]

    var body: some View {
        VStack(spacing: 20) {
            Text("How It Works")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 16) {
                ForEach(concepts, id: \.title) { concept in
                    HStack(spacing: 16) {
                        Image(systemName: concept.icon)
                            .font(.title2)
                            .foregroundStyle(.blue)
                            .frame(width: 36, alignment: .center)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(concept.title)
                                .font(.headline)
                            Text(concept.description)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
