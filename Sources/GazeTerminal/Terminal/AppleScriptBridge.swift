import Foundation

enum AppleScriptError: LocalizedError {
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .executionFailed(let message):
            return "AppleScript error: \(message)"
        }
    }
}

enum AppleScriptBridge {

    /// Execute an AppleScript synchronously and return the string result (if any).
    static func run(_ source: String) throws -> String? {
        let script = NSAppleScript(source: source)
        var errorInfo: NSDictionary?
        let result = script?.executeAndReturnError(&errorInfo)

        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String
                ?? "Unknown AppleScript error"
            throw AppleScriptError.executionFailed(message)
        }

        return result?.stringValue
    }

    /// Execute an AppleScript asynchronously, off the main actor.
    static func runAsync(_ source: String) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let value = try run(source)
                    continuation.resume(returning: value)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
