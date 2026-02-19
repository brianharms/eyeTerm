import Foundation
import AppKit
import SwiftUI
import Observation

@Observable
final class AppCoordinator {
    let appState: AppState

    let terminalManager = TerminalManager()
    private(set) var activeBackend: EyeTrackingBackend
    let calibrationManager = CalibrationManager()
    private(set) var activeVoiceBackend: VoiceTranscriptionBackend
    let commandParser = CommandParser()
    let dwellTimer: DwellTimer

    private var calibrationOverlayWindow: NSWindow?
    private var eyeTermOverlayWindow: NSPanel?
    private var onboardingWindow: NSPanel?
    private var cameraPreviewWindow: NSPanel?
    private var errorDetailsWindow: NSPanel?
    private var waveformWindow: NSPanel?

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
        pushAllSettings()
        observeSettings()

        if !OnboardingState.hasCompleted {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingWalkthrough()
            }
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        activeBackend.onGazeUpdate = { [weak self] quadrant, confidence in
            guard let self else { return }
            if quadrant != self.appState.activeQuadrant {
                self.appState.dwellingQuadrant = nil
                self.appState.dwellProgress = 0
            }
            self.appState.activeQuadrant = quadrant
            self.appState.gazeConfidence = confidence
            self.dwellTimer.update(quadrant: quadrant)
        }

        dwellTimer.onDwellProgress = { [weak self] quadrant, progress in
            guard let self else { return }
            self.appState.dwellingQuadrant = quadrant
            self.appState.dwellProgress = progress
        }

        dwellTimer.onDwellConfirmed = { [weak self] quadrant in
            guard let self else { return }
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
            if self.appState.audioLevelHistory.count > 21 {
                self.appState.audioLevelHistory.removeFirst()
            }
        }

        activeVoiceBackend.onModelState = { [weak self] state in
            guard let self else { return }
            self.appState.voiceModelState = state
        }

        activeVoiceBackend.onTranscription = { [weak self] text in
            guard let self else { return }
            self.appState.lastTranscription = text
            self.appState.transcriptionHistory.append((text: text, timestamp: Date()))
            let cutoff = Date().addingTimeInterval(-10)
            self.appState.transcriptionHistory.removeAll { $0.timestamp < cutoff }
            let commands = self.commandParser.parse(text)
            print("[AppCoordinator] Parsed \(commands.count) commands from: \"\(text)\"")

            guard let quadrant = self.appState.focusedQuadrant else {
                print("[AppCoordinator] No focused quadrant — transcription ignored. Use manual focus or eye tracking.")
                return
            }
            guard self.terminalManager.isSetup else { return }

            print("[AppCoordinator] Sending to \(quadrant.displayName)")
            Task {
                for command in commands {
                    do {
                        switch command {
                        case .typeText(let str):
                            print("[AppCoordinator] Typing: \"\(str)\"")
                            try await self.terminalManager.typeText(str, in: quadrant)
                        case .execute:
                            print("[AppCoordinator] Sending Return")
                            try await self.terminalManager.sendReturn(in: quadrant)
                        }
                    } catch {
                        print("[AppCoordinator] Command failed: \(error)")
                        self.appState.addError("Command failed: \(error.localizedDescription)")
                    }
                }
            }
        }

        calibrationManager.onCalibrationComplete = { [weak self] result in
            guard let self else { return }
            self.activeBackend.headCalibrationTransform = result.headTransform
            self.activeBackend.pupilCalibrationTransform = result.pupilTransform
            self.appState.isCalibrated = true
            self.dismissCalibrationOverlay()
        }

        calibrationManager.onNextTarget = { [weak self] _ in
            guard let self else { return }
            self.appState.calibrationSamples = self.calibrationManager.currentTargetIndex
        }

        activeBackend.onRawGazePoint = { [weak self] point in
            guard let self else { return }
            self.appState.rawGazePoint = self.debugRawFusedFilter.update(point)
        }

        activeBackend.onCalibratedGazePoint = { [weak self] point in
            guard let self else { return }
            self.appState.calibratedGazePoint = self.debugCalFusedFilter.update(point)
        }

        activeBackend.onSmoothedGazePoint = { [weak self] point in
            guard let self else { return }
            self.appState.smoothedGazePoint = point
        }

        activeBackend.onDiagnostics = { [weak self] diagnostics in
            guard let self else { return }
            self.appState.headYaw = diagnostics.headYaw
            self.appState.headPitch = diagnostics.headPitch
            self.appState.pupilOffsetX = diagnostics.pupilOffsetX
            self.appState.pupilOffsetY = diagnostics.pupilOffsetY
            self.appState.headGazePoint = self.debugHeadFilter.update(diagnostics.headGazePoint)
            self.appState.pupilGazePoint = self.debugPupilFilter.update(diagnostics.pupilGazePoint)
            self.appState.calibratedHeadGazePoint = self.debugCalHeadFilter.update(diagnostics.calibratedHeadGazePoint)
            self.appState.calibratedPupilGazePoint = self.debugCalPupilFilter.update(diagnostics.calibratedPupilGazePoint)
            self.calibrationManager.recordSample(
                headPoint: diagnostics.headGazePoint,
                pupilPoint: diagnostics.pupilGazePoint
            )
        }

        activeBackend.onFaceObservation = { [weak self] faceData in
            guard let self else { return }
            self.appState.faceObservationData = faceData
        }

        if let mpBackend = activeBackend as? MediaPipeBackend {
            mpBackend.onError = { [weak self] error in
                self?.appState.addError("MediaPipe: \(error)")
            }
        }
    }

    // MARK: - Reactive Settings

    private func observeSettings() {
        withObservationTracking {
            _ = appState.dwellTimeThreshold
            _ = appState.hysteresisDelay
            _ = appState.enableTextNormalization
            _ = appState.gazeSmoothing
            _ = appState.headWeight
            _ = appState.executeKeyword
            _ = appState.overlayMode
            _ = appState.debugSmoothing
            _ = appState.micSensitivity
            _ = appState.voiceBackend
            _ = appState.overlayIconSize
            _ = appState.fusionDotSize
            _ = appState.preferredTerminal
            _ = appState.terminalLaunchCommand
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
        activeBackend.smoothingAlpha = appState.gazeSmoothing
        activeBackend.headWeight = appState.headWeight
        activeVoiceBackend.silenceThreshold = Float(appState.micSensitivity)
        let da = appState.debugSmoothing
        debugHeadFilter.alpha = da
        debugPupilFilter.alpha = da
        debugCalHeadFilter.alpha = da
        debugCalPupilFilter.alpha = da
        debugRawFusedFilter.alpha = da
        debugCalFusedFilter.alpha = da
        terminalManager.preferredTerminal = appState.preferredTerminal
        terminalManager.launchCommand = appState.terminalLaunchCommand
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
            try await terminalManager.setupTerminals()
            appState.isTerminalSetup = true
            appState.statusMessage = "Terminals ready"
        } catch {
            appState.addError("Terminal setup failed: \(error.localizedDescription)")
        }
        updateStatus()
    }

    // MARK: - Eye Tracking

    func startEyeTracking() {
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
        updateStatus()
    }

    // MARK: - Voice

    func startVoice() async {
        activeVoiceBackend.modelName = appState.whisperModel
        commandParser.enableNormalization = appState.enableTextNormalization
        commandParser.executeKeyword = appState.executeKeyword
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

    // MARK: - Overlay Mode

    func cycleOverlayMode() {
        appState.overlayMode = appState.overlayMode.next
    }

    private func updateOverlayVisibility() {
        if appState.overlayMode == .off {
            dismissEyeTermOverlay()
        } else {
            showEyeTermOverlay()
        }
    }

    // MARK: - eyeTerm Overlay

    private func showEyeTermOverlay() {
        guard eyeTermOverlayWindow == nil else { return }
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
                Task { [weak self] in
                    await self?.startAfterOnboarding()
                }
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
