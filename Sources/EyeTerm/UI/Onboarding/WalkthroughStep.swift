import Foundation

enum WalkthroughStep: Int, CaseIterable {
    case welcome = 0
    case howItWorks
    case cameraPermission
    case microphonePermission
    case accessibilityPermission
    case ready
    case complete
}
