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

    /// Tracks the AppleScript window index (1-based) for each slot index.
    private var windowIndices: [Int: Int] = [:]

    /// Cache for findWindowIndex results (invalidated on each focus operation).
    private var cachedWindowIndex: [Int: Int] = [:]

    // MARK: - Setup

    /// Launch the preferred terminal, create cols×rows windows tiled across the screen, and run the launch command in each.
    func setupTerminals(cols: Int = 2, rows: Int = 2, appState: AppState? = nil) async throws {
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

        let count = cols * rows
        var slots: [TerminalSlot] = []

        switch preferredTerminal {
        case .iTerm2:
            try await setupITerm2(count: count, cols: cols, rows: rows)
        case .terminal:
            try await setupAppleTerminal(count: count, cols: cols, rows: rows)
        }

        for i in 0..<count {
            // Windows are created oldest-first; newest = index 1
            windowIndices[i] = count - i
            let normRect = WindowLayout.normalizedRect(slotIndex: i, cols: cols, rows: rows)
            slots.append(TerminalSlot(id: i, normalizedRect: normRect, label: "\(i + 1)"))
        }

        if let appState = appState {
            await MainActor.run {
                appState.terminalSlots = slots
            }
        }

        isSetup = true
    }

    private func setupITerm2(count: Int, cols: Int, rows: Int) async throws {
        let escapedCmd = escapeForAppleScript(launchCommand)
        for i in 0..<count {
            let bounds = WindowLayout.boundsForSlot(slotIndex: i, cols: cols, rows: rows)
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

    private func setupAppleTerminal(count: Int, cols: Int, rows: Int) async throws {
        let escapedCmd = escapeForAppleScript(launchCommand)
        for i in 0..<count {
            let bounds = WindowLayout.boundsForSlot(slotIndex: i, cols: cols, rows: rows)
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

    /// Adopt ALL existing terminal windows. Each window becomes one slot.
    func adoptTerminals(appState: AppState? = nil) async throws {
        isSetup = false
        windowIndices.removeAll()
        cachedWindowIndex.removeAll()

        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredTerminal.bundleIdentifier) != nil else {
            throw TerminalError.terminalNotInstalled(preferredTerminal)
        }

        let app = preferredTerminal.appName
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

        guard let result = try? await AppleScriptBridge.runAsync(findScript), !result.isEmpty else {
            throw TerminalError.noWindowsToAdopt
        }

        let entries = result.components(separatedBy: "|").filter { !$0.isEmpty }
        guard !entries.isEmpty else { throw TerminalError.noWindowsToAdopt }

        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame

        var slots: [TerminalSlot] = []
        for (i, entry) in entries.enumerated() {
            let parts = entry.components(separatedBy: ",")
            guard parts.count == 4,
                  let l = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let t = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  let r2 = Double(parts[2].trimmingCharacters(in: .whitespaces)),
                  let b = Double(parts[3].trimmingCharacters(in: .whitespaces)) else { continue }

            // Convert AppleScript pixel coords to normalized (0–1) fractions
            let normX = l / screenFrame.width
            let normW = (r2 - l) / screenFrame.width
            // AppleScript top is distance from screen top; convert to normalized y (0=top)
            let normY = t / screenFrame.height
            let normH = (b - t) / screenFrame.height
            let normRect = CGRect(x: normX, y: normY, width: normW, height: normH)

            windowIndices[i] = i + 1  // front-to-back: window 1 is frontmost
            slots.append(TerminalSlot(id: i, normalizedRect: normRect, label: "\(i + 1)"))
        }

        guard !slots.isEmpty else { throw TerminalError.noWindowsToAdopt }

        if let appState = appState {
            await MainActor.run {
                appState.terminalSlots = slots
            }
        }

        print("[TerminalManager] Adopted \(slots.count) terminal windows")
        isSetup = true
    }

    // MARK: - Focus

    func focusTerminal(slotIndex: Int) async throws {
        let index = try await findWindowIndex(for: slotIndex)
        cachedWindowIndex.removeAll()
        cachedWindowIndex[slotIndex] = 1

        let app = preferredTerminal.appName
        let focusScript = """
            tell application "\(app)"
                activate
                set index of window \(index) to 1
            end tell
        """
        try await AppleScriptBridge.runAsync(focusScript)
    }

    // MARK: - Input

    func typeText(_ text: String, in slotIndex: Int) async throws {
        let index = try await cachedIndex(for: slotIndex)
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

    func sendBackspaces(_ count: Int, in slotIndex: Int) async throws {
        guard count > 0 else { return }
        let index = try await cachedIndex(for: slotIndex)
        let app = preferredTerminal.appName
        let script: String
        switch preferredTerminal {
        case .iTerm2:
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

    func sendEscape(in slotIndex: Int) async throws {
        let index = try await cachedIndex(for: slotIndex)
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

    func sendDoubleEscape(in slotIndex: Int) async throws {
        try await sendEscape(in: slotIndex)
        try await Task.sleep(for: .milliseconds(50))
        try await sendEscape(in: slotIndex)
    }

    func sendReturn(in slotIndex: Int) async throws {
        let index = try await cachedIndex(for: slotIndex)
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

    private func cachedIndex(for slotIndex: Int) async throws -> Int {
        if let cached = cachedWindowIndex[slotIndex] { return cached }
        let index = try await findWindowIndex(for: slotIndex)
        cachedWindowIndex[slotIndex] = index
        return index
    }

    /// Find the terminal window whose screen position is closest to the given slot index's stored rect.
    private func findWindowIndex(for slotIndex: Int) async throws -> Int {
        let app = preferredTerminal.appName
        let screen = NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = screen.frame

        // If we have a stored window index from setup, use its position as target
        // Otherwise fall back to a full scan
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
            throw TerminalError.windowNotFound(slotIndex)
        }

        // If we know this slot's window index directly (from setup), use it
        if let knownIndex = windowIndices[slotIndex] {
            let entries = result.components(separatedBy: "|").filter { !$0.isEmpty }
            if knownIndex <= entries.count { return knownIndex }
        }

        // Fall back: find window whose midpoint is closest to the slot's normalized rect center
        // We need the slot rects — stored in windowIndices as a position hint
        // Use the normalized rect center to find the best match
        let targetNormX = 0.5 // default to screen center if no slot info
        let targetNormY = 0.5

        let entries = result.components(separatedBy: "|").filter { !$0.isEmpty }
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude

        let targetMidX = targetNormX * screenFrame.width
        let targetMidY = targetNormY * screenFrame.height

        for (i, entry) in entries.enumerated() {
            let parts = entry.components(separatedBy: ",")
            guard parts.count == 4,
                  let l = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let t = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  let r = Double(parts[2].trimmingCharacters(in: .whitespaces)),
                  let b = Double(parts[3].trimmingCharacters(in: .whitespaces)) else { continue }
            let midX = (l + r) / 2
            let midY = (t + b) / 2
            let dist = abs(midX - targetMidX) + abs(midY - targetMidY)
            if dist < bestDistance {
                bestDistance = dist
                bestIndex = i + 1
            }
        }

        guard bestIndex > 0 else { throw TerminalError.windowNotFound(slotIndex) }
        return bestIndex
    }

    private func escapeForAppleScript(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - Errors

enum TerminalError: LocalizedError {
    case terminalNotInstalled(PreferredTerminal)
    case windowNotFound(Int)
    case noWindowsToAdopt

    var errorDescription: String? {
        switch self {
        case .terminalNotInstalled(let terminal):
            return "\(terminal.rawValue) is not installed."
        case .windowNotFound(let slotIndex):
            return "No managed terminal window found for slot \(slotIndex + 1)"
        case .noWindowsToAdopt:
            return "No existing terminal windows found to adopt. Open terminal windows first."
        }
    }
}
