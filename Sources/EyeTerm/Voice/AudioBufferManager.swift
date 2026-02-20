import Foundation

final class AudioBufferManager {
    private let maxSampleCount: Int
    private let sampleRate: Double
    private var buffer: [Float] = []
    private let lock = NSLock()

    init(maxDurationSeconds: Double = 30.0, sampleRate: Double = 16000.0) {
        self.sampleRate = sampleRate
        self.maxSampleCount = Int(maxDurationSeconds * sampleRate)
    }

    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: samples)
        if buffer.count > maxSampleCount {
            buffer.removeFirst(buffer.count - maxSampleCount)
        }
    }

    func getBuffer() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        buffer.removeAll(keepingCapacity: true)
    }

    var durationSeconds: Double {
        lock.lock()
        defer { lock.unlock() }
        return Double(buffer.count) / sampleRate
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.isEmpty
    }
}
