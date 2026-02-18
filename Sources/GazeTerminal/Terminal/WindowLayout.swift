import AppKit
import Foundation

struct WindowLayout {

    /// Returns AppleScript-style bounds for the given quadrant on the main screen,
    /// accounting for the menu bar and dock.
    static func boundsForQuadrant(_ quadrant: ScreenQuadrant) -> (left: Int, top: Int, right: Int, bottom: Int) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let visibleFrame = screen?.visibleFrame ?? screenFrame
        return quadrant.appleScriptBounds(for: screenFrame, visibleFrame: visibleFrame)
    }
}
