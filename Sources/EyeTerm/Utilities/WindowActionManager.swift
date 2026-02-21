import Foundation

enum WindowAction: String, CaseIterable {
    case close, minimize, hide, goBack, goForward, reload
}

final class WindowActionManager {
    var protectedBundleIDs: Set<String> = [
        "com.googlecode.iterm2",
        "com.apple.Terminal"
    ]

    func frontmostAppBundleID() async -> String? {
        let script = """
        tell application "System Events"
            set frontApp to first application process whose frontmost is true
            return bundle identifier of frontApp
        end tell
        """
        return await runAppleScript(script)
    }

    func isFrontmostProtected() async -> Bool {
        guard let bundleID = await frontmostAppBundleID() else { return true }
        return protectedBundleIDs.contains(bundleID)
    }

    func execute(_ action: WindowAction) async throws {
        let script: String
        switch action {
        case .close:
            script = """
            tell application "System Events"
                set frontProc to first application process whose frontmost is true
                try
                    click button 1 of window 1 of frontProc
                on error
                    set appName to name of frontProc
                    tell application appName to close front window
                end try
            end tell
            """
        case .minimize:
            script = """
            tell application "System Events"
                set frontProc to first application process whose frontmost is true
                click button 3 of window 1 of frontProc
            end tell
            """
        case .hide:
            script = """
            tell application "System Events"
                set visible of (first application process whose frontmost is true) to false
            end tell
            """
        case .goBack:
            script = """
            tell application "System Events"
                keystroke "[" using command down
            end tell
            """
        case .goForward:
            script = """
            tell application "System Events"
                keystroke "]" using command down
            end tell
            """
        case .reload:
            script = """
            tell application "System Events"
                keystroke "r" using command down
            end tell
            """
        }

        let success = await runAppleScript(script)
        if success == nil {
            print("[WindowActionManager] AppleScript returned nil for \(action.rawValue) — may have still worked")
        }
    }

    @discardableResult
    private func runAppleScript(_ source: String) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                let script = NSAppleScript(source: source)
                let result = script?.executeAndReturnError(&error)
                if let error {
                    print("[WindowActionManager] AppleScript error: \(error)")
                    continuation.resume(returning: nil)
                } else {
                    continuation.resume(returning: result?.stringValue)
                }
            }
        }
    }
}
