import AppKit
import Foundation

struct WindowLayout {

    /// Returns the bounds of the main screen in points.
    static func screenBounds() -> CGRect {
        NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
    }

    /// Returns AppleScript-style bounds for the given quadrant on the main screen.
    static func boundsForQuadrant(_ quadrant: ScreenQuadrant) -> (left: Int, top: Int, right: Int, bottom: Int) {
        quadrant.appleScriptBounds(for: screenBounds())
    }
}
