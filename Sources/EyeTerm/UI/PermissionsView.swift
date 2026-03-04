import SwiftUI

@Observable
final class PermissionsViewModel {
    struct PermRow: Identifiable {
        let id: String
        let name: String
        let detail: String
        let icon: String
        var status: PermissionStatus
    }

    var rows: [PermRow] = [
        PermRow(id: "accessibility", name: "Accessibility",         detail: "Send keystrokes to terminal windows",  icon: "keyboard",     status: .notDetermined),
        PermRow(id: "automation",    name: "Automation (iTerm2)",   detail: "Control iTerm2 via AppleScript",       icon: "applescript",  status: .notDetermined),
        PermRow(id: "camera",        name: "Camera",                detail: "Eye tracking",                         icon: "camera",       status: .notDetermined),
        PermRow(id: "microphone",    name: "Microphone",            detail: "Voice commands",                       icon: "mic",          status: .notDetermined),
        PermRow(id: "speech",        name: "Speech Recognition",    detail: "Voice transcription",                  icon: "waveform",     status: .notDetermined),
    ]

    func refresh() {
        rows[0].status = Permissions.checkAccessibility() ? .granted : .notDetermined
        rows[1].status = Permissions.checkAutomation(bundleID: "com.googlecode.iterm2")
        rows[2].status = Permissions.checkCamera()
        rows[3].status = Permissions.checkMicrophone()
        rows[4].status = Permissions.checkSpeechRecognition()
    }

    func grant(id: String) async {
        switch id {
        case "accessibility":
            Permissions.requestAccessibility()
            try? await Task.sleep(nanoseconds: 600_000_000)
            refresh()
        case "automation":
            Permissions.requestAutomation(bundleID: "com.googlecode.iterm2")
            try? await Task.sleep(nanoseconds: 600_000_000)
            refresh()
        case "camera":
            _ = await Permissions.requestCamera()
            refresh()
        case "microphone":
            _ = await Permissions.requestMicrophone()
            refresh()
        case "speech":
            _ = await Permissions.requestSpeechRecognition()
            refresh()
        default:
            break
        }
    }

    func openSettings(for id: String) {
        switch id {
        case "accessibility": Permissions.openAccessibilitySettings()
        case "automation":    Permissions.openAutomationSettings()
        case "camera":        Permissions.openCameraSettings()
        case "microphone":    Permissions.openMicrophoneSettings()
        case "speech":        Permissions.openSpeechRecognitionSettings()
        default:              break
        }
    }

    var allGranted: Bool {
        rows.allSatisfy { $0.status == .granted }
    }
}

// MARK: - Main View

struct PermissionsView: View {
    @State private var viewModel = PermissionsViewModel()
    @State private var pollTimer: Timer?
    var onDismiss: (() -> Void)?
    /// When non-nil, this panel acts as a launch gate: Done becomes "Launch eyeTerm"
    /// when all permissions are granted, and calls this closure to proceed.
    var onAllGrantedDone: (() -> Void)?

    private var isGateMode: Bool { onAllGrantedDone != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.title)
                    .foregroundStyle(viewModel.allGranted ? .green : .blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Permissions Required")
                        .font(.headline)
                    Text(viewModel.allGranted
                         ? "All permissions granted — ready to launch."
                         : isGateMode
                            ? "Grant all permissions below to start eyeTerm."
                            : "Grant these before launching.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isGateMode && viewModel.allGranted {
                    Button("Launch eyeTerm") {
                        onDismiss?()
                        onAllGrantedDone?()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                } else {
                    Button("Done") {
                        onDismiss?()
                    }
                    .controlSize(.small)
                }
            }
            .padding(16)

            Divider()

            VStack(spacing: 0) {
                ForEach($viewModel.rows) { $row in
                    PermissionRowView(row: $row) {
                        Task { await viewModel.grant(id: row.id) }
                    } onOpenSettings: {
                        viewModel.openSettings(for: row.id)
                    }
                    if row.id != viewModel.rows.last?.id {
                        Divider().padding(.leading, 52)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(width: 420)
        .onAppear {
            viewModel.refresh()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                viewModel.refresh()
            }
        }
        .onDisappear {
            pollTimer?.invalidate()
            pollTimer = nil
        }
    }
}

// MARK: - Row

private struct PermissionRowView: View {
    @Binding var row: PermissionsViewModel.PermRow
    let onGrant: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(statusColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: row.icon)
                    .font(.system(size: 15))
                    .foregroundStyle(statusColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.callout)
                    .fontWeight(.medium)
                Text(row.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            switch row.status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .denied:
                Button("Open Settings", action: onOpenSettings)
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .tint(.red)
            case .notDetermined:
                Button("Grant", action: onGrant)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    private var statusColor: Color {
        switch row.status {
        case .granted:       return .green
        case .denied:        return .red
        case .notDetermined: return .orange
        }
    }
}
