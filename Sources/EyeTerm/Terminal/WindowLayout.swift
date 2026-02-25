import AppKit
import Foundation

struct WindowLayout {

    /// Normalized rect (0–1 fractions of screen) for a slot in a cols×rows grid.
    static func normalizedRect(slotIndex: Int, cols: Int, rows: Int) -> CGRect {
        let col = slotIndex % cols
        let row = slotIndex / cols
        let w = 1.0 / Double(cols)
        let h = 1.0 / Double(rows)
        return CGRect(x: Double(col) * w, y: Double(row) * h, width: w, height: h)
    }

    /// AppleScript-style pixel bounds for a slot, accounting for menu bar and dock.
    static func boundsForSlot(slotIndex: Int, cols: Int, rows: Int, screen: NSScreen? = nil) -> (left: Int, top: Int, right: Int, bottom: Int) {
        let s = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let screenFrame = s.frame
        let visibleFrame = s.visibleFrame

        // Usable area: top = menu bar bottom, bottom = dock top
        let menuBarHeight = screenFrame.maxY - visibleFrame.maxY
        let dockHeight = visibleFrame.minY - screenFrame.minY
        let usableWidth = screenFrame.width
        let usableHeight = screenFrame.height - menuBarHeight - dockHeight

        let col = slotIndex % cols
        let row = slotIndex / cols
        let slotW = usableWidth / Double(cols)
        let slotH = usableHeight / Double(rows)

        let left = Int(screenFrame.minX + Double(col) * slotW)
        let right = Int(screenFrame.minX + Double(col + 1) * slotW)
        // AppleScript top = distance from screen top (origin is top-left in AppleScript coords)
        let top = Int(menuBarHeight + Double(row) * slotH)
        let bottom = Int(menuBarHeight + Double(row + 1) * slotH)

        return (left: left, top: top, right: right, bottom: bottom)
    }
}
