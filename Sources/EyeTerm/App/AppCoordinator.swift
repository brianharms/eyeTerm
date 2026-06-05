import Foundation
import AppKit
import SwiftUI
import Observation
import CoreAudio
import AVFoundation

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
    private var partialDebounceWork: DispatchWorkItem?
    private var partialTerminalTask: Task<Void, Never>?
    private var partialClearTask: Task<Void, Never>?
    private var windowObserver: NSKeyValueObservation?
    private var previousCameraID: String = ""
    private var trackingCameraRestartCount = 0
    private var notificationObservers: [Any] = []

    let mediaPipeSetupManager = MediaPipeSetupManager()
    private var mediaPipeSetupWindow: NSPanel?
    private var permissionsWindow: NSPanel?

    private var winkCalibManager: WinkCalibrationManager?
    private var winkCalibWindow: NSPanel?

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
        self.activeVoiceBackend = appState.voiceBackend == .sfSpeech
            ? SFSpeechRecognizerBackend() as VoiceTranscriptionBackend
            : WhisperKitBackend() as VoiceTranscriptionBackend
        self.dwellTimer = DwellTimer(
            dwellThreshold: appState.dwellTimeThreshold,
            hysteresisDelay: appState.hysteresisDelay
        )
        wireCallbacks()
        wireBlinkDetector()
        appState.refreshAvailableCameras()
        previousCameraID = appState.selectedCameraDeviceID
        appState.refreshAvailableDisplays()
        pushAllSettings()
        observeSettings()
        refreshMicList()
        registerDeviceChangeListener()
        registerScreenChangeListener()
        DispatchQueue.main.async { [weak self] in
            self?.setupWindowLevelObservers()
        }

        if !OnboardingState.hasCompleted {
            DispatchQueue.main.async { [weak self] in
                self?.showOnboardingWalkthrough()
            }
        }
    }

    // MARK: - Wiring

    private func wireCallbacks() {
        activeBackend.onEyeUpdate = { [weak self] point, confidence in
            guard let self else { return }
            let slot = point.flatMap { pt in
                self.appState.terminalSlots.first { $0.normalizedRect.contains(pt) }?.id
            }
            if slot != self.appState.activeSlot {
                self.appState.dwellingSlot = nil
                self.appState.dwellProgress = 0
            }
            self.appState.activeSlot = slot
            self.appState.eyeConfidence = confidence
            self.dwellTimer.update(slot: slot)
        }

        dwellTimer.onDwellProgress = { [weak self] slot, progress in
            guard let self else { return }
            self.appState.dwellingSlot = slot
            self.appState.dwellProgress = progress
        }

        dwellTimer.onDwellConfirmed = { [weak self] slot in
            guard let self else { return }
            if let previousSlot = self.appState.focusedSlot {
                self.appState.setPartial(nil, forSlot: previousSlot)
            }
            self.partialTerminalTask?.cancel()
            self.partialTerminalTask = nil
            self.activeVoiceBackend.flushAudio()
            self.transcriptionDiffer.reset()
            self.appState.focusedSlot = slot
            guard self.appState.isTerminalSetup else { return }
            guard !self.appState.gazeActivationLocked else { return }
            guard !self.isEyeTermWindowKey() else { return }
            Task {
                do {
                    try await self.terminalManager.focusTerminal(slotIndex: slot)
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

        if let sfBackend = activeVoiceBackend as? SFSpeechRecognizerBackend {
            sfBackend.onDiagnostic = { [weak self] msg in
                self?.appState.addDiagnostic(msg)
            }
        }

        activeVoiceBackend.onPartialTranscription = { [weak self] text in
            guard let self else { return }
            let normalized = self.commandParser.normalizeOnly(text)
            self.partialDebounceWork?.cancel()

            // Always update diagnostics slot so Settings panel shows partial text
            // regardless of whether a terminal is focused.
            let diagSlot = self.appState.focusedSlot ?? -1
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.appState.setPartial(normalized, forSlot: diagSlot)
            }
            self.partialDebounceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)

        }

        activeVoiceBackend.onTranscription = { [weak self] text in
            guard let self else { return }
            self.appState.addDiagnostic("heard: \"\(text)\" | focused=\(self.appState.focusedSlot.map{String($0)} ?? "nil") active=\(self.appState.activeSlot.map{String($0)} ?? "nil") setup=\(self.terminalManager.isSetup) eyeTermKey=\(self.isEyeTermWindowKey()) winActions=\(self.appState.windowActionsEnabled)")
            self.partialDebounceWork?.cancel()
            self.partialDebounceWork = nil
            self.partialTerminalTask?.cancel()
            self.partialTerminalTask = nil
            self.appState.lastTranscription = text

            // Schedule auto-dismiss of overlay bubble after 4 seconds
            self.partialClearTask?.cancel()
            self.partialClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                await MainActor.run { self?.appState.clearAllPartials() }
            }

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
                        if let slot = self.appState.focusedSlot {
                            self.appState.setPartial(nil, forSlot: slot)
                        }
                        if let slotIndex = self.appState.focusedSlot, self.terminalManager.isSetup {
                            try? await self.terminalManager.focusTerminal(slotIndex: slotIndex)
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

        calibrationManager.onNextTarget = { _ in }

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
            if let calib = self.winkCalibManager {
                calib.update(
                    leftAperture: faceData?.leftEyeAperture ?? 0,
                    rightAperture: faceData?.rightEyeAperture ?? 0
                )
            }
        }

        if let mpBackend = activeBackend as? MediaPipeBackend {
            mpBackend.onError = { [weak self] error in
                self?.appState.addError("MediaPipe: \(error)")
            }
            mpBackend.onStarted = { [weak self] idx, name, uid in
                guard let self else { return }
                let label = name.isEmpty ? "camera \(idx)" : "\(name) (index \(idx))"
                self.appState.actualTrackingCameraInfo = label
                self.appState.actualTrackingCameraName = name

                // The user's intended camera is the ground truth — not what Python opened.
                // Resolve it by name from selectedCameraDeviceID so the preview is always
                // anchored to the user's explicit choice rather than Python's index guess.
                let intendedName: String
                if !self.appState.selectedCameraDeviceID.isEmpty,
                   let device = Self.resolveCamera(uniqueID: self.appState.selectedCameraDeviceID) {
                    intendedName = device.localizedName
                } else {
                    intendedName = name  // No specific camera selected — accept what Python opened.
                }

                let feedName = (mpBackend.activeCaptureSession?.inputs.first as? AVCaptureDeviceInput)?.device.localizedName ?? "none"
                NSLog("[eyeTerm camSync] onStarted — python='\(name)' idx=\(idx) intended='\(intendedName)' feedBefore='\(feedName)' selectedUID='\(self.appState.selectedCameraDeviceID)'")

                // Always sync the preview to the INTENDED camera.
                let syncName = intendedName.isEmpty ? name : intendedName
                if !syncName.isEmpty {
                    mpBackend.syncPreviewByName(syncName) { [weak self] in
                        guard let self else { return }
                        self.appState.currentPreviewSession = mpBackend.activeCaptureSession
                        let feedAfter = (mpBackend.activeCaptureSession?.inputs.first as? AVCaptureDeviceInput)?.device.localizedName ?? "none"
                        NSLog("[eyeTerm camSync] afterSync — feed='\(feedAfter)' tracking='\(name)' intended='\(syncName)' match=\(feedAfter == syncName || feedAfter.localizedCaseInsensitiveContains(syncName) || syncName.localizedCaseInsensitiveContains(feedAfter))")
                    }
                } else {
                    self.appState.currentPreviewSession = mpBackend.activeCaptureSession
                }

                // If Python opened the wrong camera, restart once so tracking catches up.
                // A guard counter prevents infinite loops when Python can't resolve the camera.
                if !intendedName.isEmpty && !name.isEmpty {
                    let nameMatches = name == intendedName
                        || name.localizedCaseInsensitiveContains(intendedName)
                        || intendedName.localizedCaseInsensitiveContains(name)
                    if !nameMatches {
                        if self.trackingCameraRestartCount < 2 {
                            self.trackingCameraRestartCount += 1
                            NSLog("[eyeTerm camSync] MISMATCH — restarting tracking (attempt \(self.trackingCameraRestartCount)/2). python='\(name)' intended='\(intendedName)'")
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                                self?.restartEyeTracking()
                            }
                        } else {
                            NSLog("[eyeTerm camSync] MISMATCH — gave up after 2 restarts. python='\(name)' intended='\(intendedName)'")
                            // Gave up — reset for next intentional camera switch.
                            self.trackingCameraRestartCount = 0
                        }
                    } else {
                        self.trackingCameraRestartCount = 0
                    }
                }
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

        if commands.isEmpty {
            appState.addError("Voice: heard \"\(text)\" but nothing to send (all text was filtered)")
            transcriptionDiffer.reset()
            return
        }

        guard let slotIndex = appState.focusedSlot ?? appState.activeSlot else {
            appState.addError("Voice: heard \"\(text)\" but no terminal is focused — look at a quadrant first")
            transcriptionDiffer.reset()
            return
        }
        guard terminalManager.isSetup else {
            appState.addError("Voice: heard text but terminals are not set up yet")
            transcriptionDiffer.reset()
            return
        }

        appState.addDiagnostic("sending: \"\(cleaned)\" → slot \(slotIndex)")
        Task {
            for command in commands {
                do {
                    switch command {
                    case .typeText(let str):
                        try await self.terminalManager.typeText(str, in: slotIndex)
                    case .execute:
                        print("[AppCoordinator] Sending Return")
                        self.transcriptionDiffer.reset()
                        self.partialClearTask?.cancel()
                        self.partialClearTask = nil
                        self.appState.setPartial(nil, forSlot: slotIndex)
                        if self.appState.showCommandFlash {
                            self.appState.lastCommandFlash = "EXECUTE ↵"
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                                self?.appState.lastCommandFlash = nil
                            }
                        }
                        try await self.terminalManager.sendReturn(in: slotIndex)
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
            if let slot = self.appState.focusedSlot {
                self.appState.setPartial(nil, forSlot: slot)
            }
            if self.appState.showWinkOverlay {
                self.appState.lastWinkDisplay = "(left wink) \(action.shortLabel)"
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
            if let slot = self.appState.focusedSlot {
                self.appState.setPartial(nil, forSlot: slot)
            }
            if self.appState.showWinkOverlay {
                self.appState.lastWinkDisplay = "(right wink) \(action.shortLabel)"
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
        guard let slotIndex = appState.focusedSlot, terminalManager.isSetup else { return }
        Task {
            do {
                switch action {
                case .doubleEscape:
                    try await terminalManager.sendDoubleEscape(in: slotIndex)
                case .singleEscape:
                    try await terminalManager.sendEscape(in: slotIndex)
                case .enter:
                    try await terminalManager.sendReturn(in: slotIndex)
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
            _ = appState.winkDipThreshold
            _ = appState.windowActionsEnabled
            _ = appState.terminalSetupMode
            _ = appState.selectedCameraDeviceID
            _ = appState.selectedDisplayID
            _ = appState.keepOverlayOnTop
            _ = appState.isVoiceEnabled
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                self?.pushAllSettings()
                self?.observeSettings()
            }
        }
    }

    private func pushAllSettings() {
        let currentCamID = appState.selectedCameraDeviceID
        if currentCamID != previousCameraID {
            // Camera changed: load saved wink profile for the new camera (if any)
            appState.applyWinkProfile(for: currentCamID)
            previousCameraID = currentCamID
        } else {
            // Same camera: capture current wink settings into this camera's profile
            appState.captureCurrentWinkProfile(for: currentCamID)
        }

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
        blinkDetector.winkDipThreshold = appState.winkDipThreshold
        blinkDetector.minWinkDuration = appState.minWinkDuration
        blinkDetector.maxWinkDuration = appState.maxWinkDuration
        blinkDetector.bilateralRejectWindow = appState.bilateralRejectWindow
        blinkDetector.cooldown = appState.winkCooldown
        if !appState.blinkGesturesEnabled { blinkDetector.reset() }
        // Push camera selection to whichever backend is active (not in protocol — cast required).
        // For EyeTermTracker we resolve the actual AVCaptureDevice via DiscoverySession — same
        // mechanism the camera picker uses — and hand the object directly to the tracker so it
        // never has to do a uniqueID lookup that can silently return nil and fall back to the
        // system default (which may be the Logitech or any other external camera).
        let newCamID = appState.selectedCameraDeviceID
        var cameraChanged = false
        if let tracker = activeBackend as? EyeTermTracker {
            let resolvedDevice = Self.resolveCamera(uniqueID: newCamID)
            let currentID = tracker.selectedCaptureDevice?.uniqueID ?? ""
            let incomingID = resolvedDevice?.uniqueID ?? newCamID
            if currentID != incomingID {
                tracker.selectedCaptureDevice = resolvedDevice
                cameraChanged = true
                if tracker.isRunning { restartEyeTracking() }
            }
        } else if let mp = activeBackend as? MediaPipeBackend {
            if mp.selectedCameraDeviceID != newCamID {
                mp.selectedCameraDeviceID = newCamID
                cameraChanged = true
                if mp.isRunning { restartEyeTracking() }
            }
        }
        if cameraChanged { appState.persistSettings() }
        refreshOverlayDisplay()
        updateOverlayVisibility()
        eyeTermOverlayWindow?.level = appState.keepOverlayOnTop ? .floating : .normal

        // Voice quick-toggle: start or stop voice when isVoiceEnabled changes.
        if !appState.isVoiceEnabled && activeVoiceBackend.isRunning {
            stopVoice()
        } else if appState.isVoiceEnabled && !activeVoiceBackend.isRunning && appState.isEyeTrackingActive && appState.isTerminalSetup {
            Task { await startVoice() }
        }

    }

    // MARK: - Start / Stop All

    @MainActor func startAll() async {
        appState.statusMessage = "Checking permissions..."

        // Trigger OS prompts for camera/mic/speech if not yet determined.
        // Accessibility and automation are NOT requested here — they open
        // System Preferences or target iTerm2, which can destabilize the
        // menu bar app. The permissions panel handles those individually.
        if Permissions.checkCamera() == .notDetermined { _ = await Permissions.requestCamera() }
        if Permissions.checkMicrophone() == .notDetermined { _ = await Permissions.requestMicrophone() }
        if Permissions.checkSpeechRecognition() == .notDetermined { _ = await Permissions.requestSpeechRecognition() }

        // Check all required permissions (read-only, no prompts)
        let camGranted  = Permissions.checkCamera() == .granted
        let micGranted  = Permissions.checkMicrophone() == .granted
        let accGranted  = Permissions.checkAccessibility()
        let autoGranted = Permissions.checkAutomation(bundleID: appState.preferredTerminal.bundleIdentifier) == .granted

        guard camGranted && micGranted && accGranted && autoGranted else {
            appState.statusMessage = "Permissions required"
            showPermissionsPanel(onAllGrantedDone: { [weak self] in
                Task { await self?.startAll() }
            })
            return
        }

        appState.statusMessage = "Starting..."

        await setupTerminals()

        if !appState.isEyeTrackingActive {
            print("[AppCoordinator] startAll: eye tracking not active, starting...")
            startEyeTracking()
        } else {
            print("[AppCoordinator] startAll: eye tracking already active, skipping")
        }

        print("[AppCoordinator] startAll: starting voice...")
        await startVoice()

        updateStatus()
    }

    func stopAll() {
        stopEyeTracking()
        stopVoice()
        dwellTimer.reset()
        appState.focusedSlot = nil
        appState.activeSlot = nil
        appState.isTerminalSetup = false
        dismissEyeTermOverlay()
        updateStatus()
    }

    // MARK: - Terminals

    func setupTerminals() async {
        // Always lock gaze focusing during terminal setup so dwell doesn't fire at iTerm2 windows
        // while they're being launched/positioned. Voice is only stopped if blockInteractionDuringSetup.
        appState.gazeActivationLocked = true
        let voiceWasRunning = activeVoiceBackend.isRunning
        if appState.blockInteractionDuringSetup && voiceWasRunning { stopVoice() }
        appState.statusMessage = "Eye focusing paused — launching terminals…"

        do {
            print("[AppCoordinator] setupTerminals: mode=\(appState.terminalSetupMode.rawValue)")
            switch appState.terminalSetupMode {
            case .launchNew:
                try await terminalManager.setupTerminals(cols: appState.terminalGridColumns, rows: appState.terminalGridRows, appState: appState, screen: selectedScreen())
            case .adoptExisting:
                try await terminalManager.adoptTerminals(appState: appState, screen: selectedScreen())
            case .chooseProjects:
                try await terminalManager.setupProjectTerminals(projectURLs: appState.selectedProjectFolders, initialPrompt: appState.claudeInitialPrompt, initialPromptStagger: appState.claudeInitialPromptStagger, renameToProjectName: appState.renameWindowsToProjectName, appState: appState, screen: selectedScreen())
            }
            print("[AppCoordinator] setupTerminals: success, slots=\(appState.terminalSlots.count)")
            appState.isTerminalSetup = true
        } catch {
            print("[AppCoordinator] setupTerminals: FAILED — \(error)")
            appState.addError("Terminal setup failed: \(error.localizedDescription)")
        }

        appState.gazeActivationLocked = false
        if appState.blockInteractionDuringSetup && voiceWasRunning { Task { await startVoice() } }
        // Ensure overlay is visible if the user enabled it before terminals were ready.
        updateOverlayVisibility()
        updateStatus()
    }

    // MARK: - Eye Tracking

    func startEyeTracking() {
        // Always push the current camera selection and Python path before starting —
        // observeSettings only fires on *changes*, so a first-start from cold state
        // (calibration, app launch before any settings interaction) would otherwise
        // use a stale/empty selectedCameraDeviceID and default to index 0 (Logitech).
        if let mp = activeBackend as? MediaPipeBackend {
            applyMediaPipePython()
            mp.selectedCameraDeviceID = appState.selectedCameraDeviceID
            print("[AppCoordinator] startEyeTracking: MediaPipe backend, camera=\(appState.selectedCameraDeviceID)")
        } else if let tracker = activeBackend as? EyeTermTracker {
            tracker.selectedCaptureDevice = Self.resolveCamera(uniqueID: appState.selectedCameraDeviceID)
            print("[AppCoordinator] startEyeTracking: AppleVision backend")
        }
        do {
            try activeBackend.start()
            appState.isEyeTrackingActive = true
            print("[AppCoordinator] startEyeTracking: SUCCESS, isRunning=\(activeBackend.isRunning)")
        } catch {
            appState.addError("Eye tracking failed: \(error.localizedDescription)")
            print("[AppCoordinator] startEyeTracking: FAILED — \(error)")
        }
        updateStatus()

        // Restore overlay if it was dismissed when tracking stopped.
        updateOverlayVisibility()

        // Push the new live capture session to the preview window (no window close needed).
        appState.currentPreviewSession = activeBackend.activeCaptureSession
    }

    func stopEyeTracking() {
        activeBackend.stop()
        dwellTimer.reset()
        appState.isEyeTrackingActive = false
        appState.activeSlot = nil
        appState.actualTrackingCameraInfo = ""
        appState.actualTrackingCameraName = ""
        appState.currentPreviewSession = nil
        dismissCameraPreview()
        dismissEyeTermOverlay()
        updateStatus()
    }

    // MARK: - Voice

    func startVoice() async {
        guard !activeVoiceBackend.isRunning else {
            print("[AppCoordinator] startVoice: already running, skipping")
            return
        }
        activeVoiceBackend.modelName = appState.whisperModel
        activeVoiceBackend.inputDeviceUID = appState.selectedMicDeviceUID.isEmpty ? nil : appState.selectedMicDeviceUID
        print("[AppCoordinator] startVoice: mic=\(appState.selectedMicDeviceUID.isEmpty ? "(system default)" : appState.selectedMicDeviceUID) backend=\(appState.voiceBackend.rawValue)")
        commandParser.enableNormalization = appState.enableTextNormalization
        commandParser.executeKeyword = appState.executeKeyword
        refreshMicList()
        do {
            try await activeVoiceBackend.start()
            await MainActor.run {
                appState.isVoiceActive = true
                appState.isVoiceEnabled = true
                appState.addDiagnostic("Voice started: backend=\(appState.voiceBackend.rawValue) mic=\(appState.selectedMicDeviceUID.isEmpty ? "default" : appState.selectedMicDeviceUID) eyeActive=\(appState.isEyeTrackingActive) termSetup=\(appState.isTerminalSetup)")
                showWaveformPanel()
                updateStatus()
            }
        } catch VoiceEngineError.speechRecognitionDenied {
            await MainActor.run {
                appState.addError("Speech Recognition permission denied.")
                updateStatus()
                let alert = NSAlert()
                alert.messageText = "Speech Recognition Permission Required"
                alert.informativeText = "eyeTerm needs Speech Recognition access to transcribe voice commands.\n\nOpen System Settings → Privacy & Security → Speech Recognition and enable eyeTerm."
                alert.addButton(withTitle: "Open Speech Recognition Settings")
                alert.addButton(withTitle: "Cancel")
                if alert.runModal() == .alertFirstButtonReturn {
                    Permissions.openSpeechRecognitionSettings()
                }
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
        appState.isVoiceEnabled = false
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

    func manualFocus(slotIndex: Int) {
        appState.focusedSlot = slotIndex
        print("[AppCoordinator] Manual focus set to slot \(slotIndex + 1)")
        guard terminalManager.isSetup else {
            print("[AppCoordinator] Terminals not set up — focus set but can't activate window")
            return
        }
        Task {
            do {
                try await terminalManager.focusTerminal(slotIndex: slotIndex)
            } catch {
                appState.addError("Focus failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Test Send

    func testSendText() {
        guard let slotIndex = appState.focusedSlot else {
            appState.addError("No slot focused — select one first")
            return
        }
        guard terminalManager.isSetup else {
            appState.addError("Terminals not set up")
            return
        }
        let testText = "echo hello from eyeTerm"
        print("[AppCoordinator] Test send: \"\(testText)\" to slot \(slotIndex + 1)")
        Task {
            do {
                try await terminalManager.typeText(testText, in: slotIndex)
                try await terminalManager.sendReturn(in: slotIndex)
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
        // Push the new backend's session to the preview window.
        appState.currentPreviewSession = activeBackend.activeCaptureSession
    }

    // MARK: - Voice Backend Switching

    func switchVoiceBackend(to backend: VoiceBackend) {
        let wasRunning = activeVoiceBackend.isRunning
        if wasRunning { stopVoice() }
        transcriptionDiffer.reset()

        appState.voiceBackend = backend
        activeVoiceBackend = backend == .sfSpeech
            ? SFSpeechRecognizerBackend() as VoiceTranscriptionBackend
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

    func cancelCalibration() {
        calibrationManager.reset()
        dismissCalibrationOverlay()
    }

    // MARK: - Window Level

    // Level above the overlay (.screenSaver = 1000) so Settings is always visible
    private static let settingsWindowLevel = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)

    func bringSettingsWindowToFront() {
        // KVO handles windows created for the first time (see setupWindowLevelObservers).
        // This covers re-raising an already-existing Settings window.
        for window in NSApp.windows {
            guard !(window is NSPanel), window !== eyeTermOverlayWindow else { continue }
            window.level = AppCoordinator.settingsWindowLevel
            window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func setupWindowLevelObservers() {
        // KVO fires synchronously when NSApp adds a new window — before it's shown.
        // This catches the SwiftUI Settings window at creation and sets its level immediately.
        windowObserver = NSApp.observe(\.windows, options: [.new, .old]) { [weak self] app, change in
            guard let self else { return }
            let oldSet = Set(change.oldValue ?? [])
            let newSet = Set(change.newValue ?? [])
            for window in newSet.subtracting(oldSet) {
                guard !(window is NSPanel), window !== self.eyeTermOverlayWindow else { continue }
                window.level = AppCoordinator.settingsWindowLevel
            }
        }

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  NSApp.windows.contains(window),
                  window !== self.eyeTermOverlayWindow else { return }
            if !(window is NSPanel) {
                window.level = AppCoordinator.settingsWindowLevel
                NSApp.activate(ignoringOtherApps: true)
            } else {
                window.level = .floating
            }
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  NSApp.windows.contains(window),
                  window !== self.eyeTermOverlayWindow else { return }
            // Settings window stays on top while open
            if !(window is NSPanel) {
                window.level = AppCoordinator.settingsWindowLevel
                return
            }
            // Camera preview always stays floating so it doesn't go behind terminal windows.
            if window === self.cameraPreviewWindow { return }
            window.level = .normal
        })

        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeMainNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let window = notification.object as? NSWindow,
                  NSApp.windows.contains(window),
                  window !== self.eyeTermOverlayWindow,
                  !(window is NSPanel) else { return }
            window.level = AppCoordinator.settingsWindowLevel
            NSApp.activate(ignoringOtherApps: true)
        })
    }

    // MARK: - Overlay Mode

    func cycleOverlayMode() {
        appState.overlayMode = appState.overlayMode.next
    }

    func syncOverlayVisibility() { updateOverlayVisibility() }

    /// Returns true if any eyeTerm-owned non-overlay, non-preview window is currently key.
    /// When true, gaze-based terminal focusing is suppressed so typing in Settings
    /// doesn't accidentally fire AppleScript focus calls.
    private func isEyeTermWindowKey() -> Bool {
        guard let keyWin = NSApp.keyWindow else { return false }
        // The full-screen overlay is not a "real" window — ignore it.
        if keyWin === eyeTermOverlayWindow { return false }
        // Camera preview is a monitoring window — don't suppress terminal focus.
        if keyWin === cameraPreviewWindow { return false }
        // Any other eyeTerm-owned window (Settings, onboarding, etc.)
        return NSApp.windows.contains(keyWin)
    }

    private func updateOverlayVisibility() {
        if appState.overlayMode == .off {
            let win = eyeTermOverlayWindow
            DispatchQueue.main.async { win?.orderOut(nil) }
        } else {
            showEyeTermOverlay()
        }
    }

    // MARK: - eyeTerm Overlay

    private func selectedScreen() -> NSScreen {
        let target = appState.selectedDisplayID
        return NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == target
        }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private func refreshOverlayDisplay() {
        guard let panel = eyeTermOverlayWindow else { return }
        let desired = selectedScreen()
        guard panel.screen != desired else { return }
        // Overlay is on the wrong screen — rebuild it on the correct one
        dismissEyeTermOverlay()
        if appState.overlayMode != .off {
            showEyeTermOverlay()
        }
    }

    func restartEyeTracking() {
        guard appState.isEyeTrackingActive else { return }
        if let mp = activeBackend as? MediaPipeBackend {
            // For MediaPipe, wait for the Python process to fully release the camera
            // before starting a new one — fixes camera switching getting stuck.
            dwellTimer.reset()
            appState.isEyeTrackingActive = false
            appState.activeSlot = nil
            appState.actualTrackingCameraInfo = ""
            appState.actualTrackingCameraName = ""
            appState.currentPreviewSession = nil
            dismissEyeTermOverlay()
            updateStatus()
            mp.stopAndWait { [weak self] in
                self?.startEyeTracking()
            }
        } else {
            stopEyeTracking()
            startEyeTracking()
        }
    }

    /// Select a specific camera for eye tracking and force-restart immediately.
    /// Unlike setting appState.selectedCameraDeviceID directly, this works even when the
    /// requested camera is already stored as selectedCameraDeviceID (avoids the withObservationTracking
    /// no-op when Python drifted to a different camera due to index ordering).
    func selectTrackingCamera(uniqueID: String) {
        // Reset restart guard so the new intentional selection gets a fresh self-correction budget.
        trackingCameraRestartCount = 0
        // Pre-sync the backend so pushAllSettings (triggered by appState change) won't double-restart.
        if let mp = activeBackend as? MediaPipeBackend {
            mp.selectedCameraDeviceID = uniqueID
        }
        appState.selectedCameraDeviceID = uniqueID
        if appState.isEyeTrackingActive {
            restartEyeTracking()
        }
    }

    /// Resolve an AVCaptureDevice from a uniqueID using DiscoverySession — the same
    /// mechanism AppState uses for the camera picker, which is more reliable than
    /// AVCaptureDevice(uniqueID:) which can silently return nil.
    /// Returns nil if uniqueID is empty or the device is not currently connected.
    static func resolveCamera(uniqueID: String) -> AVCaptureDevice? {
        guard !uniqueID.isEmpty else { return nil }
        let types: [AVCaptureDevice.DeviceType]
        if #available(macOS 14.0, *) {
            types = [.builtInWideAngleCamera, .external]
        } else {
            types = [.builtInWideAngleCamera, .continuityCamera]
        }
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        return session.devices.first { $0.uniqueID == uniqueID }
    }

    private func registerScreenChangeListener() {
        notificationObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.appState.refreshAvailableDisplays()
            self.refreshOverlayDisplay()
        })
    }

    private func showEyeTermOverlay() {
        // NSPanel/NSWindow operations must always run on the main thread.
        // This function can be called from non-isolated contexts (async tasks, observers).
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let panel = self.eyeTermOverlayWindow {
                panel.orderFrontRegardless()
                return
            }
            let screen = self.selectedScreen()

            let panel = NSPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.level = self.appState.keepOverlayOnTop ? .floating : .normal
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = true

            let overlayView = EyeTermOverlayView()
                .environment(self.appState)
            panel.contentView = NSHostingView(rootView: overlayView)
            panel.orderFrontRegardless()
            self.eyeTermOverlayWindow = panel
        }
    }

    private func dismissEyeTermOverlay() {
        DispatchQueue.main.async { [weak self] in
            self?.eyeTermOverlayWindow?.close()
            self?.eyeTermOverlayWindow = nil
        }
    }

    // MARK: - Camera Preview

    func showCameraPreview() {
        // Auto-start eye tracking so there's a live camera session to show.
        if !appState.isEyeTrackingActive {
            startEyeTracking()
        }
        // Ensure the session is current before the view renders.
        appState.currentPreviewSession = activeBackend.activeCaptureSession

        if let panel = cameraPreviewWindow {
            // Window already exists — just unhide it (keeps the live preview layer intact)
            panel.makeKeyAndOrderFront(nil)
            appState.isCameraPreviewVisible = true
            return
        }

        let preview = CameraPreviewView()
            .environment(appState)
            .environment(self)

        let panel = CameraPreviewPanel(
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
        panel.onEscape = { [weak self] in
            guard let self, self.calibrationOverlayWindow != nil else { return }
            self.cancelCalibration()
        }
        panel.delegate = CameraPreviewWindowDelegate { [weak self] in
            // User clicked the window's X button — fully discard it
            self?.cameraPreviewWindow = nil
            self?.appState.isCameraPreviewVisible = false
        }

        panel.contentView = NSHostingView(rootView: preview)
        panel.makeKeyAndOrderFront(nil)
        cameraPreviewWindow = panel
        appState.isCameraPreviewVisible = true
    }

    /// Switch the camera preview feed to a specific device without affecting the tracking backend.
    /// Session is updated in-place after startRunning() completes — preview window stays open.
    func switchPreviewCamera(uniqueID: String) {
        guard let mp = activeBackend as? MediaPipeBackend else { return }
        mp.switchPreviewToDevice(uniqueID: uniqueID) { [weak self] in
            self?.appState.currentPreviewSession = mp.activeCaptureSession
        }
    }

    /// Soft-hide: keeps the window alive so the preview layer stays connected.
    /// Use this for the Settings toggle button.
    func dismissCameraPreview() {
        cameraPreviewWindow?.orderOut(nil)
        appState.isCameraPreviewVisible = false
    }

    /// Hard-destroy: closes and nils the window. Use before session/backend changes.
    private func destroyCameraPreview() {
        DispatchQueue.main.async { [weak self] in
            self?.cameraPreviewWindow?.close()
            self?.cameraPreviewWindow = nil
            self?.appState.isCameraPreviewVisible = false
        }
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

        let screenFrame = selectedScreen().visibleFrame
        let x = screenFrame.midX - 66.5
        let y = screenFrame.minY + 12
        panel.setFrameOrigin(NSPoint(x: x, y: y))

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
        let screen = selectedScreen()

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
        // Explicitly enforce position on the target screen — makeKeyAndOrderFront can
        // cause macOS to reposition a panel onto the main display for a menu-bar app.
        panel.setFrame(screen.frame, display: true)
        calibrationOverlayWindow = panel
    }

    private func dismissCalibrationOverlay() {
        calibrationOverlayWindow?.close()
        calibrationOverlayWindow = nil
    }

    // MARK: - Wink Calibration

    func startWinkCalibration(eye: WinkCalibrationManager.Eye) {
        guard winkCalibWindow == nil else { return }

        // Ensure eye tracking is running so aperture data flows into the manager.
        if !appState.isEyeTrackingActive {
            startEyeTracking()
        }

        let manager = WinkCalibrationManager(eye: eye)
        manager.onComplete = { [weak self] thresholds in
            guard let self else { return }
            self.appState.winkClosedThreshold = thresholds.closedThreshold
            self.appState.winkOpenThreshold   = thresholds.openThreshold
            self.appState.winkDipThreshold    = thresholds.dipThreshold
            self.appState.minWinkDuration     = thresholds.minDuration
            self.appState.maxWinkDuration     = thresholds.maxDuration
            self.dismissWinkCalibration()
        }
        manager.onCancel = { [weak self] in
            self?.dismissWinkCalibration()
        }
        winkCalibManager = manager

        let screen = selectedScreen()
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

        let calibView = WinkCalibrationView(manager: manager)
        panel.contentView = NSHostingView(rootView: calibView)
        panel.makeKeyAndOrderFront(nil)
        panel.setFrame(screen.frame, display: true)
        winkCalibWindow = panel
    }

    private func dismissWinkCalibration() {
        winkCalibWindow?.close()
        winkCalibWindow = nil
        winkCalibManager = nil
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

    func showPermissionsPanel(onAllGrantedDone: (() -> Void)? = nil) {
        // If a gate-mode open is requested, always close existing and reopen
        // so the callback is wired correctly.
        if onAllGrantedDone != nil, permissionsWindow != nil {
            dismissPermissionsPanel()
        }
        if let existing = permissionsWindow {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        var view = PermissionsView { [weak self] in self?.dismissPermissionsPanel() }
        view.onAllGrantedDone = onAllGrantedDone
        let hosting = NSHostingView(rootView: view)
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 340),
            styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Permissions"
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.contentView = hosting
        panel.delegate = PermissionsWindowDelegate { [weak self] in
            self?.permissionsWindow = nil
        }
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        permissionsWindow = panel
    }

    func dismissPermissionsPanel() {
        permissionsWindow?.close()
        permissionsWindow = nil
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
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

/// NSPanel subclass that intercepts Escape — cancels calibration if active,
/// otherwise does nothing (Escape never closes the camera preview).
private final class CameraPreviewPanel: NSPanel {
    var onEscape: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
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

private final class PermissionsWindowDelegate: NSObject, NSWindowDelegate {
    let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
