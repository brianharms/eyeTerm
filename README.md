# eyeTerm

> **Experimental software. This project is a personal research prototype — it is unstable, under active development, and likely has bugs. Use at your own risk.**

**Control your terminal with your eyes and voice.** eyeTerm is a macOS menu bar app that lets you look at one of four terminal quadrants to focus it, then speak commands that get transcribed and sent — hands-free.

Built for developers who want to work with AI coding agents (like Claude Code) without reaching for the keyboard.

---

## What It Does

- **Eye tracking** — Your webcam tracks where you're looking. Dwell on a quadrant for ~1 second and that terminal gets focus.
- **Voice commands** — Speak naturally. Commands are transcribed in real-time via WhisperKit (CoreML / Neural Engine) and sent to the focused terminal.
- **Wink gestures** — Deliberate one-eye winks trigger terminal actions: left wink = double escape, right wink = enter. Natural blinks are filtered out.
- **Four terminal quadrants** — Works with iTerm2 or Terminal.app. Either launch four new windows or adopt your existing layout.

---

## Requirements

- macOS 14+ (Sonoma or later)
- Webcam (built-in or external)
- iTerm2 or Terminal.app
- Python 3 + MediaPipe (for the MediaPipe tracking backend, optional)

---

## Privacy

eyeTerm is built with privacy as a first principle:

- **Camera** — Your webcam feed is processed entirely on-device using Apple Vision (CoreML) or MediaPipe. No video is recorded, stored, or transmitted anywhere. Your camera data never leaves your Mac.
- **Microphone** — Voice commands are transcribed locally using [WhisperKit](https://github.com/argmaxinc/WhisperKit), a CoreML/Neural Engine implementation of OpenAI Whisper. No audio is sent to any server, ever.
- **No telemetry** — eyeTerm contains no analytics, crash reporting, or usage tracking of any kind.
- **No network access** — The app makes no outbound network connections during normal operation. (The MediaPipe auto-setup downloads the `mediapipe` Python package from PyPI on first use only, if you choose that backend.)

All processing happens on your hardware. eyeTerm does not have — and does not need — an internet connection to function.

---

## Setup

### 1. Build

```bash
git clone https://github.com/brianharms/eyeTerm
cd eyeTerm
xcodebuild -scheme eyeTerm -configuration Debug build CODE_SIGNING_ALLOWED=NO
open build-debug/Build/Products/Debug/eyeTerm.app
```

Or open `eyeTerm.xcodeproj` in Xcode and run directly. Use your Personal Team signing identity for reliable camera/mic permission dialogs.

### 2. First Launch

eyeTerm will guide you through a short onboarding walkthrough on first launch explaining the three main features.

Grant camera and microphone access when prompted. If no dialog appears, check System Settings → Privacy & Security → Camera / Microphone.

### 3. Terminal Setup

In the menu bar, click the eyeTerm icon → **Settings** → **Terminal** section.

- **Use Existing** (default) — Position four terminal windows in each screen quadrant before clicking "Adopt Windows". eyeTerm will scan for them.
- **Create New** — Launches four fresh terminal windows and positions them automatically.

### 4. Calibration

Click the menu bar icon → **Calibrate**. A 9-point grid appears — look at each dot as it highlights. Takes about 30 seconds. Calibration is saved and survives restarts.

Recalibrate any time tracking feels off (different lighting, different camera angle).

### 5. Start Tracking

Click the menu bar icon → **Start Eye Tracking**. The overlay appears. Look at a quadrant — it highlights after ~1 second of dwell. Then speak your command.

---

## Voice Commands

Commands are transcribed and sent to the focused terminal as keystrokes. A few special phrases are recognized:

| Phrase | Action |
|--------|--------|
| "run it" (configurable) | Press Enter after sending the command |
| "close it" | Close the frontmost non-terminal window |
| "minimize" | Minimize the frontmost non-terminal window |
| "hide" | Hide the frontmost app |
| "go back" | ⌘[ (browser / file navigation) |
| "go forward" | ⌘] |
| "reload" / "refresh" | ⌘R |

Text normalization handles common substitutions: "at sign" → `@`, "hash" → `#`, etc.

---

## Wink Gestures

| Gesture | Default Action |
|---------|---------------|
| Left wink | Double Escape (clears Claude Code prompt) |
| Right wink | Enter |

Natural blinks are filtered out via bilateral rejection — both eyes closing within ~100ms of each other is ignored. Winks require one eye to close while the other stays open.

**Calibrating wink thresholds:** Settings → Wink Gestures → **Calibrate Winks**. A guided wizard measures your actual eye aperture at rest, while closed, and during practice winks to compute optimal thresholds for your face and lighting.

---

## Settings Overview

| Setting | Description |
|---------|-------------|
| Tracking Backend | MediaPipe (Python subprocess) or Apple Vision (native) |
| Voice Backend | WhisperKit (fast, Neural Engine) or whisper.cpp (CPU) |
| Whisper Model | `tiny.en`, `small.en`, `base.en` — tradeoff between speed and accuracy |
| Dwell Time | How long to look before focus switches (default 1.0s) |
| Eye Smoothing | EMA smoothing on the final gaze point (lower = more responsive, more jittery) |
| Head Weight | How much head pose contributes vs pupil position (0 = pupil only, 1 = head only) |
| Overlay Mode | Off / Subtle (small eye icon) / Debug (full gaze point visualization) |
| Execute Keyword | Spoken phrase that triggers Enter after command (default: "run it") |

---

## Architecture

```
Camera → Eye Tracking Backend → Parallax Correction → Calibration Transform
       → Head/Pupil Fusion → EMA Smoothing → Quadrant Dwell Timer → AppleScript Focus

Microphone → VAD → WhisperKit Transcription → Text Normalization → Terminal Keystrokes
```

Two tracking backends:
- **MediaPipe** — Python subprocess that reads camera frames and outputs JSON head pose + pupil data over stdout
- **Apple Vision** — Native `VNDetectFaceLandmarksRequest`, no Python required

Two voice backends:
- **WhisperKit** — CoreML + Neural Engine, real-time transcription, recommended
- **whisper.cpp** (SwiftWhisper) — CPU-only, 5–10s latency on `small.en`

Calibration uses a 9-point affine transform fit (separate transforms for head and pupil signals). Parallax correction coefficients are auto-learned from within-target head drift during calibration.

---

## Troubleshooting

**Settings window hides behind the overlay** — Should be fixed as of Session 8. If it happens, click the menu bar icon to bring focus back, then re-open Settings.

**Transcription shows garbled characters** — This was a WhisperKit partial-token artifact. Fixed in Session 8 — the display now shows only complete words.

**Winks trigger on normal blinks** — Open Settings → Wink Gestures and lower Closed Threshold or increase Blink Reject window. Or run the Wink Calibration wizard.

**Camera permission blocked** — Ad-hoc code signing can silently block TCC dialogs. Build with a Personal Team signing identity in Xcode instead of `CODE_SIGNING_ALLOWED=NO`.

**AppleScript errors targeting terminal** — Make sure Accessibility access is granted for eyeTerm in System Settings → Privacy & Security → Accessibility.

---

## Project Files

| Area | File |
|------|------|
| State | `Sources/EyeTerm/App/AppState.swift` |
| Coordinator | `Sources/EyeTerm/App/AppCoordinator.swift` |
| Eye Tracking | `Sources/EyeTerm/EyeTracking/` |
| Calibration | `Sources/EyeTerm/EyeTracking/CalibrationManager.swift` |
| Voice | `Sources/EyeTerm/Voice/` |
| Wink Gestures | `Sources/EyeTerm/Utilities/BlinkGestureDetector.swift` |
| Wink Calibration | `Sources/EyeTerm/Utilities/WinkCalibrationManager.swift` |
| Terminal | `Sources/EyeTerm/Terminal/TerminalManager.swift` |
| Overlay UI | `Sources/EyeTerm/UI/EyeOverlayView.swift` |
| Settings UI | `Sources/EyeTerm/UI/SettingsView.swift` |

---

## License

MIT — [Ritual.Industries](https://ritual.industries)
