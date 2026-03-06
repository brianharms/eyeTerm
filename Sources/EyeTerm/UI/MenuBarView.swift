import SwiftUI

private struct CompactMenuButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.5 : 1.0)
            .contentShape(Rectangle())
    }
}

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // ── App Identity + Status ──
            Text("eyeTerm  v\(AppVersion.current)")
                .font(.caption)
                .fontWeight(.medium)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(appState.statusMessage)
                    .font(.caption)
                    .fontWeight(.medium)
                if appState.isCalibrated {
                    Label("Calibrated", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                }
            }

            if !(appState.isEyeTrackingActive && appState.isVoiceActive && appState.isTerminalSetup) {
                Button {
                    Task { await coordinator.startAll() }
                } label: {
                    Label("Launch All", systemImage: "bolt.fill")
                }
                .buttonStyle(CompactMenuButtonStyle())
                .font(.caption)
                .fontWeight(.semibold)
            }

            Button {
                coordinator.cycleOverlayMode()
            } label: {
                Label("Overlay: \(appState.overlayMode.displayName)", systemImage: overlayIcon)
            }
            .buttonStyle(CompactMenuButtonStyle())
            .font(.caption)

            if appState.isEyeTrackingActive || appState.isVoiceActive {
                Button {
                    coordinator.stopAll()
                } label: {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .buttonStyle(CompactMenuButtonStyle())
                .font(.caption)
                .fontWeight(.semibold)
            }

            // ── Eye Tracking ──
            sectionHeader("EYE TRACKING")

            HStack(spacing: 6) {
                Button {
                    if appState.isEyeTrackingActive {
                        coordinator.stopEyeTracking()
                    } else {
                        coordinator.startEyeTracking()
                    }
                } label: {
                    Label(
                        appState.isEyeTrackingActive ? "Stop" : "Start",
                        systemImage: appState.isEyeTrackingActive ? "eye.slash" : "eye"
                    )
                }
                .buttonStyle(CompactMenuButtonStyle())

                if appState.isEyeTrackingActive {
                    quadrantLabel
                }
            }
            .font(.caption)

            Button {
                if appState.isCameraPreviewVisible {
                    coordinator.dismissCameraPreview()
                } else {
                    coordinator.showCameraPreview()
                }
            } label: {
                Label(
                    appState.isCameraPreviewVisible ? "Hide Camera" : "Camera Preview",
                    systemImage: appState.isCameraPreviewVisible ? "video.fill" : "video"
                )
            }
            .buttonStyle(CompactMenuButtonStyle())
            .font(.caption)

            Button {
                coordinator.startCalibration()
            } label: {
                Label("Calibrate", systemImage: "scope")
            }
            .buttonStyle(CompactMenuButtonStyle())
            .font(.caption)
            .disabled(!appState.isEyeTrackingActive)

            // ── Voice ──
            sectionHeader("VOICE")

            HStack(spacing: 6) {
                Button {
                    if appState.isVoiceActive {
                        coordinator.stopVoice()
                    } else {
                        Task { await coordinator.startVoice() }
                    }
                } label: {
                    Label(
                        appState.isVoiceActive ? "Stop" : "Start",
                        systemImage: appState.isVoiceActive ? "mic.slash" : "mic"
                    )
                }
                .buttonStyle(CompactMenuButtonStyle())
                .font(.caption)

                if appState.isVoiceActive {
                    AudioLevelView(level: appState.audioLevel, isSpeaking: appState.isSpeaking)
                }

                whisperModelStatus
            }
            .fixedSize(horizontal: false, vertical: true)

            // ── Terminal ──
            sectionHeader("TERMINAL")

            VStack(alignment: .leading, spacing: 1) {
                terminalModeButton(.adoptExisting, label: "Use Existing")
                terminalModeButton(.launchNew, label: "Create New Terminals")
            }
            .font(.caption)

            Button {
                Task { await coordinator.setupTerminals() }
            } label: {
                Label(
                    appState.terminalSetupMode == .launchNew ? "Launch Terminals" : "Adopt Terminals",
                    systemImage: appState.terminalSetupMode == .launchNew ? "bolt.fill" : "rectangle.inset.filled.and.cursorarrow"
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .font(.caption)

            // ── Utilities ──
            Divider()
                .padding(.vertical, 4)

            VStack(alignment: .leading, spacing: 2) {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(CompactMenuButtonStyle())
                .onHover { _ in }
                .simultaneousGesture(TapGesture().onEnded {
                    coordinator.bringSettingsWindowToFront()
                })

                Button {
                    coordinator.showPermissionsPanel()
                } label: {
                    Label("Enable Permissions", systemImage: "lock.shield")
                }
                .buttonStyle(CompactMenuButtonStyle())
            }
            .font(.caption)

            // ── Quit ──
            Divider()
                .padding(.vertical, 4)

            Button {
                coordinator.stopAll()
                Task {
                    try? await coordinator.terminalManager.tearDown()
                }
                NSApplication.shared.terminate(nil)
            } label: {
                Label("Quit", systemImage: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .font(.caption)

            // ── Errors (only if present) ──
            if !appState.errors.isEmpty {
                Divider()
                    .padding(.vertical, 4)
                Button {
                    let allErrors = appState.errors.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(allErrors, forType: .string)
                } label: {
                    Label("Errors[\(appState.errors.count)]", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(CompactMenuButtonStyle())
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    // MARK: - Helpers

    private func terminalModeButton(_ mode: TerminalSetupMode, label: String) -> some View {
        Button {
            appState.terminalSetupMode = mode
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.terminalSetupMode == mode ? "checkmark" : "")
                    .font(.system(size: 9, weight: .bold))
                    .frame(width: 10)
                Text(label)
            }
            .foregroundStyle(appState.terminalSetupMode == mode ? .primary : .secondary)
        }
        .buttonStyle(CompactMenuButtonStyle())
    }

    private var overlayIcon: String {
        switch appState.overlayMode {
        case .off: "eye.slash"
        case .subtle: "eye"
        case .debug: "eye.trianglebadge.exclamationmark"
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
                .padding(.top, 4)
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10, weight: .heavy, design: .default))
                    .tracking(1.8)
                    .foregroundStyle(.secondary)
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(height: 1)
            }
            .padding(.top, 3)
            .padding(.bottom, 2)
        }
    }

    // MARK: - Subviews

    private var statusColor: Color {
        if appState.isEyeTrackingActive && appState.isVoiceActive && appState.isTerminalSetup {
            return .green
        } else if appState.isEyeTrackingActive || appState.isVoiceActive || appState.isTerminalSetup {
            return .yellow
        } else {
            return .red
        }
    }

    @ViewBuilder
    private var whisperModelStatus: some View {
        switch appState.voiceModelState {
        case .idle:
            EmptyView()
        case .loading:
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                ProgressView()
                    .controlSize(.mini)
                    .alignmentGuide(.firstTextBaseline) { d in d[.bottom] }
                Text("Loading model...")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        case .ready:
            Label("\(appState.voiceBackend.rawValue) ready", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
                .lineLimit(1)
        case .failed:
            Label("Model failed", systemImage: "xmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var quadrantLabel: some View {
        if let slotID = appState.focusedSlot,
           let slot = appState.terminalSlots.first(where: { $0.id == slotID }) {
            Text("Slot \(slot.label)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("No focus")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Audio Level Indicator

private struct AudioLevelView: View {
    let level: Float
    let isSpeaking: Bool

    private let barCount = 5

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { i in
                let threshold = Float(i) / Float(barCount) * 0.06
                let active = level > threshold
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(active ? (isSpeaking ? Color.green : Color.white.opacity(0.6)) : Color.gray.opacity(0.3))
                    .frame(width: 3.5, height: CGFloat(5 + i * 2))
            }
        }
        .frame(height: 16, alignment: .bottom)
        .animation(.easeOut(duration: 0.06), value: level)
    }
}
