import AVFoundation
import CoreAudio
import Speech
import AVFAudio

final class SFSpeechRecognizerBackend: VoiceTranscriptionBackend {

    // MARK: - Protocol

    var onTranscription: ((String) -> Void)?
    var onPartialTranscription: ((String) -> Void)?
    var onAudioLevel: ((Float, Bool) -> Void)?
    var onModelState: ((VoiceModelState) -> Void)?
    var modelName: String = "en-US"    // unused — locale hardcoded to en-US
    var silenceThreshold: Float = 0.01  // for audio level indicator only
    var inputDeviceUID: String?

    private(set) var isRunning = false

    // MARK: - Private

    private var audioEngine: AVAudioEngine?
    private var recognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var isStopping = false
    // Incremented on every flushAudio() call so stale task callbacks won't
    // spawn a new session, while still allowing isFinal delivery.
    private var currentSessionID: Int = 0

    // Silence-based VAD: forces endAudio() after sustained post-speech silence
    // so isFinal fires even when the user stays on the same slot indefinitely.
    private var speechDetected = false
    private var silenceTimer: DispatchSourceTimer?
    private let silenceDuration: TimeInterval = 1.0  // seconds of silence before finalizing

    /// Tracks the last partial transcription text per session so we can deliver it
    /// as a final transcription if the recognition task is cancelled before isFinal fires
    /// (e.g. when a new recognition task implicitly cancels the old one).
    private var lastPartialText: String = ""

    /// Safety timer: if endAudio() is called but neither isFinal nor error fires
    /// within this timeout, deliver lastPartialText and restart the session.
    private var endAudioTimeout: DispatchSourceTimer?
    private let endAudioTimeoutDuration: TimeInterval = 2.5

    /// Diagnostic: tracks audio buffer reception for startup health check.
    private var diagBufferCount: Int = 0
    private var diagPeakRMS: Float = 0
    /// Callback for surfacing diagnostic info (wired by coordinator).
    var onDiagnostic: ((String) -> Void)?

    // MARK: - Start / Stop

    func start() async throws {
        guard !isRunning else { return }
        isStopping = false

        // Speech recognition authorization
        let authStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { cont.resume(returning: $0) }
        }
        print("[SFSpeechRecognizerBackend] Auth status: \(authStatus.rawValue)")
        guard authStatus == .authorized else {
            throw VoiceEngineError.speechRecognitionDenied
        }

        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceEngineError.microphoneUnavailable
        }

        // TCC diagnostic — check all permission APIs for consistency
        let avAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        print("[SFSpeechRecognizerBackend] AVCaptureDevice audio auth: \(avAuthStatus.rawValue) (0=notDetermined, 1=restricted, 2=denied, 3=authorized)")
        onDiagnostic?("TCC mic status: AVCaptureDevice=\(avAuthStatus.rawValue) (3=OK)")

        let rec = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        print("[SFSpeechRecognizerBackend] Recognizer: \(rec == nil ? "nil (locale unsupported?)" : "ok"), supportsOnDevice: \(rec?.supportsOnDeviceRecognition ?? false), available: \(rec?.isAvailable ?? false)")
        guard let rec else {
            throw VoiceEngineError.speechRecognitionDenied
        }
        guard rec.isAvailable else {
            print("[SFSpeechRecognizerBackend] Recognizer not available — model not ready or network unavailable")
            throw VoiceEngineError.speechRecognitionDenied
        }
        recognizer = rec
        DispatchQueue.main.async { self.onModelState?(.ready) }

        // Initial engine setup uses setupAudioEngine (no audioUnit force-init).
        // On macOS 26, the first engine after app launch consistently gets zero
        // audio data from TCC. DO NOT access inputNode.audioUnit here — it taints
        // the CoreAudio session and prevents recovery from working. Instead, let
        // this engine fail, and the 1-second health check triggers recovery with
        // a fresh engine (which uses audioUnit force-init and works because TCC
        // has had time to settle).
        let deviceUID = inputDeviceUID
        let silThreshold = silenceThreshold
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.main.async { [weak self] in
                guard let self else { cont.resume(); return }
                do {
                    try self.setupAudioEngine(deviceUID: deviceUID, silenceThreshold: silThreshold)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }

        // Allow audio hardware to settle before beginning recognition.
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        guard !isStopping else { return }
        startNewRecognitionSession()
        print("[SFSpeechRecognizerBackend] Started")

        // Health check after 1 second — triggers fast recovery if no real audio.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.isRunning else { return }
            let msg = "Audio health: \(self.diagBufferCount) buffers, peakRMS=\(String(format: "%.6f", self.diagPeakRMS)), threshold=\(self.silenceThreshold)"
            print("[SFSpeechRecognizerBackend] \(msg)")
            self.onDiagnostic?(msg)
            if self.diagBufferCount == 0 || self.diagPeakRMS < 0.0001 {
                self.onDiagnostic?("Warming up mic — restarting audio engine")
                self.attemptAudioRecovery()
            }
        }
    }

    func stop() {
        isStopping = true
        cancelSilenceTimer()
        cancelEndAudioTimeout()
        speechDetected = false
        lastPartialText = ""
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        recognizer = nil
        isRunning = false
        print("[SFSpeechRecognizerBackend] Stopped")
    }

    func flushAudio() {
        // Cancel VAD timer — the explicit flush supersedes silence detection.
        cancelSilenceTimer()
        cancelEndAudioTimeout()
        speechDetected = false

        // Capture any partial text before killing the session — SFSpeechRecognizer
        // cancels the old task when a new one starts, so isFinal may never fire.
        // Deliver the last partial as a final transcription to avoid losing speech.
        let pendingText = lastPartialText
        lastPartialText = ""

        // Invalidate the current session so its restart callback won't fire a
        // duplicate session.
        currentSessionID += 1
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        startNewRecognitionSession()

        // Deliver captured partial text as final (after starting new session so
        // the pipeline is ready for the next utterance).
        if !pendingText.isEmpty {
            print("[SFSpeechRecognizerBackend] Flush — delivering pending partial as final: \(pendingText)")
            DispatchQueue.main.async { self.onTranscription?(pendingText) }
        }
    }

    func trimAudio(keepLastSeconds: Double) {
        // Not applicable — SFSpeechRecognizer manages its own audio window
    }

    // MARK: - Audio Engine Setup (must run on main thread)

    /// Creates, configures, and starts the AVAudioEngine with an input tap.
    /// Must be called on the main thread — tap callbacks fail to fire when
    /// the engine is set up on Swift's cooperative thread pool (macOS 26).
    private func setupAudioEngine(deviceUID: String?, silenceThreshold: Float) throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode

        // Resolve the device UID — skip forcing if it's already the system default.
        let resolvedUID: String? = {
            if let uid = deviceUID, !uid.isEmpty { return uid }
            return nil
        }()
        if let uid = resolvedUID, let deviceID = Self.audioDeviceID(forUID: uid) {
            if Self.isDefaultInputDevice(deviceID) {
                print("[SFSpeechRecognizerBackend] Device \(uid) (id=\(deviceID)) is already system default — skipping explicit set")
            } else if let au = inputNode.audioUnit {
                var devID = deviceID
                let status = AudioUnitSetProperty(
                    au,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                print("[SFSpeechRecognizerBackend] Set input device UID: \(uid), deviceID: \(deviceID), status: \(status)")
            } else {
                print("[SFSpeechRecognizerBackend] WARNING: inputNode.audioUnit is nil — cannot set device \(uid)")
            }
        } else {
            print("[SFSpeechRecognizerBackend] Using system default input device")
        }

        // Query actual device for diagnostics
        let actualDeviceName = Self.currentInputDeviceName(for: inputNode)
        print("[SFSpeechRecognizerBackend] Actual input device: \(actualDeviceName)")

        // Check system input volume for the device
        let inputVolume = Self.systemInputVolume(for: inputNode)
        print("[SFSpeechRecognizerBackend] System input volume: \(inputVolume)")
        if inputVolume.contains("vol=0.00") || inputVolume.contains("MUTED") {
            onDiagnostic?("WARNING: System input volume is 0 — mic may be muted in System Settings")
        }

        let nativeFormat = inputNode.outputFormat(forBus: 0)
        let hwRate = nativeFormat.sampleRate
        let hwChannels = nativeFormat.channelCount
        print("[SFSpeechRecognizerBackend] Format: rate=\(hwRate) ch=\(hwChannels) fmt=\(nativeFormat.commonFormat.rawValue)")

        let tapFormat: AVAudioFormat
        if nativeFormat.commonFormat == .pcmFormatFloat32 && hwRate > 0 && hwChannels > 0 {
            tapFormat = nativeFormat
        } else {
            let fallbackRate = hwRate > 0 ? hwRate : 48000.0
            tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: fallbackRate,
                                      channels: max(hwChannels, 1),
                                      interleaved: false)!
            print("[SFSpeechRecognizerBackend] Using fallback format: rate=\(fallbackRate) ch=\(max(hwChannels, 1))")
        }
        diagBufferCount = 0
        diagPeakRMS = 0
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self, !self.isStopping else { return }
            self.diagBufferCount += 1
            self.recognitionRequest?.append(buffer)

            guard let channelData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let ptr = UnsafeBufferPointer(start: channelData[0], count: count)
            let rms = Self.computeRMS(ptr)
            if rms > self.diagPeakRMS { self.diagPeakRMS = rms }
            let threshold = silenceThreshold
            DispatchQueue.main.async {
                self.onAudioLevel?(rms, rms >= threshold)
                self.updateVAD(rms: rms, threshold: threshold)
            }
        }

        try engine.start()
        audioEngine = engine
        isRunning = true
        print("[SFSpeechRecognizerBackend] Engine started on main thread")
    }

    // MARK: - Silence VAD

    private func updateVAD(rms: Float, threshold: Float) {
        if rms >= threshold {
            // Active speech — reset silence countdown
            speechDetected = true
            cancelSilenceTimer()
        } else if speechDetected {
            // Dropped below threshold after speech — start countdown if not already running
            if silenceTimer == nil {
                startSilenceTimer()
            }
        }
    }

    private func startSilenceTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + silenceDuration)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopping else { return }
            print("[SFSpeechRecognizerBackend] Silence VAD — finalizing utterance")
            self.silenceTimer = nil
            self.speechDetected = false
            // Just call endAudio() — do NOT start a new session here.
            // SFSpeechRecognizer cancels the old task when a new one starts,
            // which would prevent isFinal from being delivered.
            // The isFinal callback (or error callback) will restart the session.
            let sid = self.currentSessionID
            self.recognitionRequest?.endAudio()
            // Safety net: if the callback never fires, deliver text anyway.
            self.startEndAudioTimeout(sessionID: sid)
        }
        timer.resume()
        silenceTimer = timer
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
    }

    private func cancelEndAudioTimeout() {
        endAudioTimeout?.cancel()
        endAudioTimeout = nil
    }

    /// Start a safety timer after endAudio(). If the recognition callback never
    /// fires (isFinal or error), deliver lastPartialText and restart the session.
    private func startEndAudioTimeout(sessionID: Int) {
        cancelEndAudioTimeout()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + endAudioTimeoutDuration)
        timer.setEventHandler { [weak self] in
            guard let self, !self.isStopping, self.currentSessionID == sessionID else { return }
            let pending = self.lastPartialText
            self.lastPartialText = ""
            self.endAudioTimeout = nil
            print("[SFSpeechRecognizerBackend] endAudio timeout — callback never fired (session \(sessionID))")
            if !pending.isEmpty {
                print("[SFSpeechRecognizerBackend] Delivering pending partial as final via timeout: \(pending)")
                self.onTranscription?(pending)
            }
            // Force-restart the session
            self.recognitionTask?.cancel()
            self.recognitionTask = nil
            self.recognitionRequest = nil
            self.startNewRecognitionSession()
        }
        timer.resume()
        endAudioTimeout = timer
    }

    // MARK: - Recognition session management

    private func startNewRecognitionSession() {
        guard !isStopping, let recognizer else { return }

        let sessionID = currentSessionID

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Don't force on-device — if the model isn't fully loaded the session
        // fails silently with no results. Let the OS pick server vs on-device.
        recognitionRequest = request

        print("[SFSpeechRecognizerBackend] Starting recognition task (session \(sessionID))")
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self, !self.isStopping else { return }

            if let result {
                let text = result.bestTranscription.formattedString
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }

                if result.isFinal {
                    self.cancelEndAudioTimeout()
                    print("[SFSpeechRecognizerBackend] Final (session \(sessionID)): \(text)")
                    self.lastPartialText = ""
                    // Always deliver final text regardless of session ID — a slot
                    // change (flushAudio) should not discard speech already spoken.
                    DispatchQueue.main.async { self.onTranscription?(text) }
                    // Only restart if this session is still current (not flushed).
                    DispatchQueue.main.async {
                        guard !self.isStopping, self.currentSessionID == sessionID else { return }
                        self.recognitionRequest = nil
                        self.recognitionTask = nil
                        self.startNewRecognitionSession()
                    }
                } else {
                    // Track partial text so flushAudio() can deliver it if the task
                    // gets cancelled before isFinal fires.
                    self.lastPartialText = text
                    print("[SFSpeechRecognizerBackend] Partial (session \(sessionID)): \(text)")
                    DispatchQueue.main.async { self.onPartialTranscription?(text) }
                }
                return
            }

            if let error {
                self.cancelEndAudioTimeout()
                let nsError = error as NSError
                // 1110 = no speech, 203/301 = cancelled — all routine
                let isCancelled = nsError.code == 203 || nsError.code == 301
                let isNoSpeech = nsError.code == 1110
                let isRoutine = isCancelled || isNoSpeech
                if !isRoutine {
                    print("[SFSpeechRecognizerBackend] Error \(nsError.code) (session \(sessionID)): \(error)")
                } else {
                    print("[SFSpeechRecognizerBackend] Routine end (code \(nsError.code), session \(sessionID))")
                }

                // If the task was cancelled (e.g. by silence VAD endAudio or system)
                // and we had partial text, deliver it as a final transcription.
                // This prevents speech from being silently dropped.
                let pending = self.lastPartialText
                self.lastPartialText = ""
                if !pending.isEmpty && self.currentSessionID == sessionID {
                    print("[SFSpeechRecognizerBackend] Delivering pending partial as final on task end: \(pending)")
                    DispatchQueue.main.async { self.onTranscription?(pending) }
                }

                DispatchQueue.main.async {
                    guard !self.isStopping, self.currentSessionID == sessionID else { return }
                    self.recognitionRequest = nil
                    self.recognitionTask = nil
                    self.startNewRecognitionSession()
                }
            }
        }
    }

    // MARK: - Helpers

    private static func computeRMS(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    /// Returns the UID of the first built-in (internal) input device, or nil if none found.
    private static func builtInInputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return nil }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr else { return nil }

        for deviceID in devices {
            // Check it has input streams
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamSize) == noErr, streamSize > 0 else { continue }

            // Check transport type = built-in
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var transport: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &transportSize, &transport) == noErr,
                  transport == kAudioDeviceTransportTypeBuiltIn else { continue }

            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uidRef: CFString? = nil
            var uidSize = UInt32(MemoryLayout<CFString?>.size)
            guard AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, &uidRef) == noErr,
                  let uid = uidRef as String? else { continue }
            return uid
        }
        return nil
    }

    /// Restart the audio engine without forcing a specific device.
    /// Called automatically if zero buffers are received after 3 seconds.
    private func attemptAudioRecovery() {
        guard isRunning, !isStopping else { return }
        print("[SFSpeechRecognizerBackend] Auto-recovery: restarting engine with system default device")

        // Tear down current engine
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()

        // Rebuild with system default (no device forcing)
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let _ = inputNode.audioUnit  // Force initialization

        let recoveryNative = inputNode.outputFormat(forBus: 0)
        print("[SFSpeechRecognizerBackend] Recovery format: rate=\(recoveryNative.sampleRate) ch=\(recoveryNative.channelCount)")
        let recoveryFormat: AVAudioFormat
        if recoveryNative.commonFormat == .pcmFormatFloat32 && recoveryNative.sampleRate > 0 && recoveryNative.channelCount > 0 {
            recoveryFormat = recoveryNative
        } else {
            recoveryFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false)!
        }
        diagBufferCount = 0
        diagPeakRMS = 0

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recoveryFormat) { [weak self] buffer, _ in
            guard let self, !self.isStopping else { return }
            self.diagBufferCount += 1
            self.recognitionRequest?.append(buffer)

            guard let channelData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let ptr = UnsafeBufferPointer(start: channelData[0], count: count)
            let rms = Self.computeRMS(ptr)
            if rms > self.diagPeakRMS { self.diagPeakRMS = rms }
            let threshold = self.silenceThreshold
            DispatchQueue.main.async {
                self.onAudioLevel?(rms, rms >= threshold)
                self.updateVAD(rms: rms, threshold: threshold)
            }
        }

        do {
            try engine.start()
            audioEngine = engine
            print("[SFSpeechRecognizerBackend] Recovery engine started")
            startNewRecognitionSession()
            onDiagnostic?("Audio recovered — engine restarted with system default")

            // Verify recovery after 2 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, self.isRunning else { return }
                if self.diagBufferCount == 0 {
                    self.onDiagnostic?("CRITICAL: Still no audio after recovery. Check System Settings > Privacy > Microphone.")
                } else {
                    self.onDiagnostic?("Recovery confirmed: \(self.diagBufferCount) buffers, peakRMS=\(String(format: "%.6f", self.diagPeakRMS))")
                }
            }
        } catch {
            print("[SFSpeechRecognizerBackend] Recovery failed: \(error)")
            onDiagnostic?("Audio recovery failed: \(error.localizedDescription)")
        }
    }

    /// Check if a CoreAudio device ID matches the system's current default input device.
    private static func isDefaultInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var defaultID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &defaultID
        )
        guard status == noErr else { return false }
        return defaultID == deviceID
    }

    /// Query the name of the audio device currently assigned to an input node's audio unit.
    private static func currentInputDeviceName(for inputNode: AVAudioInputNode) -> String {
        guard let au = inputNode.audioUnit else { return "(no audio unit)" }
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != 0 else { return "(unknown, status=\(status))" }
        // Get device name
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameRef: CFString? = nil
        var nameSize = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &nameRef) == noErr,
              let name = nameRef as String? else { return "(id=\(deviceID), name unknown)" }
        return "\(name) (id=\(deviceID))"
    }

    /// Query the system input volume for the device used by the given input node.
    private static func systemInputVolume(for inputNode: AVAudioInputNode) -> String {
        guard let au = inputNode.audioUnit else { return "(no audio unit)" }
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            &size
        )
        guard status == noErr, deviceID != 0 else { return "(unknown device)" }

        // Query input volume
        var volumeAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var volume: Float32 = -1
        var volumeSize = UInt32(MemoryLayout<Float32>.size)
        let volStatus = AudioObjectGetPropertyData(deviceID, &volumeAddress, 0, nil, &volumeSize, &volume)

        // Query mute state
        var muteAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var mute: UInt32 = 0
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        let muteStatus = AudioObjectGetPropertyData(deviceID, &muteAddress, 0, nil, &muteSize, &mute)

        let volStr = volStatus == noErr ? String(format: "%.2f", volume) : "n/a(err=\(volStatus))"
        let muteStr = muteStatus == noErr ? (mute != 0 ? "MUTED" : "unmuted") : "n/a"
        return "vol=\(volStr) mute=\(muteStr) deviceID=\(deviceID)"
    }

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF = uid as CFString
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<CFString>.size),
            &uidCF,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}
