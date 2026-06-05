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
        let visibleFrame = s.visibleFrame

        // AppleScript uses top-left of primary screen as origin (y increases downward).
        // Cocoa uses bottom-left of primary screen as origin (y increases upward).
        // Conversion: appleScriptY = primaryH - cocoaY
        let primaryH = NSScreen.screens[0].frame.height

        let slotW = visibleFrame.width / Double(cols)
        let slotH = visibleFrame.height / Double(rows)

        let col = slotIndex % cols
        let row = slotIndex / cols

        // Horizontal: same in both systems
        let left  = Int(visibleFrame.minX + Double(col) * slotW)
        let right = Int(visibleFrame.minX + Double(col + 1) * slotW)

        // Row 0 = topmost row = highest Cocoa Y = lowest AppleScript Y
        let cocoaTop    = visibleFrame.maxY - Double(row) * slotH
        let cocoaBottom = visibleFrame.maxY - Double(row + 1) * slotH
        let top    = Int(primaryH - cocoaTop)
        let bottom = Int(primaryH - cocoaBottom)

        return (left: left, top: top, right: right, bottom: bottom)
    }

    /// Normalized rects for 1–12 project folders.
    /// Full rows use equal-width columns. The last row, if shorter, uses wider windows to fill the screen.
    ///
    /// Grid dimensions:
    ///  1→1×1  2→2×1  3-4→2×2  5-6→3×2  7-8→4×2  9→3×3  10-12→4×3
    static func projectSlotLayouts(count: Int) -> [CGRect] {
        guard count > 0 else { return [] }
        let n = min(count, 12)

        let cols: Int
        let rows: Int
        switch n {
        case 1:       cols = 1; rows = 1
        case 2:       cols = 2; rows = 1
        case 3...4:   cols = 2; rows = 2
        case 5...6:   cols = 3; rows = 2
        case 7...8:   cols = 4; rows = 2
        case 9:       cols = 3; rows = 3
        default:      cols = 4; rows = 3   // 10–12
        }

        let rowH = 1.0 / Double(rows)
        let colW = 1.0 / Double(cols)
        let fullRowCount = (rows - 1) * cols   // windows in all-but-last rows
        let lastRowCount = n - fullRowCount
        let lastRowW    = 1.0 / Double(lastRowCount)
        let lastRowY    = Double(rows - 1) * rowH

        var rects: [CGRect] = []

        for i in 0..<fullRowCount {
            let col = i % cols
            let row = i / cols
            rects.append(CGRect(x: Double(col) * colW, y: Double(row) * rowH, width: colW, height: rowH))
        }

        for i in 0..<lastRowCount {
            rects.append(CGRect(x: Double(i) * lastRowW, y: lastRowY, width: lastRowW, height: rowH))
        }

        return rects
    }

    /// AppleScript pixel bounds from a normalized rect, accounting for menu bar and dock.
    static func boundsForProjectSlot(normalizedRect r: CGRect, screen: NSScreen? = nil) -> (left: Int, top: Int, right: Int, bottom: Int) {
        let s = screen ?? NSScreen.main ?? NSScreen.screens.first!
        let visibleFrame = s.visibleFrame

        let primaryH = NSScreen.screens[0].frame.height

        let usableWidth  = visibleFrame.width
        let usableHeight = visibleFrame.height

        // Horizontal: same in both systems
        let left  = Int(visibleFrame.minX + r.minX * usableWidth)
        let right = Int(visibleFrame.minX + r.maxX * usableWidth)

        // r.minY = top of slot (y=0 is top in normalized space), r.maxY = bottom
        let cocoaTop    = visibleFrame.maxY - r.minY * usableHeight
        let cocoaBottom = visibleFrame.maxY - r.maxY * usableHeight
        let top    = Int(primaryH - cocoaTop)
        let bottom = Int(primaryH - cocoaBottom)

        return (left: left, top: top, right: right, bottom: bottom)
    }
}
