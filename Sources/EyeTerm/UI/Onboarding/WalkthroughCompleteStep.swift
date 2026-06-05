import SwiftUI

struct WalkthroughCompleteStep: View {
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)

            Text("Setup Complete")
                .font(.title)
                .fontWeight(.bold)

            Text("eyeTerm is now running in your menu bar.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Menu bar icon hint with arrow
            VStack(spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: "eye")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.blue)
                        .frame(width: 28, height: 28)
                        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))

                    Text("Look for this icon in your menu bar")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                // Arrow pointing up toward menu bar
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(.blue)
            }
            .padding(.top, 8)

            Spacer()

            Button(action: onDone) {
                Text("Done")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 40)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
