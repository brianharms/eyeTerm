import Foundation

enum ParsedCommand: Equatable {
    case typeText(String)
    case execute
}

final class CommandParser {
    var enableNormalization: Bool = true
    var executeKeyword: String = "run it"

    /// Regex that matches text inside square brackets or parentheses (e.g. [inaudible], (silence)).
    private static let bracketedPattern = try! NSRegularExpression(pattern: "\\[.*?\\]|\\(.*?\\)", options: [])

    private static let windowActionPhrases: [String: WindowAction] = [
        "close it": .close,
        "close the window": .close,
        "close window": .close,
        "close this": .close,
        "dismiss": .close,
        "dismiss it": .close,
        "minimize": .minimize,
        "minimize it": .minimize,
        "minimize the window": .minimize,
        "hide it": .hide,
        "hide the window": .hide,
        "hide": .hide,
        "go back": .goBack,
        "back": .goBack,
        "go forward": .goForward,
        "forward": .goForward,
        "reload": .reload,
        "reload the page": .reload,
        "refresh": .reload,
        "refresh the page": .reload,
    ]

    func detectWindowAction(_ text: String) -> WindowAction? {
        let cleaned = stripBracketedText(text)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Self.windowActionPhrases[cleaned]
    }

    private func stripBracketedText(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return Self.bracketedPattern
            .stringByReplacingMatches(in: text, range: range, withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let normalizations: [(pattern: String, replacement: String)] = [
        ("at sign", "@"),
        ("backslash", "\\"),
        ("asterisk", "*"),
        ("hashtag", "#"),
        ("underscore", "_"),
        ("hyphen", "-"),
        ("period", "."),
        ("equals", "="),
        ("tilde", "~"),
        ("slash", "/"),
        ("space", " "),
        ("pipe", "|"),
        ("star", "*"),
        ("dash", "-"),
        ("dot", "."),
        ("hash", "#"),
        ("pound", "#"),
    ]

    func parse(_ transcription: String) -> [ParsedCommand] {
        let cleaned = stripBracketedText(transcription)
        guard !cleaned.isEmpty else { return [] }
        let words = executeKeyword
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }

        let pattern = words.joined(separator: "\\s+")
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: "\\b\(pattern)\\b", options: .caseInsensitive) else {
            return processText(cleaned)
        }

        let nsString = cleaned as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: cleaned, range: fullRange)

        if matches.isEmpty {
            return processText(cleaned)
        }

        var commands: [ParsedCommand] = []
        var currentIndex = 0

        for match in matches {
            let matchRange = match.range
            if matchRange.location > currentIndex {
                let textRange = NSRange(location: currentIndex, length: matchRange.location - currentIndex)
                let segment = nsString.substring(with: textRange)
                commands.append(contentsOf: processText(segment))
            }
            commands.append(.execute)
            currentIndex = matchRange.location + matchRange.length
        }

        if currentIndex < nsString.length {
            let remaining = nsString.substring(from: currentIndex)
            commands.append(contentsOf: processText(remaining))
        }

        return commands
    }

    func normalizeOnly(_ text: String) -> String {
        let cleaned = stripBracketedText(text)
        guard !cleaned.isEmpty else { return "" }
        guard enableNormalization else {
            return cleaned
        }
        var result = cleaned
        for (pattern, replacement) in Self.normalizations {
            let escaped = NSRegularExpression.escapedPattern(for: pattern)
            if let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive) {
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func processText(_ text: String) -> [ParsedCommand] {
        var result = text
        if enableNormalization {
            for (pattern, replacement) in Self.normalizations {
                let escaped = NSRegularExpression.escapedPattern(for: pattern)
                if let regex = try? NSRegularExpression(pattern: "\\b\(escaped)\\b", options: .caseInsensitive) {
                    let range = NSRange(location: 0, length: (result as NSString).length)
                    result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
                }
            }
        }
        let trimmed = result.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            return []
        }
        return [.typeText(trimmed)]
    }
}
