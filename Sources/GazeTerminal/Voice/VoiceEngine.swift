import AVFoundation
import WhisperKit

final class VoiceEngine {
    var onTranscription: ((String) -> Void)?
    var modelName: String = "small.en"
    var silenceThreshold: Float = 0.01
    var silenceDuration: TimeInterval = 0.5

    private(set) var isRunning = false

    private var audioEngine: AVAudioEngine?
    private var whisperKit: WhisperKit?
    private let bufferManager = AudioBufferManager()
    private var isSpeaking = false
    private var silenceStart: Date?
    private var vadTask: Task<Void, Never>?

    func start() async throws {
        guard !isRunning else { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceEngineError.microphoneUnavailable
        }

        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: modelName))
        } catch {
            throw VoiceEngineError.modelInitializationFailed(error)
        }

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        let targetSampleRate: Double = 16000.0
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw VoiceEngineError.audioFormatError
        }

        let needsConversion = inputFormat.sampleRate != targetSampleRate || inputFormat.channelCount != 1
        var converter: AVAudioConverter?
        if needsConversion {
            converter = AVAudioConverter(from: inputFormat, to: targetFormat)
            guard converter != nil else {
                throw VoiceEngineError.audioFormatError
            }
        }

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] pcmBuffer, _ in
            guard let self else { return }
            let samples: [Float]
            if let converter {
                let frameCapacity = AVAudioFrameCount(
                    Double(pcmBuffer.frameLength) * targetSampleRate / inputFormat.sampleRate
                )
                guard let convertedBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: frameCapacity
                ) else { return }

                var error: NSError?
                var allConsumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if allConsumed {
                        outStatus.pointee = .noDataNow
                        return nil
                    }
                    allConsumed = true
                    outStatus.pointee = .haveData
                    return pcmBuffer
                }
                if error != nil { return }
                samples = self.extractSamples(from: convertedBuffer)
            } else {
                samples = self.extractSamples(from: pcmBuffer)
            }
            self.bufferManager.append(samples)
            self.processVAD(samples: samples)
        }

        try engine.start()
        self.audioEngine = engine
        isRunning = true
    }

    func stop() {
        vadTask?.cancel()
        vadTask = nil
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        bufferManager.clear()
        isRunning = false
        isSpeaking = false
        silenceStart = nil
    }

    // MARK: - Private

    private func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    private func processVAD(samples: [Float]) {
        let rms = computeRMS(samples)

        if rms >= silenceThreshold {
            isSpeaking = true
            silenceStart = nil
        } else if isSpeaking {
            if silenceStart == nil {
                silenceStart = Date()
            }
            if let start = silenceStart, Date().timeIntervalSince(start) >= silenceDuration {
                isSpeaking = false
                silenceStart = nil
                triggerTranscription()
            }
        }
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    private func triggerTranscription() {
        let audio = bufferManager.getBuffer()
        bufferManager.clear()

        guard !audio.isEmpty, let whisperKit else { return }

        vadTask = Task { [weak self] in
            do {
                let results = try await whisperKit.transcribe(audioArray: audio)
                let text = results.compactMap(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                await MainActor.run {
                    self?.onTranscription?(text)
                }
            } catch {
                // Transcription failed — silently continue listening
            }
        }
    }
}

enum VoiceEngineError: LocalizedError {
    case microphoneUnavailable
    case modelInitializationFailed(Error)
    case audioFormatError

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "Microphone access is required for voice input."
        case .modelInitializationFailed(let error):
            return "Failed to initialize WhisperKit: \(error.localizedDescription)"
        case .audioFormatError:
            return "Could not configure audio format for recording."
        }
    }
}
