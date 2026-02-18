import SwiftUI

struct ErrorDetailView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(appState.errors.count) Error\(appState.errors.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                Button("Clear All") {
                    appState.clearErrors()
                }
                .buttonStyle(.borderless)
            }
            .padding()

            Divider()

            if appState.errors.isEmpty {
                Text("No errors")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(appState.errors.enumerated()), id: \.offset) { index, error in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20, alignment: .trailing)
                                Text(error)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if index < appState.errors.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .padding()
                }
            }
        }
        .frame(minWidth: 350, minHeight: 200)
    }
}
