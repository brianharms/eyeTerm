import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    @State private var showDescriptions = false
    @FocusState private var customKeywordFocused: Bool

    private let whisperModels = ["tiny.en", "base.en", "small.en", "medium.en"]
    private let keywordPresets = ["run it", "go ahead", "do it", "execute"]

    var body: some View {
        @Bindable var state = appState

        Form {
            Section {
                Button {
                    Task { await coordinator.startAll() }
                } label: {
                    Label("Launch All", systemImage: "bolt.fill")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(state.isEyeTrackingActive && state.isVoiceActive && state.isTerminalSetup)

                Toggle("Show Setting Descriptions", isOn: $showDescriptions)
            }

            Section("Eye Tracking") {
                HStack {
                    Button {
                        if state.isEyeTrackingActive {
                            coordinator.stopEyeTracking()
                        } else {
                            coordinator.startEyeTracking()
                        }
                    } label: {
                        Label(state.isEyeTrackingActive ? "Stop Eye Tracking" : "Start Eye Tracking",
                              systemImage: state.isEyeTrackingActive ? "eye.slash" : "eye")
                    }

                    Spacer()

                    Button {
                        coordinator.startCalibration()
                    } label: {
                        Label("Calibrate", systemImage: "scope")
                    }
                    .disabled(!state.isEyeTrackingActive)
                }

                described("Apple Vision uses the built-in Vision framework. MediaPipe uses a Python subprocess for face mesh tracking.") {
                    Picker("Tracking Engine", selection: $state.trackingBackend) {
                        ForEach(TrackingBackend.allCases) { backend in
                            Text(backend.rawValue).tag(backend)
                        }
                    }
                    .onChange(of: state.trackingBackend) { _, newValue in
                        coordinator.switchBackend(to: newValue)
                    }
                }

                described("Which camera to use for eye tracking. Changing restarts the tracker.") {
                    Picker("Camera", selection: $state.selectedCameraDeviceID) {
                        Text("System Default").tag("")
                        ForEach(state.availableCameras, id: \.uid) { cam in
                            Text(cam.name).tag(cam.uid)
                        }
                    }
                }

                described("Which display the overlay and calibration UI appear on. Pick the screen you face while working.") {
                    Picker("Display", selection: $state.selectedDisplayID) {
                        ForEach(state.availableDisplays, id: \.id) { display in
                            Text(display.name).tag(display.id)
                        }
                    }
                }

                described("How long you must look at a quadrant before it focuses. Shorter = faster, longer = fewer accidental switches.") {
                    LabeledContent("Dwell Time") {
                        HStack {
                            Slider(value: $state.dwellTimeThreshold, in: 0.3...3.0, step: 0.1)
                            Text("\(state.dwellTimeThreshold, specifier: "%.1f")s")
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }

                described("Grace period before the dwell timer resets when your gaze briefly leaves a quadrant. Prevents resets from jitter.") {
                    LabeledContent("Hysteresis") {
                        HStack {
                            Slider(value: $state.hysteresisDelay, in: 0.1...1.0, step: 0.05)
                            Text("\(state.hysteresisDelay, specifier: "%.2f")s")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }

                described("Smoothing filter on the final gaze point. More smoothing = stable but laggy, more responsive = jittery but instant.") {
                    LabeledContent("Smoothing") {
                        HStack {
                            Text("Smooth")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $state.eyeSmoothing, in: 0.05...1.0, step: 0.05)
                            Text("Responsive")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                described("How much head pose vs. pupil position drives the gaze estimate. Head is stable; pupil is precise but noisier.") {
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

                described("Scales vertical head pitch. Increase if gaze doesn't reach the top or bottom of your screen.") {
                    LabeledContent("Vertical Sensitivity") {
                        HStack {
                            Text("Narrow")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $state.headPitchSensitivity, in: 0.1...2.0, step: 0.05)
                            Text("Wide")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                described("Multiplier for head movements. Higher = small head turns cover more screen. Useful for subtle movements.") {
                    LabeledContent("Head Amplification") {
                        HStack {
                            Text("None")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $state.headAmplification, in: 1.0...10.0, step: 0.5)
                            Text("Strong")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

            }

            Section("Eye-Tracking Visualization") {
                described("Off = hidden. Subtle = small gaze dot. Debug = full diagnostic view with raw, calibrated, and smoothed points.") {
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

                described("Smoothing on debug overlay dots only. Doesn't affect actual tracking — just makes debug dots easier to read.") {
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
                }

                described("Stroke width of lines and borders in the debug overlay.") {
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
                }

                described("Size of the head and pupil icons in the debug overlay.") {
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
                }

                described("Size of the fused gaze dot — the blended head+pupil signal before smoothing.") {
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
                }

                described("Size of the final smoothed gaze circle — where the system thinks you're looking.") {
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
                }

                described("Size of the gaze indicator in Subtle mode. A small dot that follows your gaze.") {
                    LabeledContent("Subtle Eye Size") {
                        HStack {
                            Text("Small")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $state.subtleEyeSize, in: 5.0...100.0, step: 1.0)
                            Text("Large")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                described("Transparency of the Subtle mode gaze dot. Lower = less distracting.") {
                    LabeledContent("Subtle Eye Opacity") {
                        HStack {
                            Text("Faint")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $state.subtleEyeOpacity, in: 0.05...1.0, step: 0.05)
                            Text("Solid")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
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
                                (.circle(8), "Eye Position"),
                            ])
                        }
                    }
                    settingHint("Toggle debug overlay layers. Red = raw, Green = calibrated, Blue = smoothed (final).")
                }

                described("Show a colored border around the focused quadrant in the overlay.") {
                    Toggle("Quadrant Highlighting", isOn: $state.showQuadrantHighlighting)
                }
                described("Thickness of the focused quadrant border — applies to both Subtle and Debug overlays.") {
                    LabeledContent("Border Thickness") {
                        HStack {
                            Text("Thin")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Slider(value: $state.quadrantBorderWidth, in: 0.5...8.0, step: 0.5)
                            Text("Thick")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                described("Show a visual indicator when eye tracking is active or loading.") {
                    Toggle("Active / Loading State", isOn: $state.showActiveState)
                }

                described("Adds a dark grey screen backdrop behind the debug overlay — makes gaze dots easier to see.") {
                    Toggle("Dark Backdrop", isOn: $state.showDebugBackdrop)
                        .disabled(state.overlayMode == .off)
                }

                described("Shows live dictated text in large font at the bottom of the screen while speaking.") {
                    Toggle("Live Dictation Display", isOn: $state.showDictationDisplay)
                        .disabled(state.overlayMode == .off)
                }

                described("Flashes a label on screen whenever a wink gesture fires.") {
                    Toggle("Wink Visualization", isOn: $state.showWinkOverlay)
                        .disabled(state.overlayMode == .off)
                }

                described("Flashes a label on screen when an execute or window action command is dispatched.") {
                    Toggle("Command Flash", isOn: $state.showCommandFlash)
                        .disabled(state.overlayMode == .off)
                }
            }

            Section("Wink Gestures") {
                described("Detect deliberate one-eye winks to trigger terminal actions. Normal blinks are filtered out.") {
                    Toggle("Enable Wink Gestures", isOn: $state.blinkGesturesEnabled)
                }

                described("Action sent to the focused terminal when you close your left eye.") {
                    Picker("Left Wink", selection: $state.leftWinkAction) {
                        ForEach(WinkAction.allCases) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                }

                described("Action sent to the focused terminal when you close your right eye.") {
                    Picker("Right Wink", selection: $state.rightWinkAction) {
                        ForEach(WinkAction.allCases) { action in
                            Text(action.rawValue).tag(action)
                        }
                    }
                }

                described("Eye aperture below this = \"closed\". Watch Live Aperture while closing one eye to find your value.") {
                    LabeledContent("Closed Threshold") {
                        HStack {
                            Slider(value: $state.winkClosedThreshold, in: 0.05...0.3, step: 0.01)
                            Text("\(state.winkClosedThreshold, specifier: "%.2f")")
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }

                described("Eye aperture above this = \"open\". The gap between thresholds prevents flutter from noisy readings.") {
                    LabeledContent("Open Threshold") {
                        HStack {
                            Slider(value: $state.winkOpenThreshold, in: 0.1...0.5, step: 0.01)
                            Text("\(state.winkOpenThreshold, specifier: "%.2f")")
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                }

                described("Eye must stay closed at least this long. Filters out fast involuntary twitches.") {
                    LabeledContent("Min Duration") {
                        HStack {
                            Slider(value: $state.minWinkDuration, in: 0.05...0.5, step: 0.05)
                            Text("\(state.minWinkDuration, specifier: "%.2f")s")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }

                described("Eye closed longer than this = squint, not a wink. Ignored.") {
                    LabeledContent("Max Duration") {
                        HStack {
                            Slider(value: $state.maxWinkDuration, in: 0.2...2.0, step: 0.1)
                            Text("\(state.maxWinkDuration, specifier: "%.1f")s")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }

                described("Both eyes closing within this window = natural blink, ignored. Increase if normal blinks trigger winks.") {
                    LabeledContent("Blink Reject") {
                        HStack {
                            Slider(value: $state.bilateralRejectWindow, in: 0.02...0.3, step: 0.02)
                            Text("\(state.bilateralRejectWindow, specifier: "%.2f")s")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }

                described("Minimum time between accepted winks. Prevents rapid-fire from eye fatigue.") {
                    LabeledContent("Cooldown") {
                        HStack {
                            Slider(value: $state.winkCooldown, in: 0.2...2.0, step: 0.1)
                            Text("\(state.winkCooldown, specifier: "%.1f")s")
                                .monospacedDigit()
                                .frame(width: 42, alignment: .trailing)
                        }
                    }
                }

                LabeledContent("Live Aperture") {
                    HStack(spacing: 12) {
                        Text("L: \(state.leftEyeAperture, specifier: "%.2f")")
                            .monospacedDigit()
                        Text("R: \(state.rightEyeAperture, specifier: "%.2f")")
                            .monospacedDigit()
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                settingHint("Real-time eye openness. Watch these while winking to dial in thresholds.")

                WinkIndicatorView(lastWinkEvent: state.lastWinkEvent)

                WinkDiagnosticLogView(
                    events: appState.winkDiagnosticLog,
                    closedThreshold: appState.winkClosedThreshold,
                    openThreshold: appState.winkOpenThreshold,
                    minDuration: appState.minWinkDuration,
                    maxDuration: appState.maxWinkDuration,
                    cooldown: appState.winkCooldown
                )
            }

            Section("Voice") {
                Button {
                    if state.isVoiceActive {
                        coordinator.stopVoice()
                    } else {
                        Task { await coordinator.startVoice() }
                    }
                } label: {
                    Label(state.isVoiceActive ? "Stop Voice" : "Start Voice",
                          systemImage: state.isVoiceActive ? "mic.slash" : "mic")
                }

                described("WhisperKit uses CoreML + Neural Engine (fast). whisper.cpp is CPU-only (slower, no framework deps).") {
                    Picker("Voice Engine", selection: $state.voiceBackend) {
                        ForEach(VoiceBackend.allCases) { backend in
                            Text(backend.rawValue).tag(backend)
                        }
                    }
                    .onChange(of: state.voiceBackend) { _, newValue in
                        coordinator.switchVoiceBackend(to: newValue)
                    }
                }

                described("Which microphone to capture from. System Default uses whatever macOS has selected.") {
                    Picker("Microphone", selection: $state.selectedMicDeviceUID) {
                        Text("System Default").tag("")
                        ForEach(state.availableMics, id: \.uid) { mic in
                            Text(mic.name).tag(mic.uid)
                        }
                    }
                }

                described("Larger models are more accurate but slower and use more memory. small.en is a good balance.") {
                    Picker("Whisper Model", selection: $state.whisperModel) {
                        ForEach(whisperModels, id: \.self) { model in
                            Text(model).tag(model)
                        }
                    }
                }

                described("Say this phrase to send text to the terminal and press Enter. The keyword is stripped from output.") {
                    LabeledContent("Execute Keyword") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Picker("", selection: Binding(
                                get: {
                                    keywordPresets.contains(state.executeKeyword) ? state.executeKeyword : "__custom__"
                                },
                                set: { newValue in
                                    if newValue == "__custom__" {
                                        state.executeKeyword = ""
                                    } else {
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
                                    .focused($customKeywordFocused)
                                    .onChange(of: state.executeKeyword) { _, newValue in
                                        if newValue == "" {
                                            customKeywordFocused = true
                                        }
                                    }
                            }
                        }
                    }
                }

                described("Voice activity detection threshold. Lower = picks up quieter speech but also more background noise.") {
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
                }

                described("Convert spoken forms to typed equivalents: \"at sign\" \u{2192} @, \"hashtag\" \u{2192} #, \"new line\" \u{2192} newline.") {
                    Toggle("Text Normalization", isOn: $state.enableTextNormalization)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Window Voice Actions", isOn: $state.windowActionsEnabled)
                    if showDescriptions {
                        Text("Dismiss non-terminal windows by voice. Never acts on iTerm2 or Terminal.app.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        VStack(alignment: .leading, spacing: 3) {
                            windowPhraseRow("Close", phrases: "close it · close window · dismiss")
                            windowPhraseRow("Minimize", phrases: "minimize · minimize it")
                            windowPhraseRow("Hide", phrases: "hide · hide it · hide the window")
                            windowPhraseRow("Back", phrases: "go back · back  (\u{2318}[)")
                            windowPhraseRow("Forward", phrases: "go forward · forward  (\u{2318}])")
                            windowPhraseRow("Reload", phrases: "reload · refresh  (\u{2318}R)")
                        }
                        .padding(.top, 2)
                    }
                }
            }

            Section("Transcription Log") {
                HStack {
                    Text(state.voiceBackend.rawValue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    switch state.voiceModelState {
                    case .idle:
                        Text("Idle")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    case .loading:
                        HStack(spacing: 4) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Loading model...")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    case .ready:
                        Text("Ready")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    case .failed(let msg):
                        Text("Failed: \(msg)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }

                if !state.partialTranscription.isEmpty {
                    Text(state.partialTranscription)
                        .font(.caption)
                        .foregroundStyle(.blue)
                        .italic()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if state.transcriptionHistory.isEmpty && state.partialTranscription.isEmpty {
                    Text("Listening...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .frame(height: 100)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(state.transcriptionHistory.indices.reversed(), id: \.self) { index in
                                let entry = state.transcriptionHistory[index]
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text("Raw")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                            .frame(width: 30, alignment: .leading)
                                        Text(entry.text)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 4) {
                                        Text("Send")
                                            .font(.system(size: 8, weight: .semibold))
                                            .foregroundStyle(entry.cleaned.isEmpty ? .red.opacity(0.6) : .green)
                                            .frame(width: 30, alignment: .leading)
                                        Text(entry.cleaned.isEmpty ? "(filtered out)" : entry.cleaned)
                                            .font(.caption)
                                            .fontWeight(.medium)
                                            .foregroundStyle(entry.cleaned.isEmpty ? .red.opacity(0.6) : .primary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(height: 100)
                }
            }

            Section("Terminal") {
                described("iTerm2 recommended for better AppleScript support and window management.") {
                    Picker("Terminal App", selection: $state.preferredTerminal) {
                        ForEach(PreferredTerminal.allCases) { terminal in
                            Text(terminal.rawValue).tag(terminal)
                        }
                    }
                }

                if state.preferredTerminal == .iTerm2 {
                    Link("Get iTerm2", destination: URL(string: "https://iterm2.com")!)
                        .font(.caption)
                }

                described("Create New opens four terminal windows. Use Existing finds and adopts windows already positioned in quadrants.") {
                    Picker("Setup Mode", selection: $state.terminalSetupMode) {
                        ForEach(TerminalSetupMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                if state.terminalSetupMode == .launchNew {
                    described("Number of terminal columns and rows to create.") {
                        LabeledContent("Grid") {
                            HStack {
                                Stepper("Cols: \(state.terminalGridColumns)", value: $state.terminalGridColumns, in: 1...6)
                                Stepper("Rows: \(state.terminalGridRows)", value: $state.terminalGridRows, in: 1...6)
                            }
                        }
                    }
                    described("Shell command run in each terminal on launch. Typically a Claude CLI command.") {
                        LabeledContent("Command to run on terminal launch") {
                            TextField("", text: $state.terminalLaunchCommand)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                        }
                    }
                }

                Button {
                    Task { await coordinator.setupTerminals() }
                } label: {
                    Label(
                        state.terminalSetupMode == .launchNew ? "Create Terminals" : "Adopt Terminals",
                        systemImage: state.terminalSetupMode == .launchNew ? "terminal" : "rectangle.on.rectangle"
                    )
                }
                if state.terminalSetupMode == .launchNew {
                    settingHint("Creates \(state.terminalGridColumns * state.terminalGridRows) terminal windows in a \(state.terminalGridColumns)×\(state.terminalGridRows) grid and runs the launch command in each.")
                } else {
                    let count = appState.terminalSlots.count
                    settingHint(count > 0 ? "\(count) slots adopted. Scans existing terminal windows and adopts them for management." : "Scans for existing terminal windows and adopts them for management.")
                }

                LabeledContent("Manual Focus") {
                    HStack(spacing: 4) {
                        ForEach(appState.terminalSlots) { slot in
                            Button {
                                coordinator.manualFocus(slotIndex: slot.id)
                            } label: {
                                Text(slot.label)
                                    .foregroundStyle(appState.focusedSlot == slot.id ? Color.accentColor : Color.secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
                .disabled(!appState.isTerminalSetup)
                settingHint("Click a slot number to manually focus that terminal without eye tracking.")

                Button {
                    coordinator.testSendText()
                } label: {
                    Label("Send Test Command", systemImage: "paperplane")
                }
                .disabled(appState.focusedSlot == nil || !appState.isTerminalSetup)
                settingHint("Sends a test string to the focused terminal to verify the connection.")
            }

            Section("Onboarding") {
                Button("Show Walkthrough Again") {
                    OnboardingState.reset()
                    coordinator.showOnboardingWalkthrough()
                }
                settingHint("Re-show the first-run walkthrough explaining how eyeTerm works.")
            }

            Section {
                HStack {
                    Button {
                        appState.saveSettingsAsDefaults()
                    } label: {
                        Label("Save Defaults", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        appState.loadPersistedSettings()
                    } label: {
                        Label("Revert", systemImage: "arrow.uturn.backward")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380, height: 640)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func settingHint(_ text: String) -> some View {
        if showDescriptions {
            Text(text)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func windowPhraseRow(_ action: String, phrases: String) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Text(action)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Text(phrases)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    private func described<Content: View>(_ hint: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            content()
            if showDescriptions {
                Text(hint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
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

struct WinkDiagnosticLogView: View {
    let events: [WinkDiagnosticEvent]
    let closedThreshold: Double
    let openThreshold: Double
    let minDuration: Double
    let maxDuration: Double
    let cooldown: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Detection Log")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)

            if events.isEmpty {
                Text("No events yet — try winking or blinking")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(events.reversed().enumerated()), id: \.offset) { _, event in
                    WinkDiagnosticRowView(
                        event: event,
                        closedThreshold: closedThreshold,
                        openThreshold: openThreshold,
                        minDuration: minDuration,
                        maxDuration: maxDuration,
                        cooldown: cooldown
                    )
                }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }
}

struct WinkDiagnosticRowView: View {
    let event: WinkDiagnosticEvent
    let closedThreshold: Double
    let openThreshold: Double
    let minDuration: Double
    let maxDuration: Double
    let cooldown: Double

    var sideLabel: String { event.side == .left ? "L" : "R" }
    var sideColor: Color { event.side == .left ? .blue : .orange }

    var outcomeText: String {
        switch event.outcome {
        case .fired: return "fired"
        case .bilateralBlink: return "bilateral blink"
        case .otherEyeNotOpen: return "other eye not open"
        case .otherEyeDipped: return "other eye dipped"
        case .tooShort: return "too short"
        case .tooLong: return "too long"
        case .cooldown: return "cooldown"
        }
    }

    var outcomeColor: Color {
        switch event.outcome {
        case .fired: return .green
        default: return .red
        }
    }

    // Pass/fail for each check
    var eyePass: Bool { event.winkEyeMin < closedThreshold }
    var otherPass: Bool {
        if case .otherEyeNotOpen = event.outcome { return false }
        return event.otherEyeMin >= openThreshold
    }
    var durPass: Bool { event.duration >= minDuration && event.duration <= maxDuration }
    var bltPass: Bool {
        if case .bilateralBlink = event.outcome { return false }
        return true
    }
    var cdPass: Bool {
        if case .cooldown = event.outcome { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // Line 1: side + duration + outcome
            HStack(spacing: 6) {
                Text(sideLabel)
                    .font(.caption.bold())
                    .foregroundStyle(sideColor)
                    .frame(width: 14)
                Text(String(format: "%.2fs", event.duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 38, alignment: .trailing)
                Text(outcomeText)
                    .font(.caption.bold())
                    .foregroundStyle(outcomeColor)
                Spacer()
            }
            // Line 2: stat pills
            HStack(spacing: 5) {
                statPill(
                    label: "Eye↓",
                    value: String(format: "%.2f", event.winkEyeMin),
                    target: String(format: "<%.2f", closedThreshold),
                    pass: eyePass
                )
                statPill(
                    label: "Other",
                    value: String(format: "%.2f", event.otherEyeMin),
                    target: String(format: "≥%.2f", openThreshold),
                    pass: otherPass
                )
                statPill(
                    label: "Dur",
                    value: String(format: "%.2f", event.duration),
                    target: String(format: "%.2f–%.1f", minDuration, maxDuration),
                    pass: durPass
                )
                statPill(label: "Blt", value: bltPass ? "ok" : "!", target: "", pass: bltPass)
                statPill(label: "CD", value: cdPass ? "ok" : "!", target: "", pass: cdPass)
                Spacer()
            }
            .padding(.leading, 20)
        }
    }

    @ViewBuilder
    private func statPill(label: String, value: String, target: String, pass: Bool) -> some View {
        HStack(spacing: 2) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 8, design: .monospaced))
                .foregroundStyle(.primary)
            if !target.isEmpty {
                Text(target)
                    .font(.system(size: 7, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Text(pass ? "✓" : "✗")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(pass ? Color.green : Color.red)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(Color(NSColor.quaternaryLabelColor).opacity(0.4), in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct WinkIndicatorView: View {
    let lastWinkEvent: WinkEvent?
    @State private var flash = false

    var body: some View {
        HStack(spacing: 8) {
            if let event = lastWinkEvent {
                Image(systemName: event.side == .left ? "eye.trianglebadge.exclamationmark" : "eye.trianglebadge.exclamationmark")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(flash ? .green : .secondary)
                    .font(.system(size: 14))
                Text("\(event.side == .left ? "Left" : "Right") wink \u{2192} \(event.action.shortLabel)")
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(flash ? .primary : .secondary)
            } else {
                Image(systemName: "eye")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 14))
                Text("No wink detected yet")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        .onChange(of: lastWinkEvent?.timestamp) {
            flash = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                flash = false
            }
        }
    }
}
