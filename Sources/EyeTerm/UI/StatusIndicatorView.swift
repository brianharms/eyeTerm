import SwiftUI

struct StatusIndicatorView: View {
    let label: String
    let isActive: Bool
    var color: Color?

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(resolvedColor)
                .frame(width: 8, height: 8)
            Text(label)
                .font(.caption)
        }
    }

    private var resolvedColor: Color {
        if let color { return color }
        return isActive ? .green : .gray
    }
}
