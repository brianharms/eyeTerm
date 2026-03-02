import AVFoundation
import CoreAudio
import Speech

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

        let engine = AVAudioEngine()

        // Resolve the device UID to use — prefer explicit selection, then
        // fall back to the built-in mic (ignoring the system default which
        // may be AirPods/external device), then let AVAudioEngine decide.
        let resolvedUID: String? = {
            if let uid = inputDeviceUID, !uid.isEmpty { return uid }
            return Self.builtInInputDeviceUID()
        }()
        if let uid = resolvedUID, let deviceID = Self.audioDeviceID(forUID: uid) {
            var devID = deviceID
            AudioUnitSetProperty(
                engine.inputNode.audioUnit!,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &devID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            print("[SFSpeechRecognizerBackend] Using input device UID: \(uid)")
        }

        let inputNode = engine.inputNode
        // Use the hardware's native sample rate but force float32 so that
        // floatChannelData is always non-nil in the tap callback.
        // inputFormat(forBus:) reflects hardware and is available before start().
        let hwRate = inputNode.inputFormat(forBus: 0).sampleRate
        let tapRate = hwRate > 0 ? hwRate : 44100.0
        let tapFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: tapRate, channels: 1,
                                      interleaved: false)!
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self, !self.isStopping else { return }
            self.recognitionRequest?.append(buffer)

            // Emit audio level for waveform indicator + drive silence-based VAD
            guard let channelData = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            let ptr = UnsafeBufferPointer(start: channelData[0], count: count)
            let rms = Self.computeRMS(ptr)
            let threshold = self.silenceThreshold
            DispatchQueue.main.async {
                self.onAudioLevel?(rms, rms >= threshold)
                self.updateVAD(rms: rms, threshold: threshold)
            }
        }

        // Start engine after tap is installed — starting before any tap is
        // configured can throw an ObjC exception (not catchable via Swift try).
        try engine.start()
        audioEngine = engine
        isRunning = true

        // Allow audio hardware to settle before beginning recognition.
        try await Task.sleep(nanoseconds: 200_000_000)  // 200ms

        guard !isStopping else { return }
        startNewRecognitionSession()
        print("[SFSpeechRecognizerBackend] Started")
    }

    func stop() {
        isStopping = true
        cancelSilenceTimer()
        speechDetected = false
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
        speechDetected = false
        // Invalidate the current session so its restart callback won't fire a
        // duplicate session, but do NOT cancel — let endAudio() trigger isFinal
        // so any in-progress speech still reaches onTranscription.
        currentSessionID += 1
        recognitionRequest?.endAudio()
        recognitionTask = nil
        recognitionRequest = nil
        startNewRecognitionSession()
    }

    func trimAudio(keepLastSeconds: Double) {
        // Not applicable — SFSpeechRecognizer manages its own audio window
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
            self.currentSessionID += 1
            self.recognitionRequest?.endAudio()
            self.recognitionTask = nil
            self.recognitionRequest = nil
            self.startNewRecognitionSession()
        }
        timer.resume()
        silenceTimer = timer
    }

    private func cancelSilenceTimer() {
        silenceTimer?.cancel()
        silenceTimer = nil
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
                    print("[SFSpeechRecognizerBackend] Final (session \(sessionID)): \(text)")
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
                    print("[SFSpeechRecognizerBackend] Partial (session \(sessionID)): \(text)")
                    DispatchQueue.main.async { self.onPartialTranscription?(text) }
                }
                return
            }

            if let error {
                let nsError = error as NSError
                // 1110 = no speech, 203/301 = cancelled — all routine
                let isRoutine = nsError.code == 1110 || nsError.code == 203 || nsError.code == 301
                if !isRoutine {
                    print("[SFSpeechRecognizerBackend] Error \(nsError.code) (session \(sessionID)): \(error)")
                } else {
                    print("[SFSpeechRecognizerBackend] Routine end (code \(nsError.code), session \(sessionID)), restarting")
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
