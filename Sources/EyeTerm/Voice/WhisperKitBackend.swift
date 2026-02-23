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
    private var isTranscribing = false

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
        transcriptionTask?.cancel()
        transcriptionTask = nil
        interimTask?.cancel()
        interimTask = nil
        isTranscribing = false
        pipeline.stop()
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

    // MARK: - Private

    private func transcribe(audio: [Float]) {
        guard let whisperKit else {
            print("[WhisperKitBackend] Skipping transcription: whisperKit nil")
            return
        }

        let durationSec = Double(audio.count) / 16000.0
        print("[WhisperKitBackend] Transcribing \(String(format: "%.1f", durationSec))s of audio (\(audio.count) samples)...")

        isTranscribing = true
        transcriptionTask = Task { [weak self] in
            defer { self?.isTranscribing = false }
            do {
                let results = try await whisperKit.transcribe(audioArray: audio)
                let text = results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                print("[WhisperKitBackend] Transcription result: \"\(text)\"")
                guard !text.isEmpty else {
                    print("[WhisperKitBackend] Empty transcription, ignoring")
                    return
                }
                await MainActor.run {
                    self?.onTranscription?(text)
                }
            } catch {
                print("[WhisperKitBackend] Transcription FAILED: \(error)")
            }
        }
    }

    private func transcribeInterim(audio: [Float]) {
        guard !isTranscribing else {
            print("[WhisperKitBackend] Skipping interim: transcription in-flight")
            return
        }
        guard let whisperKit else { return }

        let durationSec = Double(audio.count) / 16000.0
        print("[WhisperKitBackend] Interim transcribing \(String(format: "%.1f", durationSec))s...")

        isTranscribing = true
        interimTask = Task { [weak self] in
            defer { self?.isTranscribing = false }
            do {
                let results = try await whisperKit.transcribe(audioArray: audio, callback: { [weak self] progress in
                    guard let self, !Task.isCancelled else { return false }
                    let partial = progress.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !partial.isEmpty {
                        DispatchQueue.main.async { self.onPartialTranscription?(partial) }
                    }
                    return nil // continue decoding
                })
                let text = results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                print("[WhisperKitBackend] Interim result: \"\(text)\"")
                guard !text.isEmpty, !Task.isCancelled else { return }
                await MainActor.run {
                    self?.onPartialTranscription?(text)
                }
            } catch {
                if !Task.isCancelled {
                    print("[WhisperKitBackend] Interim transcription FAILED: \(error)")
                }
            }
        }
    }
}
