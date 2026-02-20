import AVFoundation

final class VoiceAudioPipeline {
    var onAudioLevel: ((Float, Bool) -> Void)?
    var onSpeechSegmentReady: (([Float]) -> Void)?
    var onInterimAudioReady: (([Float]) -> Void)?
    var silenceThreshold: Float = 0.01
    var silenceDuration: TimeInterval = 0.5
    var interimInterval: TimeInterval = 1.0

    private(set) var isRunning = false

    private var audioEngine: AVAudioEngine?
    private let bufferManager = AudioBufferManager()
    private var isSpeaking = false
    private var silenceStart: Date?
    private var lastInterimEmit: Date?

    func start() async throws {
        guard !isRunning else { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceEngineError.microphoneUnavailable
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

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(rms, rms >= (self?.silenceThreshold ?? 0.01))
        }

        if rms >= silenceThreshold {
            isSpeaking = true
            silenceStart = nil

            // Emit interim audio snapshots while speaking
            let now = Date()
            let bufferDuration = bufferManager.durationSeconds
            let timeSinceLastInterim = lastInterimEmit.map { now.timeIntervalSince($0) } ?? .infinity
            if bufferDuration >= 0.5 && timeSinceLastInterim >= interimInterval {
                lastInterimEmit = now
                let snapshot = bufferManager.getBuffer()
                if !snapshot.isEmpty {
                    onInterimAudioReady?(snapshot)
                }
            }
        } else if isSpeaking {
            if silenceStart == nil {
                silenceStart = Date()
            }
            if let start = silenceStart, Date().timeIntervalSince(start) >= silenceDuration {
                isSpeaking = false
                silenceStart = nil
                lastInterimEmit = nil
                emitSpeechSegment()
            }
        }
    }

    private func computeRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sumOfSquares = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return sqrt(sumOfSquares / Float(samples.count))
    }

    private func emitSpeechSegment() {
        let audio = bufferManager.getBuffer()
        bufferManager.clear()
        guard !audio.isEmpty else { return }
        onSpeechSegmentReady?(audio)
    }
}
