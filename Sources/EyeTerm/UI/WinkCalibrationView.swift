import SwiftUI

struct WinkCalibrationView: View {
    @Bindable var manager: WinkCalibrationManager

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Wink Calibration")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                    Spacer()
                    Button {
                        manager.cancel()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.6))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 28)
                .padding(.top, 28)
                .padding(.bottom, 20)

                Divider().background(.white.opacity(0.15))

                // Step Content
                Group {
                    switch manager.currentStep {
                    case .intro:
                        introView
                    case .results:
                        resultsView
                    default:
                        collectionStepView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(28)
            }
        }
        .frame(width: 420, height: 340)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 32)
    }

    // MARK: - Intro
    private var introView: some View {
        VStack(spacing: 20) {
            Image(systemName: "eye")
                .font(.system(size: 48))
                .foregroundStyle(.cyan)

            Text("Calibrate your wink thresholds")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("We'll measure your eye aperture at rest, while closed, and during natural blinks to compute optimal detection thresholds.")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()

            Button("Start Calibration") {
                manager.advance()
            }
            .buttonStyle(CalibrationPrimaryButtonStyle())
        }
    }

    // MARK: - Collection Step
    private var collectionStepView: some View {
        VStack(spacing: 20) {
            stepIcon
                .font(.system(size: 44))
                .foregroundStyle(.cyan)

            Text(stepTitle)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)

            Text(manager.statusMessage)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.6))

            if isCountStep {
                // Show wink count progress
                HStack(spacing: 8) {
                    ForEach(0..<manager.requiredWinks, id: \.self) { i in
                        Circle()
                            .fill(i < manager.completedWinks ? Color.cyan : Color.white.opacity(0.25))
                            .frame(width: 14, height: 14)
                    }
                }
                .padding(.top, 4)
            } else {
                // Show frame progress bar
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.white.opacity(0.15))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.cyan)
                            .frame(width: geo.size.width * manager.progress)
                    }
                }
                .frame(height: 8)
                .padding(.top, 4)
            }

            Spacer()

            stepHint
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.45))
        }
    }

    // MARK: - Results
    private var resultsView: some View {
        VStack(spacing: 16) {
            if let r = manager.result {
                Text("Calibration Complete")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)

                VStack(spacing: 8) {
                    resultRow("Closed threshold", value: r.closedThreshold)
                    resultRow("Open threshold", value: r.openThreshold)
                    resultRow("Min wink duration", value: r.minWinkDuration, unit: "s")
                    resultRow("Max wink duration", value: r.maxWinkDuration, unit: "s")
                    resultRow("Bilateral window", value: r.bilateralRejectWindow, unit: "s")
                }
                .padding(.vertical, 4)

                Spacer()

                HStack(spacing: 12) {
                    Button("Cancel") {
                        manager.cancel()
                    }
                    .buttonStyle(CalibrationSecondaryButtonStyle())

                    Button("Apply") {
                        manager.applyResult()
                    }
                    .buttonStyle(CalibrationPrimaryButtonStyle())
                }
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.cyan)
            }
        }
    }

    private func resultRow(_ label: String, value: Double, unit: String = "") -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.7))
            Spacer()
            Text(String(format: "%.3f\(unit)", value))
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(.cyan)
        }
    }

    // MARK: - Step Helpers
    private var isCountStep: Bool {
        switch manager.currentStep {
        case .naturalBlinks, .leftWinkPractice, .rightWinkPractice: return true
        default: return false
        }
    }

    private var stepIcon: Image {
        switch manager.currentStep {
        case .eyesOpen: return Image(systemName: "eye")
        case .eyesClosed: return Image(systemName: "eye.slash")
        case .naturalBlinks: return Image(systemName: "eye.trianglebadge.exclamationmark")
        case .leftWinkPractice: return Image(systemName: "arrow.left.circle")
        case .rightWinkPractice: return Image(systemName: "arrow.right.circle")
        default: return Image(systemName: "questionmark")
        }
    }

    private var stepTitle: String {
        switch manager.currentStep {
        case .eyesOpen: return "Eyes Open"
        case .eyesClosed: return "Eyes Closed"
        case .naturalBlinks: return "Natural Blinks"
        case .leftWinkPractice: return "Left Wink Practice"
        case .rightWinkPractice: return "Right Wink Practice"
        default: return ""
        }
    }

    private var stepHint: Text {
        switch manager.currentStep {
        case .eyesOpen: return Text("Stay relaxed and look naturally at the screen")
        case .eyesClosed: return Text("Close completely — both eyes")
        case .naturalBlinks: return Text("Blink at your normal rate")
        case .leftWinkPractice: return Text("Close only your LEFT eye deliberately")
        case .rightWinkPractice: return Text("Close only your RIGHT eye deliberately")
        default: return Text("")
        }
    }
}

// MARK: - Button Styles

struct CalibrationPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.cyan, in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.8 : 1.0)
    }
}

struct CalibrationSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 24)
            .padding(.vertical, 10)
            .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
