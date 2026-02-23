import Foundation
import AppKit
import SwiftUI
import Observation
import CoreAudio

@Observable
final class AppCoordinator {
    let appState: AppState

    let terminalManager = TerminalManager()
    private(set) var activeBackend: EyeTrackingBackend
    let calibrationManager = CalibrationManager()
    private(set) var activeVoiceBackend: VoiceTranscriptionBackend
    let commandParser = CommandParser()
    let windowActionManager = WindowActionManager()
    let transcriptionDiffer = StreamingTranscriptionDiffer()
    let dwellTimer: DwellTimer
    let blinkDetector = BlinkGestureDetector()

    private var calibrationOverlayWindow: NSWindow?
    private var eyeTermOverlayWindow: NSPanel?
    private var onboardingWindow: NSPanel?
    private var cameraPreviewWindow: NSPanel?
    private var errorDetailsWindow: NSPanel?
    private var waveformWindow: NSPanel?
    private var deviceChangeListenerRegistered = false
    private var deviceChangeListenerBlock: AudioObjectPropertyListenerBlock?

    let mediaPipeSetupManager = MediaPipeSetupManager()
    private var mediaPipeSetupWindow: NSPanel?

    // Debug visualization smoothers (separate from pipeline smoothing)
    private var debugHeadFilter = EyeTermEMAFilter(alpha: 0.15)
    private var debugPupilFilter = EyeTermEMAFilter(alpha: 0.15)
    private var debugCalHeadFilter = EyeTermEMAFilter(alpha: 0.15)
    private var debugCalPupilFilter = EyeTermEMAFilter(alpha: 0.15)
    private var debugRawFusedFilter = EyeTermEMAFilter(alpha: 0.15)
    private var debugCalFusedFilter = EyeTermEMAFilter(alpha: 0.15)

    init(appState: AppState) {
        self.appState = appState
        self.activeBackend = appState.trackingBackend == .mediaPipe
            ? MediaPipeBackend() as EyeTrackingBackend
            : EyeTermTracker() as EyeTrackingBackend
        self.activeVoiceBackend = appState.voiceBackend == .whisperCpp
            ? WhisperCppBackend() as VoiceTranscriptionBackend
            : WhisperKitBackend() as VoiceTranscriptionBackend
        self.dwellTimer = DwellTimer(
            dwellThreshold: appState.dwellTimeThreshold,
            hysteresisDelay: appState.hysteresisDelay
        )
        wireCallbacks()
        wireBlinkDetector()
        pushAllSettings()
        observeSettings()
        refreshMicList()
        registerDeviceChangeListener()
        setupWindowLevelObservers()

        if !OnboardingState.hasCompleted {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingWalkthrough()
            }
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        activeBackend.onEyeUpdate = { [weak self] quadrant, confidence in
            guard let self else { return }
            if quadrant != self.appState.activeQuadrant {
                self.appState.dwellingQuadrant = nil
                self.appState.dwellProgress = 0
            }
            self.appState.activeQuadrant = quadrant
            self.appState.eyeConfidence = confidence
            self.dwellTimer.update(quadrant: quadrant)
        }

        dwellTimer.onDwellProgress = { [weak self] quadrant, progress in
            guard let self else { return }
            self.appState.dwellingQuadrant = quadrant
            self.appState.dwellProgress = progress
        }

        dwellTimer.onDwellConfirmed = { [weak self] quadrant in
            guard let self else { return }
            self.activeVoiceBackend.flushAudio()
            self.transcriptionDiffer.reset()
            self.appState.focusedQuadrant = quadrant
            guard self.appState.isTerminalSetup else { return }
            Task {
                do {
                    try await self.terminalManager.focusTerminal(quadrant: quadrant)
                } catch {
                    self.appState.addError("Focus failed: \(error.localizedDescription)")
                }
            }
        }

        activeVoiceBackend.onAudioLevel = { [weak self] level, speaking in
            guard let self else { return }
            self.appState.audioLevel = level
            self.appState.isSpeaking = speaking
            self.appState.audioLevelHistory.append(level)
            if self.appState.audioLevelHistory.count > 27 {
                self.appState.audioLevelHistory.removeFirst()
            }
        }

        activeVoiceBackend.onModelState = { [weak self] state in
            guard let self else { return }
            self.appState.voiceModelState = state
        }

        activeVoiceBackend.onPartialTranscription = { [weak self] text in
            guard let self else { return }
            let normalized = self.commandParser.normalizeOnly(text)
            self.appState.partialTranscription = normalized
            guard !normalized.isEmpty else { return }

            guard let quadrant = self.appState.focusedQuadrant else { return }
            guard self.terminalManager.isSetup else { return }

            let edit = self.transcriptionDiffer.diff(newText: normalized)
            print("[AppCoordinator] Partial diff: \(edit)")
            Task {
                do {
                    switch edit {
                    case .noChange:
                        break
                    case .append(let str):
                        try await self.terminalManager.typeText(str, in: quadrant)
                        self.activeVoiceBackend.trimAudio(keepLastSeconds: 1.5)
                    case .replaceFromOffset(let backspaces, let newText):
                        try await self.terminalManager.sendBackspaces(backspaces, in: quadrant)
                        if !newText.isEmpty {
                            try await self.terminalManager.typeText(newText, in: quadrant)
                        }
                        self.activeVoiceBackend.trimAudio(keepLastSeconds: 1.5)
                    }
                } catch {
                    print("[AppCoordinator] Partial command failed: \(error)")
                }
            }
        }

        activeVoiceBackend.onTranscription = { [weak self] text in
            guard let self else { return }
            self.appState.partialTranscription = ""
            self.appState.lastTranscription = text

            // Window action interception — before command parsing
            if self.appState.windowActionsEnabled,
               let windowAction = self.commandParser.detectWindowAction(text) {
                Task {
                    let isProtected = await self.windowActionManager.isFrontmostProtected()
                    if !isProtected {
                        print("[AppCoordinator] Window action: \(windowAction.rawValue)")
                        if self.appState.showCommandFlash {
                            self.appState.lastCommandFlash = windowAction.rawValue.uppercased()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                                self?.appState.lastCommandFlash = nil
                            }
                        }
                        try? await self.windowActionManager.execute(windowAction)
                        if let quadrant = self.appState.focusedQuadrant, self.terminalManager.isSetup {
                            try? await self.terminalManager.focusTerminal(quadrant: quadrant)
                        }
                        self.transcriptionDiffer.reset()
                        self.appState.transcriptionHistory.append((text: text, cleaned: "[\(windowAction.rawValue)]", timestamp: Date()))
                        let cutoff = Date().addingTimeInterval(-10)
                        self.appState.transcriptionHistory.removeAll { $0.timestamp < cutoff }
                        return
                    }
                    // Frontmost is a terminal — dispatch text normally
                    print("[AppCoordinator] Window action skipped — terminal is frontmost")
                    self.dispatchTranscription(text)
                }
                return
            }

            self.dispatchTranscription(text)
        }

        calibrationManager.onCalibrationComplete = { [weak self] result in
            guard let self else { return }
            self.activeBackend.headCalibrationTransform = result.headTransform
            self.activeBackend.pupilCalibrationTransform = result.pupilTransform
            self.activeBackend.parallaxCorrX = result.parallaxCorrX
            self.activeBackend.parallaxCorrY = result.parallaxCorrY
            self.appState.parallaxCorrX = result.parallaxCorrX
            self.appState.parallaxCorrY = result.parallaxCorrY
            self.appState.isCalibrated = true
            self.dismissCalibrationOverlay()
        }

        calibrationManager.onNextTarget = { [weak self] _ in
            guard let self else { return }
            self.appState.calibrationSamples = self.calibrationManager.currentTargetIndex
        }

        activeBackend.onRawEyePoint = { [weak self] point in
            guard let self else { return }
            self.appState.rawEyePoint = self.debugRawFusedFilter.update(point)
        }

        activeBackend.onCalibratedEyePoint = { [weak self] point in
            guard let self else { return }
            self.appState.calibratedEyePoint = self.debugCalFusedFilter.update(point)
        }

        activeBackend.onSmoothedEyePoint = { [weak self] point in
            guard let self else { return }
            self.appState.smoothedEyePoint = point
        }

        activeBackend.onDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            self.appState.headYaw = diagnostics.headYaw
            self.appState.headPitch = diagnostics.headPitch
            self.appState.pupilOffsetX = diagnostics.pupilOffsetX
            self.appState.pupilOffsetY = diagnostics.pupilOffsetY
            self.appState.headEyePoint = self.debugHeadFilter.update(diagnostics.headPoint)
            self.appState.pupilEyePoint = self.debugPupilFilter.update(diagnostics.pupilPoint)
            self.appState.calibratedHeadEyePoint = self.debugCalHeadFilter.update(diagnostics.calibratedHeadPoint)
            self.appState.calibratedPupilEyePoint = self.debugCalPupilFilter.update(diagnostics.calibratedPupilPoint)
            self.calibrationManager.recordSample(
                headPoint: diagnostics.headPoint,
                pupilPoint: diagnostics.pupilPoint,
                headYaw: diagnostics.headYaw,
                headPitch: diagnostics.headPitch
            )
        }

        activeBackend.onFaceObservation = { [weak self] faceData in
            guard let self else { return }
            self.appState.faceObservationData = faceData
            self.appState.leftEyeAperture = faceData?.leftEyeAperture ?? 0
            self.appState.rightEyeAperture = faceData?.rightEyeAperture ?? 0
            if self.appState.blinkGesturesEnabled {
                self.blinkDetector.update(
                    leftAperture: faceData?.leftEyeAperture,
                    rightAperture: faceData?.rightEyeAperture
                )
            }
        }

        if let mpBackend = activeBackend as? MediaPipeBackend {
            mpBackend.onError = { [weak self] error in
                self?.appState.addError("MediaPipe: \(error)")
            }
        }
    }

    private func dispatchTranscription(_ text: String) {
        let commands = commandParser.parse(text)
        let cleaned = commands.compactMap { cmd -> String? in
            if case .typeText(let s) = cmd { return s }
            return nil
        }.joined(separator: " ")
        appState.transcriptionHistory.append((text: text, cleaned: cleaned, timestamp: Date()))
        let cutoff = Date().addingTimeInterval(-10)
        appState.transcriptionHistory.removeAll { $0.timestamp < cutoff }
        print("[AppCoordinator] Parsed \(commands.count) commands from: \"\(text)\"")

        guard let quadrant = appState.focusedQuadrant else {
            print("[AppCoordinator] No focused quadrant — transcription ignored. Use manual focus or eye tracking.")
            transcriptionDiffer.reset()
            return
        }
        guard terminalManager.isSetup else {
            transcriptionDiffer.reset()
            return
        }

        print("[AppCoordinator] Sending to \(quadrant.displayName)")
        Task {
            for command in commands {
                do {
                    switch command {
                    case .typeText(let str):
                        let edit = self.transcriptionDiffer.finalize(finalText: str)
                        print("[AppCoordinator] Final diff: \(edit)")
                        switch edit {
                        case .noChange:
                            break
                        case .append(let appendStr):
                            try await self.terminalManager.typeText(appendStr, in: quadrant)
                        case .replaceFromOffset(let backspaces, let newText):
                            try await self.terminalManager.sendBackspaces(backspaces, in: quadrant)
                            if !newText.isEmpty {
                                try await self.terminalManager.typeText(newText, in: quadrant)
                            }
                        }
                    case .execute:
                        print("[AppCoordinator] Sending Return")
                        if self.appState.showCommandFlash {
                            self.appState.lastCommandFlash = "EXECUTE ↵"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                                self?.appState.lastCommandFlash = nil
                            }
                        }
                        try await self.terminalManager.sendReturn(in: quadrant)
                    }
                } catch {
                    print("[AppCoordinator] Command failed: \(error)")
                    self.appState.addError("Command failed: \(error.localizedDescription)")
                }
            }
            self.transcriptionDiffer.reset()
        }
    }

    private func wireBlinkDetector() {
        blinkDetector.onLeftWink = { [weak self] in
            guard let self else { return }
            let action = self.appState.leftWinkAction
            self.appState.lastWinkEvent = WinkEvent(side: .left, action: action, timestamp: Date())
            print("[AppCoordinator] Left wink → \(action.shortLabel)")
            if self.appState.showWinkOverlay {
                self.appState.lastWinkDisplay = "← ESC"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.appState.lastWinkDisplay = nil
                }
            }
            self.executeWinkAction(action)
        }
        blinkDetector.onRightWink = { [weak self] in
            guard let self else { return }
            let action = self.appState.rightWinkAction
            self.appState.lastWinkEvent = WinkEvent(side: .right, action: action, timestamp: Date())
            print("[AppCoordinator] Right wink → \(action.shortLabel)")
            if self.appState.showWinkOverlay {
                self.appState.lastWinkDisplay = "→ ENTER"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                    self?.appState.lastWinkDisplay = nil
                }
            }
            self.executeWinkAction(action)
        }
        blinkDetector.onDiagnosticEvent = { [weak self] event in
            DispatchQueue.main.async {
                self?.appState.appendWinkDiagnostic(event)
            }
        }
    }

    private func executeWinkAction(_ action: WinkAction) {
        guard action != .none else { return }
        guard let quadrant = appState.focusedQuadrant, terminalManager.isSetup else { return }
        Task {
            do {
                switch action {
                case .doubleEscape:
                    try await terminalManager.sendDoubleEscape(in: quadrant)
                case .singleEscape:
                    try await terminalManager.sendEscape(in: quadrant)
                case .enter:
                    try await terminalManager.sendReturn(in: quadrant)
                case .none:
                    break
                }
            } catch {
                appState.addError("Wink action failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Reactive Settings

    private func observeSettings() {
        withObservationTracking {
            _ = appState.dwellTimeThreshold
            _ = appState.hysteresisDelay
            _ = appState.enableTextNormalization
            _ = appState.eyeSmoothing
            _ = appState.headWeight
            _ = appState.headPitchSensitivity
            _ = appState.parallaxCorrX
            _ = appState.parallaxCorrY
            _ = appState.headAmplification
            _ = appState.executeKeyword
            _ = appState.overlayMode
            _ = appState.debugSmoothing
            _ = appState.micSensitivity
            _ = appState.selectedMicDeviceUID
            _ = appState.voiceBackend
            _ = appState.overlayIconSize
            _ = appState.fusionDotSize
            _ = appState.preferredTerminal
            _ = appState.terminalLaunchCommand
            _ = appState.blinkGesturesEnabled
            _ = appState.winkClosedThreshold
            _ = appState.winkOpenThreshold
            _ = appState.leftWinkAction
            _ = appState.rightWinkAction
            _ = appState.minWinkDuration
            _ = appState.maxWinkDuration
            _ = appState.bilateralRejectWindow
            _ = appState.winkCooldown
            _ = appState.windowActionsEnabled
            _ = appState.terminalSetupMode
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.pushAllSettings()
                self?.observeSettings()
            }
        }
    }

    private func pushAllSettings() {
        dwellTimer.dwellThreshold = appState.dwellTimeThreshold
        dwellTimer.hysteresisDelay = appState.hysteresisDelay
        commandParser.enableNormalization = appState.enableTextNormalization
        commandParser.executeKeyword = appState.executeKeyword
        activeBackend.smoothingAlpha = appState.eyeSmoothing
        activeBackend.headWeight = appState.headWeight
        activeBackend.headPitchSensitivity = appState.headPitchSensitivity
        activeBackend.parallaxCorrX = appState.parallaxCorrX
        activeBackend.parallaxCorrY = appState.parallaxCorrY
        activeBackend.headAmplification = appState.headAmplification
        activeVoiceBackend.silenceThreshold = Float(appState.micSensitivity)
        let newUID = appState.selectedMicDeviceUID.isEmpty ? nil : appState.selectedMicDeviceUID
        if activeVoiceBackend.inputDeviceUID != newUID {
            activeVoiceBackend.inputDeviceUID = newUID
            // Restart voice to apply the new device
            if activeVoiceBackend.isRunning {
                stopVoice()
                Task { await startVoice() }
            }
        }
        let da = appState.debugSmoothing
        debugHeadFilter.alpha = da
        debugPupilFilter.alpha = da
        debugCalHeadFilter.alpha = da
        debugCalPupilFilter.alpha = da
        debugRawFusedFilter.alpha = da
        debugCalFusedFilter.alpha = da
        terminalManager.preferredTerminal = appState.preferredTerminal
        terminalManager.launchCommand = appState.terminalLaunchCommand
        blinkDetector.closedThreshold = appState.winkClosedThreshold
        blinkDetector.openThreshold = appState.winkOpenThreshold
        blinkDetector.minWinkDuration = appState.minWinkDuration
        blinkDetector.maxWinkDuration = appState.maxWinkDuration
        blinkDetector.bilateralRejectWindow = appState.bilateralRejectWindow
        blinkDetector.cooldown = appState.winkCooldown
        if !appState.blinkGesturesEnabled { blinkDetector.reset() }
        updateOverlayVisibility()
    }

    // MARK: - Start / Stop All

    func startAll() async {
        appState.statusMessage = "Starting..."

        let permissions = await Permissions.requestAllPermissions()
        if !permissions.camera {
            appState.addError("Camera permission denied — eye tracking unavailable.")
        }
        if !permissions.microphone {
            appState.addError("Microphone permission denied — voice input unavailable.")
        }
        if !Permissions.checkAccessibility() {
            appState.addError("Accessibility permission needed for terminal control.")
        }

        await setupTerminals()

        if permissions.camera {
            startEyeTracking()
        }

        if permissions.microphone {
            await startVoice()
        }

        updateStatus()
    }

    func stopAll() {
        stopEyeTracking()
        stopVoice()
        dwellTimer.reset()
        appState.focusedQuadrant = nil
        appState.activeQuadrant = nil
        dismissEyeTermOverlay()
        updateStatus()
    }

    // MARK: - Terminals

    func setupTerminals() async {
        do {
            switch appState.terminalSetupMode {
            case .launchNew:
                try await terminalManager.setupTerminals()
            case .adoptExisting:
                try await terminalManager.adoptTerminals()
            }
            appState.isTerminalSetup = true
            appState.statusMessage = "Terminals ready"
        } catch {
            appState.addError("Terminal setup failed: \(error.localizedDescription)")
        }
        updateStatus()
    }

    // MARK: - Eye Tracking

    func startEyeTracking() {
        // For MediaPipe, ensure venv python is wired in if setup already ran.
        if activeBackend is MediaPipeBackend {
            applyMediaPipePython()
        }
        do {
            try activeBackend.start()
            appState.isEyeTrackingActive = true
        } catch {
            appState.addError("Eye tracking failed: \(error.localizedDescription)")
        }
        updateStatus()

        // Refresh camera preview if it was opened before tracking started,
        // so it picks up the now-active capture session.
        if appState.isCameraPreviewVisible {
            dismissCameraPreview()
            showCameraPreview()
        }
    }

    func stopEyeTracking() {
        activeBackend.stop()
        dwellTimer.reset()
        appState.isEyeTrackingActive = false
        appState.activeQuadrant = nil
        dismissEyeTermOverlay()
        dismissCameraPreview()
        updateStatus()
    }

    // MARK: - Voice

    func startVoice() async {
        activeVoiceBackend.modelName = appState.whisperModel
        activeVoiceBackend.inputDeviceUID = appState.selectedMicDeviceUID.isEmpty ? nil : appState.selectedMicDeviceUID
        commandParser.enableNormalization = appState.enableTextNormalization
        commandParser.executeKeyword = appState.executeKeyword
        refreshMicList()
        do {
            try await activeVoiceBackend.start()
            await MainActor.run {
                appState.isVoiceActive = true
                showWaveformPanel()
                updateStatus()
            }
        } catch {
            await MainActor.run {
                appState.addError("Voice engine failed: \(error.localizedDescription)")
                updateStatus()
            }
        }
    }

    func stopVoice() {
        activeVoiceBackend.stop()
        appState.isVoiceActive = false
        dismissWaveformPanel()
        updateStatus()
    }

    // MARK: - Post-Onboarding Start

    func startAfterOnboarding() async {
        appState.statusMessage = "Starting..."

        let cameraGranted = Permissions.checkCamera() == .granted
        let micGranted = Permissions.checkMicrophone() == .granted

        if !cameraGranted {
            appState.addError("Camera permission not granted — eye tracking unavailable.")
        }
        if !micGranted {
            appState.addError("Microphone permission not granted — voice input unavailable.")
        }
        if !Permissions.checkAccessibility() {
            appState.addError("Accessibility permission needed for terminal control.")
        }

        await setupTerminals()

        if cameraGranted {
            startEyeTracking()

            if !calibrationManager.isCalibrated {
                startCalibration()
            }
        }

        if micGranted {
            await startVoice()
        }

        updateStatus()
    }

    // MARK: - Manual Focus

    func manualFocus(quadrant: ScreenQuadrant) {
        appState.focusedQuadrant = quadrant
        print("[AppCoordinator] Manual focus set to \(quadrant.displayName)")
        guard terminalManager.isSetup else {
            print("[AppCoordinator] Terminals not set up — focus set but can't activate window")
            return
        }
        Task {
            do {
                try await terminalManager.focusTerminal(quadrant: quadrant)
            } catch {
                appState.addError("Focus failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Test Send

    func testSendText() {
        guard let quadrant = appState.focusedQuadrant else {
            appState.addError("No quadrant focused — select one first")
            return
        }
        guard terminalManager.isSetup else {
            appState.addError("Terminals not set up")
            return
        }
        let testText = "echo hello from eyeTerm"
        print("[AppCoordinator] Test send: \"\(testText)\" to \(quadrant.displayName)")
        Task {
            do {
                try await terminalManager.typeText(testText, in: quadrant)
                try await terminalManager.sendReturn(in: quadrant)
            } catch {
                appState.addError("Test send failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Backend Switching

    func switchBackend(to backend: TrackingBackend) {
        let wasRunning = activeBackend.isRunning
        if wasRunning { stopEyeTracking() }

        appState.trackingBackend = backend
        activeBackend = backend == .mediaPipe
            ? MediaPipeBackend() as EyeTrackingBackend
            : EyeTermTracker() as EyeTrackingBackend
        wireCallbacks()
        pushAllSettings()

        if wasRunning { startEyeTracking() }

        // Refresh camera preview if it's open so it uses the new backend's session.
        if appState.isCameraPreviewVisible {
            dismissCameraPreview()
            showCameraPreview()
        }
    }

    // MARK: - Voice Backend Switching

    func switchVoiceBackend(to backend: VoiceBackend) {
        let wasRunning = activeVoiceBackend.isRunning
        if wasRunning { stopVoice() }
        transcriptionDiffer.reset()

        appState.voiceBackend = backend
        activeVoiceBackend = backend == .whisperCpp
            ? WhisperCppBackend() as VoiceTranscriptionBackend
            : WhisperKitBackend() as VoiceTranscriptionBackend
        wireCallbacks()
        pushAllSettings()

        if wasRunning { Task { await startVoice() } }
    }

    // MARK: - Calibration

    func startCalibration() {
        if !appState.isEyeTrackingActive {
            startEyeTracking()
        }
        activeBackend.headCalibrationTransform = nil
        activeBackend.pupilCalibrationTransform = nil
        calibrationManager.startCalibration()
        showCalibrationOverlay()
    }

    // MARK: - Window Level

    private func setupWindowLevelObservers() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  NSApp.windows.contains(window),
                  window !== self.eyeTermOverlayWindow else { return }
            window.level = .floating
        }

        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  NSApp.windows.contains(window),
                  window !== self.eyeTermOverlayWindow else { return }
            window.level = .normal
        }
    }

    // MARK: - Overlay Mode

    func cycleOverlayMode() {
        appState.overlayMode = appState.overlayMode.next
    }

    private func updateOverlayVisibility() {
        if appState.overlayMode == .off {
            eyeTermOverlayWindow?.orderOut(nil)
        } else {
            showEyeTermOverlay()
        }
    }

    // MARK: - eyeTerm Overlay

    private func showEyeTermOverlay() {
        if let panel = eyeTermOverlayWindow {
            panel.orderFrontRegardless()
            return
        }
        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        let overlayView = EyeTermOverlayView()
            .environment(appState)
        panel.contentView = NSHostingView(rootView: overlayView)
        panel.orderFrontRegardless()
        eyeTermOverlayWindow = panel
    }

    private func dismissEyeTermOverlay() {
        eyeTermOverlayWindow?.close()
        eyeTermOverlayWindow = nil
    }

    // MARK: - Camera Preview

    func showCameraPreview() {
        guard cameraPreviewWindow == nil else { return }

        let preview = CameraPreviewView(captureSession: activeBackend.activeCaptureSession)
            .environment(appState)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hasShadow = true
        panel.title = "eyeTerm — Camera Preview"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.delegate = CameraPreviewWindowDelegate { [weak self] in
            self?.cameraPreviewWindow = nil
            self?.appState.isCameraPreviewVisible = false
        }

        panel.contentView = NSHostingView(rootView: preview)
        panel.makeKeyAndOrderFront(nil)
        cameraPreviewWindow = panel
        appState.isCameraPreviewVisible = true
    }

    func dismissCameraPreview() {
        cameraPreviewWindow?.close()
        cameraPreviewWindow = nil
        appState.isCameraPreviewVisible = false
    }

    // MARK: - Waveform Panel

    private func showWaveformPanel() {
        guard waveformWindow == nil else { return }

        let waveformView = AudioWaveformView()
            .environment(appState)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 133, height: 36),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true

        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - 66.5
            let y = screenFrame.minY + 12
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.contentView = NSHostingView(rootView: waveformView)
        panel.orderFrontRegardless()
        waveformWindow = panel
    }

    private func dismissWaveformPanel() {
        waveformWindow?.close()
        waveformWindow = nil
    }

    // MARK: - Error Details

    func showErrorDetails() {
        guard errorDetailsWindow == nil else {
            errorDetailsWindow?.makeKeyAndOrderFront(nil)
            return
        }

        let detailView = ErrorDetailView()
            .environment(appState)

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hasShadow = true
        panel.title = "eyeTerm — Errors"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.delegate = ErrorDetailsWindowDelegate { [weak self] in
            self?.errorDetailsWindow = nil
        }

        panel.contentView = NSHostingView(rootView: detailView)
        panel.makeKeyAndOrderFront(nil)
        errorDetailsWindow = panel
    }

    func dismissErrorDetails() {
        errorDetailsWindow?.close()
        errorDetailsWindow = nil
    }

    // MARK: - Microphone Enumeration

    func refreshMicList() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceIDs) == noErr else { return }

        var mics: [(uid: String, name: String)] = []
        for deviceID in deviceIDs {
            // Check if this device has input streams
            var inputAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &inputAddress, 0, nil, &streamSize) == noErr,
                  streamSize > 0 else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uid) == noErr else { continue }

            // Get name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name) == noErr else { continue }

            mics.append((uid: uid as String, name: name as String))
        }

        appState.availableMics = mics
    }

    private func registerDeviceChangeListener() {
        guard !deviceChangeListenerRegistered else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshMicList()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main,
            block
        )
        if status == noErr {
            deviceChangeListenerBlock = block
            deviceChangeListenerRegistered = true
        }
    }

    // MARK: - Status

    private func updateStatus() {
        if appState.isEyeTrackingActive && appState.isVoiceActive && appState.isTerminalSetup {
            appState.statusMessage = "All systems active"
        } else if appState.isEyeTrackingActive || appState.isVoiceActive || appState.isTerminalSetup {
            var parts: [String] = []
            if appState.isTerminalSetup { parts.append("Terminals") }
            if appState.isEyeTrackingActive { parts.append("Eye Tracking") }
            if appState.isVoiceActive { parts.append("Voice") }
            appState.statusMessage = parts.joined(separator: " + ") + " active"
        } else {
            appState.statusMessage = "Idle"
        }
    }

    // MARK: - Calibration Overlay

    private func showCalibrationOverlay() {
        guard let screen = NSScreen.main else { return }

        let panel = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let overlayView = CalibrationOverlayView(
            calibrationManager: calibrationManager,
            onDismiss: { [weak self] in
                self?.dismissCalibrationOverlay()
            }
        )
        panel.contentView = NSHostingView(rootView: overlayView)
        panel.makeKeyAndOrderFront(nil)
        calibrationOverlayWindow = panel
    }

    private func dismissCalibrationOverlay() {
        calibrationOverlayWindow?.close()
        calibrationOverlayWindow = nil
    }

    // MARK: - Onboarding

    func showOnboardingWalkthrough() {
        guard onboardingWindow == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hasShadow = true
        panel.title = "Welcome to eyeTerm"
        panel.isReleasedWhenClosed = false
        panel.center()
        panel.delegate = OnboardingWindowDelegate { [weak self] in
            self?.onboardingWindow = nil
        }

        let walkthroughView = WalkthroughView(
            onGetStarted: { [weak self] in
                OnboardingState.markComplete()
                self?.dismissOnboarding()
            },
            onExploreSettings: { [weak self] in
                OnboardingState.markComplete()
                self?.dismissOnboarding()
                DispatchQueue.main.async {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                }
            }
        )
        panel.contentView = NSHostingView(rootView: walkthroughView)

        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = panel
    }

    func dismissOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    // MARK: - MediaPipe Setup

    func startMediaPipeWithSetup() {
        guard !mediaPipeSetupManager.isReady else {
            applyMediaPipePython()
            startEyeTracking()
            return
        }
        showMediaPipeSetupWindow()
        mediaPipeSetupManager.checkOrInstall()
    }

    private func applyMediaPipePython() {
        if let mpBackend = activeBackend as? MediaPipeBackend,
           let path = mediaPipeSetupManager.pythonExecutablePath {
            mpBackend.pythonExecutable = path
        }
    }

    func showMediaPipeSetupWindow() {
        guard mediaPipeSetupWindow == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
            styleMask: [.nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.hasShadow = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.center()

        let view = MediaPipeSetupView(
            manager: mediaPipeSetupManager,
            onDismiss: { [weak self] in
                self?.applyMediaPipePython()
                self?.dismissMediaPipeSetup()
                self?.startEyeTracking()
            },
            onUseAppleVision: { [weak self] in
                self?.dismissMediaPipeSetup()
                self?.switchBackend(to: .appleVision)
            }
        )
        panel.contentView = NSHostingView(rootView: view)
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        mediaPipeSetupWindow = panel
    }

    func dismissMediaPipeSetup() {
        mediaPipeSetupWindow?.close()
        mediaPipeSetupWindow = nil
    }

    deinit {
        if deviceChangeListenerRegistered, let block = deviceChangeListenerBlock {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                DispatchQueue.main,
                block
            )
        }
    }
}

private final class CameraPreviewWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private final class ErrorDetailsWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}

private final class OnboardingWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
