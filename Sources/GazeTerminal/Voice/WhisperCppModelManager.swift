import Foundation

final class WhisperCppModelManager {
    static let shared = WhisperCppModelManager()

    private let modelsDirectory: URL
    private var downloadTasks: [String: Task<URL, Error>] = [:]

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        modelsDirectory = appSupport.appendingPathComponent("eyeTerm/models", isDirectory: true)
    }

    func modelPath(for modelName: String) async throws -> URL {
        let fileName = "ggml-\(modelName).bin"

        // Check app bundle first
        if let bundledURL = Bundle.main.url(forResource: fileName, withExtension: nil, subdirectory: "Models/ggml") {
            print("[WhisperCppModelManager] Using bundled model: \(fileName)")
            return bundledURL
        }

        let localURL = modelsDirectory.appendingPathComponent(fileName)

        if FileManager.default.fileExists(atPath: localURL.path) {
            print("[WhisperCppModelManager] Model already cached: \(fileName)")
            return localURL
        }

        if let existing = downloadTasks[modelName] {
            return try await existing.value
        }

        let task = Task<URL, Error> {
            try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)

            let remoteURL = URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")!
            print("[WhisperCppModelManager] Downloading \(fileName) from \(remoteURL)...")

            let (tempURL, response) = try await URLSession.shared.download(from: remoteURL)

            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
                throw WhisperCppModelError.downloadFailed(fileName)
            }

            try FileManager.default.moveItem(at: tempURL, to: localURL)
            print("[WhisperCppModelManager] Downloaded \(fileName) successfully")
            return localURL
        }

        downloadTasks[modelName] = task

        do {
            let result = try await task.value
            downloadTasks[modelName] = nil
            return result
        } catch {
            downloadTasks[modelName] = nil
            throw error
        }
    }
}

enum WhisperCppModelError: LocalizedError {
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let name):
            return "Failed to download whisper.cpp model: \(name)"
        }
    }
}
