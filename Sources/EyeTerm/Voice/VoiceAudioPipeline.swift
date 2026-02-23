import AVFoundation
import CoreAudio

final class VoiceAudioPipeline {
    var onAudioLevel: ((Float, Bool) -> Void)?
    var onSpeechSegmentReady: (([Float]) -> Void)?
    var onInterimAudioReady: (([Float]) -> Void)?
    var silenceThreshold: Float = 0.01
    var silenceDuration: TimeInterval = 0.5
    var interimInterval: TimeInterval = 0.2
    var inputDeviceUID: String?   // nil = system default

    private(set) var isRunning = false

    private var audioEngine: AVAudioEngine?
    private let bufferManager = AudioBufferManager()
    private var isSpeaking = false
    private var silenceStart: Date?
    private var lastInterimEmit: Date?

    // Serial queue that owns all VAD state mutations and callback dispatch.
    private let vadQueue = DispatchQueue(label: "com.eyeterm.vad", qos: .userInitiated)

    func start() async throws {
        guard !isRunning else { return }

        guard await AVAudioApplication.requestRecordPermission() else {
            throw VoiceEngineError.microphoneUnavailable
        }

        let engine = AVAudioEngine()

        // Apply non-default input device if requested
        if let uid = inputDeviceUID, !uid.isEmpty {
            if let deviceID = Self.audioDeviceID(forUID: uid) {
                var devID = deviceID
                let status = AudioUnitSetProperty(
                    engine.inputNode.audioUnit!,
                    kAudioOutputUnitProperty_CurrentDevice,
                    kAudioUnitScope_Global,
                    0,
                    &devID,
                    UInt32(MemoryLayout<AudioDeviceID>.size)
                )
                if status != noErr {
                    print("[VoiceAudioPipeline] Failed to set input device (status \(status)), using default")
                }
            } else {
                print("[VoiceAudioPipeline] Device UID '\(uid)' not found, using default")
            }
        }

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

            // Perform sample extraction on the audio thread — no allocations beyond the array.
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

            // RMS is cheap and allocation-free — compute inline so the audio-level
            // callback gets the freshest possible value without queuing latency.
            let rms = self.computeRMS(samples)

            // All state mutation and callback invocations happen off the audio thread.
            self.vadQueue.async {
                self.bufferManager.append(samples)
                self.processVAD(rms: rms, samples: samples)
            }
        }

        try engine.start()
        self.audioEngine = engine
        isRunning = true
    }

    func stop() {
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine?.stop()
        audioEngine = nil
        // Dispatch state reset onto vadQueue so any in-flight async block finishes first.
        vadQueue.async {
            self.bufferManager.clear()
            self.isSpeaking = false
            self.silenceStart = nil
            self.lastInterimEmit = nil
        }
        isRunning = false
    }

    func flushBuffer() {
        vadQueue.async {
            self.bufferManager.clear()
            self.isSpeaking = false
            self.silenceStart = nil
            self.lastInterimEmit = nil
        }
    }

    func trimBuffer(keepLastSeconds: Double) {
        vadQueue.async {
            self.bufferManager.trimToLast(seconds: keepLastSeconds)
        }
    }

    // MARK: - Private

    private func extractSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    /// Must be called only from `vadQueue`.
    private func processVAD(rms: Float, samples: [Float]) {
        let threshold = silenceThreshold

        DispatchQueue.main.async { [weak self] in
            self?.onAudioLevel?(rms, rms >= threshold)
        }

        if rms >= threshold {
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

    /// Must be called only from `vadQueue`.
    private func emitSpeechSegment() {
        let audio = bufferManager.getBuffer()
        bufferManager.clear()
        guard !audio.isEmpty else { return }
        onSpeechSegmentReady?(audio)
    }

    // MARK: - CoreAudio Helpers

    private static func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF: CFString = uid as CFString
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
