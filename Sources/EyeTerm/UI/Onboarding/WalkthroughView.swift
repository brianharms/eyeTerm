import SwiftUI

struct WalkthroughView: View {
    let onGetStarted: () -> Void
    let onExploreSettings: () -> Void

    @State private var currentStep: WalkthroughStep = .welcome
    @State private var permissionRefreshToken = false
    @State private var chosenAction: ChosenAction = .getStarted

    private enum ChosenAction {
        case getStarted
        case exploreSettings
    }

    private var stepIndex: Int { currentStep.rawValue }
    private var totalSteps: Int { WalkthroughStep.allCases.count }
    private var isFirst: Bool { currentStep == .welcome }
    private var isLast: Bool { currentStep == .ready || currentStep == .complete }

    var body: some View {
        VStack(spacing: 0) {
            // Step content
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(currentStep)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing),
                    removal: .move(edge: .leading)
                ))

            if currentStep != .complete {
                Divider()

                // Navigation bar
                HStack {
                    if !isFirst {
                        Button("Back") {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                goBack()
                            }
                        }
                        .buttonStyle(.borderless)
                    }

                    Spacer()

                    // Page dots
                    HStack(spacing: 6) {
                        ForEach(WalkthroughStep.allCases, id: \.rawValue) { step in
                            if step != .complete {
                                Circle()
                                    .fill(step == currentStep ? Color.accentColor : Color.secondary.opacity(0.3))
                                    .frame(width: 7, height: 7)
                            }
                        }
                    }

                    Spacer()

                    if !isLast {
                        Button(nextButtonTitle) {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                goForward()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        }
        .frame(width: 560, height: 420)
    }

    @ViewBuilder
    private var stepContent: some View {
        switch currentStep {
        case .welcome:
            WalkthroughWelcomeStep()

        case .howItWorks:
            WalkthroughHowItWorksStep()

        case .cameraPermission:
            WalkthroughPermissionStep(
                iconName: "camera.fill",
                title: "Camera Access",
                explanation: "eyeTerm uses your camera to track where you're looking on screen. Everything is processed entirely on-device — nothing is stored or sent anywhere.",
                check: { Permissions.checkCamera() },
                request: { _ = await Permissions.requestCamera() },
                isAccessibility: false,
                onPermissionChanged: { permissionRefreshToken.toggle() }
            )

        case .microphonePermission:
            WalkthroughPermissionStep(
                iconName: "mic.fill",
                title: "Microphone Access",
                explanation: "Voice commands are transcribed locally using Whisper. Audio is processed on-device and never leaves your Mac.",
                check: { Permissions.checkMicrophone() },
                request: { _ = await Permissions.requestMicrophone() },
                isAccessibility: false,
                onPermissionChanged: { permissionRefreshToken.toggle() }
            )

        case .accessibilityPermission:
            WalkthroughPermissionStep(
                iconName: "accessibility",
                title: "Accessibility Access",
                explanation: "eyeTerm needs accessibility permission to control iTerm2 windows — focusing, typing, and running commands on your behalf.",
                check: { Permissions.checkAccessibility() ? .granted : .notDetermined },
                request: { Permissions.requestAccessibility() },
                isAccessibility: true,
                onPermissionChanged: { permissionRefreshToken.toggle() }
            )

        case .ready:
            WalkthroughReadyStep(
                onGetStarted: {
                    chosenAction = .getStarted
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep = .complete
                    }
                },
                onExploreSettings: {
                    chosenAction = .exploreSettings
                    withAnimation(.easeInOut(duration: 0.3)) {
                        currentStep = .complete
                    }
                }
            )

        case .complete:
            WalkthroughCompleteStep(onDone: {
                switch chosenAction {
                case .getStarted:
                    onGetStarted()
                case .exploreSettings:
                    onExploreSettings()
                }
            })
        }
    }

    private var nextButtonTitle: String {
        // Touch the token so SwiftUI re-evaluates when permissions change
        _ = permissionRefreshToken
        switch currentStep {
        case .cameraPermission:
            if Permissions.checkCamera() != .granted {
                return "Continue Without Camera"
            }
        case .microphonePermission:
            if Permissions.checkMicrophone() != .granted {
                return "Continue Without Mic"
            }
        case .accessibilityPermission:
            if !Permissions.checkAccessibility() {
                return "Continue Without Access"
            }
        default:
            break
        }
        return "Next"
    }

    private func goForward() {
        guard let next = WalkthroughStep(rawValue: stepIndex + 1) else { return }
        currentStep = next
        skipGrantedPermissions()
    }

    private func skipGrantedPermissions() {
        while true {
            let shouldSkip: Bool
            switch currentStep {
            case .cameraPermission:
                shouldSkip = Permissions.checkCamera() == .granted
            case .microphonePermission:
                shouldSkip = Permissions.checkMicrophone() == .granted
            case .accessibilityPermission:
                shouldSkip = Permissions.checkAccessibility()
            default:
                shouldSkip = false
            }
            guard shouldSkip, let next = WalkthroughStep(rawValue: currentStep.rawValue + 1) else { break }
            currentStep = next
        }
    }

    private func goBack() {
        guard let prev = WalkthroughStep(rawValue: stepIndex - 1) else { return }
        currentStep = prev
    }
}
