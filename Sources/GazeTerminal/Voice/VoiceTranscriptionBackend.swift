import Foundation

enum VoiceBackend: String, CaseIterable, Identifiable {
    case whisperKit = "WhisperKit"
    case whisperCpp = "whisper.cpp"

    var id: String { rawValue }
}

protocol VoiceTranscriptionBackend: AnyObject {
    var isRunning: Bool { get }
    var onTranscription: ((String) -> Void)? { get set }
    var onAudioLevel: ((Float, Bool) -> Void)? { get set }
    var onModelState: ((VoiceModelState) -> Void)? { get set }
    var modelName: String { get set }
    var silenceThreshold: Float { get set }
    func start() async throws
    func stop()
}

enum VoiceModelState {
    case idle
    case loading
    case ready
    case failed(String)
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
            return "Failed to initialize voice model: \(error.localizedDescription)"
        case .audioFormatError:
            return "Could not configure audio format for recording."
        }
    }
}
