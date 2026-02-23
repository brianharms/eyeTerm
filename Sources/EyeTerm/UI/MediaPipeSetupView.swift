import SwiftUI

struct MediaPipeSetupView: View {
    @Bindable var manager: MediaPipeSetupManager
    let onDismiss: () -> Void
    let onUseAppleVision: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            RoundedRectangle(cornerRadius: 16)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(radius: 24)
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
                .frame(width: 440, height: 320)
                .overlay(content)
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(spacing: 20) {
            switch manager.state {
            case .checking:
                ProgressView()
                    .scaleEffect(1.2)
                Text("Checking MediaPipe…")
                    .font(.headline)
                    .foregroundStyle(.secondary)

            case .installing:
                VStack(spacing: 16) {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Setting up MediaPipe")
                            .font(.headline)
                    }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(manager.outputLines, id: \.self) { line in
                                Text(line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.hasPrefix("✓") ? Color.green : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal, 8)
                    }
                    .frame(height: 120)
                    .background(Color.black.opacity(0.3))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("Do not close this window. This only runs once.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 24)

            case .ready:
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("MediaPipe Ready")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Eye tracking will start now.")
                    .foregroundStyle(.secondary)
                Button("Continue") {
                    onDismiss()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text("Setup Failed")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    Button("Retry") {
                        Task { await manager.install() }
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Use Apple Vision Instead") {
                        onUseAppleVision()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding(24)
        .frame(width: 440, height: 320)
    }
}
