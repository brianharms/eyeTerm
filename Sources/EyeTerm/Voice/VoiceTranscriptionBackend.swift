import Foundation

enum VoiceBackend: String, CaseIterable, Identifiable {
    case sfSpeech = "Apple Dictation"
    case whisperKit = "WhisperKit"

    var id: String { rawValue }
}

protocol VoiceTranscriptionBackend: AnyObject {
    var isRunning: Bool { get }
    var onTranscription: ((String) -> Void)? { get set }
    var onPartialTranscription: ((String) -> Void)? { get set }
    var onAudioLevel: ((Float, Bool) -> Void)? { get set }
    var onModelState: ((VoiceModelState) -> Void)? { get set }
    var modelName: String { get set }
    var silenceThreshold: Float { get set }
    var inputDeviceUID: String? { get set }
    func start() async throws
    func stop()
    func flushAudio()
    func trimAudio(keepLastSeconds: Double)
}

enum VoiceModelState {
    case idle
    case loading
    case ready
    case failed(String)
}

enum VoiceEngineError: LocalizedError {
    case microphoneUnavailable
    case speechRecognitionDenied
    case modelInitializationFailed(Error)
    case audioFormatError

    var errorDescription: String? {
        switch self {
        case .microphoneUnavailable:
            return "Microphone access is required for voice input."
        case .speechRecognitionDenied:
            return "Speech Recognition permission denied. Go to System Settings → Privacy & Security → Speech Recognition and enable eyeTerm."
        case .modelInitializationFailed(let error):
            return "Failed to initialize voice model: \(error.localizedDescription)"
        case .audioFormatError:
            return "Could not configure audio format for recording."
        }
    }
}
