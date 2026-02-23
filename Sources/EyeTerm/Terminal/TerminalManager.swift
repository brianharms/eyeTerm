import AppKit
import Foundation

enum PreferredTerminal: String, CaseIterable, Identifiable {
    case iTerm2 = "iTerm2"
    case terminal = "Terminal"

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .iTerm2: return "com.googlecode.iterm2"
        case .terminal: return "com.apple.Terminal"
        }
    }

    var appName: String {
        switch self {
        case .iTerm2: return "iTerm2"
        case .terminal: return "Terminal"
        }
    }
}

final class TerminalManager {

    // MARK: - State

    private(set) var isSetup = false
    var preferredTerminal: PreferredTerminal = .iTerm2
    var launchCommand: String = "claude --dangerously-skip-permissions"

    /// Tracks the window index (1-based, newest = 1) for each quadrant.
    /// After setup the windows are ordered so that the first created has the highest index.
    private var windowIndices: [ScreenQuadrant: Int] = [:]

    /// Cache for findWindowIndex results to avoid a fresh AppleScript scan on every keystroke.
    private var cachedWindowIndex: [ScreenQuadrant: Int] = [:]

    // MARK: - Setup

    /// Launch the preferred terminal, create four windows positioned in screen quadrants, and run the launch command in each.
    func setupTerminals() async throws {
        // Allow re-launch if windows were manually closed
        isSetup = false
        windowIndices.removeAll()
        cachedWindowIndex.removeAll()

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredTerminal.bundleIdentifier) else {
            throw TerminalError.terminalNotInstalled(preferredTerminal)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await NSWorkspace.shared.openApplication(at: url, configuration: config)

        try await Task.sleep(for: .seconds(1))

        let orderedQuadrants: [ScreenQuadrant] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

        switch preferredTerminal {
        case .iTerm2:
            try await setupITerm2(quadrants: orderedQuadrants)
        case .terminal:
            try await setupAppleTerminal(quadrants: orderedQuadrants)
        }

        for (offset, quadrant) in orderedQuadrants.enumerated() {
            windowIndices[quadrant] = orderedQuadrants.count - offset
        }

        isSetup = true
    }

    private func setupITerm2(quadrants: [ScreenQuadrant]) async throws {
        let escapedCmd = escapeForAppleScript(launchCommand)
        for quadrant in quadrants {
            let bounds = WindowLayout.boundsForQuadrant(quadrant)
            let script = """
                tell application "iTerm2"
                    create window with default profile
                    set bounds of current window to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}
                    tell current session of current window
                        write text "\(escapedCmd)"
                    end tell
                end tell
            """
            try await AppleScriptBridge.runAsync(script)
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    private func setupAppleTerminal(quadrants: [ScreenQuadrant]) async throws {
        let escapedCmd = escapeForAppleScript(launchCommand)
        for quadrant in quadrants {
            let bounds = WindowLayout.boundsForQuadrant(quadrant)
            let script = """
                tell application "Terminal"
                    do script "\(escapedCmd)"
                    set bounds of front window to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}
                end tell
            """
            try await AppleScriptBridge.runAsync(script)
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    /// Adopt existing terminal windows by scanning for windows already positioned in each quadrant.
    func adoptTerminals() async throws {
        isSetup = false
        windowIndices.removeAll()
        cachedWindowIndex.removeAll()

        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredTerminal.bundleIdentifier) != nil else {
            throw TerminalError.terminalNotInstalled(preferredTerminal)
        }

        let orderedQuadrants: [ScreenQuadrant] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
        var adopted = 0

        for quadrant in orderedQuadrants {
            do {
                let index = try await findWindowIndex(for: quadrant)
                windowIndices[quadrant] = index
                adopted += 1
            } catch {
                print("[TerminalManager] No window found for \(quadrant.displayName) — skipping")
            }
        }

        guard adopted > 0 else {
            throw TerminalError.noWindowsToAdopt
        }

        print("[TerminalManager] Adopted \(adopted)/4 terminal windows")
        isSetup = true
    }

    // MARK: - Focus

    /// Bring the terminal window for the given quadrant to the front by matching screen position.
    func focusTerminal(quadrant: ScreenQuadrant) async throws {
        // Try the cached index first; fall back to a fresh scan if it fails.
        let index: Int
        if let cached = cachedWindowIndex[quadrant] {
            index = cached
        } else {
            let fresh = try await findWindowIndex(for: quadrant)
            cachedWindowIndex[quadrant] = fresh
            index = fresh
        }

        let app = preferredTerminal.appName
        let focusScript: String
        switch preferredTerminal {
        case .iTerm2:
            focusScript = """
                tell application "\(app)"
                    activate
                    set index of window \(index) to 1
                end tell
            """
        case .terminal:
            focusScript = """
                tell application "\(app)"
                    activate
                    set index of window \(index) to 1
                end tell
            """
        }
        try await AppleScriptBridge.runAsync(focusScript)
    }

    // MARK: - Input

    /// Type arbitrary text into the terminal session for the given quadrant.
    func typeText(_ text: String, in quadrant: ScreenQuadrant) async throws {
        let index = try await cachedIndex(for: quadrant)
        let escaped = escapeForAppleScript(text)
        let app = preferredTerminal.appName
        let script: String
        switch preferredTerminal {
        case .iTerm2:
            script = """
                tell application "\(app)"
                    tell current session of window \(index)
                        write text "\(escaped)" without newline
                    end tell
                end tell
            """
        case .terminal:
            script = """
                tell application "System Events"
                    tell process "Terminal"
                        keystroke "\(escaped)"
                    end tell
                end tell
            """
        }
        try await AppleScriptBridge.runAsync(script)
    }

    /// Send N backspace keystrokes to the terminal session for the given quadrant.
    func sendBackspaces(_ count: Int, in quadrant: ScreenQuadrant) async throws {
        guard count > 0 else { return }
        let index = try await cachedIndex(for: quadrant)
        let app = preferredTerminal.appName
        let script: String
        switch preferredTerminal {
        case .iTerm2:
            // Use AppleScript to build a string of DEL (character id 127) and write it in one call
            script = """
                tell application "\(app)"
                    set delStr to ""
                    repeat \(count) times
                        set delStr to delStr & (character id 127)
                    end repeat
                    tell current session of window \(index)
                        write text delStr without newline
                    end tell
                end tell
            """
        case .terminal:
            script = """
                tell application "System Events"
                    repeat \(count) times
                        key code 51
                    end repeat
                end tell
            """
        }
        try await AppleScriptBridge.runAsync(script)
    }

    /// Send an Escape keystroke to the terminal session for the given quadrant.
    func sendEscape(in quadrant: ScreenQuadrant) async throws {
        let index = try await cachedIndex(for: quadrant)
        let app = preferredTerminal.appName
        let script: String
        switch preferredTerminal {
        case .iTerm2:
            script = """
                tell application "\(app)"
                    tell current session of window \(index)
                        write text (character id 27) without newline
                    end tell
                end tell
            """
        case .terminal:
            script = """
                tell application "System Events"
                    key code 53
                end tell
            """
        }
        try await AppleScriptBridge.runAsync(script)
    }

    /// Send two Escape keystrokes to the terminal session for the given quadrant.
    func sendDoubleEscape(in quadrant: ScreenQuadrant) async throws {
        try await sendEscape(in: quadrant)
        try await Task.sleep(for: .milliseconds(50))
        try await sendEscape(in: quadrant)
    }

    /// Send an Enter keystroke to the terminal session for the given quadrant.
    func sendReturn(in quadrant: ScreenQuadrant) async throws {
        let index = try await cachedIndex(for: quadrant)
        let app = preferredTerminal.appName
        let script: String
        switch preferredTerminal {
        case .iTerm2:
            script = """
                tell application "\(app)"
                    tell current session of window \(index)
                        write text ""
                    end tell
                end tell
            """
        case .terminal:
            script = """
                tell application "\(app)"
                    do script "" in window \(index)
                end tell
            """
        }
        try await AppleScriptBridge.runAsync(script)
    }

    // MARK: - Teardown

    /// Close only the managed eyeTerm windows, leaving user windows untouched.
    func tearDown() async throws {
        guard isSetup else { return }

        let app = preferredTerminal.appName
        let sorted = windowIndices.values.sorted(by: >)
        for index in sorted {
            try? await AppleScriptBridge.runAsync("""
                tell application "\(app)"
                    close window \(index)
                end tell
            """)
        }

        windowIndices.removeAll()
        cachedWindowIndex.removeAll()
        isSetup = false
    }

    // MARK: - Helpers

    /// Return the cached window index for a quadrant, running a fresh scan only on a cache miss.
    private func cachedIndex(for quadrant: ScreenQuadrant) async throws -> Int {
        if let cached = cachedWindowIndex[quadrant] {
            return cached
        }
        let index = try await findWindowIndex(for: quadrant)
        cachedWindowIndex[quadrant] = index
        return index
    }

    /// Find the terminal window whose screen position is closest to the target quadrant.
    private func findWindowIndex(for quadrant: ScreenQuadrant) async throws -> Int {
        let app = preferredTerminal.appName
        let target = WindowLayout.boundsForQuadrant(quadrant)
        let targetMidX = (target.left + target.right) / 2
        let targetMidY = (target.top + target.bottom) / 2

        let findScript = """
            tell application "\(app)"
                set windowInfo to ""
                repeat with w in windows
                    set b to bounds of w
                    set windowInfo to windowInfo & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text) & "|"
                end repeat
                return windowInfo
            end tell
        """
        guard let result = try await AppleScriptBridge.runAsync(findScript), !result.isEmpty else {
            throw TerminalError.windowNotFound(quadrant)
        }

        let entries = result.components(separatedBy: "|").filter { !$0.isEmpty }
        var bestIndex = 0
        var bestDistance = Int.max
        for (i, entry) in entries.enumerated() {
            let parts = entry.components(separatedBy: ",")
            guard parts.count == 4,
                  let l = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                  let t = Int(parts[1].trimmingCharacters(in: .whitespaces)),
                  let r = Int(parts[2].trimmingCharacters(in: .whitespaces)),
                  let b = Int(parts[3].trimmingCharacters(in: .whitespaces)) else { continue }
            let midX = (l + r) / 2
            let midY = (t + b) / 2
            let dist = abs(midX - targetMidX) + abs(midY - targetMidY)
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = i + 1  // AppleScript windows are 1-indexed
            }
        }

        guard bestIndex > 0 else {
            throw TerminalError.windowNotFound(quadrant)
        }
        return bestIndex
    }

    /// Escape backslashes and double-quotes so the string is safe inside an AppleScript literal.
    private func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Errors

enum TerminalError: LocalizedError {
    case terminalNotInstalled(PreferredTerminal)
    case windowNotFound(ScreenQuadrant)
    case noWindowsToAdopt

    var errorDescription: String? {
        switch self {
        case .terminalNotInstalled(let terminal):
            return "\(terminal.rawValue) is not installed."
        case .windowNotFound(let quadrant):
            return "No managed terminal window found for \(quadrant.displayName)"
        case .noWindowsToAdopt:
            return "No existing terminal windows found to adopt. Open terminal windows and position them in screen quadrants first."
        }
    }
}
