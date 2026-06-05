import SwiftUI

struct WalkthroughReadyStep: View {
    let onGetStarted: () -> Void
    let onExploreSettings: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("You're Ready")
                .font(.title)
                .fontWeight(.bold)
                .padding(.top, 8)

            VStack(alignment: .leading, spacing: 12) {
                permissionRow(
                    title: "Camera",
                    granted: Permissions.checkCamera() == .granted
                )
                permissionRow(
                    title: "Microphone",
                    granted: Permissions.checkMicrophone() == .granted
                )
                permissionRow(
                    title: "Accessibility",
                    granted: Permissions.checkAccessibility()
                )
            }
            .padding(.horizontal, 40)

            Spacer()

            VStack(spacing: 12) {
                Button(action: onGetStarted) {
                    Text("Get Started")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onExploreSettings) {
                    Text("Explore Settings First")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 40)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func permissionRow(title: String, granted: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(granted ? .green : .orange)
                .font(.title3)

            Text(title)
                .font(.body)

            Spacer()

            Text(granted ? "Granted" : "Not Granted")
                .font(.caption)
                .foregroundStyle(granted ? .green : .orange)
        }
    }
}
