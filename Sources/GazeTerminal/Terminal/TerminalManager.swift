import AppKit
import Foundation

final class TerminalManager {

    // MARK: - State

    private(set) var isSetup = false

    /// Tracks the iTerm2 window index (1-based, newest = 1) for each quadrant.
    /// After setup the windows are ordered so that the first created has the highest index.
    private var windowIndices: [ScreenQuadrant: Int] = [:]

    // MARK: - Setup

    /// Launch iTerm2, create four windows positioned in screen quadrants, and run "cla" in each.
    func setupTerminals() async throws {
        guard !isSetup else { return }

        // Make sure iTerm2 is running.
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") else {
            throw TerminalError.iTermNotInstalled
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await NSWorkspace.shared.openApplication(at: url, configuration: config)

        // Small delay so iTerm2 finishes launching.
        try await Task.sleep(for: .seconds(1))

        // Count existing windows so we can track our new ones by ID.
        let countResult = try await AppleScriptBridge.runAsync("""
            tell application "iTerm2"
                count of windows
            end tell
        """)
        let existingWindowCount = Int(countResult ?? "0") ?? 0

        // Create one window per quadrant. We iterate in a fixed order and record each
        // window's index after all four are created.
        let orderedQuadrants: [ScreenQuadrant] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

        for quadrant in orderedQuadrants {
            let bounds = WindowLayout.boundsForQuadrant(quadrant)
            let script = """
                tell application "iTerm2"
                    create window with default profile
                    set bounds of current window to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}
                    tell current session of current window
                        write text "cla"
                    end tell
                end tell
            """
            try await AppleScriptBridge.runAsync(script)
            try await Task.sleep(for: .milliseconds(400))
        }

        // After creating 4 windows the most recently created window is index 1.
        // Existing windows are pushed to higher indices.
        // We created them in order: topLeft, topRight, bottomLeft, bottomRight
        // so bottomRight is newest (index 1) and topLeft is oldest (index 4).
        for (offset, quadrant) in orderedQuadrants.enumerated() {
            windowIndices[quadrant] = orderedQuadrants.count - offset
        }

        isSetup = true
    }

    // MARK: - Focus

    /// Bring the terminal window for the given quadrant to the front.
    func focusTerminal(quadrant: ScreenQuadrant) async throws {
        let index = try windowIndex(for: quadrant)
        let script = """
            tell application "iTerm2"
                activate
                select window \(index)
            end tell
        """
        try await AppleScriptBridge.runAsync(script)
    }

    // MARK: - Input

    /// Type arbitrary text into the terminal session for the given quadrant.
    func typeText(_ text: String, in quadrant: ScreenQuadrant) async throws {
        let index = try windowIndex(for: quadrant)
        let escaped = escapeForAppleScript(text)
        let script = """
            tell application "iTerm2"
                tell current session of window \(index)
                    write text "\(escaped)" without newline
                end tell
            end tell
        """
        try await AppleScriptBridge.runAsync(script)
    }

    /// Send an Enter keystroke to the terminal session for the given quadrant.
    func sendReturn(in quadrant: ScreenQuadrant) async throws {
        let index = try windowIndex(for: quadrant)
        let script = """
            tell application "iTerm2"
                tell current session of window \(index)
                    write text ""
                end tell
            end tell
        """
        try await AppleScriptBridge.runAsync(script)
    }

    // MARK: - Teardown

    /// Close only the managed eyeTerm windows, leaving user windows untouched.
    func tearDown() async throws {
        guard isSetup else { return }

        // Close in reverse index order (highest first) so indices stay valid.
        let sorted = windowIndices.values.sorted(by: >)
        for index in sorted {
            try? await AppleScriptBridge.runAsync("""
                tell application "iTerm2"
                    close window \(index)
                end tell
            """)
        }

        windowIndices.removeAll()
        isSetup = false
    }

    // MARK: - Helpers

    private func windowIndex(for quadrant: ScreenQuadrant) throws -> Int {
        guard let index = windowIndices[quadrant] else {
            throw TerminalError.windowNotFound(quadrant)
        }
        return index
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
    case iTermNotInstalled
    case windowNotFound(ScreenQuadrant)

    var errorDescription: String? {
        switch self {
        case .iTermNotInstalled:
            return "iTerm2 is not installed. Please install it from https://iterm2.com"
        case .windowNotFound(let quadrant):
            return "No managed terminal window found for \(quadrant.displayName)"
        }
    }
}
