import Foundation

enum TranscriptionEdit {
    case noChange
    case append(String)
    case replaceFromOffset(backspaces: Int, newText: String)
}

final class StreamingTranscriptionDiffer {
    private(set) var committedText: String = ""

    func diff(newText: String) -> TranscriptionEdit {
        guard newText != committedText else { return .noChange }

        let prefix = committedText.commonPrefix(with: newText)

        let oldSuffix = String(committedText.dropFirst(prefix.count))
        let newSuffix = String(newText.dropFirst(prefix.count))

        if oldSuffix.isEmpty {
            // Pure append
            guard !newSuffix.isEmpty else { return .noChange }
            committedText = newText
            return .append(newSuffix)
        } else {
            // Need to backspace the old suffix and type the new one
            committedText = newText
            return .replaceFromOffset(backspaces: oldSuffix.count, newText: newSuffix)
        }
    }

    func finalize(finalText: String) -> TranscriptionEdit {
        return diff(newText: finalText)
    }

    func reset() {
        committedText = ""
    }
}
