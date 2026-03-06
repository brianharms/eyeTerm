import SwiftUI
import AVFoundation
import CoreMedia

struct CameraPreviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(AppCoordinator.self) private var coordinator

    private static func feedCameraName(from session: AVCaptureSession?) -> String {
        (session?.inputs.first as? AVCaptureDeviceInput)?.device.localizedName ?? ""
    }

    private static func trackingCameraName(id: String) -> String {
        guard !id.isEmpty else { return "system default" }
        return AVCaptureDevice(uniqueID: id)?.localizedName ?? id
    }

    private static func cameraAspectRatio(from session: AVCaptureSession?) -> CGSize {
        guard let session,
              let input = session.inputs.first as? AVCaptureDeviceInput else {
            return CGSize(width: 4, height: 3)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        return CGSize(width: Int(dims.width), height: Int(dims.height))
    }

    private static func videoDisplayRect(in viewSize: CGSize, session: AVCaptureSession?) -> CGRect {
        let ratio = cameraAspectRatio(from: session)
        let videoAspect = ratio.width / ratio.height
        let viewAspect = viewSize.width / viewSize.height
        let scaledWidth: CGFloat
        let scaledHeight: CGFloat
        if viewAspect > videoAspect {
            scaledWidth = viewSize.width
            scaledHeight = viewSize.width / videoAspect
        } else {
            scaledHeight = viewSize.height
            scaledWidth = viewSize.height * videoAspect
        }
        return CGRect(
            x: (viewSize.width - scaledWidth) / 2,
            y: (viewSize.height - scaledHeight) / 2,
            width: scaledWidth,
            height: scaledHeight
        )
    }

    var body: some View {
        @Bindable var appState = appState
        let session = appState.currentPreviewSession
        VStack(spacing: 0) {
            ZStack {
                if let session {
                    CameraPreviewRepresentable(captureSession: session)
                        .id(ObjectIdentifier(session))
                } else {
                    Color.black
                }

                GeometryReader { geometry in
                    let size = geometry.size
                    let videoRect = Self.videoDisplayRect(in: size, session: session)

                    // Eye visualization (face mesh + pupils)
                    if appState.showCameraEyeVisualization {
                        if let face = appState.faceObservationData {
                            FaceMeshLayer(faceData: face, videoRect: videoRect)
                            if let lp = face.leftPupilCenter {
                                Circle()
                                    .fill(.cyan)
                                    .frame(width: 5, height: 5)
                                    .position(
                                        x: videoRect.origin.x + (1 - lp.x) * videoRect.width,
                                        y: videoRect.origin.y + (1 - lp.y) * videoRect.height
                                    )
                            }
                            if let rp = face.rightPupilCenter {
                                Circle()
                                    .fill(.cyan)
                                    .frame(width: 5, height: 5)
                                    .position(
                                        x: videoRect.origin.x + (1 - rp.x) * videoRect.width,
                                        y: videoRect.origin.y + (1 - rp.y) * videoRect.height
                                    )
                            }
                        } else {
                            Text("No face detected")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }

                    // Quadrant grid overlay
                    if appState.showCameraDebugOverlay {
                        QuadrantGridOverlay(appState: appState, size: size)
                    }

                    // Wink indicators — positioned near the winking eye
                    if let wink = appState.lastWinkDisplay,
                       let face = appState.faceObservationData {
                        WinkEyeLabel(
                            text: wink,
                            faceData: face,
                            videoRect: videoRect,
                            viewSize: size
                        )
                    }

                    // Yaw/pitch readout (bottom-left) when eye viz on
                    if appState.showCameraEyeVisualization, let face = appState.faceObservationData {
                        VStack(alignment: .leading, spacing: 2) {
                            if let yaw = face.yaw {
                                Text("Yaw: \(String(format: "%+.3f", yaw))")
                            }
                            if let pitch = face.pitch {
                                Text("Pitch: \(String(format: "%+.3f", pitch))")
                            }
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                        .padding(5)
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    }

                    // Camera diagnostic (top-right) when debug overlay on
                    if appState.showCameraDebugOverlay {
                        let feedName = Self.feedCameraName(from: session)
                        // Use actual Python-reported camera when available; fall back to selectedCameraDeviceID
                        let trackingName: String = {
                            if !appState.actualTrackingCameraInfo.isEmpty {
                                return appState.actualTrackingCameraInfo
                            }
                            return Self.trackingCameraName(id: appState.selectedCameraDeviceID)
                        }()
                        // Mismatch when feed camera name doesn't appear anywhere in tracking info
                        let mismatch = !feedName.isEmpty && !trackingName.lowercased().contains(feedName.lowercased())
                        VStack(alignment: .trailing, spacing: 2) {
                            HStack(spacing: 4) {
                                Text("Feed:").foregroundStyle(.secondary)
                                Text(feedName.isEmpty ? "none" : feedName)
                                    .foregroundStyle(mismatch ? .orange : .green)
                            }
                            HStack(spacing: 4) {
                                Text("Tracking:").foregroundStyle(.secondary)
                                Text(trackingName)
                                    .foregroundStyle(mismatch ? .orange : .white)
                            }
                            if mismatch {
                                Text("MISMATCH ⚠️")
                                    .foregroundStyle(.orange)
                                    .fontWeight(.bold)
                            }
                        }
                        .font(.system(size: 10, design: .monospaced))
                        .padding(5)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                        .padding(.trailing, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
            }
            .frame(minWidth: 320, minHeight: 240)
            .clipped()

            // Toggle controls bar
            HStack(spacing: 12) {
                Toggle(isOn: $appState.showCameraEyeVisualization) {
                    Label("Gaze", systemImage: "eye")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)

                // Voice: start/stop voice backend directly, same as menu bar "Start Voice"
                Button {
                    if coordinator.activeVoiceBackend.isRunning {
                        coordinator.stopVoice()
                    } else {
                        Task { await coordinator.startVoice() }
                    }
                } label: {
                    Label("Voice", systemImage: appState.isVoiceActive ? "mic.fill" : "mic.slash")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Toggle voice transcription on/off")

                // Overlay: toggles both the main display overlay and the camera debug view
                Toggle(isOn: $appState.overlayAndFocusEnabled) {
                    Label("Overlay", systemImage: appState.overlayAndFocusEnabled ? "square.grid.2x2.fill" : "square.grid.2x2")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Toggle main display overlay and camera debug view")
                .onChange(of: appState.overlayAndFocusEnabled) { _, newValue in
                    appState.showCameraDebugOverlay = newValue
                }

                let videoDevices: [AVCaptureDevice] = {
                    let types: [AVCaptureDevice.DeviceType]
                    if #available(macOS 14.0, *) {
                        types = [.external, .builtInWideAngleCamera]
                    } else {
                        types = [.externalUnknown, .builtInWideAngleCamera]
                    }
                    return AVCaptureDevice.DiscoverySession(
                        deviceTypes: types,
                        mediaType: .video,
                        position: .unspecified
                    ).devices
                }()

                // Preview feed picker — swaps the camera in this window only
                Menu {
                    ForEach(videoDevices, id: \.uniqueID) { device in
                        Button(device.localizedName) {
                            coordinator.switchPreviewCamera(uniqueID: device.uniqueID)
                        }
                    }
                } label: {
                    Image(systemName: "camera")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Switch preview feed camera (this window only)")

                // Tracking camera picker — changes which camera eye tracking uses
                Menu {
                    ForEach(videoDevices, id: \.uniqueID) { device in
                        Button(device.localizedName) {
                            coordinator.selectTrackingCamera(uniqueID: device.uniqueID)
                        }
                    }
                } label: {
                    Image(systemName: "dot.scope")
                        .font(.system(size: 12, weight: .medium))
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Switch tracking camera (restarts eye tracking)")

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.ultraThickMaterial)
        }
    }
}

// MARK: - Face Mesh Layer

private struct FaceMeshLayer: View {
    let faceData: FaceObservationData
    let videoRect: CGRect

    var body: some View {
        ZStack {
            // Full face mesh contours (MediaPipe backend)
            if !faceData.faceMeshContours.isEmpty {
                ForEach(Array(faceData.faceMeshContours.enumerated()), id: \.offset) { _, pts in
                    MeshContourShape(points: pts, videoRect: videoRect)
                        .stroke(.green.opacity(0.8), lineWidth: 1)
                }
            } else {
                // Apple Vision fallback: bounding box
                FaceOverlayShape(faceData: faceData, videoRect: videoRect)
                    .stroke(.green, lineWidth: 1.5)
                EyeRegionShape(points: faceData.leftEyePoints, videoRect: videoRect)
                    .stroke(.red, lineWidth: 1)
                EyeRegionShape(points: faceData.rightEyePoints, videoRect: videoRect)
                    .stroke(.red, lineWidth: 1)
            }
        }
    }
}

// MARK: - Quadrant Grid Overlay

private struct QuadrantGridOverlay: View {
    let appState: AppState
    let size: CGSize

    private var cols: Int { max(1, appState.terminalGridColumns) }
    private var rows: Int { max(1, appState.terminalGridRows) }

    /// Gaze cell derived directly from smoothed eye point — works even without terminals configured.
    private var gazeCellFromPoint: Int? {
        guard appState.isEyeTrackingActive,
              appState.smoothedEyePoint != .zero else { return nil }
        let col = max(0, min(cols - 1, Int(appState.smoothedEyePoint.x * CGFloat(cols))))
        let row = max(0, min(rows - 1, Int(appState.smoothedEyePoint.y * CGFloat(rows))))
        return row * cols + col
    }

    /// Effective slots — use terminal-based slots when configured, else fall back to raw gaze cell.
    private var effectiveActiveSlot: Int? { appState.activeSlot ?? gazeCellFromPoint }
    private var effectiveDwellingSlot: Int? { appState.dwellingSlot ?? gazeCellFromPoint }

    /// The slot currently under the gaze — dwelling takes priority over settled focus.
    private var gazeSlot: Int? { effectiveDwellingSlot ?? effectiveActiveSlot }

    private func cellRect(col: Int, row: Int) -> CGRect {
        let w = size.width / CGFloat(cols)
        let h = size.height / CGFloat(rows)
        return CGRect(x: CGFloat(col) * w, y: CGFloat(row) * h, width: w, height: h)
    }

    private func slotLabel(_ slot: Int) -> String {
        guard slot < appState.terminalSlots.count else { return "Slot \(slot)" }
        return appState.terminalSlots[slot].label
    }

    private var gazeText: String {
        String(format: "%.2f, %.2f", appState.smoothedEyePoint.x, appState.smoothedEyePoint.y)
    }

    var body: some View {
        ZStack {
            // Stage 1: dwell gaze — dim white fill showing where you're looking
            if let dwell = effectiveDwellingSlot {
                let col = dwell % cols
                let row = dwell / cols
                let rect = cellRect(col: col, row: row)
                Rectangle()
                    .fill(.white.opacity(0.10))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeInOut(duration: 0.15), value: dwell)
            }

            // Stage 2: active focused slot — colored border + stronger fill
            if let active = effectiveActiveSlot {
                let col = active % cols
                let row = active / cols
                let rect = cellRect(col: col, row: row)
                Rectangle()
                    .fill(.cyan.opacity(0.15))
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeInOut(duration: 0.2), value: active)
                Rectangle()
                    .strokeBorder(.cyan.opacity(0.7), lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .animation(.easeInOut(duration: 0.2), value: active)

                // Debug info inside active cell
                VStack(alignment: .leading, spacing: 3) {
                    Text(slotLabel(active))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.cyan)
                    Text(gazeText)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.65))
                }
                .padding(7)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
                .position(x: rect.midX, y: rect.midY)
                .animation(.easeInOut(duration: 0.2), value: active)
            }

            // Grid lines
            Canvas { ctx, sz in
                let w = sz.width / CGFloat(cols)
                let h = sz.height / CGFloat(rows)
                var path = Path()
                for c in 1..<cols {
                    let x = CGFloat(c) * w
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: sz.height))
                }
                for r in 1..<rows {
                    let y = CGFloat(r) * h
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: sz.width, y: y))
                }
                ctx.stroke(path, with: .color(.white.opacity(0.3)), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Wink Eye Label

private struct WinkEyeLabel: View {
    let text: String
    let faceData: FaceObservationData
    let videoRect: CGRect
    let viewSize: CGSize

    /// True if this was a left-eye wink (user's left eye = right side of mirrored preview).
    private var isLeftWink: Bool {
        text.localizedCaseInsensitiveContains("left")
    }

    /// Average of a set of normalized Vision points converted to view coords (with x-flip).
    private func eyeCenter(_ points: [CGPoint]) -> CGPoint? {
        guard !points.isEmpty else { return nil }
        let avg = points.reduce(.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let nx = avg.x / CGFloat(points.count)
        let ny = avg.y / CGFloat(points.count)
        return CGPoint(
            x: videoRect.origin.x + (1 - nx) * videoRect.width,
            y: videoRect.origin.y + (1 - ny) * videoRect.height
        )
    }

    /// "[wink] Action" label from the raw display string.
    private var formattedLabel: String {
        let raw = text
            .replacingOccurrences(of: "(left wink)", with: "", options: .caseInsensitive)
            .replacingOccurrences(of: "(right wink)", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespaces)
        let action: String
        switch raw.lowercased() {
        case "esc esc", "double escape": action = "Esc ×2"
        case "enter":                    action = "Enter"
        case "esc", "escape":            action = "Esc"
        default:                         action = raw.isEmpty ? text : raw
        }
        return "[wink] \(action)"
    }

    var body: some View {
        // User's left eye → rendered on RIGHT side of flipped video
        // User's right eye → rendered on LEFT side of flipped video
        let pts = isLeftWink ? faceData.leftEyePoints : faceData.rightEyePoints
        if let center = eyeCenter(pts) {
            // Right wink → label on right side; left wink → label on left side
            let outwardOffset: CGFloat = isLeftWink ? -52 : 52
            let labelPos = CGPoint(x: center.x + outwardOffset, y: center.y)

            Text(formattedLabel)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                .position(labelPos)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                .animation(.easeOut(duration: 0.3), value: text)
        }
    }
}

// MARK: - NSViewRepresentable

private struct CameraPreviewRepresentable: NSViewRepresentable {
    let captureSession: AVCaptureSession

    func makeNSView(context: Context) -> CameraPreviewNSView {
        let view = CameraPreviewNSView()
        view.previewLayer.session = captureSession
        return view
    }

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {
        if nsView.previewLayer.session !== captureSession {
            nsView.previewLayer.session = captureSession
        }
    }
}

private final class CameraPreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        wantsLayer = true
        layer?.addSublayer(previewLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        previewLayer.frame = bounds
    }
}

// MARK: - Shapes

private struct MeshContourShape: Shape {
    let points: [CGPoint]
    let videoRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let converted = points.map { pt in
            CGPoint(x: videoRect.origin.x + (1 - pt.x) * videoRect.width,
                    y: videoRect.origin.y + (1 - pt.y) * videoRect.height)
        }
        path.move(to: converted[0])
        for pt in converted.dropFirst() { path.addLine(to: pt) }
        return path
    }
}

private struct FaceOverlayShape: Shape {
    let faceData: FaceObservationData
    let videoRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bb = faceData.boundingBox
        let x = videoRect.origin.x + (1 - bb.origin.x - bb.width) * videoRect.width
        let y = videoRect.origin.y + (1 - bb.origin.y - bb.height) * videoRect.height
        path.addRect(CGRect(x: x, y: y, width: bb.width * videoRect.width, height: bb.height * videoRect.height))
        return path
    }
}

private struct EyeRegionShape: Shape {
    let points: [CGPoint]
    let videoRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard points.count >= 2 else { return path }
        let converted = points.map { pt in
            CGPoint(x: videoRect.origin.x + (1 - pt.x) * videoRect.width,
                    y: videoRect.origin.y + (1 - pt.y) * videoRect.height)
        }
        path.move(to: converted[0])
        for pt in converted.dropFirst() { path.addLine(to: pt) }
        path.closeSubpath()
        return path
    }
}
