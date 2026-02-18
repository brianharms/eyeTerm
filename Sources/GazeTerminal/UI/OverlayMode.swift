import Foundation

enum OverlayMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case subtle = 1
    case debug = 2

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .off: "Off"
        case .subtle: "Subtle"
        case .debug: "Debug"
        }
    }

    var next: OverlayMode {
        let all = Self.allCases
        let nextIndex = (all.firstIndex(of: self)! + 1) % all.count
        return all[nextIndex]
    }
}
