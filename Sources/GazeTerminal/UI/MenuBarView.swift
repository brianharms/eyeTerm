import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // ── App Identity + Status ──
            Text("eyeTerm")
                .font(.caption)
                .fontWeight(.bold)

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(appState.statusMessage)
                    .font(.caption)
                    .fontWeight(.medium)
                Spacer()
                if appState.isCalibrated {
                    Label("Calibrated", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption2)
                }
            }

            // ── Eye Tracking ──
            Divider()
            sectionHeader("EYE TRACKING")

            Group {
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
                    .buttonStyle(.borderless)

                    Button {
                        coordinator.startCalibration()
                    } label: {
                        Label("Calibrate", systemImage: "scope")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!appState.isEyeTrackingActive)

                    Spacer()

                    if appState.isEyeTrackingActive {
                        quadrantLabel
                    }
                }
                .font(.caption)
            }
            .padding(.bottom, 6)

            // ── Voice ──
            Divider()
                .padding(.vertical, 4)
            sectionHeader("VOICE")

            Group {
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
                .buttonStyle(.borderless)
                .font(.caption)

                if !appState.lastTranscription.isEmpty {
                    Text(appState.lastTranscription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.bottom, 6)

            // ── Terminal ──
            Divider()
                .padding(.vertical, 4)
            sectionHeader("TERMINAL")

            Group {
                Button {
                    Task { await coordinator.setupTerminals() }
                } label: {
                    Label("Launch Terminals", systemImage: "terminal")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.bottom, 6)

            // ── Utilities ──
            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                SettingsLink {
                    Label("Settings", systemImage: "gear")
                }
                .buttonStyle(.borderless)
                .onHover { _ in }
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })

                Button {
                    coordinator.cycleOverlayMode()
                } label: {
                    Label("Overlay: \(appState.overlayMode.displayName)", systemImage: overlayIcon)
                }
                .buttonStyle(.borderless)

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
                .buttonStyle(.borderless)
            }
            .font(.caption)
            .padding(.bottom, 4)

            // ── Quit ──
            Divider()
                .padding(.vertical, 2)

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
            .font(.caption)

            // ── Errors (only if present) ──
            if !appState.errors.isEmpty {
                Divider()
                    .padding(.top, 4)
                Button {
                    let allErrors = appState.errors.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(allErrors, forType: .string)
                } label: {
                    Label("Errors[\(appState.errors.count)]", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(12)
        .frame(width: 260)
    }

    // MARK: - Helpers

    private var overlayIcon: String {
        switch appState.overlayMode {
        case .off: "eye.slash"
        case .subtle: "eye"
        case .debug: "eye.trianglebadge.exclamationmark"
        }
    }

    @ViewBuilder
    private func sectionHeader(_ title: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 10, weight: .heavy, design: .default))
                .tracking(1.8)
                .foregroundStyle(.secondary)
            Rectangle()
                .fill(Color.secondary.opacity(0.4))
                .frame(height: 1)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
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
    private var quadrantLabel: some View {
        if let quadrant = appState.focusedQuadrant {
            Text(quadrant.displayName)
                .font(.caption2)
                .foregroundStyle(.secondary)
        } else {
            Text("No focus")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
