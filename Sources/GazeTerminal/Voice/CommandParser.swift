import Foundation

enum ParsedCommand: Equatable {
    case typeText(String)
    case execute
}

final class CommandParser {
    var enableNormalization: Bool = true
    var executeKeyword: String = "run it"

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
        ("at", "@"),
    ]

    func parse(_ transcription: String) -> [ParsedCommand] {
        let words = executeKeyword
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }
            .map { NSRegularExpression.escapedPattern(for: $0) }

        let pattern = words.joined(separator: "\\s+")
        guard !pattern.isEmpty,
              let regex = try? NSRegularExpression(pattern: "\\b\(pattern)\\b", options: .caseInsensitive) else {
            return processText(transcription)
        }

        let nsString = transcription as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)
        let matches = regex.matches(in: transcription, range: fullRange)

        if matches.isEmpty {
            return processText(transcription)
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
