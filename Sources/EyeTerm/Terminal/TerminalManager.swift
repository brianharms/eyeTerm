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

    /// Normalized screen rect for each slot — used for position-based window matching.
    private var slotNormRects: [Int: CGRect] = [:]

    /// Cache for findWindowIndex results (invalidated on each focus operation).
    private var cachedWindowIndex: [Int: Int] = [:]

    /// iTerm2 session unique IDs per slot — bypasses window-index matching for input delivery.
    private var iTermSessionIDs: [Int: String] = [:]

    /// iTerm2 window IDs per slot — used to rename the title bar after Claude overrides it.
    private var iTermWindowIDs: [Int: Int] = [:]

    /// The screen terminals are on — set during setup/adopt, used for position matching.
    private var activeScreen: NSScreen = NSScreen.main ?? NSScreen.screens[0]

    // MARK: - Setup

    /// Launch the preferred terminal, create cols×rows windows tiled across the screen, and run the launch command in each.
    func setupTerminals(cols: Int = 2, rows: Int = 2, appState: AppState? = nil, screen: NSScreen? = nil) async throws {
        isSetup = false
        windowIndices.removeAll()
        cachedWindowIndex.removeAll()
        iTermSessionIDs.removeAll()
        iTermWindowIDs.removeAll()
        slotNormRects.removeAll()
        if let screen { activeScreen = screen }

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
            try await setupITerm2(count: count, cols: cols, rows: rows, screen: screen)
        case .terminal:
            try await setupAppleTerminal(count: count, cols: cols, rows: rows, screen: screen)
        }

        for i in 0..<count {
            // Windows are created oldest-first; newest = index 1
            windowIndices[i] = count - i
            let normRect = WindowLayout.normalizedRect(slotIndex: i, cols: cols, rows: rows)
            slotNormRects[i] = normRect
            slots.append(TerminalSlot(id: i, normalizedRect: normRect, label: "\(i + 1)"))
        }

        if let appState = appState {
            await MainActor.run {
                appState.terminalSlots = slots
            }
        }

        isSetup = true
    }

    private func setupITerm2(count: Int, cols: Int, rows: Int, screen: NSScreen? = nil) async throws {
        let escapedCmd = escapeForAppleScript(launchCommand)
        for i in 0..<count {
            let bounds = WindowLayout.boundsForSlot(slotIndex: i, cols: cols, rows: rows, screen: screen)
            let script = """
                tell application "iTerm2"
                    create window with default profile
                    set bounds of current window to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}
                    set sid to unique id of current session of current window
                    tell current session of current window
                        write text "\(escapedCmd)"
                    end tell
                    return sid
                end tell
            """
            if let sid = try await AppleScriptBridge.runAsync(script) {
                iTermSessionIDs[i] = sid.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            try await Task.sleep(for: .milliseconds(400))
        }
    }

    private func setupAppleTerminal(count: Int, cols: Int, rows: Int, screen: NSScreen? = nil) async throws {
        let escapedCmd = escapeForAppleScript(launchCommand)
        for i in 0..<count {
            let bounds = WindowLayout.boundsForSlot(slotIndex: i, cols: cols, rows: rows, screen: screen)
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

    /// Launch terminal windows for each project folder, cd into the folder, run the launch command, then send a shared initial prompt.
    func setupProjectTerminals(projectURLs: [URL], initialPrompt: String, initialPromptStagger: Double = 20.0, renameToProjectName: Bool = true, appState: AppState? = nil, screen: NSScreen? = nil) async throws {
        isSetup = false
        windowIndices.removeAll()
        cachedWindowIndex.removeAll()
        iTermSessionIDs.removeAll()
        iTermWindowIDs.removeAll()
        slotNormRects.removeAll()
        if let screen { activeScreen = screen }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredTerminal.bundleIdentifier) else {
            throw TerminalError.terminalNotInstalled(preferredTerminal)
        }

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        try await NSWorkspace.shared.openApplication(at: url, configuration: config)
        try await Task.sleep(for: .seconds(1))

        let count = min(projectURLs.count, 12)
        let normRects = WindowLayout.projectSlotLayouts(count: count)
        var slots: [TerminalSlot] = []

        for i in 0..<count {
            let projectURL = projectURLs[i]
            let escapedPath = escapeForAppleScript(projectURL.path)
            let escapedCmd = escapeForAppleScript(launchCommand)
            let fullCmd = "cd \\\"\(escapedPath)\\\" && \(escapedCmd)"

            let normRect = normRects[i]
            let bounds = WindowLayout.boundsForProjectSlot(normalizedRect: normRect, screen: screen)

            switch preferredTerminal {
            case .iTerm2:
                let script = """
                    tell application "iTerm2"
                        create window with default profile
                        set bounds of current window to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}
                        set wid to id of current window
                        set sid to unique id of current session of current window
                        tell current session of current window
                            write text "\(fullCmd)"
                        end tell
                        return (wid as text) & "|" & sid
                    end tell
                """
                if let result = try await AppleScriptBridge.runAsync(script) {
                    let parts = result.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "|")
                    if parts.count >= 2 {
                        if let wid = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                            iTermWindowIDs[i] = wid
                        }
                        let cleanSID = parts[1].trimmingCharacters(in: .whitespaces)
                        iTermSessionIDs[i] = cleanSID
                    }
                }
            case .terminal:
                let script = """
                    tell application "Terminal"
                        do script "\(fullCmd)"
                        set bounds of front window to {\(bounds.left), \(bounds.top), \(bounds.right), \(bounds.bottom)}
                    end tell
                """
                try await AppleScriptBridge.runAsync(script)
            }

            try await Task.sleep(for: .milliseconds(400))
            slotNormRects[i] = normRect
            slots.append(TerminalSlot(id: i, normalizedRect: normRect, label: projectURL.lastPathComponent))
        }

        // Windows created oldest-first; newest = index 1
        for i in 0..<count {
            windowIndices[i] = count - i
        }

        if let appState = appState {
            await MainActor.run {
                appState.terminalSlots = slots
            }
        }

        isSetup = true

        // After Claude starts and sets its own title, rename sessions + windows back to project names.
        if renameToProjectName || !initialPrompt.isEmpty {
            try await Task.sleep(for: .seconds(4))

            if renameToProjectName {
                for i in 0..<count {
                    let name = escapeForAppleScript(projectURLs[i].lastPathComponent)
                    if let wid = iTermWindowIDs[i] {
                        try? await AppleScriptBridge.runAsync("""
                            tell application "iTerm2"
                                tell window id \(wid) to select
                            end tell
                            delay 0.4
                            tell application "System Events"
                                tell process "iTerm2"
                                    keystroke "i" using {command down}
                                    delay 0.9
                                    key code 48
                                    key code 48
                                    key code 48
                                    keystroke "a" using {command down}
                                    keystroke "\(name)"
                                    key code 36
                                    delay 0.3
                                    keystroke "w" using {command down}
                                    delay 0.3
                                end tell
                            end tell
                        """)
                    }
                }
            }

            if !initialPrompt.isEmpty {
                for i in 0..<count {
                    try? await typeText(initialPrompt, in: i)
                    try await Task.sleep(for: .milliseconds(200))
                    try? await sendReturn(in: i)
                    // Wait between terminals so window-manipulating prompts (e.g. rename-window)
                    // don't race against each other and accidentally close windows via Cmd+W.
                    // Polls for iTerm2 sheets (Edit Session dialog) so we exit as soon as the
                    // previous prompt's dialog closes, rather than sleeping a fixed duration.
                    if i < count - 1 {
                        await waitForPromptDialog(timeout: initialPromptStagger)
                    }
                }
            }
        }
    }

    /// Waits for any iTerm2 "Edit Session" sheet to appear then disappear, then adds a short
    /// buffer. If no sheet appears within `timeout` seconds, returns immediately. This prevents
    /// window-manipulating Claude prompts (e.g. rename-window) from racing across terminals.
    private func waitForPromptDialog(timeout: Double) async {
        let pollInterval: UInt64 = 500_000_000 // 0.5s in nanoseconds
        let maxWaitForOpen = min(timeout, 12.0)

        let sheetCountScript = """
            tell application "System Events"
                tell process "iTerm2"
                    set n to 0
                    repeat with w in windows
                        set n to n + (count of sheets of w)
                    end repeat
                    return n as text
                end tell
            end tell
        """

        func sheetCount() async -> Int {
            guard let r = try? await AppleScriptBridge.runAsync(sheetCountScript) else { return 0 }
            return Int(r.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        }

        // Phase 1 — wait for a sheet to open (meaning rename-window is running).
        var elapsed = 0.0
        var dialogOpened = false
        while elapsed < maxWaitForOpen {
            if await sheetCount() > 0 { dialogOpened = true; break }
            try? await Task.sleep(nanoseconds: pollInterval)
            elapsed += 0.5
        }

        guard dialogOpened else { return } // prompt didn't open a dialog — proceed now

        // Phase 2 — wait for the sheet to close.
        while await sheetCount() > 0 {
            try? await Task.sleep(nanoseconds: pollInterval)
        }

        // Short buffer so the script that closed the sheet finishes cleanly.
        try? await Task.sleep(for: .milliseconds(1500))
    }

    /// Adopt ALL existing terminal windows. Each window becomes one slot.
    func adoptTerminals(appState: AppState? = nil, screen: NSScreen? = nil) async throws {
        isSetup = false
        windowIndices.removeAll()
        cachedWindowIndex.removeAll()
        iTermSessionIDs.removeAll()
        iTermWindowIDs.removeAll()
        slotNormRects.removeAll()
        if let screen { activeScreen = screen }

        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: preferredTerminal.bundleIdentifier) != nil else {
            throw TerminalError.terminalNotInstalled(preferredTerminal)
        }

        let app = preferredTerminal.appName
        // For iTerm2 include session IDs (5th field); Terminal.app uses 4 fields only.
        let findScript: String
        if preferredTerminal == .iTerm2 {
            findScript = """
                tell application "iTerm2"
                    set windowInfo to ""
                    repeat with w in windows
                        set b to bounds of w
                        set sid to unique id of current session of w
                        set windowInfo to windowInfo & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text) & "," & sid & "|"
                    end repeat
                    return windowInfo
                end tell
            """
        } else {
            findScript = """
                tell application "\(app)"
                    set windowInfo to ""
                    repeat with w in windows
                        set b to bounds of w
                        set windowInfo to windowInfo & (item 1 of b as text) & "," & (item 2 of b as text) & "," & (item 3 of b as text) & "," & (item 4 of b as text) & "|"
                    end repeat
                    return windowInfo
                end tell
            """
        }

        guard let result = try? await AppleScriptBridge.runAsync(findScript), !result.isEmpty else {
            throw TerminalError.noWindowsToAdopt
        }

        let entries = result.components(separatedBy: "|").filter { !$0.isEmpty }
        guard !entries.isEmpty else { throw TerminalError.noWindowsToAdopt }

        let screenFrame = activeScreen.frame

        var slots: [TerminalSlot] = []
        for (i, entry) in entries.enumerated() {
            let parts = entry.components(separatedBy: ",")
            guard parts.count >= 4,
                  let l = Double(parts[0].trimmingCharacters(in: .whitespaces)),
                  let t = Double(parts[1].trimmingCharacters(in: .whitespaces)),
                  let r2 = Double(parts[2].trimmingCharacters(in: .whitespaces)),
                  let b = Double(parts[3].trimmingCharacters(in: .whitespaces)) else { continue }
            if parts.count >= 5 {
                iTermSessionIDs[i] = parts[4].trimmingCharacters(in: .whitespaces)
            }

            // Convert AppleScript pixel coords to normalized (0–1) fractions
            let normX = l / screenFrame.width
            let normW = (r2 - l) / screenFrame.width
            // AppleScript top is distance from screen top; convert to normalized y (0=top)
            let normY = t / screenFrame.height
            let normH = (b - t) / screenFrame.height
            let normRect = CGRect(x: normX, y: normY, width: normW, height: normH)

            windowIndices[i] = i + 1  // front-to-back: window 1 is frontmost
            slotNormRects[i] = normRect
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
        let escaped = escapeForAppleScript(text)
        switch preferredTerminal {
        case .iTerm2:
            if let sid = iTermSessionIDs[slotIndex] {
                do {
                    try await AppleScriptBridge.runAsync("""
                        tell application "iTerm2"
                            tell session id "\(sid)"
                                write text "\(escaped)" without newline
                            end tell
                        end tell
                    """)
                    return
                } catch {
                    guard isStaleSessionError(error) else { throw error }
                    iTermSessionIDs.removeValue(forKey: slotIndex)
                }
            }
            let index = try await cachedIndex(for: slotIndex)
            try await AppleScriptBridge.runAsync("""
                tell application "iTerm2"
                    tell current session of window \(index)
                        write text "\(escaped)" without newline
                    end tell
                end tell
            """)
        case .terminal:
            try await AppleScriptBridge.runAsync("""
                tell application "System Events"
                    tell process "Terminal"
                        keystroke "\(escaped)"
                    end tell
                end tell
            """)
        }
    }

    func sendBackspaces(_ count: Int, in slotIndex: Int) async throws {
        guard count > 0 else { return }
        switch preferredTerminal {
        case .iTerm2:
            if let sid = iTermSessionIDs[slotIndex] {
                do {
                    try await AppleScriptBridge.runAsync("""
                        tell application "iTerm2"
                            set delStr to ""
                            repeat \(count) times
                                set delStr to delStr & (character id 127)
                            end repeat
                            tell session id "\(sid)"
                                write text delStr without newline
                            end tell
                        end tell
                    """)
                    return
                } catch {
                    guard isStaleSessionError(error) else { throw error }
                    iTermSessionIDs.removeValue(forKey: slotIndex)
                }
            }
            let index = try await cachedIndex(for: slotIndex)
            try await AppleScriptBridge.runAsync("""
                tell application "iTerm2"
                    set delStr to ""
                    repeat \(count) times
                        set delStr to delStr & (character id 127)
                    end repeat
                    tell current session of window \(index)
                        write text delStr without newline
                    end tell
                end tell
            """)
        case .terminal:
            try await AppleScriptBridge.runAsync("""
                tell application "System Events"
                    repeat \(count) times
                        key code 51
                    end repeat
                end tell
            """)
        }
    }

    func sendEscape(in slotIndex: Int) async throws {
        switch preferredTerminal {
        case .iTerm2:
            if let sid = iTermSessionIDs[slotIndex] {
                do {
                    try await AppleScriptBridge.runAsync("""
                        tell application "iTerm2"
                            tell session id "\(sid)"
                                write text (character id 27) without newline
                            end tell
                        end tell
                    """)
                    return
                } catch {
                    guard isStaleSessionError(error) else { throw error }
                    iTermSessionIDs.removeValue(forKey: slotIndex)
                }
            }
            let index = try await cachedIndex(for: slotIndex)
            try await AppleScriptBridge.runAsync("""
                tell application "iTerm2"
                    tell current session of window \(index)
                        write text (character id 27) without newline
                    end tell
                end tell
            """)
        case .terminal:
            try await AppleScriptBridge.runAsync("""
                tell application "System Events"
                    key code 53
                end tell
            """)
        }
    }

    func sendDoubleEscape(in slotIndex: Int) async throws {
        try await sendEscape(in: slotIndex)
        try await Task.sleep(for: .milliseconds(50))
        try await sendEscape(in: slotIndex)
    }

    func sendReturn(in slotIndex: Int) async throws {
        switch preferredTerminal {
        case .iTerm2:
            if let sid = iTermSessionIDs[slotIndex] {
                do {
                    try await AppleScriptBridge.runAsync("""
                        tell application "iTerm2"
                            tell session id "\(sid)"
                                write text ""
                            end tell
                        end tell
                    """)
                    return
                } catch {
                    guard isStaleSessionError(error) else { throw error }
                    iTermSessionIDs.removeValue(forKey: slotIndex)
                }
            }
            let index = try await cachedIndex(for: slotIndex)
            try await AppleScriptBridge.runAsync("""
                tell application "iTerm2"
                    tell current session of window \(index)
                        write text ""
                    end tell
                end tell
            """)
        case .terminal:
            let index = try await cachedIndex(for: slotIndex)
            try await AppleScriptBridge.runAsync("""
                tell application "\(preferredTerminal.appName)"
                    do script "" in window \(index)
                end tell
            """)
        }
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

    /// Find the terminal window whose screen position is closest to the stored rect for the given slot.
    /// Always uses position-based matching — window indices shift after every focus/reorder operation,
    /// so stored integer indices become stale immediately.
    private func findWindowIndex(for slotIndex: Int) async throws -> Int {
        let app = preferredTerminal.appName
        let screenFrame = activeScreen.frame

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

        let entries = result.components(separatedBy: "|").filter { !$0.isEmpty }

        // Position-based match using the stored normalized rect for this slot.
        // This is robust against window reordering caused by AppleScript "set index".
        let normRect = slotNormRects[slotIndex] ?? CGRect(x: 0.5, y: 0.5, width: 0, height: 0)
        let targetMidX = normRect.midX * screenFrame.width
        let targetMidY = normRect.midY * screenFrame.height

        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude

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

    private func isStaleSessionError(_ error: Error) -> Bool {
        let desc = error.localizedDescription
        return desc.contains("Can't get session id") || desc.contains("session id")
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
