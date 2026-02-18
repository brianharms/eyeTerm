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
