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
    func appleScriptBounds(for screenBounds: CGRect) -> (left: Int, top: Int, right: Int, bottom: Int) {
        let halfWidth = Int(screenBounds.width / 2)
        let halfHeight = Int(screenBounds.height / 2)
        let screenWidth = Int(screenBounds.width)
        let screenHeight = Int(screenBounds.height)

        switch self {
        case .topLeft:
            return (0, 0, halfWidth, halfHeight)
        case .topRight:
            return (halfWidth, 0, screenWidth, halfHeight)
        case .bottomLeft:
            return (0, halfHeight, halfWidth, screenHeight)
        case .bottomRight:
            return (halfWidth, halfHeight, screenWidth, screenHeight)
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
