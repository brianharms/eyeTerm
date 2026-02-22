import Foundation
import SwiftWhisper

final class WhisperCppBackend: VoiceTranscriptionBackend {
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
    private var whisper: Whisper?
    /// The currently in-flight whisper task (full or interim). Each new task
    /// awaits the previous one before calling whisper.transcribe, serializing
    /// access to the underlying C library which returns `instanceBusy` on
    /// concurrent calls.
    private var activeWhisperTask: Task<Void, Never>?

    func start() async throws {
        guard !isRunning else { return }

        NSLog("[WhisperCppBackend] Downloading model: %@", modelName)
        DispatchQueue.main.async { self.onModelState?(.loading) }
        do {
            let modelPath = try await WhisperCppModelManager.shared.modelPath(for: modelName)
            NSLog("[WhisperCppBackend] Model path: %@", modelPath.path)
            whisper = try Whisper(fromFileURL: modelPath)
            NSLog("[WhisperCppBackend] Model loaded successfully")
            DispatchQueue.main.async { self.onModelState?(.ready) }
        } catch {
            NSLog("[WhisperCppBackend] Model load FAILED: %@", error.localizedDescription)
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
        pipeline.onInterimAudioReady = { [weak self] audio in
            self?.transcribeInterim(audio: audio)
        }

        try await pipeline.start()
        isRunning = true
    }

    func stop() {
        activeWhisperTask?.cancel()
        activeWhisperTask = nil
        pipeline.stop()
        whisper = nil
        isRunning = false
    }

    func flushAudio() {
        activeWhisperTask?.cancel()
        activeWhisperTask = nil
        pipeline.flushBuffer()
    }

    func trimAudio(keepLastSeconds: Double) {
        pipeline.trimBuffer(keepLastSeconds: keepLastSeconds)
    }

    // MARK: - Private

    private func transcribe(audio: [Float]) {
        guard let whisper else {
            NSLog("[WhisperCppBackend] Skipping transcription: whisper nil")
            return
        }

        let durationSec = Double(audio.count) / 16000.0
        NSLog("[WhisperCppBackend] Transcribing %.1fs of audio (%d samples)...", durationSec, audio.count)

        let previous = activeWhisperTask
        activeWhisperTask = Task { [weak self] in
            // Wait for any in-flight whisper call to finish — whisper.cpp
            // returns instanceBusy if called concurrently.
            _ = await previous?.result
            NSLog("[WhisperCppBackend] Previous task done, starting full transcription")

            do {
                let segments = try await whisper.transcribe(audioFrames: audio)
                NSLog("[WhisperCppBackend] Got %d segments", segments.count)
                let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[WhisperCppBackend] Transcription result: \"%@\"", text)
                guard !text.isEmpty else {
                    NSLog("[WhisperCppBackend] Empty transcription, ignoring")
                    return
                }
                guard !Task.isCancelled else {
                    NSLog("[WhisperCppBackend] Task cancelled, discarding result")
                    return
                }
                await MainActor.run {
                    self?.onTranscription?(text)
                }
            } catch {
                NSLog("[WhisperCppBackend] Transcription FAILED: %@", error.localizedDescription)
            }
        }
    }

    private func transcribeInterim(audio: [Float]) {
        // Skip interim if a task is already queued — we don't want to pile up
        guard activeWhisperTask == nil else {
            NSLog("[WhisperCppBackend] Skipping interim: whisper task in-flight")
            return
        }
        guard let whisper else { return }

        let durationSec = Double(audio.count) / 16000.0
        NSLog("[WhisperCppBackend] Interim transcribing %.1fs...", durationSec)

        activeWhisperTask = Task { [weak self] in
            defer { self?.activeWhisperTask = nil }
            do {
                let segments = try await whisper.transcribe(audioFrames: audio)
                let text = segments.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                NSLog("[WhisperCppBackend] Interim result: \"%@\"", text)
                guard !text.isEmpty, !Task.isCancelled else { return }
                await MainActor.run {
                    self?.onPartialTranscription?(text)
                }
            } catch {
                if !Task.isCancelled {
                    NSLog("[WhisperCppBackend] Interim transcription FAILED: %@", error.localizedDescription)
                }
            }
        }
    }
}
