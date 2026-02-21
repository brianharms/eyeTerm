# eyeTerm

macOS menu bar app that lets you control four terminal quadrants using eye tracking and voice commands. Look at a quadrant to focus it, speak commands that get transcribed and sent to the focused terminal.

## Build & Run

```bash
# Debug build (no code signing)
cd "/Users/brianharms/Desktop/Claude Projects/eyeTerm"
xcodebuild -scheme eyeTerm -configuration Debug build CODE_SIGNING_ALLOWED=NO

# Launch from build artifacts
open build-debug/Build/Products/Debug/eyeTerm.app

# Or open in Xcode
open eyeTerm.xcodeproj
```

Project uses XcodeGen (`project.yml`) but the `.xcodeproj` is already generated and committed.

## Architecture

### Core Loop
1. Camera frames feed into eye tracking backend (MediaPipe or Apple Vision)
2. Backend produces raw head pose + pupil position
3. Parallax compensation removes head-rotation artifacts from pupil signal
4. Head amplification stretches small head movements to cover screen range
5. Calibration transforms (dual affine: one for head, one for pupil) map raw to screen coords
6. Head/eye fusion blends the two signals (configurable weight slider)
7. Smoothing (EMA) stabilizes the final gaze point
8. Gaze point maps to screen quadrant -> dwell timer -> terminal focus via AppleScript
9. Voice transcription runs in parallel, sending cleaned text to the focused terminal

### Key Files

| Area | File | Purpose |
|------|------|---------|
| **State** | `Sources/EyeTerm/App/AppState.swift` | All observable state + settings. `saveSettingsAsDefaults()` writes to `saved-defaults.json` for baking new defaults |
| **Coordinator** | `Sources/EyeTerm/App/AppCoordinator.swift` | Wires everything together — starts/stops backends, observes settings, manages overlays, handles calibration callbacks |
| **Eye Tracking** | `Sources/EyeTerm/EyeTracking/EyeEstimator.swift` | Apple Vision backend math (head pose + pupil extraction from VNFaceObservation) |
| **Eye Tracking** | `Sources/EyeTerm/EyeTracking/MediaPipeBackend.swift` | MediaPipe Python subprocess backend (reads JSON lines from stdout) |
| **Eye Tracking** | `Sources/EyeTerm/EyeTracking/EyeTracker.swift` | AVCaptureSession + Apple Vision pipeline, wraps EyeEstimator |
| **Eye Tracking** | `Sources/EyeTerm/EyeTracking/EyeTrackingBackend.swift` | Protocol both backends conform to |
| **Calibration** | `Sources/EyeTerm/EyeTracking/CalibrationManager.swift` | 9-point calibration grid (0.05/0.5/0.95), dual affine transform fitting, auto-learns parallax correction coefficients |
| **Voice** | `Sources/EyeTerm/Voice/WhisperKitBackend.swift` | Primary voice backend — CoreML/Neural Engine, fast |
| **Voice** | `Sources/EyeTerm/Voice/WhisperCppBackend.swift` | Alternate voice backend — CPU-only, 5-10s latency with small.en |
| **Voice** | `Sources/EyeTerm/Voice/VoiceAudioPipeline.swift` | Shared audio capture + VAD (voice activity detection). RMS threshold, 0.5s silence = segment ready |
| **Voice** | `Sources/EyeTerm/Voice/CommandParser.swift` | Strips bracket artifacts `[...]` `(...)`, applies text normalizations ("at sign" -> "@"), detects execute keyword, detects window action phrases |
| **Window Actions** | `Sources/EyeTerm/Utilities/WindowActionManager.swift` | AppleScript-based non-terminal window manipulation (close, minimize, hide, go back/forward, reload) with terminal protection |
| **Blink Gestures** | `Sources/EyeTerm/Utilities/BlinkGestureDetector.swift` | Detects deliberate one-eye winks for terminal actions (escape, enter). Filters blinks via bilateral reject, duration bounds, cooldown |
| **Terminal** | `Sources/EyeTerm/Terminal/TerminalManager.swift` | AppleScript bridge to iTerm2/Terminal.app. Position-based window lookup for focus. Supports launch (create new) and adopt (use existing) modes |
| **UI** | `Sources/EyeTerm/UI/SettingsView.swift` | Main settings panel (eye tracking, voice, terminal, visualization) |
| **UI** | `Sources/EyeTerm/UI/GazeOverlayView.swift` | Full-screen transparent overlay showing gaze points, calibration dots, dwell progress |
| **UI** | `Sources/EyeTerm/UI/AudioWaveformView.swift` | Floating waveform pill showing mic input levels |
| **UI** | `Sources/EyeTerm/UI/CalibrationOverlayView.swift` | 9-point calibration target UI |

### Settings Flow
Settings live as properties on `AppState` (an `@Observable` class). `AppCoordinator.observeSettings()` uses `withObservationTracking` to push changes to the active backend whenever a setting changes. The "Save Settings as Default" button writes current values to `saved-defaults.json` — a developer then bakes those into the hardcoded defaults in `AppState.swift`.

### Voice Backends
- **WhisperKit** (recommended): Uses CoreML + Neural Engine. Fast, real-time transcription.
- **whisper.cpp** (SwiftWhisper): CPU-only inference. Works but 5-10s latency on `small.en`. Had a race condition where `instanceBusy` errors silently ate all transcriptions — fixed by serializing `whisper.transcribe()` calls through a single `activeWhisperTask` chain.

### Calibration System
- 9-point grid at positions `(0.05, 0.5, 0.95)` x `(0.05, 0.5, 0.95)` for good edge coverage
- Records head and pupil samples independently per target
- Fits separate affine transforms for head and pupil signals
- Auto-learns parallax correction coefficients (`parallaxCorrX`, `parallaxCorrY`) from within-target head drift during calibration
- Persists transforms + coefficients to UserDefaults

## Recent Work (Feb 2026)

### Session 7 — Feb 21
- **Voice-controlled window management**: Say "close it", "minimize", "hide", "go back", "go forward", "reload" to act on non-terminal windows. Terminal windows (iTerm2/Terminal.app) are protected — phrases pass through as text when terminal is frontmost. Refocuses terminal quadrant after action.
- **Wink gestures**: Deliberate one-eye winks trigger terminal actions (left wink = double escape, right wink = enter). Bilateral reject window filters natural blinks. Configurable thresholds, durations, cooldowns in Settings.
- **Terminal setup modes**: Two-mode workflow — "Use Existing" (default) adopts already-positioned terminal windows by scanning screen quadrants, "Create New Terminals" launches four new windows. Checkmark selection in menu bar dropdown.
- **Mic device picker**: Select input microphone in Settings, with CoreAudio device change listener for hot-plug support.
- **Onboarding walkthrough**: First-run overlay explaining eye tracking, voice, and terminal setup.

### Session 6 — Feb 20
- **WhisperCpp race condition fix**: `instanceBusy` error from concurrent `whisper_full()` calls. Serialized with single `activeWhisperTask` that awaits previous task before calling `whisper.transcribe()`
- **Transcription diagnostics**: Settings log now shows Raw and Send (cleaned) text per transcription, with color-coded labels. Helps verify bracket filtering and text normalization
- **Waveform improvements**: Bars thinned (4pt -> 2pt), power curve `pow(linear, 0.4)` for low-volume visibility, pill widened 30% (21 -> 27 bars)

### Session 5 — Feb 19
- **Head-compensated pupil tracking**: Parallax correction removes head-rotation artifacts from pupil signal. Head amplification stretches small head movements.
- **9-point calibration**: Expanded from 5 points. Wider targets at 0.05/0.95 for better edge coverage. Auto-learns parallax coefficients.
- **Settings save/load**: `saveSettingsAsDefaults()` writes JSON for baking into next build

### Earlier Sessions
See `SESSION_LOG.md` for detailed per-session changelogs covering: camera overlay alignment, dual calibration, debug visualization, dwell timer rewrite, terminal focus rewrite, voice backend refactor, overlay toggle controls, and more.

## Known Issues
- Ad-hoc code signing (`CODE_SIGN_IDENTITY = "-"`) may silently block TCC prompts — use Personal Team signing in Xcode for reliable camera/mic/AppleEvent authorization dialogs
- `ENABLE_HARDENED_RUNTIME = NO` in both configs — needed for notarization/distribution
- Gaze inversions were corrected iteratively and may need re-verification on different cameras
- AppleScript window bounds query adds slight latency to each terminal focus call

## GitHub
- Repo: https://github.com/brianharms/eyeTerm (private)
- Branch: `main`

## Future Ideas
- **L2CS-Net CoreML backend**: Third tracking backend, fully native (no Python/C++). Predicts gaze yaw/pitch from single webcam frame. See `SESSION_LOG.md` TODO section.
- **SFSpeechRecognizer**: Apple's built-in speech recognition as a third voice backend option — lower latency, no model download, but less accurate than WhisperKit
