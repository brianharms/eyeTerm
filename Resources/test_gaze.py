#!/usr/bin/env python3
"""
Quick dev test for MediaPipe gaze tracking.

Modes:
  --web        MJPEG stream on localhost:8080 (works from subprocess / Claude Code)
  --terminal   Live single-line readout in terminal (numbers only, no GUI)
  (default)    cv2.imshow window (requires real terminal, not subprocess)

Press Ctrl-C to quit in any mode.
"""

import argparse
import cv2
import json
import math
import sys
import threading
import time
import webbrowser
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

import numpy as np
import mediapipe as mp

RIGHT_IRIS_CENTER = 468
LEFT_IRIS_CENTER = 473
RIGHT_EYE_INNER, RIGHT_EYE_OUTER = 133, 33
RIGHT_EYE_TOP, RIGHT_EYE_BOTTOM = 159, 145
LEFT_EYE_INNER, LEFT_EYE_OUTER = 362, 263
LEFT_EYE_TOP, LEFT_EYE_BOTTOM = 386, 374

RIGHT_EYE = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
LEFT_EYE = [362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398]

POSE_INDICES = [1, 199, 33, 263, 61, 291]
MODEL_POINTS = np.array([
    (0, 0, 0), (0, 330, -65), (-225, -170, -135),
    (225, -170, -135), (-150, 150, -125), (150, 150, -125)
], dtype=np.float64)

# ---------------------------------------------------------------------------
# Global settings & calibration state
# ---------------------------------------------------------------------------

_settings = {"head_weight": 0.85, "smoothing": 0.5}
_settings_lock = threading.Lock()

_smooth_gx = None
_smooth_gy = None

CALIBRATION_TARGETS = [
    (0.5, 0.5),
    (0.15, 0.15),
    (0.85, 0.15),
    (0.15, 0.85),
    (0.85, 0.85),
]
SETTLE_FRAMES = 30
COLLECT_FRAMES = 45

_calibration = {
    "active": False,
    "target_index": 0,
    "settle_count": 0,
    "samples": [],
    "collected": [],
    "transform": None,
    "status": "idle",
}
_cal_lock = threading.Lock()


def iris_ratio(lm, iris_idx, inner_idx, outer_idx, top_idx, bot_idx):
    iris, inner, outer = lm[iris_idx], lm[inner_idx], lm[outer_idx]
    top, bot = lm[top_idx], lm[bot_idx]
    ew = math.dist((inner.x, inner.y), (outer.x, outer.y))
    eh = math.dist((top.x, top.y), (bot.x, bot.y))
    rx = math.dist((iris.x, iris.y), (outer.x, outer.y)) / ew if ew > 1e-6 else 0.5
    ry = math.dist((iris.x, iris.y), (top.x, top.y)) / eh if eh > 1e-6 else 0.5
    return max(0, min(1, rx)), max(0, min(1, ry))


def head_pose(lm, w, h):
    pts = np.array([(lm[i].x * w, lm[i].y * h) for i in POSE_INDICES], dtype=np.float64)
    cam = np.array([[w, 0, w/2], [0, w, h/2], [0, 0, 1]], dtype=np.float64)
    ok, rvec, _ = cv2.solvePnP(MODEL_POINTS, pts, cam, np.zeros((4,1)), flags=cv2.SOLVEPNP_ITERATIVE)
    if not ok:
        return 0, 0
    R, _ = cv2.Rodrigues(rvec)
    sy = math.sqrt(R[0,0]**2 + R[1,0]**2)
    yaw = math.atan2(-R[2,0], sy)
    pitch = math.atan2(R[2,1], R[2,2])
    return yaw, pitch


def compute_affine_transform(collected):
    """Compute 2x3 affine transform from calibration samples using least-squares."""
    if len(collected) < 3:
        return None
    # Build system: for each point pair (raw -> target)
    # target_x = a*raw_x + b*raw_y + tx
    # target_y = c*raw_x + d*raw_y + ty
    n = len(collected)
    A = np.zeros((2 * n, 6))
    b = np.zeros(2 * n)
    for i, (raw, target) in enumerate(collected):
        A[2*i, 0] = raw[0]
        A[2*i, 1] = raw[1]
        A[2*i, 2] = 1.0
        b[2*i] = target[0]
        A[2*i+1, 3] = raw[0]
        A[2*i+1, 4] = raw[1]
        A[2*i+1, 5] = 1.0
        b[2*i+1] = target[1]
    result, _, _, _ = np.linalg.lstsq(A, b, rcond=None)
    transform = [[result[0], result[1], result[2]],
                 [result[3], result[4], result[5]]]
    return transform


def apply_transform(transform, gx, gy):
    """Apply 2x3 affine transform to gaze point."""
    if transform is None:
        return gx, gy
    a, b, tx = transform[0]
    c, d, ty = transform[1]
    nx = a * gx + b * gy + tx
    ny = c * gx + d * gy + ty
    return max(0, min(1, nx)), max(0, min(1, ny))


def annotate_frame(frame, lm, w, h):
    """Draw all overlays on frame and return gaze data dict."""
    # Eye contours
    for eye_idx in [LEFT_EYE, RIGHT_EYE]:
        pts = [(int((1 - lm[i].x) * w), int(lm[i].y * h)) for i in eye_idx]
        for i in range(len(pts)):
            cv2.line(frame, pts[i], pts[(i+1) % len(pts)], (0, 255, 255), 1)

    # Iris centers
    for idx in [LEFT_IRIS_CENTER, RIGHT_IRIS_CENTER]:
        cx = int((1 - lm[idx].x) * w)
        cy = int(lm[idx].y * h)
        cv2.circle(frame, (cx, cy), 4, (0, 0, 255), -1)

    # Iris ratios
    r_rx, r_ry = iris_ratio(lm, RIGHT_IRIS_CENTER, RIGHT_EYE_INNER, RIGHT_EYE_OUTER, RIGHT_EYE_TOP, RIGHT_EYE_BOTTOM)
    l_rx, l_ry = iris_ratio(lm, LEFT_IRIS_CENTER, LEFT_EYE_INNER, LEFT_EYE_OUTER, LEFT_EYE_TOP, LEFT_EYE_BOTTOM)
    avg_ix = (r_rx + (1 - l_rx)) / 2
    avg_iy = (r_ry + l_ry) / 2

    # Head pose
    yaw, pitch = head_pose(lm, w, h)

    # Fuse gaze (negated yaw/pitch for mirror display)
    with _settings_lock:
        head_weight = _settings["head_weight"]
    eye_weight = 1.0 - head_weight

    hx = 0.5 - yaw / 1.0
    hy = 0.5 - pitch / 0.6
    gx = max(0, min(1, head_weight * hx + eye_weight * avg_ix))
    gy = max(0, min(1, head_weight * hy + eye_weight * avg_iy))

    # Apply calibration transform if available
    with _cal_lock:
        transform = _calibration["transform"]
    gx, gy = apply_transform(transform, gx, gy)

    # Feed calibration if active
    with _cal_lock:
        if _calibration["active"]:
            ti = _calibration["target_index"]
            if ti < len(CALIBRATION_TARGETS):
                target = CALIBRATION_TARGETS[ti]
                if _calibration["settle_count"] < SETTLE_FRAMES:
                    _calibration["settle_count"] += 1
                    _calibration["status"] = f"settling {_calibration['settle_count']}/{SETTLE_FRAMES}"
                else:
                    _calibration["samples"].append((gx, gy))
                    count = len(_calibration["samples"])
                    _calibration["status"] = f"collecting {count}/{COLLECT_FRAMES}"
                    if count >= COLLECT_FRAMES:
                        raw_avg = (
                            sum(s[0] for s in _calibration["samples"]) / count,
                            sum(s[1] for s in _calibration["samples"]) / count,
                        )
                        _calibration["collected"].append((raw_avg, target))
                        _calibration["target_index"] += 1
                        _calibration["settle_count"] = 0
                        _calibration["samples"] = []
                        if _calibration["target_index"] >= len(CALIBRATION_TARGETS):
                            _calibration["transform"] = compute_affine_transform(_calibration["collected"])
                            _calibration["active"] = False
                            _calibration["status"] = "complete"

    # Draw calibration target if active
    with _cal_lock:
        if _calibration["active"]:
            ti = _calibration["target_index"]
            if ti < len(CALIBRATION_TARGETS):
                tx_norm, ty_norm = CALIBRATION_TARGETS[ti]
                tx_px, ty_px = int(tx_norm * w), int(ty_norm * h)
                # Crosshair
                size = 30
                cv2.line(frame, (tx_px - size, ty_px), (tx_px + size, ty_px), (0, 255, 255), 2)
                cv2.line(frame, (tx_px, ty_px - size), (tx_px, ty_px + size), (0, 255, 255), 2)
                cv2.circle(frame, (tx_px, ty_px), 8, (0, 255, 255), 2)
                # Progress bar
                settle = _calibration["settle_count"]
                samples = len(_calibration["samples"])
                if settle < SETTLE_FRAMES:
                    progress = settle / SETTLE_FRAMES
                    label = "Settling..."
                else:
                    progress = samples / COLLECT_FRAMES
                    label = "Look at target"
                bar_w = 200
                bar_h = 16
                bar_x = (w - bar_w) // 2
                bar_y = h - 50
                cv2.rectangle(frame, (bar_x, bar_y), (bar_x + bar_w, bar_y + bar_h), (80, 80, 80), -1)
                cv2.rectangle(frame, (bar_x, bar_y), (bar_x + int(bar_w * progress), bar_y + bar_h), (0, 255, 255), -1)
                cv2.putText(frame, f"{label} ({ti+1}/{len(CALIBRATION_TARGETS)})",
                            (bar_x, bar_y - 8), cv2.FONT_HERSHEY_SIMPLEX, 0.5, (0, 255, 255), 1)

    # Gaze point (raw)
    gaze_px = int(gx * w)
    gaze_py = int(gy * h)
    cv2.circle(frame, (gaze_px, gaze_py), 6, (0, 255, 0), -1)
    cv2.circle(frame, (gaze_px, gaze_py), 7, (255, 255, 255), 2)

    # Smoothed gaze point (EMA)
    global _smooth_gx, _smooth_gy
    with _settings_lock:
        alpha = 1.0 - _settings["smoothing"]
    if _smooth_gx is None:
        _smooth_gx, _smooth_gy = gx, gy
    else:
        _smooth_gx = alpha * gx + (1.0 - alpha) * _smooth_gx
        _smooth_gy = alpha * gy + (1.0 - alpha) * _smooth_gy
    sgx = int(_smooth_gx * w)
    sgy = int(_smooth_gy * h)
    cv2.circle(frame, (sgx, sgy), 6, (255, 0, 255), -1)
    cv2.circle(frame, (sgx, sgy), 7, (255, 255, 255), 2)

    # Quadrant
    if gx < 0.5:
        q = "TL" if gy < 0.5 else "BL"
    else:
        q = "TR" if gy < 0.5 else "BR"

    # HUD text
    cv2.putText(frame, f"Gaze: ({gx:.2f}, {gy:.2f}) [{q}]", (10, 30),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 255, 0), 2)
    cv2.putText(frame, f"Yaw: {yaw:+.3f}  Pitch: {pitch:+.3f}", (10, 60),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 200, 200), 1)
    cv2.putText(frame, f"Iris X: {avg_ix:.2f}  Y: {avg_iy:.2f}  W: {head_weight:.0%}H/{eye_weight:.0%}E", (10, 85),
                cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 200, 200), 1)

    # Quadrant grid
    cv2.line(frame, (w//2, 0), (w//2, h), (100, 100, 100), 1)
    cv2.line(frame, (0, h//2), (w, h//2), (100, 100, 100), 1)

    return {"gx": gx, "gy": gy, "q": q, "yaw": yaw, "pitch": pitch,
            "iris_x": avg_ix, "iris_y": avg_iy}


# ---------------------------------------------------------------------------
# MJPEG web stream
# ---------------------------------------------------------------------------

_latest_jpeg = None
_jpeg_lock = threading.Lock()

WEB_HTML = b"""<!DOCTYPE html>
<html><head><title>eyeTerm Gaze Test</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{background:#000;color:#eee;font-family:-apple-system,sans-serif;
     margin:0;padding:0;overflow:hidden}
img#stream{position:fixed;top:0;left:0;width:100vw;height:100vh;object-fit:cover}
.controls{display:flex;flex-wrap:wrap;align-items:center;gap:16px;
           position:fixed;bottom:20px;left:50%;transform:translateX(-50%);z-index:10;
           padding:12px 20px;background:rgba(26,26,26,0.85);backdrop-filter:blur(8px);
           border-radius:8px;border:1px solid #333}
.slider-group{display:flex;align-items:center;gap:8px}
.slider-group label{font-size:13px;color:#aaa;white-space:nowrap}
.slider-group input[type=range]{width:180px;accent-color:#0ff}
.slider-group .value{font-size:13px;color:#0ff;min-width:36px;text-align:right}
button{padding:6px 14px;border:1px solid #555;border-radius:6px;
       background:#222;color:#eee;font-size:13px;cursor:pointer}
button:hover{background:#333}
button:disabled{opacity:0.4;cursor:not-allowed}
.status{font-size:12px;color:#888;margin-left:8px}
.status.active{color:#0ff}
.status.complete{color:#0f0}
</style></head>
<body>
<img id="stream" src="/stream">
<div class="controls">
  <div class="slider-group">
    <label>Head Pose</label>
    <input type="range" id="weight" min="0" max="100" value="85">
    <label>Eye Tracking</label>
    <span class="value" id="wval">85%</span>
  </div>
  <div class="slider-group">
    <label>Smoothing</label>
    <input type="range" id="smooth" min="0" max="95" value="50">
    <span class="value" id="sval">50%</span>
  </div>
  <button id="cal-btn" onclick="startCal()">Calibrate</button>
  <button id="reset-btn" onclick="resetCal()">Reset Calibration</button>
  <span class="status" id="cal-status"></span>
</div>
<script>
const slider=document.getElementById('weight');
const wval=document.getElementById('wval');
const calBtn=document.getElementById('cal-btn');
const resetBtn=document.getElementById('reset-btn');
const calStatus=document.getElementById('cal-status');

const smoothSlider=document.getElementById('smooth');
const sval=document.getElementById('sval');

slider.addEventListener('input',()=>{
  const v=slider.value;
  wval.textContent=v+'%';
  fetch('/api/settings',{method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({head_weight:v/100})});
});

smoothSlider.addEventListener('input',()=>{
  const v=smoothSlider.value;
  sval.textContent=v+'%';
  fetch('/api/settings',{method:'POST',
    headers:{'Content-Type':'application/json'},
    body:JSON.stringify({smoothing:v/100})});
});

function startCal(){
  calBtn.disabled=true;
  fetch('/api/calibrate/start',{method:'POST'}).then(()=>{
    setTimeout(pollCal,300);
  });
}
function resetCal(){
  fetch('/api/calibrate/reset',{method:'POST'});
  calStatus.textContent='';
  calStatus.className='status';
  calBtn.disabled=false;
}
function pollCal(){
  fetch('/api/calibrate/status').then(r=>r.json()).then(d=>{
    calStatus.textContent=d.status;
    if(d.active){
      calStatus.className='status active';
      setTimeout(pollCal,200);
    }else{
      calStatus.className='status '+(d.status==='complete'?'complete':'');
      calBtn.disabled=false;
    }
  });
}
</script>
</body></html>"""


class MJPEGHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/":
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            self.wfile.write(WEB_HTML)
        elif self.path == "/stream":
            self.send_response(200)
            self.send_header("Content-Type", "multipart/x-mixed-replace; boundary=frame")
            self.end_headers()
            try:
                while True:
                    with _jpeg_lock:
                        jpeg = _latest_jpeg
                    if jpeg is None:
                        time.sleep(0.01)
                        continue
                    self.wfile.write(b"--frame\r\n")
                    self.wfile.write(b"Content-Type: image/jpeg\r\n\r\n")
                    self.wfile.write(jpeg)
                    self.wfile.write(b"\r\n")
                    time.sleep(0.033)
            except (BrokenPipeError, ConnectionResetError):
                pass
        elif self.path == "/api/settings":
            with _settings_lock:
                data = json.dumps(_settings)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data.encode())
        elif self.path == "/api/calibrate/status":
            with _cal_lock:
                data = json.dumps({
                    "active": _calibration["active"],
                    "status": _calibration["status"],
                    "target_index": _calibration["target_index"],
                    "total_targets": len(CALIBRATION_TARGETS),
                    "has_transform": _calibration["transform"] is not None,
                })
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(data.encode())
        else:
            self.send_error(404)

    def do_POST(self):
        if self.path == "/api/settings":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                updates = json.loads(body)
                with _settings_lock:
                    if "head_weight" in updates:
                        _settings["head_weight"] = max(0.0, min(1.0, float(updates["head_weight"])))
                    if "smoothing" in updates:
                        _settings["smoothing"] = max(0.0, min(0.95, float(updates["smoothing"])))
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                with _settings_lock:
                    self.wfile.write(json.dumps(_settings).encode())
            except (json.JSONDecodeError, ValueError):
                self.send_error(400)
        elif self.path == "/api/calibrate/start":
            with _cal_lock:
                _calibration["active"] = True
                _calibration["target_index"] = 0
                _calibration["settle_count"] = 0
                _calibration["samples"] = []
                _calibration["collected"] = []
                _calibration["transform"] = None
                _calibration["status"] = "starting"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
        elif self.path == "/api/calibrate/reset":
            with _cal_lock:
                _calibration["active"] = False
                _calibration["target_index"] = 0
                _calibration["settle_count"] = 0
                _calibration["samples"] = []
                _calibration["collected"] = []
                _calibration["transform"] = None
                _calibration["status"] = "idle"
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(b'{"ok":true}')
        else:
            self.send_error(404)

    def log_message(self, format, *args):
        pass


def run_web(cap, fm, port=8080):
    global _latest_jpeg

    server = ThreadingHTTPServer(("127.0.0.1", port), MJPEGHandler)
    server_thread = threading.Thread(target=server.serve_forever, daemon=True)
    server_thread.start()

    url = f"http://localhost:{port}"
    print(f"MJPEG stream at {url}  — Ctrl-C to quit")
    webbrowser.open(url)

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                continue
            h, w = frame.shape[:2]
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            res = fm.process(rgb)
            frame = cv2.flip(frame, 1)

            if res.multi_face_landmarks:
                lm = res.multi_face_landmarks[0].landmark
                annotate_frame(frame, lm, w, h)
            else:
                cv2.putText(frame, "No face detected", (10, 30),
                            cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

            _, jpeg = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 80])
            with _jpeg_lock:
                _latest_jpeg = jpeg.tobytes()
    except KeyboardInterrupt:
        print("\nStopping.")
    finally:
        server.shutdown()


# ---------------------------------------------------------------------------
# Terminal dashboard
# ---------------------------------------------------------------------------

def run_terminal(cap, fm):
    print("Terminal mode — Ctrl-C to quit")
    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                continue
            h, w = frame.shape[:2]
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            res = fm.process(rgb)

            if res.multi_face_landmarks:
                lm = res.multi_face_landmarks[0].landmark
                r_rx, r_ry = iris_ratio(lm, RIGHT_IRIS_CENTER, RIGHT_EYE_INNER, RIGHT_EYE_OUTER, RIGHT_EYE_TOP, RIGHT_EYE_BOTTOM)
                l_rx, l_ry = iris_ratio(lm, LEFT_IRIS_CENTER, LEFT_EYE_INNER, LEFT_EYE_OUTER, LEFT_EYE_TOP, LEFT_EYE_BOTTOM)
                avg_ix = (r_rx + (1 - l_rx)) / 2
                avg_iy = (r_ry + l_ry) / 2
                yaw, pitch = head_pose(lm, w, h)

                with _settings_lock:
                    head_weight = _settings["head_weight"]
                eye_weight = 1.0 - head_weight

                hx = 0.5 - yaw / 1.0
                hy = 0.5 - pitch / 0.6
                gx = max(0, min(1, head_weight * hx + eye_weight * avg_ix))
                gy = max(0, min(1, head_weight * hy + eye_weight * avg_iy))

                with _cal_lock:
                    transform = _calibration["transform"]
                gx, gy = apply_transform(transform, gx, gy)

                q = ("TL" if gy < 0.5 else "BL") if gx < 0.5 else ("TR" if gy < 0.5 else "BR")

                line = f"Face: YES | Gaze: ({gx:.2f}, {gy:.2f}) [{q}] | Yaw: {yaw:+.3f} | Pitch: {pitch:+.3f} | Iris: {avg_ix:.2f}/{avg_iy:.2f}"
            else:
                line = "Face: NO  | Gaze: --           | Yaw: --     | Pitch: --     | Iris: --"

            sys.stdout.write(f"\r{line}   ")
            sys.stdout.flush()
    except KeyboardInterrupt:
        print("\nStopping.")


# ---------------------------------------------------------------------------
# cv2.imshow (original default)
# ---------------------------------------------------------------------------

def run_window(cap, fm):
    print("Camera open. Press Q in the window to quit.")
    while True:
        ret, frame = cap.read()
        if not ret:
            continue
        h, w = frame.shape[:2]
        rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
        res = fm.process(rgb)
        frame = cv2.flip(frame, 1)

        if res.multi_face_landmarks:
            lm = res.multi_face_landmarks[0].landmark
            annotate_frame(frame, lm, w, h)
        else:
            cv2.putText(frame, "No face detected", (10, 30),
                        cv2.FONT_HERSHEY_SIMPLEX, 0.7, (0, 0, 255), 2)

        cv2.imshow("eyeTerm Gaze Test", frame)
        if cv2.waitKey(1) & 0xFF == ord('q'):
            break

    cv2.destroyAllWindows()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="eyeTerm gaze tracking dev test")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--web", action="store_true",
                       help="MJPEG stream on localhost:8080 (no GUI needed)")
    group.add_argument("--terminal", action="store_true",
                       help="Live single-line readout in terminal")
    parser.add_argument("--port", type=int, default=8080,
                        help="Port for --web mode (default: 8080)")
    args = parser.parse_args()

    mp_fm = mp.solutions.face_mesh
    fm = mp_fm.FaceMesh(max_num_faces=1, refine_landmarks=True,
                        min_detection_confidence=0.6, min_tracking_confidence=0.6)

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("ERROR: Cannot open camera")
        return

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)

    try:
        if args.web:
            run_web(cap, fm, port=args.port)
        elif args.terminal:
            run_terminal(cap, fm)
        else:
            run_window(cap, fm)
    finally:
        cap.release()
        fm.close()


if __name__ == "__main__":
    main()
