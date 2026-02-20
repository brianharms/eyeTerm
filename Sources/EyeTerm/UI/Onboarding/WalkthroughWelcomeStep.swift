import SwiftUI

struct WalkthroughWelcomeStep: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "eye.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.blue)
                .symbolRenderingMode(.hierarchical)

            Text("eyeTerm")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Hands-free terminal control using\neye tracking and voice commands")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
