import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    private let whisperModels = ["tiny.en", "base.en", "small.en", "medium.en"]
    private let keywordPresets = ["run it", "go ahead", "do it"]

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Eye Tracking") {
                Picker("Tracking Engine", selection: $state.trackingBackend) {
                    ForEach(TrackingBackend.allCases) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                .onChange(of: state.trackingBackend) { _, newValue in
                    coordinator.switchBackend(to: newValue)
                }

                LabeledContent("Dwell Time") {
                    HStack {
                        Slider(value: $state.dwellTimeThreshold, in: 0.3...3.0, step: 0.1)
                        Text("\(state.dwellTimeThreshold, specifier: "%.1f")s")
                            .monospacedDigit()
                            .frame(width: 36, alignment: .trailing)
                    }
                }

                LabeledContent("Hysteresis") {
                    HStack {
                        Slider(value: $state.hysteresisDelay, in: 0.1...1.0, step: 0.05)
                        Text("\(state.hysteresisDelay, specifier: "%.2f")s")
                            .monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    }
                }

                LabeledContent("Smoothing") {
                    HStack {
                        Text("Smooth")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.gazeSmoothing, in: 0.05...1.0, step: 0.05)
                        Text("Responsive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Head / Eye Balance") {
                    HStack {
                        Text("Eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.headWeight, in: 0.0...1.0, step: 0.05)
                        Text("Head")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Overlay") {
                    Picker("", selection: $state.overlayMode) {
                        ForEach(OverlayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
            }

            Section("Voice") {
                Picker("Whisper Model", selection: $state.whisperModel) {
                    ForEach(whisperModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

                Toggle("Text Normalization", isOn: $state.enableTextNormalization)

                LabeledContent("Execute Keyword") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Picker("", selection: Binding(
                            get: {
                                keywordPresets.contains(state.executeKeyword) ? state.executeKeyword : "__custom__"
                            },
                            set: { newValue in
                                if newValue != "__custom__" {
                                    state.executeKeyword = newValue
                                }
                            }
                        )) {
                            ForEach(keywordPresets, id: \.self) { preset in
                                Text("\"\(preset)\"").tag(preset)
                            }
                            Text("Custom...").tag("__custom__")
                        }
                        .labelsHidden()

                        if !keywordPresets.contains(state.executeKeyword) {
                            TextField("Custom keyword", text: $state.executeKeyword)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 160)
                        }
                    }
                }
            }
            Section("Onboarding") {
                Button("Show Walkthrough Again") {
                    OnboardingState.reset()
                    coordinator.showOnboardingWalkthrough()
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 480)
    }
}
