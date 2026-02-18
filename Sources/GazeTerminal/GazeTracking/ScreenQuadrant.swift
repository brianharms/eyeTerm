import Foundation
import CoreGraphics

enum ScreenQuadrant: String, CaseIterable, Codable, Identifiable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .topLeft: "Top Left"
        case .topRight: "Top Right"
        case .bottomLeft: "Bottom Left"
        case .bottomRight: "Bottom Right"
        }
    }

    var symbol: String {
        switch self {
        case .topLeft: "rectangle.inset.topleft.filled"
        case .topRight: "rectangle.inset.topright.filled"
        case .bottomLeft: "rectangle.inset.bottomleft.filled"
        case .bottomRight: "rectangle.inset.bottomright.filled"
        }
    }

    /// Returns the frame for this quadrant within the given screen bounds.
    /// Uses macOS native coordinates (origin at bottom-left, Y increases upward).
    func frame(for screenBounds: CGRect) -> CGRect {
        let halfWidth = screenBounds.width / 2
        let halfHeight = screenBounds.height / 2

        switch self {
        case .topLeft:
            return CGRect(x: screenBounds.minX, y: screenBounds.minY + halfHeight,
                          width: halfWidth, height: halfHeight)
        case .topRight:
            return CGRect(x: screenBounds.minX + halfWidth, y: screenBounds.minY + halfHeight,
                          width: halfWidth, height: halfHeight)
        case .bottomLeft:
            return CGRect(x: screenBounds.minX, y: screenBounds.minY,
                          width: halfWidth, height: halfHeight)
        case .bottomRight:
            return CGRect(x: screenBounds.minX + halfWidth, y: screenBounds.minY,
                          width: halfWidth, height: halfHeight)
        }
    }

    /// Returns AppleScript-style bounds {left, top, right, bottom} where origin is top-left of screen.
    /// Uses the visible frame (excluding menu bar and dock) for proper tiling.
    func appleScriptBounds(for screenFrame: CGRect, visibleFrame: CGRect) -> (left: Int, top: Int, right: Int, bottom: Int) {
        let screenHeight = screenFrame.height

        // Convert visible frame from macOS coords (origin bottom-left) to AppleScript coords (origin top-left)
        let visLeft = Int(visibleFrame.minX)
        let visTop = Int(screenHeight - visibleFrame.maxY)
        let visRight = Int(visibleFrame.maxX)
        let visBottom = Int(screenHeight - visibleFrame.minY)

        let midX = (visLeft + visRight) / 2
        let midY = (visTop + visBottom) / 2

        switch self {
        case .topLeft:
            return (visLeft, visTop, midX, midY)
        case .topRight:
            return (midX, visTop, visRight, midY)
        case .bottomLeft:
            return (visLeft, midY, midX, visBottom)
        case .bottomRight:
            return (midX, midY, visRight, visBottom)
        }
    }

    /// Classify a normalized point (0,0 = top-left, 1,1 = bottom-right) into a quadrant.
    static func from(normalizedPoint point: CGPoint) -> ScreenQuadrant {
        if point.x < 0.5 {
            return point.y < 0.5 ? .topLeft : .bottomLeft
        } else {
            return point.y < 0.5 ? .topRight : .bottomRight
        }
    }
}
