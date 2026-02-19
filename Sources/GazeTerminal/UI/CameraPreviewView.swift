import SwiftUI
import AVFoundation
import CoreMedia

struct CameraPreviewView: View {
    @Environment(AppState.self) private var appState
    let captureSession: AVCaptureSession?

    /// Query the actual video dimensions from the capture session's camera device.
    private static func cameraAspectRatio(from session: AVCaptureSession?) -> CGSize {
        guard let session,
              let input = session.inputs.first as? AVCaptureDeviceInput else {
            return CGSize(width: 4, height: 3)
        }
        let dims = CMVideoFormatDescriptionGetDimensions(input.device.activeFormat.formatDescription)
        return CGSize(width: Int(dims.width), height: Int(dims.height))
    }

    /// Compute the aspect-fill rect: the video scaled to completely fill the view, with excess cropped.
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
        ZStack {
            if let captureSession {
                CameraPreviewRepresentable(captureSession: captureSession)
            } else {
                Color.black
            }

            GeometryReader { geometry in
                let size = geometry.size
                let videoRect = Self.videoDisplayRect(in: size, session: captureSession)
                if let face = appState.faceObservationData {
                    FaceOverlayShape(faceData: face, videoRect: videoRect)
                        .stroke(.green, lineWidth: 1.5)

                    EyeRegionShape(points: face.leftEyePoints, videoRect: videoRect)
                        .stroke(.red, lineWidth: 1)
                    EyeRegionShape(points: face.rightEyePoints, videoRect: videoRect)
                        .stroke(.red, lineWidth: 1)

                    if let lp = face.leftPupilCenter {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                            .position(
                                x: videoRect.origin.x + (1 - lp.x) * videoRect.width,
                                y: videoRect.origin.y + (1 - lp.y) * videoRect.height
                            )
                    }
                    if let rp = face.rightPupilCenter {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                            .position(
                                x: videoRect.origin.x + (1 - rp.x) * videoRect.width,
                                y: videoRect.origin.y + (1 - rp.y) * videoRect.height
                            )
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        if let yaw = face.yaw {
                            Text("Yaw: \(String(format: "%+.3f", yaw))")
                        }
                        if let pitch = face.pitch {
                            Text("Pitch: \(String(format: "%+.3f", pitch))")
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.green)
                    .padding(6)
                    .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                    .position(x: 70, y: size.height - 30)
                } else {
                    Text("No face detected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minWidth: 320, minHeight: 240)
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

    func updateNSView(_ nsView: CameraPreviewNSView, context: Context) {}
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

// MARK: - Overlay Shapes

private struct FaceOverlayShape: Shape {
    let faceData: FaceObservationData
    let videoRect: CGRect

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let bb = faceData.boundingBox
        let x = videoRect.origin.x + (1 - bb.origin.x - bb.width) * videoRect.width
        let y = videoRect.origin.y + (1 - bb.origin.y - bb.height) * videoRect.height
        let w = bb.width * videoRect.width
        let h = bb.height * videoRect.height
        path.addRect(CGRect(x: x, y: y, width: w, height: h))
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
        for pt in converted.dropFirst() {
            path.addLine(to: pt)
        }
        path.closeSubpath()
        return path
    }
}
