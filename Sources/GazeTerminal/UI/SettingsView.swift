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

            }

            Section("Eye-Tracking Visualization") {
                LabeledContent("Overlay") {
                    Picker("", selection: $state.overlayMode) {
                        ForEach(OverlayMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                LabeledContent("Debug Smoothing") {
                    HStack {
                        Text("Smooth")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.debugSmoothing, in: 0.05...1.0, step: 0.05)
                        Text("Raw")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Debug Line Width") {
                    HStack {
                        Text("Thin")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.debugLineWidth, in: 0.5...5.0, step: 0.5)
                        Text("Thick")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Icon Size") {
                    HStack {
                        Text("Small")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.overlayIconSize, in: 0.5...2.5, step: 0.1)
                        Text("Large")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Fusion Dot Size") {
                    HStack {
                        Text("Small")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.fusionDotSize, in: 3.0...48.0, step: 1.0)
                        Text("Large")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Smoothed Circle Size") {
                    HStack {
                        Text("Small")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.smoothedCircleSize, in: 3.0...48.0, step: 1.0)
                        Text("Large")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Subtle Gaze Size") {
                    HStack {
                        Text("Small")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.subtleGazeSize, in: 5.0...100.0, step: 1.0)
                        Text("Large")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Subtle Gaze Opacity") {
                    HStack {
                        Text("Faint")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.subtleGazeOpacity, in: 0.05...1.0, step: 0.05)
                        Text("Solid")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("Overlay Legend")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Toggle("", isOn: $state.showRawOverlay)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            legendGroup(label: "Raw", color: .red, items: [
                                (.icon("person.fill"), "Head"),
                                (.icon("eye.fill"), "Pupil"),
                                (.circle(6), "Fused"),
                            ])
                        }
                        HStack(spacing: 4) {
                            Toggle("", isOn: $state.showCalibratedOverlay)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            legendGroup(label: "Calibrated", color: .green, items: [
                                (.icon("person.fill"), "Head"),
                                (.icon("eye.fill"), "Pupil"),
                                (.circle(6), "Fused"),
                            ])
                        }
                        HStack(spacing: 4) {
                            Toggle("", isOn: $state.showSmoothedOverlay)
                                .labelsHidden()
                                .toggleStyle(.checkbox)
                            legendGroup(label: "Smoothed", color: .blue, items: [
                                (.circle(8), "Gaze Position"),
                            ])
                        }
                    }
                }
            }

            Section("Voice") {
                Picker("Voice Engine", selection: $state.voiceBackend) {
                    ForEach(VoiceBackend.allCases) { backend in
                        Text(backend.rawValue).tag(backend)
                    }
                }
                .onChange(of: state.voiceBackend) { _, newValue in
                    coordinator.switchVoiceBackend(to: newValue)
                }

                Picker("Whisper Model", selection: $state.whisperModel) {
                    ForEach(whisperModels, id: \.self) { model in
                        Text(model).tag(model)
                    }
                }

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

                LabeledContent("Mic Sensitivity") {
                    HStack {
                        Text("Sensitive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Slider(value: $state.micSensitivity, in: 0.001...0.05)
                        Text("Less sensitive")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Toggle("Text Normalization", isOn: $state.enableTextNormalization)
            }

            Section("Transcription Log") {
                if state.transcriptionHistory.isEmpty {
                    Text("Listening...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 100)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(state.transcriptionHistory.indices.reversed(), id: \.self) { index in
                                Text(state.transcriptionHistory[index].text)
                                    .font(.caption)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 100)
                }
            }

            Section("Terminal") {
                Picker("Terminal App", selection: $state.preferredTerminal) {
                    ForEach(PreferredTerminal.allCases) { terminal in
                        Text(terminal.rawValue).tag(terminal)
                    }
                }

                if state.preferredTerminal == .iTerm2 {
                    Link("Get iTerm2", destination: URL(string: "https://iterm2.com")!)
                        .font(.caption)
                }

                LabeledContent("Command to run on terminal launch") {
                    TextField("", text: $state.terminalLaunchCommand)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }

                Button {
                    Task { await coordinator.setupTerminals() }
                } label: {
                    Label("Launch Terminals", systemImage: "terminal")
                }

                LabeledContent("Manual Focus") {
                    HStack(spacing: 4) {
                        ForEach(ScreenQuadrant.allCases) { quadrant in
                            Button {
                                coordinator.manualFocus(quadrant: quadrant)
                            } label: {
                                Image(systemName: quadrant.symbol)
                                    .foregroundStyle(appState.focusedQuadrant == quadrant ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help(quadrant.displayName)
                        }
                    }
                }
                .disabled(!appState.isTerminalSetup)

                Button {
                    coordinator.testSendText()
                } label: {
                    Label("Send Test Command", systemImage: "paperplane")
                }
                .disabled(appState.focusedQuadrant == nil || !appState.isTerminalSetup)
            }

            Section("Onboarding") {
                Button("Show Walkthrough Again") {
                    OnboardingState.reset()
                    coordinator.showOnboardingWalkthrough()
                }
            }

            Section {
                Button {
                    appState.saveSettingsAsDefaults()
                } label: {
                    Label("Save Settings as Default", systemImage: "square.and.arrow.down")
                }
                .help("Writes current settings to saved-defaults.json for Claude to bake into the next build")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 640)
        .onAppear {
            DispatchQueue.main.async {
                for window in NSApp.windows where window.title.contains("Settings") || window.identifier?.rawValue.contains("settings") == true {
                    window.level = .floating
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    private enum LegendSymbol {
        case icon(String)
        case circle(CGFloat)
    }

    private func legendGroup(label: String, color: Color, items: [(LegendSymbol, String)]) -> some View {
        HStack {
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
                .foregroundStyle(color)
                .frame(width: 62, alignment: .leading)
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                if index > 0 { Spacer() }
                HStack(spacing: 3) {
                    switch item.0 {
                    case .icon(let name):
                        Image(systemName: name)
                            .font(.system(size: 9))
                            .foregroundStyle(color)
                    case .circle(let size):
                        Circle()
                            .fill(color.opacity(0.7))
                            .frame(width: size, height: size)
                    }
                    Text(item.1)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}
