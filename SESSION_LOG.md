# Session Log

This file tracks session handoffs so the next Claude Code instance can quickly get up to speed.

---

## Session — 2026-02-18 01:19

### Goal
Fix camera preview overlay alignment in eyeTerm (GazeTerminal) — the green face bounding box, cyan eye contours, and red pupil dots were drifting from the actual face position, especially at frame edges. Also fix a calibration freeze bug discovered during testing.

### Accomplished
- Fixed overlay coordinate mapping in `CameraPreviewView.swift` to account for aspect-ratio differences between the camera feed and the preview window
- Changed `AVCaptureVideoPreviewLayer` from `.resizeAspect` (letterboxed) to `.resizeAspectFill` (fills entire view, matching MediaPipe behavior)
- Replaced hardcoded 4:3 aspect ratio with dynamic query of the camera device's actual `activeFormat` dimensions via `CMVideoFormatDescriptionGetDimensions`
- Computed aspect-fill rect so overlay coordinates map to the correct position even when the video is cropped
- Updated `FaceOverlayShape` and `EyeRegionShape` to accept a `CGRect` (video rect) instead of `CGSize` (view size), offsetting all coordinates by the rect's origin
- Fixed calibration freeze bug: second calibration run would freeze the entire UI because (a) `EyeTermEstimator` applies calibration transform before returning `gaze.point`, so re-calibration fed already-calibrated data into the solver, making it degenerate, and (b) if `solve3x3` returned nil, `finishCalibration()` exited without calling `onCalibrationComplete`, leaving the `.screenSaver`-level overlay window stuck on screen
- Fix: `AppCoordinator.startCalibration()` now clears `activeBackend.calibrationTransform` before starting, and `finishCalibration()` falls back to `.identity` transform on solve failure
- Initialized git repo and made initial commit
- Updated Claude Code to latest version via npm

### In Progress / Incomplete
- User has not yet tested the latest build with dynamic aspect ratio detection — needs to verify overlay accuracy on both MediaPipe and Apple Vision backends
- No remote git repository configured yet — only local

### Key Decisions
- Used `.resizeAspectFill` instead of `.resizeAspect` to match MediaPipe's behavior of filling the entire preview window (no bars)
- Queried actual camera dimensions at runtime rather than hardcoding, since Mac cameras vary (720p, 1080p, different aspect ratios)
- Chose to fall back to `.identity` transform on calibration solve failure rather than silently ignoring — ensures overlay always dismisses

### Files Changed
- `Sources/GazeTerminal/UI/CameraPreviewView.swift` — aspect-fill video rect, dynamic camera aspect ratio, videoRect-based overlay mapping
- `Sources/GazeTerminal/App/AppCoordinator.swift` — clear calibration transform before re-calibration
- `Sources/GazeTerminal/GazeTracking/CalibrationManager.swift` — dismiss overlay on solve failure
- `.gitignore` — created to exclude build/, .DS_Store, DerivedData, xcuserdata

### Known Issues
- Overlay accuracy on Apple Vision backend still needs user verification after the dynamic aspect ratio fix
- MediaPipe Python process coordinate space vs Apple Vision coordinate space: MediaPipe coords come from OpenCV (may or may not be mirrored depending on the Python script), Apple Vision coords come from raw pixel buffer (unmirrored). Both use `(1 - pt.x)` for horizontal flip in the overlay — if one backend's coords are pre-mirrored, this could cause horizontal inversion for that backend.

### Running Services
- No running processes. eyeTerm was force-killed during calibration freeze debugging.

### Next Steps
- Launch eyeTerm, test overlay accuracy on both backends (MediaPipe and Apple Vision) with dynamic aspect ratio
- If horizontal alignment is still off on one backend, investigate whether MediaPipe Python script mirrors the frame before face detection (check `Resources/gaze_tracker.py`)
- Set up a remote git repository if desired

---

## Session — 2026-02-18 16:30

### Goal
Continue gaze tracking pipeline development — fix bugs, add independent head/pupil calibration, add debug visualization tools, fix iTerm AppleScript authorization, add voice audio waveform visualizer, and push to GitHub.

### Accomplished
- **Camera restart fix**: `EyeTermTracker.stop()` now removes all inputs/outputs from AVCaptureSession so the camera can restart cleanly
- **Quadrant driven by smoothed point**: Changed MediaPipe backend to always use `ScreenQuadrant.from(normalizedPoint: smoothedPoint)` instead of letting Python's raw quadrant override
- **Vertical tracking fix (Apple Vision)**: Changed pitch normalization divisor from 0.6 to 0.3
- **Head pose fix (Apple Vision)**: Added two-step Vision request — `VNDetectFaceRectanglesRequest` first for reliable yaw/pitch, then `VNDetectFaceLandmarksRequest` with `inputFaceObservations`
- **Slider now functional on both backends**: MediaPipe fusion moved from Python (hardcoded 0.85) to Swift side using raw head_yaw/head_pitch/iris_ratio_x/iris_ratio_y components
- **Multiple gaze inversion corrections** across both backends (head and pupil, took several iterations)
  - Apple: `headX = 0.5 - (yaw / 1.0)`, `headY = 0.5 + (pitch / 0.3)`
  - MediaPipe: `headX = 0.5 - (headYaw / 1.0)`, `headY = 0.5 - (headPitch / 0.6)`
  - MediaPipe pupil: `1.0 - irisRatioX`, `1.0 - irisRatioY`
- **Separate raw/calibrated points**: `EyeTermGazeResult` now returns both `rawPoint` and `calibratedPoint`
- **Head/pupil visualization**: Debug overlay shows orange person.fill (head), green eye.fill (pupil), white fusion line with slider-position dot
- **Independent calibration**: `CalibrationManager` records head and pupil samples separately, computes dual affine transforms. Backend protocol has `headCalibrationTransform` and `pupilCalibrationTransform`
- **Calibrated head/pupil visualization**: Outlined icons and yellow fusion line for calibrated signals
- **Dwell progress border**: Cyan border stroke that grows during dwell, solid when confirmed
- **Debug smoothing slider**: EMA filters for all 6 debug visualization points (head, pupil, cal head, cal pupil, raw fused, cal fused) — separate from pipeline smoothing
- **Voice audio level**: `onAudioLevel` callback from VoiceEngine, wired to AppState
- **Floating waveform panel**: Whisper-style `AudioWaveformView` in a floating NSPanel at bottom-center, auto-shows/hides with voice start/stop. 64-bar scrolling amplitude display
- **Audio level meter**: 5-bar indicator in menu bar voice section
- **iTerm AppleScript authorization**: Added `NSAppleEventsUsageDescription` to Info.plist, moved `NSAppleScript` execution to main thread via `@MainActor`
- **Terminal window tiling**: Uses `NSScreen.visibleFrame` (excludes menu bar/dock) instead of full frame. Proper coordinate conversion from macOS bottom-left to AppleScript top-left origin
- **No longer closes existing iTerm windows**: Removed `close every window` from setup, teardown only closes managed windows (by index, in reverse order)
- **GitHub repo created**: https://github.com/brianharms/eyeTerm (private)

### In Progress / Incomplete
- User has not yet tested this build — plans to test tomorrow
- L2CS-Net CoreML backend integration (deferred, see TODO section below)

### Key Decisions
- UIKit window-level UIPanGestureRecognizer for chat swipe dismiss (from prior projectQ work, noted in CLAUDE.md)
- Two-step Vision framework approach because `VNDetectFaceLandmarksRequest` alone doesn't reliably populate yaw/pitch
- Independent calibration before fusion allows the head/eye slider to work post-calibration
- Debug smoothing is visualization-only (doesn't affect actual gaze pipeline)
- Floating waveform panel chosen over menu bar indicator for visibility
- Ad-hoc code signing (`CODE_SIGN_IDENTITY = "-"`) may still prevent TCC prompts on fresh installs — user should switch to Personal Team signing in Xcode if authorization dialogs don't appear

### Files Changed
- `Sources/GazeTerminal/App/AppState.swift` — added audioLevel, isSpeaking, audioLevelHistory, debugSmoothing, calibratedHeadGazePoint, calibratedPupilGazePoint, dwellingQuadrant, dwellProgress, headGazePoint, pupilGazePoint
- `Sources/GazeTerminal/App/AppCoordinator.swift` — debug EMA filters, waveform panel management, audio level wiring, calibration dual-transform wiring
- `Sources/GazeTerminal/GazeTracking/GazeEstimator.swift` — EyeTermDiagnostics with head/pupil/calibrated points, dual calibration transforms, sign corrections
- `Sources/GazeTerminal/GazeTracking/GazeTracker.swift` — two-step Vision request, session cleanup on stop, dual calibration proxying
- `Sources/GazeTerminal/GazeTracking/MediaPipeBackend.swift` — Swift-side fusion from raw components, dual calibration, sign corrections
- `Sources/GazeTerminal/GazeTracking/EyeTrackingBackend.swift` — dual calibration transform protocol
- `Sources/GazeTerminal/GazeTracking/CalibrationManager.swift` — dual sample recording, dual transform computation, CalibrationResult struct
- `Sources/GazeTerminal/GazeTracking/ScreenQuadrant.swift` — `appleScriptBounds(for:visibleFrame:)` with proper coordinate conversion
- `Sources/GazeTerminal/Terminal/TerminalManager.swift` — no longer closes existing windows, teardown closes only managed windows
- `Sources/GazeTerminal/Terminal/WindowLayout.swift` — uses visibleFrame
- `Sources/GazeTerminal/Terminal/AppleScriptBridge.swift` — `@MainActor runAsync`
- `Sources/GazeTerminal/UI/GazeOverlayView.swift` — head/pupil icons, fusion lines, calibrated visualization, dwell progress border, HUD legend
- `Sources/GazeTerminal/UI/AudioWaveformView.swift` — new file, floating waveform panel
- `Sources/GazeTerminal/UI/MenuBarView.swift` — AudioLevelView, voice section layout
- `Sources/GazeTerminal/UI/SettingsView.swift` — debug smoothing slider
- `Sources/GazeTerminal/Utilities/DwellTimer.swift` — onDwellProgress callback
- `Sources/GazeTerminal/Voice/VoiceEngine.swift` — onAudioLevel callback
- `Info.plist` — NSAppleEventsUsageDescription
- `GazeTerminal.xcodeproj/project.pbxproj` — AudioWaveformView.swift added

### Known Issues
- Ad-hoc code signing may silently block TCC AppleEvent prompts on fresh machines — needs Personal Team signing for reliable authorization dialogs
- Gaze inversions were corrected through iterative testing but have not been verified on other machines/cameras
- `ENABLE_HARDENED_RUNTIME = NO` in both Debug and Release configs — would need hardened runtime for notarization/distribution

### Running Services
- eyeTerm app may still be running in the menu bar (launched during testing)

### Next Steps
- User plans to test the full build tomorrow (eye tracking, calibration, voice, terminal control)
- If AppleScript auth still fails, switch to Personal Team signing in Xcode
- Test voice waveform panel visibility and responsiveness
- Verify terminal window tiling respects dock/menu bar correctly
- Consider L2CS-Net CoreML integration when ready (see TODO section)

---

## Session — 2026-02-18 22:45

### Goal
Settings UI polish, overlay improvements, fix dwell timer, fix terminal focus targeting.

### Accomplished
- **Settings UI polish**: Legend rows evenly spaced, launch command label updated, placeholder removed, "Launch Terminals" button added, manual focus + test command disabled when terminals not set up
- **Overlay legend visibility toggles**: Checkboxes for raw/calibrated/smoothed layers that show/hide corresponding debug overlay elements
- **Fusion circle improvements**: Changed to solid black, positioned directly behind raw/calibrated fused gaze dots (not on interpolated line), max size 3x larger (48pt)
- **Smoothed circle size slider**: Separate from fusion dot, up to 48pt
- **Subtle overlay**: Added smoothed gaze circle with dedicated size (up to 100px) and opacity sliders, removed corner bracket crosshairs
- **Debug overlay**: Added dwell countdown ring with percentage, "Active"/"Focused" pills in quadrant centers, adjustable debug line width slider, cyan focus border (40% opacity, 2pt), moved HUD panel down 100pts
- **DwellTimer rewrite**: Fixed critical bug where hysteresis timer was reset every camera frame (~30fps), preventing progress from ever firing. Unified hysteresis+dwell into single continuous progress — countdown starts from first gaze frame entering a quadrant
- **Terminal focus rewrite**: Replaced stale z-order index system with position-based lookup — queries all terminal window bounds via AppleScript and picks closest match to target quadrant. Fixes wrong-quadrant activation after any focus change
- **Camera preview fix**: Auto-refreshes when eye tracking starts after preview was already open (was showing black)
- **Focus error suppression**: Terminal focus skipped silently when terminals not launched
- **Save Settings as Default button**: Writes current settings to `saved-defaults.json` for Claude to bake into AppState.swift on next build
- **Voice backend refactor**: VoiceEngine split into VoiceAudioPipeline + VoiceTranscriptionBackend protocol with WhisperKit and WhisperCpp implementations

### In Progress / Incomplete
- User has not yet pressed "Save Settings as Default" to capture their preferred values
- Position-based terminal focus not yet tested by user with actual terminal windows

### Key Decisions
- Unified dwell progress (hysteresis + dwell as single bar) rather than separate phases — gives immediate visual feedback
- Position-based terminal focus using AppleScript `bounds of w` queries at focus time, not cached indices
- Separate subtle overlay gaze size/opacity from debug overlay smoothed circle size — they serve different purposes
- Black fusion circles placed at actual pipeline fused gaze position (behind red/green dots), not at interpolated head/pupil line position

### Files Changed
- `Sources/GazeTerminal/App/AppState.swift` — added smoothedCircleSize, showRawOverlay, showCalibratedOverlay, showSmoothedOverlay, debugLineWidth, subtleGazeSize, subtleGazeOpacity, saveSettingsAsDefaults()
- `Sources/GazeTerminal/App/AppCoordinator.swift` — camera preview refresh on tracking start, isTerminalSetup guard on dwell confirm
- `Sources/GazeTerminal/UI/SettingsView.swift` — legend toggles, new sliders, launch button, save defaults button, control disabling
- `Sources/GazeTerminal/UI/GazeOverlayView.swift` — visibility guards, dwell ring, Active/Focused labels, fusion circle repositioning, subtle overlay gaze circle, removed corner brackets
- `Sources/GazeTerminal/Utilities/DwellTimer.swift` — complete rewrite with unified progress
- `Sources/GazeTerminal/Terminal/TerminalManager.swift` — position-based window lookup for focus/typeText/sendReturn
- `Sources/GazeTerminal/Voice/VoiceAudioPipeline.swift` — new (split from VoiceEngine)
- `Sources/GazeTerminal/Voice/VoiceTranscriptionBackend.swift` — new protocol
- `Sources/GazeTerminal/Voice/WhisperCppBackend.swift` — new
- `Sources/GazeTerminal/Voice/WhisperCppModelManager.swift` — new
- `Sources/GazeTerminal/Voice/WhisperKitBackend.swift` — new

### Known Issues
- AppleScript window bounds query adds slight latency to each focus call (runs on every dwell confirmation)
- Terminal focus only tested conceptually — user needs to verify correct quadrant targeting with actual terminals launched
- `build-debug/` directory not committed (large build artifacts)

### Running Services
- eyeTerm app likely running in menu bar from last launch

### Next Steps
- Test terminal focus targeting with all four terminals launched
- Press "Save Settings as Default" once happy with slider values, then ask Claude to apply them to AppState.swift
- Consider caching window bounds briefly to reduce AppleScript overhead on rapid quadrant switches

---

## Session — 2026-02-19 03:53

### Goal
Debug overlay visual fixes: Z-order of fusion circles, hide redundant subtle circle in debug mode, add quadrant/dwell toggle controls, and add start/stop buttons for eye tracking and voice in settings.

### Accomplished
- **Black fusion circle Z-order**: Moved black circles to render before lines/icons in both raw and calibrated overlay layers so they sit underneath
- **Subtle circle hidden in debug mode**: `SubtleOverlayContent` now only renders for `.subtle` mode, not `.debug` (was redundant)
- **Quadrant highlighting toggle**: New `showQuadrantHighlighting` bool in AppState wraps the entire quadrant fills ForEach in DebugOverlayContent and the focused flash border in SubtleOverlayContent
- **Active/dwell state toggle**: New `showActiveState` bool wraps the dwell countdown ring + percentage in debug mode and the dwell progress border in subtle mode
- **Settings toggles**: Two new checkboxes in Eye-Tracking Visualization section for the above
- **Observation tracking fix**: Child overlay views (`SubtleOverlayContent`, `DebugOverlayContent`) changed from `let appState: AppState` to `@Environment(AppState.self)` — fixes SwiftUI skipping body re-evaluation when the reference pointer hasn't changed
- **Overlay window preservation**: `updateOverlayVisibility()` now uses `orderOut(nil)` instead of `close()` when mode switches to `.off`, and `orderFrontRegardless()` when switching back. Keeps the NSPanel and its SwiftUI observation registrations alive
- **Start/Stop Eye Tracking button**: Added to Eye Tracking settings section with eye/eye.slash icons
- **Calibrate button**: Added next to Start Eye Tracking, disabled when tracking isn't active
- **Start/Stop Voice button**: Added to Voice settings section with mic/mic.slash icons
- **Camera cleanup on stop**: `stopEyeTracking()` now calls `dismissCameraPreview()` to close the camera window
- **Both new properties saved**: `showQuadrantHighlighting` and `showActiveState` added to `saveSettingsAsDefaults()`

### In Progress / Incomplete
- Nothing left incomplete — all planned changes implemented and building

### Key Decisions
- Used `@Environment` instead of `let` for observable objects in child views — this is the correct pattern with `@Observable` to avoid SwiftUI's structural identity optimization killing observation tracking
- Chose `orderOut`/`orderFront` over `close`/recreate for overlay panel — avoids observation tracking loss across mode switches
- Calibrate button disabled when eye tracking inactive (requires camera session)
- Camera preview dismissed on eye tracking stop since the camera session is no longer running

### Files Changed
- `Sources/GazeTerminal/UI/GazeOverlayView.swift` — Z-order fix, @Environment migration, subtle mode conditional, quadrant/dwell guards
- `Sources/GazeTerminal/App/AppState.swift` — showQuadrantHighlighting, showActiveState properties + saveSettingsAsDefaults
- `Sources/GazeTerminal/UI/SettingsView.swift` — start/stop eye tracking, calibrate, start/stop voice buttons, quadrant/active toggles
- `Sources/GazeTerminal/App/AppCoordinator.swift` — overlay window preservation (orderOut vs close), camera dismiss on stop

### Known Issues
- None new. Existing issues from prior sessions still apply (ad-hoc signing, hardened runtime off)

### Running Services
- eyeTerm app is running in the menu bar (last launched this session)

### Next Steps
- Test the overlay toggle controls (quadrant highlighting on/off, active state on/off)
- Verify overlay renders reliably across mode switches (debug → off → debug) with the observation fix
- Test start/stop buttons for eye tracking and voice from settings

---

## Session — 2026-02-20 09:30

### Goal
Create a `CLAUDE.md` project file summarizing the entire codebase and conversation history, with instructions for the next Claude Code session.

### Accomplished
- Created `CLAUDE.md` at project root with:
  - Build & run instructions
  - Full architecture overview (eye tracking -> voice -> terminal pipeline)
  - Key files table mapping every important file to its purpose
  - Settings flow explanation (AppState observation, saveSettingsAsDefaults)
  - Voice backend comparison (WhisperKit vs whisper.cpp, instanceBusy fix)
  - Calibration system docs (9-point grid, dual affine, parallax learning)
  - Condensed recent work summaries (sessions 4-5)
  - Known issues, GitHub link, future ideas
  - References SESSION_LOG.md for detailed per-session changelogs

### In Progress / Incomplete
- Nothing — task was fully completed

### Key Decisions
- Created CLAUDE.md (picked up by Claude Code automatically) rather than a generic README
- Referenced SESSION_LOG.md for granular history rather than duplicating it
- Focused on architecture and "how things work" over changelog details

### Files Changed
- `CLAUDE.md` — new file, comprehensive project reference

### Known Issues
- None new

### Running Services
- None

### Next Steps
- No pending work. Resume whatever the user wants to work on next.

---

## Session — 2026-02-21 13:30

### Goal
Implement voice-controlled window management, wink gestures, terminal setup modes (launch new vs adopt existing), mic device picker, and onboarding walkthrough. Multiple sessions of iterative refinement on the terminal mode UI in the menu bar dropdown.

### Accomplished
- **WindowActionManager**: New `Sources/EyeTerm/Utilities/WindowActionManager.swift` — AppleScript-based close/minimize/hide/goBack/goForward/reload for non-terminal windows. Checks frontmost app bundle ID against protected set (iTerm2, Terminal.app) before acting.
- **Voice window action detection**: `CommandParser.detectWindowAction()` matches phrases like "close it", "minimize", "go back", "reload" etc. Intercepted in `AppCoordinator.onTranscription` before command parsing — if frontmost app is not a terminal, executes the action and refocuses terminal.
- **BlinkGestureDetector**: New `Sources/EyeTerm/Utilities/BlinkGestureDetector.swift` — processes per-frame eye aperture values, detects deliberate one-eye winks using configurable thresholds (closed/open), duration bounds (min/max), bilateral reject window (filters natural blinks), and cooldown. Wired into AppCoordinator via `wireBlinkDetector()`.
- **Wink settings UI**: Full section in SettingsView with left/right wink action pickers (double escape, enter, single escape, none), threshold sliders, duration sliders, blink reject slider, cooldown slider, live aperture readout, and wink indicator flash.
- **Terminal setup modes**: `TerminalSetupMode` enum with `.launchNew` ("Create New Terminals") and `.adoptExisting` ("Use Existing", default). `TerminalManager.adoptTerminals()` scans existing windows by position. Menu bar shows checkmark-based selection. "Launch Terminals" action button only shown when "Create New Terminals" is selected.
- **Mic device picker**: CoreAudio `AudioObjectAddPropertyListenerBlock` for device change notifications. Picker in Settings Voice section with system default + enumerated devices.
- **Onboarding walkthrough**: First-run overlay with step-by-step explanation.
- **Menu bar terminal UI iterations**: Started with segmented picker (invisible in NSMenu popover), switched to styled buttons (selection too subtle), final version uses checkmark + text with clear primary/secondary contrast.

### In Progress / Incomplete
- Nothing incomplete — all features implemented and building

### Key Decisions
- SwiftUI `.pickerStyle(.segmented)` does not render in NSMenu-hosted popovers — replaced with custom checkmark buttons
- Default terminal mode is "Use Existing" (`.adoptExisting`) — most common workflow is adopting pre-positioned windows
- "Launch Terminals" action button hidden when "Use Existing" is selected since adoption happens via "Launch All"
- Window actions protected: never act on iTerm2/Terminal.app — phrases pass through as typed text
- Terminal refocus after window action sends user back to their focused quadrant

### Files Changed
- `Sources/EyeTerm/Utilities/WindowActionManager.swift` — new file
- `Sources/EyeTerm/Utilities/BlinkGestureDetector.swift` — new file
- `Sources/EyeTerm/Voice/CommandParser.swift` — added `detectWindowAction()`
- `Sources/EyeTerm/App/AppCoordinator.swift` — window action interception, blink detector wiring, mic device listener, onboarding
- `Sources/EyeTerm/App/AppState.swift` — `windowActionsEnabled`, `blinkGesturesEnabled`, wink settings, `TerminalSetupMode` enum, default changed to `.adoptExisting`
- `Sources/EyeTerm/Terminal/TerminalManager.swift` — `adoptTerminals()`, `noWindowsToAdopt` error
- `Sources/EyeTerm/UI/MenuBarView.swift` — checkmark-based terminal mode toggle, conditional action button
- `Sources/EyeTerm/UI/SettingsView.swift` — window voice actions toggle, wink gestures section, terminal mode picker, mic picker
- `Sources/EyeTerm/Voice/VoiceAudioPipeline.swift` — mic device selection support
- `Sources/EyeTerm/Voice/VoiceTranscriptionBackend.swift` — protocol updates
- `Sources/EyeTerm/Voice/WhisperKitBackend.swift` — backend updates
- `Sources/EyeTerm/Voice/WhisperCppBackend.swift` — backend updates
- `Sources/EyeTerm/EyeTracking/EyeTracker.swift` — blink gesture aperture data
- `Sources/EyeTerm/EyeTracking/MediaPipeBackend.swift` — blink gesture aperture data
- `eyeTerm.xcodeproj/project.pbxproj` — new files added
- `CLAUDE.md` — updated with session 7 summary, new key files

### Known Issues
- None new

### Running Services
- eyeTerm app running in menu bar

### Next Steps
- Test window voice actions with browser windows
- Test wink gestures with eye tracking active
- Test terminal adopt mode with pre-positioned iTerm2 windows

---

## Session — 2026-02-22 02:30

### Goal
Fix transcription leaking across terminal switches when user speaks while switching gaze between terminal quadrants. Add more granular word-by-word delivery.

### Accomplished
- **Audio buffer flush on terminal switch**: `flushAudio()` added to `VoiceTranscriptionBackend` protocol and both backends (WhisperKit, WhisperCpp). Cancels in-flight transcription tasks and clears the audio buffer via `VoiceAudioPipeline.flushBuffer()`. Called in `AppCoordinator.dwellTimer.onDwellConfirmed` before `transcriptionDiffer.reset()` — prevents pre-switch audio from being transcribed into the new terminal.
- **Audio trim after interim delivery**: `trimAudio(keepLastSeconds:)` added to protocol and both backends. After each successful partial text delivery to a terminal, trims the audio buffer to only keep the last 1.5 seconds, preventing Whisper from re-transcribing already-sent words.
- **Faster interim interval**: Changed `VoiceAudioPipeline.interimInterval` from 1.0s to 0.5s for more frequent, granular word delivery.
- **AudioBufferManager.trimToLast(seconds:)**: New method that removes all but the last N seconds of samples from the buffer.
- **Improved wink detection** (bundled from prior uncommitted work): Tracks other eye's minimum aperture during a wink — rejects if the other eye dipped below `openThreshold` at any point, catching asymmetric natural blinks. `bilateralRejectWindow` default widened from 0.1 to 0.15.
- **Settings revert button** (bundled): Added "Revert" button next to "Save Defaults" in settings.

### In Progress / Incomplete
- Nothing incomplete — all changes built and installed to /Applications

### Key Decisions
- Flush audio buffer (not just reset the differ) on terminal switch — this is the root cause fix
- 1.5 second trim window after delivery balances context for Whisper accuracy vs preventing re-transcription
- 0.5s interim interval chosen as balance between responsiveness and CPU load

### Files Changed
- `Sources/EyeTerm/Voice/VoiceTranscriptionBackend.swift` — added `flushAudio()`, `trimAudio(keepLastSeconds:)` to protocol
- `Sources/EyeTerm/Voice/AudioBufferManager.swift` — added `trimToLast(seconds:)`
- `Sources/EyeTerm/Voice/VoiceAudioPipeline.swift` — added `flushBuffer()`, `trimBuffer(keepLastSeconds:)`, changed `interimInterval` to 0.5
- `Sources/EyeTerm/Voice/WhisperKitBackend.swift` — implemented `flushAudio()`, `trimAudio(keepLastSeconds:)`
- `Sources/EyeTerm/Voice/WhisperCppBackend.swift` — implemented `flushAudio()`, `trimAudio(keepLastSeconds:)`
- `Sources/EyeTerm/App/AppCoordinator.swift` — call `flushAudio()` on dwell confirmed, call `trimAudio()` after interim delivery
- `Sources/EyeTerm/Utilities/BlinkGestureDetector.swift` — other-eye min tracking for wink rejection
- `Sources/EyeTerm/UI/SettingsView.swift` — revert button

### Known Issues
- None new

### Running Services
- eyeTerm.app installed to /Applications — not currently running

### Next Steps
- Test: speak while looking at Terminal A, switch gaze to Terminal B mid-sentence, verify B doesn't receive pre-switch text
- Test: new speech in Terminal B appears fresh, word by word
- Test: improved wink detection rejects natural blinks more reliably

---

## TODO — Future Features

### L2CS-Net CoreML Backend (Third Tracking Backend)
- Convert L2CS-Net PyTorch model to CoreML via coremltools (PyTorch → ONNX → CoreML)
- Creates a fully native third backend — no Python subprocess, no C++ dependencies
- L2CS-Net predicts gaze yaw/pitch angles from a single webcam frame with ~3.9 degree accuracy (best of evaluated options)
- MobileGaze variant (MobileNet/MobileOne backbones) available for faster inference
- Integration path: load .mlmodel in Swift, feed camera frames, get yaw/pitch, fuse with existing head/eye weight system
- Repo: github.com/Ahmednull/L2CS-Net (Apache 2.0 license)
- Lightweight variant: github.com/yakhyo/gaze-estimation
