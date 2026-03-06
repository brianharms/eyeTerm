# Session Log

This file tracks session handoffs so the next Claude Code instance can quickly get up to speed.

---

## Session — 2026-03-06 00:15

### Goal
Fix startup camera mismatch (preview shows wrong camera on launch) and two crash bugs discovered during testing.

### Accomplished
- **v0.82 — Camera name sync**: `syncPreviewToTrackingCamera` changed from index-based to name-based device lookup. When Python's PyObjC resolves cameras by UID, it enumerates in built-in-first order — opposite of Swift's `opencvOrderedDevices()`. Using the camera name bypasses the enumeration order mismatch entirely. Index fallback retained for environments without PyObjC.
- **v0.83 — Main-thread NSWindow crash**: `startAll()` is non-isolated async; Swift 6 runs it on the cooperative thread pool. It was calling `showEyeTermOverlay()` (NSPanel creation = main-thread only), causing `EXC_BREAKPOINT`. Fixed by adding `@MainActor` to `startAll()` and wrapping all NSPanel/NSWindow ops in `DispatchQueue.main.async`.
- **v0.84 — Startup KVO crash**: `setupWindowLevelObservers()` called synchronously during `AppCoordinator.init()` crashed on macOS 26 with `assertionFailure` (~150ms after launch). Root cause: `NSApp.observe(\.windows, options: [.new, .old])` fires or asserts before the AppKit event loop is running. Fixed by deferring the call with `DispatchQueue.main.async`, matching the pattern already used for `showOnboardingWalkthrough()` below it.

### In Progress / Incomplete
- **Camera desync still occurs**: User can force a resync manually (camera picker in preview) but the automatic sync on startup is still unreliable. Root cause likely in `eye_tracker.py` `find_camera_index()` — Python's camera enumeration order doesn't consistently match what Swift's `syncPreviewToTrackingCamera` expects even with name-based lookup (e.g., partial name matches, Logitech vs MacBook Pro). The plan file at `~/.claude/plans/distributed-splashing-walrus.md` has additional planned features not yet implemented (Voice/Overlay toggles in preview toolbar, blockInteractionDuringSetup setting).

### Key Decisions
- Name-based camera lookup is order-independent and more robust than index-based, but still can fail if Python reports a different/shortened name than AVFoundation's `localizedName`
- `DispatchQueue.main.async` preferred over `@MainActor` on helper methods to avoid Swift 6 isolation errors from non-isolated callers

### Files Changed
- `Sources/EyeTerm/EyeTracking/MediaPipeBackend.swift` — `syncPreviewToTrackingCamera(cameraName:opencvIndex:onReady:)`, added `opencvOrderedDevices()`
- `Sources/EyeTerm/App/AppCoordinator.swift` — `@MainActor startAll()`, `DispatchQueue.main.async` in `showEyeTermOverlay()` and `updateOverlayVisibility()`, deferred `setupWindowLevelObservers()`
- `Sources/EyeTerm/App/AppVersion.swift` — bumped to 0.84

### Known Issues
- Camera preview and tracking camera still occasionally desync at startup; user has manual workaround via camera picker
- The plan at `~/.claude/plans/distributed-splashing-walrus.md` (Voice/Overlay toolbar toggles, blockInteractionDuringSetup) is unimplemented

### Running Services
- eyeTerm v0.84 running at `/Applications/eyeTerm.app`
- No dev servers or background processes

### Next Steps
- Investigate `eye_tracker.py` `find_camera_index()` more deeply — log the exact camera name Python resolves and compare to what AVFoundation returns in Swift to narrow down remaining desync
- Consider implementing the preview toolbar Voice/Overlay toggles from the plan file
- Consider adding `blockInteractionDuringSetup` setting

---

## Session — 2026-03-05

### Goal
Ensure calibration overlay appears on the selected external monitor.

### Accomplished
- **Calibration on external monitor (v0.54)**: Added `panel.setFrame(screen.frame, display: true)` after `makeKeyAndOrderFront(nil)` in `showCalibrationOverlay()`. Root cause: `makeKeyAndOrderFront` can cause macOS to reposition a menu-bar app's panel onto the main display; explicit `setFrame` after ordering front forces the window onto the target screen.

### Files Changed
- `Sources/EyeTerm/App/AppVersion.swift` — bumped 0.53 → 0.54
- `Sources/EyeTerm/App/AppCoordinator.swift` — `showCalibrationOverlay()`: added `panel.setFrame(screen.frame, display: true)` after `makeKeyAndOrderFront`

### Known Issues
- None new

### Running Services
- eyeTerm.app running at `/Applications/eyeTerm.app` (v0.54)

---

## Session — 2026-03-04 19:35

### Goal
1. Fix crash when clicking "Adopt Terminals" while eye tracking was active (EXC_BREAKPOINT / SIGTRAP — "Must only be used from the main thread")
2. Implement per-camera wink profiles (each camera device stores its own set of 7 wink thresholds)

### Accomplished
- **Crash fix (v0.52)**: `dismissEyeTermOverlay()` and `destroyCameraPreview()` in `AppCoordinator.swift` now dispatch `NSWindow.close()` to `DispatchQueue.main.async`. Root cause was `setupTerminals()` → `stopEyeTracking()` → `dismissEyeTermOverlay()` calling NSWindow ops off main thread from a cooperative async Task.
- **Per-camera wink profiles (v0.53)**:
  - Added `WinkProfile` struct to `AppState.swift` (below `WinkEvent`) with 7 threshold fields, `asDictionary()`, two inits (`memberwise` + `init?(from: [String: Double])`)
  - Added `winkProfiles: [String: WinkProfile]` property + `captureCurrentWinkProfile(for:)` + `applyWinkProfile(for:)` methods on `AppState`
  - Added `winkProfiles` serialization to both `saveSettingsAsDefaults()` and `persistSettings()` in `AppState`
  - Added `winkProfiles` loading + `applyWinkProfile(for: selectedCameraDeviceID)` call in `loadPersistedSettings()` in `AppState`
  - Added `private var previousCameraID: String = ""` to `AppCoordinator` properties
  - Initialized `previousCameraID = appState.selectedCameraDeviceID` in `AppCoordinator.init` after `refreshAvailableCameras()`
  - Added camera-change detection block at top of `pushAllSettings()`: if camera changed → `applyWinkProfile(for: currentCamID)`, else → `captureCurrentWinkProfile(for: currentCamID)`
  - Updated SettingsView `DisclosureGroup` label to show camera name: `"Wink Gestures — [Camera Name]"`
- Built and deployed v0.53 to `/Applications/eyeTerm.app`

### In Progress / Incomplete
- Nothing — both features are fully implemented and deployed

### Key Decisions
- **Thread safety via DispatchQueue.main.async** rather than `@MainActor` annotations — `@MainActor` caused a cascade of compiler errors at all non-actor callsites. Internal dispatch is more surgical.
- **Camera profile save/load in `pushAllSettings()`** — every settings change captures the current camera's profile; camera switches load the saved profile. The follow-up `pushAllSettings()` triggered by `applyWinkProfile`'s property changes is harmless (just re-saves the same values).
- **No `isApplyingProfile` flag needed** — the async dispatch of `withObservationTracking` onChange means re-entrancy isn't a real concern; the duplicate save on camera switch is benign.
- **`WinkProfile` uses `[String: Double]` for JSON** — consistent with the existing `[String: Any]` / `JSONSerialization` pattern in AppState persistence.

### Files Changed
- `Sources/EyeTerm/App/AppVersion.swift` — bumped 0.52 → 0.53
- `Sources/EyeTerm/App/AppState.swift` — added `WinkProfile` struct, `winkProfiles` property + methods, updated `saveSettingsAsDefaults`/`persistSettings`/`loadPersistedSettings`
- `Sources/EyeTerm/App/AppCoordinator.swift` — crash fix (main thread dispatch), `previousCameraID` property, init, camera-change detection in `pushAllSettings()`
- `Sources/EyeTerm/UI/SettingsView.swift` — DisclosureGroup label shows camera name

### Known Issues
- None from this session

### Running Services
- `eyeTerm.app` running at `/Applications/eyeTerm.app` (v0.53)

### Next Steps
- Test per-camera wink profiles with two different cameras: verify switching cameras loads distinct thresholds, verify "Save Defaults" persists per-camera profiles
- Consider adding a visual indicator in Settings when a camera has a saved custom profile vs. using defaults

---

## Session — 2026-02-26 18:30

### Goal
Increase max slider range for Closed Threshold and Dip Threshold in wink gesture settings. Rebuild and reinstall app.

### Accomplished
- **Closed Threshold slider max**: `0.3 → 0.6` in `SettingsView.swift`
- **Dip Threshold slider max**: `0.50 → 1.00` in `SettingsView.swift`
- Deleted old `/Applications/eyeTerm.app`, rebuilt (BUILD SUCCEEDED), installed to `/Applications/eyeTerm.app`, launched

### In Progress / Incomplete
- Runtime testing of the dynamic slot system (from prior session) still pending

### Key Decisions
- User wanted 2x headroom on both thresholds — some users may need higher aperture values depending on their camera/face geometry

### Files Changed
- `Sources/EyeTerm/UI/SettingsView.swift` — updated two `Slider(in:)` ranges

### Known Issues
- None new

### Running Services
- eyeTerm.app running from `/Applications/eyeTerm.app`

### Next Steps
- Test wink detection with the wider threshold ranges
- Test dynamic terminal slots: 2×2 and 3×2 grid creation, adopt existing terminals, verify gaze in empty space gives no slot focus

---

## Session — 2026-02-24 ~12:00

### Goal
Implement the "Dynamic Terminal Slots" plan: replace the hardcoded 4-quadrant `ScreenQuadrant` enum with a dynamic `Int`-indexed slot system supporting arbitrary N×M window grids. Gaze outside all slots → `nil` (no spurious focus).

### Accomplished
- **Deleted** `Sources/EyeTerm/EyeTracking/ScreenQuadrant.swift` and removed its reference from `eyeTerm.xcodeproj/project.pbxproj`
- **`AppState.swift`**: Added `TerminalSlot` struct (`id`, `normalizedRect`, `label`), `terminalSlots: [TerminalSlot]`, `activeSlot/focusedSlot/dwellingSlot: Int?`, `terminalGridColumns/Rows: Int`; removed `activeQuadrant`, `focusedQuadrant`, `dwellingQuadrant`
- **`EyeTrackingBackend.swift`**: Protocol callback changed from `((ScreenQuadrant?, Double) -> Void)?` → `((CGPoint?, Double) -> Void)?`
- **`DwellTimer.swift`**: All `ScreenQuadrant` types → `Int`; `update(slot: Int?)` signature
- **`EyeTracker.swift`**: Emits `CGPoint?` (smoothed gaze point) instead of `ScreenQuadrant?`
- **`MediaPipeBackend.swift`**: Same — emits `CGPoint?`
- **`WindowLayout.swift`**: Replaced `boundsForQuadrant()` with `normalizedRect(slotIndex:cols:rows:)` and `boundsForSlot(slotIndex:cols:rows:screen:)`
- **`TerminalManager.swift`**: Full rewrite — `windowIndices: [Int: Int]`, `setupTerminals(cols:rows:appState:)` tiles N×M windows and populates `appState.terminalSlots`, `adoptTerminals(appState:)` queries ALL windows via AppleScript; fixed `guard let result = try?` double-unwrap bug (removed redundant `let r = result`)
- **`AppCoordinator.swift`**: `onEyeUpdate` now hit-tests `CGPoint` against `appState.terminalSlots[].normalizedRect`, classifies to `activeSlot: Int?`; dwell/focus callbacks use `Int`; `manualFocus(slotIndex:)`; setup calls `terminalManager.setupTerminals(cols:rows:appState:)` / `adoptTerminals(appState:)`
- **`EyeOverlayView.swift`**: All `ForEach(ScreenQuadrant.allCases)` → `ForEach(appState.terminalSlots)`; `slotRect(_ slot:, size:)` helper using `normalizedRect`; slot comparisons via `slot.id`
- **`SettingsView.swift`**: Grid size steppers (Cols/Rows 1–6) in "Create New Terminals" section; Manual Focus uses slot buttons from `appState.terminalSlots`
- **`MenuBarView.swift`**: `focusedQuadrant` → slot lookup using `appState.focusedSlot` + `terminalSlots`
- **Build**: `BUILD SUCCEEDED` with only warnings (no errors)

### In Progress / Incomplete
Nothing — the plan is fully implemented and building cleanly.

### Key Decisions
- Slot classification (gaze point → slot index) lives in `AppCoordinator.wireCallbacks()` using `normalizedRect.contains(pt)` hit-test
- `focusedSlot` persists after gaze leaves all slots — voice/winks still route to last focused terminal
- `adoptTerminals()` queries ALL windows (no limit), one slot per window ordered front-to-back
- `setupTerminals()` takes `cols:rows:appState:` and passes `appState` for slot population on the MainActor

### Files Changed
- `Sources/EyeTerm/EyeTracking/ScreenQuadrant.swift` — DELETED
- `Sources/EyeTerm/App/AppState.swift`
- `Sources/EyeTerm/App/AppCoordinator.swift`
- `Sources/EyeTerm/EyeTracking/EyeTrackingBackend.swift`
- `Sources/EyeTerm/EyeTracking/DwellTimer.swift` (via `Utilities/DwellTimer.swift`)
- `Sources/EyeTerm/EyeTracking/EyeTracker.swift`
- `Sources/EyeTerm/EyeTracking/MediaPipeBackend.swift`
- `Sources/EyeTerm/Terminal/TerminalManager.swift`
- `Sources/EyeTerm/Terminal/WindowLayout.swift`
- `Sources/EyeTerm/UI/EyeOverlayView.swift`
- `Sources/EyeTerm/UI/SettingsView.swift`
- `Sources/EyeTerm/UI/MenuBarView.swift`
- `Sources/EyeTerm/Utilities/BlinkGestureDetector.swift`
- `Sources/EyeTerm/Utilities/DwellTimer.swift`
- `eyeTerm.xcodeproj/project.pbxproj` — removed ScreenQuadrant.swift file reference

### Known Issues
- None blocking. There are non-fatal warnings in `TerminalManager.swift` about unused `try?` results and Swift 6 sendability, pre-existing.
- `adoptTerminals()` normalized rect conversion assumes AppleScript Y origin matches screen origin — may need verification on non-primary screens.

### Running Services
None.

### Next Steps
- Test at runtime: launch app, verify "Create New Terminals" with 2×2 creates 4 tiled windows, overlay shows 4 slot borders
- Test 3×2 grid: change steppers to 3 cols × 2 rows, re-run setup, confirm 6 windows + 6 overlay borders
- Test "Adopt Existing": open 4 iTerm windows manually, click Adopt, confirm overlay matches actual window positions
- Verify gaze in empty space between terminals → no slot highlighted, no dwell progress
- Verify wink gesture still routes to correct slot after the refactor

---

## Session — 2026-02-23 22:00

### Goal
1. Fix all code review issues (Critical/High/Medium) across the codebase with a parallel agent team.
2. Reorder Settings sections: Wink Gestures before Voice.
3. Remove the non-functional Wink Calibration wizard entirely.
4. Replace it with a rich wink/blink detection log so the user can diagnose why winks aren't registering.

### Accomplished
- **11-file code review fix pass** (parallel 5-agent team, single build pass):
  - `AppState.swift`: removed hardcoded path, wrapped `saveSettingsAsDefaults()` in `#if DEBUG`
  - `TerminalManager.swift`: Terminal.app `do script` → `keystroke` via System Events; window index caching
  - `VoiceAudioPipeline.swift`: VAD moved to `vadQueue` serial dispatch; buffer mutations serialized
  - `WhisperKitBackend.swift`: `isTranscribing` TOCTOU fixed with `stateQueue.sync`; `isStopping` guard on result callbacks
  - `AppCoordinator.swift`: NSWindow level observer filtered to `NSApp.windows`; `[weak self]` on asyncAfter closures; CoreAudio listener block stored + removed in `deinit`; `winkCalibrationManager.onComplete` dispatched to main
  - `CalibrationManager.swift`: `isCalibrated` changed from `||` to `&&` (requires BOTH transforms)
  - `MediaPipeBackend.swift`: `waitUntilExit()` added in `stop()`
  - `BlinkGestureDetector.swift`: time-based `bilateralRejected` flag expiry
  - `MediaPipeSetupManager.swift`: pip install timeout with `DispatchWorkItem` + `resumeOnce` guard
  - `CommandParser.swift`: removed `("at", "@")` (kept `"at sign"`) to prevent false positives
  - `MediaPipeSetupView.swift`: `ForEach` with `.enumerated()` for index-based IDs
- **Settings reorder**: Wink Gestures section moved before Voice section
- **Wink calibration removed**: Deleted `WinkCalibrationManager.swift`, `WinkCalibrationView.swift`; removed `showWinkCalibration`, `winkCalibrationValid` from AppState + all persist paths; removed `startWinkCalibration()` + `winkCalibrationManager` from AppCoordinator
- **Wink diagnostic log added**:
  - `WinkDiagnosticEvent` struct in `BlinkGestureDetector.swift` with `Side` + `Outcome` enums
  - `onDiagnosticEvent` callback fires at every exit point of `checkWink()`: bilateralBlink, otherEyeNotOpen, otherEyeDipped(otherMin:), tooShort(duration:), tooLong(duration:), cooldown(remaining:), fired
  - `winkDiagnosticLog: [WinkDiagnosticEvent]` in AppState (capped at 8), `appendWinkDiagnostic()` helper
  - `AppCoordinator.wireBlinkDetector()` wires `onDiagnosticEvent` → `appState.appendWinkDiagnostic()` on main thread
  - `WinkDiagnosticLogView` + `WinkDiagnosticRowView` in `SettingsView.swift` replace the calibration button: shows side (L=blue/R=orange), duration, outcome text (green=fired, secondary=rejected)
- Build succeeded; app launched for testing

### In Progress / Incomplete
- User has not yet tested the diagnostic log — scheduled for tomorrow
- CLAUDE.md still mentions wink calibration wizard in "Recent Work" and "Next Steps" sections — should be updated to reflect removal

### Key Decisions
- Diagnostic events fire on **every** closed→open transition (not just wink candidates), so bilateral blinks also appear in the log — gives full picture of what the detector sees
- `bilateralBlink` rejection: the `bilateralRejected` flag fires at the rejection point even if duration is also out of bounds (flag checked first)
- Log capped at 8 entries (newest first in UI via `.reversed()`)
- `WinkDiagnosticEvent` defined in `BlinkGestureDetector.swift` — same module, no import needed

### Files Changed
- `Sources/EyeTerm/Utilities/BlinkGestureDetector.swift` — added `WinkDiagnosticEvent`, `onDiagnosticEvent`, rewrote `checkWink()`
- `Sources/EyeTerm/App/AppState.swift` — added `winkDiagnosticLog`, `appendWinkDiagnostic()`, removed calibration state
- `Sources/EyeTerm/App/AppCoordinator.swift` — wired `onDiagnosticEvent`, removed calibration manager/methods
- `Sources/EyeTerm/UI/SettingsView.swift` — replaced calibration button with `WinkDiagnosticLogView`; swapped Wink/Voice section order
- `Sources/EyeTerm/Utilities/WinkCalibrationManager.swift` — **deleted**
- `Sources/EyeTerm/UI/WinkCalibrationView.swift` — **deleted**
- `eyeTerm.xcodeproj/project.pbxproj` — regenerated via `xcodegen` to drop deleted file references
- (Prior in session) `TerminalManager.swift`, `VoiceAudioPipeline.swift`, `WhisperKitBackend.swift`, `CalibrationManager.swift`, `MediaPipeBackend.swift`, `MediaPipeSetupManager.swift`, `CommandParser.swift`, `MediaPipeSetupView.swift`

### Known Issues
- Wink detection reliability still untested with the new log — user will verify tomorrow
- Several pre-existing Swift warnings in AppCoordinator (Sendable, weak delegate, CFString UnsafeMutableRawPointer) — not new, not blocking

### Running Services
- eyeTerm.app launched from `/tmp/eyeterm-sim-build/Build/Products/Debug/eyeTerm.app`

### Next Steps
1. User tests wink detection log in Settings → Wink Gestures — verify events populate and rejection reasons are legible
2. If winks still don't fire despite good log values, check if `blinkDetector.openThreshold` / `closedThreshold` match the logged `otherEyeMin` values
3. Update CLAUDE.md: remove wink calibration wizard from "Recent Work Session 8" and "Next Steps" sections; add wink diagnostic log entry
4. Consider: log could show `otherEyeMin` value inline even for non-dip rejections (currently only shown for `.otherEyeDipped`) — useful for tuning `openThreshold`

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

## Session — 2026-02-23 21:00

### Goal
Three bug fixes: (1) add "Stop All" button to menu bar dropdown, (2) fix gibberish appearing in terminal during dictation, (3) fix status messages / hallucinations being sent to terminal as words. Also investigated and fixed misaligned terminal-to-quadrant mapping.

### Accomplished
- **Stop All button** (`MenuBarView.swift`): Added button below "Launch All", visible when `isEyeTrackingActive || isVoiceActive`. Calls `coordinator.stopAll()`.
- **Gibberish fix** (`AppCoordinator.swift`): Removed ALL terminal injection from `onPartialTranscription`. WhisperKit's interim tokens (mid-word fragments like "h", "hel", "hello") were being streamed into the terminal via `transcriptionDiffer.diff()`, producing visible correction backspaces. Partial transcription now only updates `appState.partialTranscription` for the overlay display. Final transcription (`onTranscription`) handles all terminal injection.
- **Hallucination filter** (`WhisperKitBackend.swift`): Added `isHallucination(_ text: String) -> Bool` and `knownHallucinations` set. Filters common Whisper artifacts ("thank you.", "you.", "hmm.", lone punctuation, <2 word characters) before calling `onTranscription` or `onPartialTranscription`. Filtered strings are print-logged.
- **Terminal quadrant alignment fix** (`TerminalManager.swift`): `focusTerminal` was using a stale `cachedWindowIndex`. Every `set index of window X to 1` AppleScript call renumbers ALL iTerm2 windows (frontmost=1), invalidating every other cached index. Fixed: `focusTerminal` now always does a fresh `findWindowIndex` (position-based scan), then wipes `cachedWindowIndex` and re-seeds only the focused quadrant at index 1. Subsequent `typeText` calls for that quadrant correctly use index 1.

### In Progress / Incomplete
- User has not yet tested the changes — app was launched but testing deferred

### Key Decisions
- Removed streaming partial injection entirely rather than trying to throttle/debounce it — terminal input should be atomic (type once, correctly), not streamed with corrections
- Hallucination blocklist kept simple (static set + char count) — no WhisperKit `DecodingOptions` changes to avoid introducing model config complexity
- `focusTerminal` no longer uses the cache at all for the initial lookup — position scan is the source of truth; cache only used for same-quadrant `typeText` calls after a focus

### Files Changed
- `Sources/EyeTerm/UI/MenuBarView.swift` — Stop All button
- `Sources/EyeTerm/App/AppCoordinator.swift` — stripped terminal injection from `onPartialTranscription`
- `Sources/EyeTerm/Voice/WhisperKitBackend.swift` — `isHallucination()` + `knownHallucinations`, applied in `transcribe()` and `transcribeInterim()`
- `Sources/EyeTerm/Terminal/TerminalManager.swift` — `focusTerminal` always fresh-scans, cache invalidated + re-seeded after focus

### Known Issues
- Changes untested by user — scheduled for next session
- `trimAudio(keepLastSeconds:)` calls were only in the partial injection path (now removed). Final transcription path never trims. If a very long utterance is captured, Whisper will re-transcribe the full buffer. Not a regression — was always true for the final path.

### Running Services
- eyeTerm.app running from `/tmp/eyeterm-sim-build/Build/Products/Debug/eyeTerm.app`

### Next Steps
- User to test: dictate into terminal, verify no gibberish before words appear
- User to test: speak during silence, verify "thank you" / "hmm" etc. don't fire
- User to test: look at each quadrant, verify the correct terminal gets focused
- User to test: Stop All button visible and functional when tracking/voice is running

---

## Session — 2026-03-01 21:10

### Goal
Fix SFSpeechRecognizer voice backend (user rejected WhisperKit), fix crash on voice enable, fix waveform/transcription not showing, fix debug overlay quadrant highlighting, add version tracking, make quadrant highlights work without terminals launched.

### Accomplished
- **SFSpeechRecognizer backend fully repaired**: installTap before engine.start() (prevents ObjC exception crash), explicit float32 tap format (fixes nil floatChannelData / no waveform), removed requiresOnDeviceRecognition (was silently failing)
- **Built-in mic default**: CoreAudio scan for kAudioDeviceTransportTypeBuiltIn — always prefers internal MIC over AirPods/system default
- **@Observable dict mutation fix**: slotPartialTranscriptions direct subscript mutation never fired property setter → added `setPartial(_:forSlot:)` using full dict reassignment; AppCoordinator updated to use it
- **dropLast() removed**: Was WhisperKit-specific workaround cutting off last word; removed for SFSpeechRecognizer
- **Debug overlay quadrant fix**: ForEach was inside showQuadrantHighlighting guard — moved outside so slots always render in debug mode
- **AppVersion.swift added**: Enum with `static let current`, shown in menu bar dropdown. v0.01→0.05 across sessions
- **Fallback quadrant slots**: Both DebugOverlayContent and SubtleOverlayContent now compute `displaySlots` — if terminalSlots is empty, renders 4 equal placeholder quadrants so highlighting works before any terminals are adopted
- **Voice confirmed working** by user in quiet environment
- Built and installed v0.05

### In Progress / Incomplete
- Nothing — all session goals completed

### Key Decisions
- Version must increment on every build (saved to MEMORY.md)
- SFSpeechRecognizer is the preferred backend — WhisperKit was rejected by user
- Fallback slots are computed only in the view layer, not stored in AppState — keeps state clean

### Files Changed
- `Sources/EyeTerm/Voice/SFSpeechRecognizerBackend.swift` — full rewrite: float32 tap, built-in mic detection, session ID flush logic, silence VAD
- `Sources/EyeTerm/App/AppVersion.swift` — NEW file, `enum AppVersion { static let current = "0.05" }`
- `Sources/EyeTerm/App/AppState.swift` — added `setPartial(_:forSlot:)` helper
- `Sources/EyeTerm/App/AppCoordinator.swift` — all 6 slotPartialTranscriptions mutations → setPartial(), onPartialTranscription stores under diagSlot
- `Sources/EyeTerm/UI/EyeOverlayView.swift` — fallback displaySlots in Debug + Subtle overlays, dropLast() removed, ForEach moved outside showQuadrantHighlighting guard
- `Sources/EyeTerm/UI/MenuBarView.swift` — version display in dropdown
- `eyeTerm.xcodeproj/project.pbxproj` — regenerated via xcodegen to include AppVersion.swift

### Known Issues
- Voice works best in quiet environments (expected — SFSpeechRecognizer limitation)

### Running Services
- eyeTerm.app v0.05 running from `/tmp/eyeterm-sim-build/Build/Products/Debug/eyeTerm.app`

### Next Steps
- Test dictation: verify partial transcriptions appear in Settings diagnostics and overlay bubbles
- Test quadrant highlighting without any terminals adopted (should now show 4 placeholder rects)
- Consider: dictation display fade animation (pops in/out currently)
- Consider: per-quadrant terminal label in subtle overlay

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

---

## Session — 2026-03-03 23:56

### Goal
Fix the rename-window Claude Code skill (TTY approach wasn't working), add persistent window renaming to eyeTerm's terminal setup, and fix the permissions gate that was hiding the menu bar status item.

### Accomplished
- **v0.41** — Voice overlay auto-dismiss: after final transcription, partial text clears after 4s delay (`partialClearTask` in AppCoordinator, `clearAllPartials()` on AppState)
- **v0.42** — Permissions gate: `startAll()` checks all permissions first, shows PermissionsView with `onAllGrantedDone` callback before launching terminals. "Launch eyeTerm" button appears (green, prominent) when all permissions granted.
- **v0.43** — Fixed menu bar disappearing after permissions panel: removed `NSApp.activate(ignoringOtherApps: true)` from `showPermissionsPanel()`; removed `requestAccessibility()` and `requestAutomation()` from `startAll()` (only camera/mic/speech are auto-requested; accessibility/automation left to individual Grant buttons)
- **v0.44** — Persistent window rename in TerminalManager: replaced direct `set name to` AppleScript (non-persistent) with Cmd+I → Tab×3 → type → Enter → Cmd+W dialog approach (persistent). Updated `setupProjectTerminals()` rename block.
- **rename-window skill** rewritten to: single-window only, Tab×3 to Window Title field, Cmd+W to close dialog
- **rename-all skill** created (`~/.claude/commands/rename-all.md`): renames ALL iTerm2 windows, isolated dialog cycle per window
- Confirmed accessibility tree of Edit Session dialog: 5 AXTextFields in `tab group 1 of group 1 of window "Edit Session"`, field 5 = Window Title (current value). Tab×3 from dialog open lands on Window Title field.

### In Progress / Incomplete
- rename-all and rename-window skills have NOT been live-tested beyond the single window test (which succeeded). The per-window loop in rename-all is untested.
- TerminalManager's new Cmd+I approach in `setupProjectTerminals()` is untested — requires a full terminal launch with `renameWindowsToProjectName: true`.

### Key Decisions
- **Tab×3 over accessibility tree traversal**: discovered Tab×3 from dialog open reliably lands on Window Title field. Accessibility approach (AXTextField by index) failed because fields are inside nested tab group.
- **Per-window dialog cycle**: each window opens/closes its own dialog cycle. Dialog stays open between windows was rejected because keystrokes could leak to terminal shells if dialog loses focus on window switch.
- **Cmd+W closes dialog (not terminal)**: after Enter in dialog, dialog remains frontmost. Cmd+W closes the dialog panel. No second Cmd+I needed.
- **Don't call `NSApp.activate()` on LSUIElement apps**: known to destabilize status bar items. Removed from `showPermissionsPanel()`.
- **startAll() only auto-requests camera/mic/speech**: accessibility opens System Preferences (can't auto-confirm), automation targets iTerm2 (may not be running). These are left to the PermissionsView's individual Grant buttons.

### Files Changed
- `Sources/EyeTerm/App/AppVersion.swift` — bumped 0.40 → 0.41 → 0.42 → 0.43 → 0.44
- `Sources/EyeTerm/App/AppState.swift` — added `clearAllPartials()`
- `Sources/EyeTerm/App/AppCoordinator.swift` — `partialClearTask`, rewritten `startAll()`, updated `showPermissionsPanel()` (removed NSApp.activate)
- `Sources/EyeTerm/UI/PermissionsView.swift` — added `onAllGrantedDone` callback, `isGateMode`, conditional "Launch eyeTerm" button
- `Sources/EyeTerm/Terminal/TerminalManager.swift` — renamed block in `setupProjectTerminals()` now uses Cmd+I dialog approach
- `~/.claude/commands/rename-window.md` — rewritten: single-window, Tab×3, Cmd+W
- `~/.claude/commands/rename-all.md` — NEW: renames all iTerm2 windows

### Known Issues
- `renameWindowsToProjectName` toggle in SettingsView (line 830) exists and persists correctly. eyeTerm's new rename approach uses `iTermWindowIDs[i]` — if a window ID is nil for a slot, that slot is silently skipped.
- `waitForPromptDialog()` in TerminalManager was designed for Claude Code sessions running `/rename-window` (which opened sheets). Now that eyeTerm handles rename natively, this stagger mechanism may be redundant for the rename step (it's still used for `initialPrompt` staggering).

### Running Services
- eyeTerm v0.44 launched at `/Applications/eyeTerm.app`

### Next Steps
- Test `rename-all` skill with multiple iTerm2 windows open
- Test eyeTerm terminal setup with `renameWindowsToProjectName: true` to verify Cmd+I approach works during setup
- Consider whether `waitForPromptDialog()` stagger is still needed now that eyeTerm handles rename internally
