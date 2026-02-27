import Foundation
import WhisperKit

final class WhisperKitBackend: VoiceTranscriptionBackend {
    var onTranscription: ((String) -> Void)?
    var onPartialTranscription: ((String) -> Void)?
    var onAudioLevel: ((Float, Bool) -> Void)?
    var onModelState: ((VoiceModelState) -> Void)?
    var modelName: String = "small.en"
    var silenceThreshold: Float = 0.01 {
        didSet { pipeline.silenceThreshold = silenceThreshold }
    }
    var inputDeviceUID: String? {
        get { pipeline.inputDeviceUID }
        set { pipeline.inputDeviceUID = newValue }
    }

    private(set) var isRunning = false

    private let pipeline = VoiceAudioPipeline()
    private var whisperKit: WhisperKit?
    private var transcriptionTask: Task<Void, Never>?
    private var interimTask: Task<Void, Never>?

    // Serial queue that owns all reads and writes of `isTranscribing` and `isStopping`,
    // eliminating the TOCTOU race between transcribe() and transcribeInterim().
    private let stateQueue = DispatchQueue(label: "com.eyeterm.whisper.state")
    private var _isTranscribing = false
    private var _isStopping = false

    private var isTranscribing: Bool {
        get { stateQueue.sync { _isTranscribing } }
        set { stateQueue.async { self._isTranscribing = newValue } }
    }

    private var isStopping: Bool {
        get { stateQueue.sync { _isStopping } }
        set { stateQueue.async { self._isStopping = newValue } }
    }

    func start() async throws {
        guard !isRunning else { return }

        print("[WhisperKitBackend] Loading model: \(modelName)...")
        DispatchQueue.main.async { self.onModelState?(.loading) }
        do {
            let variant = "openai_whisper-\(modelName)"
            var config = WhisperKitConfig(model: modelName)
            if let bundledPath = Bundle.main.path(forResource: variant, ofType: nil, inDirectory: "Models/whisperkit"),
               FileManager.default.fileExists(atPath: bundledPath) {
                print("[WhisperKitBackend] Using bundled model at \(bundledPath)")
                config.modelFolder = bundledPath
                config.download = false
            }
            whisperKit = try await WhisperKit(config)
            print("[WhisperKitBackend] Model loaded successfully")
            DispatchQueue.main.async { self.onModelState?(.ready) }
        } catch {
            print("[WhisperKitBackend] Model load FAILED: \(error)")
            DispatchQueue.main.async { self.onModelState?(.failed(error.localizedDescription)) }
            throw VoiceEngineError.modelInitializationFailed(error)
        }

        isStopping = false
        pipeline.silenceThreshold = silenceThreshold
        pipeline.onAudioLevel = { [weak self] level, speaking in
            self?.onAudioLevel?(level, speaking)
        }
        pipeline.onSpeechSegmentReady = { [weak self] audio in
            self?.interimTask?.cancel()
            self?.interimTask = nil
            self?.transcribe(audio: audio)
        }
        pipeline.onInterimAudioReady = { [weak self] audio in
            self?.transcribeInterim(audio: audio)
        }

        try await pipeline.start()
        isRunning = true
    }

    func stop() {
        // Set the stopping flag first so any in-flight Task result callbacks are suppressed.
        isStopping = true
        transcriptionTask?.cancel()
        transcriptionTask = nil
        interimTask?.cancel()
        interimTask = nil
        isTranscribing = false
        pipeline.stop()
        // Nullify whisperKit after cancelling tasks. The active Task captures a local
        // strong reference to whisperKit (captured at call site below), so the inference
        // call itself is safe to finish; we just won't process the result.
        whisperKit = nil
        isRunning = false
    }

    func flushAudio() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        interimTask?.cancel()
        interimTask = nil
        isTranscribing = false
        pipeline.flushBuffer()
    }

    func trimAudio(keepLastSeconds: Double) {
        pipeline.trimBuffer(keepLastSeconds: keepLastSeconds)
    }

    // MARK: - Hallucination Filter

    /// Common Whisper hallucinations produced during silence or ambient noise.
    private static let knownHallucinations: Set<String> = [
        "thank you", "thank you.", "thanks", "thanks.", "thanks for watching",
        "thanks for watching.", "thanks for watching!", "thank you for watching",
        "thank you for watching.", "you", "you.", "hmm", "hmm.", "hm", "hm.",
        "bye", "bye.", "bye-bye", "bye-bye.", "okay", "okay.", "ok", "ok.",
        ".", "..", "...", "....", " ", "♪", "♪♪",
        // WhisperKit special token artifacts (raw or decoded)
        "start of transcript", "start of transcript.", "[start of transcript]",
        "end of transcript", "end of transcript.", "[end of transcript]",
        "no speech", "[no speech]", "no audio", "inaudible", "[inaudible]",
        "silence", "[silence]", "music", "[music]", "applause", "[applause]",
    ]

    private func isHallucination(_ text: String) -> Bool {
        let lower = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.knownHallucinations.contains(lower) { return true }
        // Reject strings with fewer than 2 actual word characters
        let wordChars = lower.filter { $0.isLetter || $0.isNumber }
        return wordChars.count < 2
    }

    // MARK: - Private

    private func transcribe(audio: [Float]) {
        // Capture whisperKit strongly before entering the Task so that a concurrent
        // stop() call nullifying self.whisperKit does not affect this inference.
        guard let wk = whisperKit else {
            print("[WhisperKitBackend] Skipping transcription: whisperKit nil")
            return
        }

        let durationSec = Double(audio.count) / 16000.0
        print("[WhisperKitBackend] Transcribing \(String(format: "%.1f", durationSec))s of audio (\(audio.count) samples)...")

        // Atomic check+set on stateQueue to prevent TOCTOU with transcribeInterim.
        let alreadyTranscribing = stateQueue.sync { () -> Bool in
            if self._isTranscribing { return true }
            self._isTranscribing = true
            return false
        }
        guard !alreadyTranscribing else {
            print("[WhisperKitBackend] Skipping transcription: already in-flight")
            return
        }

        transcriptionTask = Task { [weak self] in
            defer { self?.isTranscribing = false }
            do {
                let results = try await wk.transcribe(audioArray: audio)
                let text = results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                print("[WhisperKitBackend] Transcription result: \"\(text)\"")
                guard !text.isEmpty else {
                    print("[WhisperKitBackend] Empty transcription, ignoring")
                    return
                }
                guard let self, !self.isStopping else { return }
                guard !self.isHallucination(text) else {
                    print("[WhisperKitBackend] Filtering hallucination: \"\(text)\"")
                    return
                }
                await MainActor.run {
                    self.onTranscription?(text)
                }
            } catch {
                print("[WhisperKitBackend] Transcription FAILED: \(error)")
            }
        }
    }

    private func transcribeInterim(audio: [Float]) {
        // Atomic check+set on stateQueue to prevent TOCTOU with transcribe().
        let shouldSkip = stateQueue.sync { () -> Bool in
            if self._isTranscribing { return true }
            self._isTranscribing = true
            return false
        }
        guard !shouldSkip else {
            print("[WhisperKitBackend] Skipping interim: transcription in-flight")
            return
        }

        // Capture whisperKit strongly before entering the Task.
        guard let wk = whisperKit else {
            isTranscribing = false
            return
        }

        let durationSec = Double(audio.count) / 16000.0
        print("[WhisperKitBackend] Interim transcribing \(String(format: "%.1f", durationSec))s...")

        interimTask = Task { [weak self] in
            defer { self?.isTranscribing = false }
            do {
                let results = try await wk.transcribe(audioArray: audio, callback: { [weak self] progress in
                    guard let self, !Task.isCancelled, !self.isStopping else { return false }
                    let partial = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty && !self.isHallucination(partial) {
                        DispatchQueue.main.async { self.onPartialTranscription?(partial) }
                    }
                    return nil // continue decoding
                })
                let text = results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                print("[WhisperKitBackend] Interim result: \"\(text)\"")
                guard !text.isEmpty, !Task.isCancelled else { return }
                guard let self, !self.isStopping else { return }
                guard !self.isHallucination(text) else {
                    print("[WhisperKitBackend] Filtering interim hallucination: \"\(text)\"")
                    return
                }
                await MainActor.run {
                    self.onPartialTranscription?(text)
                }
            } catch {
                if !Task.isCancelled {
                    print("[WhisperKitBackend] Interim transcription FAILED: \(error)")
                }
            }
        }
    }
}
