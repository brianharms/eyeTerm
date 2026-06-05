import SwiftUI

struct WinkCalibrationView: View {

    @State var manager: WinkCalibrationManager

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()

            switch manager.phase {
            case .collecting:
                CollectingPage(manager: manager)
            case .results(let thresholds):
                ResultsPage(thresholds: thresholds, manager: manager)
            case .done:
                EmptyView()
            }
        }
        .ignoresSafeArea()
    }
}

// MARK: - Collecting

private struct CollectingPage: View {
    let manager: WinkCalibrationManager

    private var eyeName: String { manager.eye == .right ? "Right Eye" : "Left Eye" }
    private var eyeColor: Color { manager.eye == .right ? .cyan : .orange }

    var body: some View {
        VStack(spacing: 28) {
            Text("Calibrating \(eyeName)")
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)

            Text("Wink your **\(eyeName.lowercased())** about five times,\nthen press Done.")
                .font(.system(size: 16))
                .foregroundStyle(.white.opacity(0.80))
                .multilineTextAlignment(.center)

            Text("Thresholds are computed from your actual aperture data.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)

            // Rough wink counter (heuristic — for visual feedback only)
            HStack(spacing: 10) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .frame(width: 14, height: 14)
                        .foregroundStyle(i < manager.detectedWinkCount ? eyeColor : .white.opacity(0.20))
                        .animation(.spring(response: 0.3), value: manager.detectedWinkCount)
                }
                if manager.detectedWinkCount >= 5 {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(eyeColor.opacity(0.7))
                }
            }

            HStack(spacing: 16) {
                Button("Cancel") { manager.cancel() }
                    .buttonStyle(CalibButtonStyle(color: .gray))

                Button("Done") { manager.finish() }
                    .buttonStyle(CalibButtonStyle(color: eyeColor))
            }
            .padding(.top, 4)
        }
        .padding(48)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 420)
    }
}

// MARK: - Results

private struct ResultsPage: View {
    let thresholds: WinkThresholds
    let manager: WinkCalibrationManager

    private var eyeName: String { manager.eye == .right ? "Right Eye" : "Left Eye" }

    private var winkCountColor: Color {
        thresholds.detectedWinks >= 5 ? .green : .orange
    }

    var body: some View {
        VStack(spacing: 24) {
            Text("\(eyeName) Calibration Complete")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.white)

            // Validated wink count badge
            HStack(spacing: 6) {
                Image(systemName: thresholds.detectedWinks >= 5 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(winkCountColor)
                Text("\(thresholds.detectedWinks) wink\(thresholds.detectedWinks == 1 ? "" : "s") detected in recorded data")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(winkCountColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(winkCountColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

            VStack(spacing: 0) {
                ThresholdRow(label: "Closed Threshold", value: thresholds.closedThreshold, description: "Winking eye must dip below this")
                Divider().background(.white.opacity(0.12))
                ThresholdRow(label: "Open Threshold",   value: thresholds.openThreshold,   description: "Winking eye must rise above this")
                Divider().background(.white.opacity(0.12))
                ThresholdRow(label: "Dip Threshold",    value: thresholds.dipThreshold,    description: "Non-winking eye must stay above this")
                Divider().background(.white.opacity(0.12))
                ThresholdRow(label: "Min Duration",     value: thresholds.minDuration,     description: "Minimum wink length", isTime: true)
                Divider().background(.white.opacity(0.12))
                ThresholdRow(label: "Max Duration",     value: thresholds.maxDuration,     description: "Maximum wink length", isTime: true)
            }
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 16) {
                Button("Cancel") { manager.cancel() }
                    .buttonStyle(CalibButtonStyle(color: .gray))
                Button("Apply") { manager.acceptResults() }
                    .buttonStyle(CalibButtonStyle(color: .accentColor))
            }
        }
        .padding(48)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .frame(maxWidth: 480)
    }
}

private struct ThresholdRow: View {
    let label: String
    let value: Double
    let description: String
    var isTime: Bool = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
            }
            Spacer()
            Text(isTime ? String(format: "%.2fs", value) : String(format: "%.3f", value))
                .font(.system(size: 14, weight: .semibold).monospacedDigit())
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

private struct CalibButtonStyle: ButtonStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(color.opacity(configuration.isPressed ? 0.7 : 1.0), in: RoundedRectangle(cornerRadius: 10))
    }
}
