import SwiftUI

struct WalkthroughPermissionStep: View {
    let iconName: String
    let title: String
    let explanation: String
    let check: () -> PermissionStatus
    let request: () async -> Void
    let isAccessibility: Bool
    var onPermissionChanged: (() -> Void)?

    @State private var status: PermissionStatus = .notDetermined
    @State private var isRequesting = false
    @State private var pollTimer: Timer?

    var body: some View {
        VStack(spacing: 20) {
            Text(title)
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 8)

            Image(systemName: iconName)
                .font(.system(size: 48))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            Text(explanation)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer()

            statusView

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            refreshStatus()
            if isAccessibility && status != .granted {
                startPolling()
            }
        }
        .onDisappear {
            stopPolling()
        }
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .granted:
            Label("Permission Granted", systemImage: "checkmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.green)

        case .denied:
            VStack(spacing: 12) {
                Label("Permission Denied", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)

                if isAccessibility {
                    Button("Open System Settings") {
                        Permissions.requestAccessibility()
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    Text("You can grant access later in System Settings.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

        case .notDetermined:
            if isRequesting {
                ProgressView()
                    .controlSize(.regular)
            } else {
                Button(isAccessibility ? "Open System Settings" : "Grant Access") {
                    requestPermission()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
    }

    private func refreshStatus() {
        if isAccessibility {
            status = Permissions.checkAccessibility() ? .granted : .notDetermined
        } else {
            status = check()
        }
    }

    private func requestPermission() {
        if isAccessibility {
            Permissions.requestAccessibility()
            startPolling()
        } else {
            isRequesting = true
            Task {
                await request()
                await MainActor.run {
                    isRequesting = false
                    refreshStatus()
                    onPermissionChanged?()
                }
            }
        }
    }

    private func startPolling() {
        stopPolling()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            if Permissions.checkAccessibility() {
                status = .granted
                stopPolling()
                onPermissionChanged?()
            }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}
