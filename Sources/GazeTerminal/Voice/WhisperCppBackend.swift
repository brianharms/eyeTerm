import Foundation
import SwiftWhisper

final class WhisperCppBackend: VoiceTranscriptionBackend {
    var onTranscription: ((String) -> Void)?
    var onAudioLevel: ((Float, Bool) -> Void)?
    var onModelState: ((VoiceModelState) -> Void)?
    var modelName: String = "small.en"
    var silenceThreshold: Float = 0.01 {
        didSet { pipeline.silenceThreshold = silenceThreshold }
    }

    private(set) var isRunning = false

    private let pipeline = VoiceAudioPipeline()
    private var whisper: Whisper?
    private var transcriptionTask: Task<Void, Never>?

    func start() async throws {
        guard !isRunning else { return }

        print("[WhisperCppBackend] Downloading model: \(modelName)...")
        DispatchQueue.main.async { self.onModelState?(.loading) }
        do {
            let modelPath = try await WhisperCppModelManager.shared.modelPath(for: modelName)
            whisper = try Whisper(fromFileURL: modelPath)
            print("[WhisperCppBackend] Model loaded successfully")
            DispatchQueue.main.async { self.onModelState?(.ready) }
        } catch {
            print("[WhisperCppBackend] Model load FAILED: \(error)")
            DispatchQueue.main.async { self.onModelState?(.failed(error.localizedDescription)) }
            throw VoiceEngineError.modelInitializationFailed(error)
        }

        pipeline.silenceThreshold = silenceThreshold
        pipeline.onAudioLevel = { [weak self] level, speaking in
            self?.onAudioLevel?(level, speaking)
        }
        pipeline.onSpeechSegmentReady = { [weak self] audio in
            self?.transcribe(audio: audio)
        }

        try await pipeline.start()
        isRunning = true
    }

    func stop() {
        transcriptionTask?.cancel()
        transcriptionTask = nil
        pipeline.stop()
        whisper = nil
        isRunning = false
    }

    // MARK: - Private

    private func transcribe(audio: [Float]) {
        guard let whisper else {
            print("[WhisperCppBackend] Skipping transcription: whisper nil")
            return
        }

        let durationSec = Double(audio.count) / 16000.0
        print("[WhisperCppBackend] Transcribing \(String(format: "%.1f", durationSec))s of audio (\(audio.count) samples)...")

        transcriptionTask = Task { [weak self] in
            do {
                let segments = try await whisper.transcribe(audioFrames: audio)
                let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                print("[WhisperCppBackend] Transcription result: \"\(text)\"")
                guard !text.isEmpty else {
                    print("[WhisperCppBackend] Empty transcription, ignoring")
                    return
                }
                await MainActor.run {
                    self?.onTranscription?(text)
                }
            } catch {
                print("[WhisperCppBackend] Transcription FAILED: \(error)")
            }
        }
    }
}
