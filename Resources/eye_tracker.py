#!/usr/bin/env python3
"""
eyeTerm MediaPipe Gaze Tracker

Captures webcam frames, runs MediaPipe Face Mesh with iris landmarks,
and outputs gaze estimation as JSON lines on stdout.

Run with -u flag for unbuffered output.
"""

import sys
import json
import math
import cv2
import numpy as np
import mediapipe as mp

# Iris landmark indices (refine_landmarks=True required)
RIGHT_IRIS_CENTER = 468
LEFT_IRIS_CENTER = 473

# Eye corner indices (subject's perspective)
RIGHT_EYE_INNER = 133
RIGHT_EYE_OUTER = 33
RIGHT_EYE_TOP = 159
RIGHT_EYE_BOTTOM = 145

LEFT_EYE_INNER = 362
LEFT_EYE_OUTER = 263
LEFT_EYE_TOP = 386
LEFT_EYE_BOTTOM = 374

# Eye contour indices for overlay
RIGHT_EYE_CONTOUR = [33, 7, 163, 144, 145, 153, 154, 155, 133, 173, 157, 158, 159, 160, 161, 246]
LEFT_EYE_CONTOUR = [362, 382, 381, 380, 374, 373, 390, 249, 263, 466, 388, 387, 386, 385, 384, 398]

# Face mesh contour groups for overlay visualization
FACE_OVAL_INDICES = [10, 338, 297, 332, 284, 251, 389, 356, 454, 323, 361, 288,
                     397, 365, 379, 378, 400, 377, 152, 148, 176, 149, 150, 136,
                     172, 58, 132, 93, 234, 127, 162, 21, 54, 103, 67, 109]
LEFT_EYEBROW_INDICES  = [276, 283, 282, 295, 285, 336, 296, 334, 293, 300]
RIGHT_EYEBROW_INDICES = [46,  53,  52,  65,  55,  107, 66,  105, 63,  70]
NOSE_BRIDGE_INDICES   = [168, 6, 197, 195, 5, 4, 1]
LIPS_OUTER_INDICES    = [61, 185, 40, 39, 37, 0, 267, 269, 270, 409, 291,
                         375, 321, 405, 314, 17, 84, 181, 91, 146, 61]

# 3D model points for head pose estimation (generic face model)
MODEL_POINTS = np.array([
    (0, 0, 0),            # Nose tip
    (0, 330, -65),         # Chin
    (-225, -170, -135),    # Left eye outer
    (225, -170, -135),     # Right eye outer
    (-150, 150, -125),     # Left mouth corner
    (150, 150, -125),      # Right mouth corner
], dtype=np.float64)

# Corresponding landmark indices
POSE_INDICES = [1, 199, 33, 263, 61, 291]


def compute_iris_ratio(landmarks, iris_idx, inner_idx, outer_idx, top_idx, bottom_idx):
    iris = landmarks[iris_idx]
    inner = landmarks[inner_idx]
    outer = landmarks[outer_idx]
    top = landmarks[top_idx]
    bottom = landmarks[bottom_idx]

    eye_w = math.dist((inner.x, inner.y), (outer.x, outer.y))
    if eye_w < 1e-6:
        rx = 0.5
    else:
        rx = math.dist((iris.x, iris.y), (outer.x, outer.y)) / eye_w

    eye_h = math.dist((top.x, top.y), (bottom.x, bottom.y))
    if eye_h < 1e-6:
        ry = 0.5
    else:
        ry = math.dist((iris.x, iris.y), (top.x, top.y)) / eye_h

    return max(0.0, min(1.0, rx)), max(0.0, min(1.0, ry))


def compute_head_pose(landmarks, frame_w, frame_h):
    image_points = np.array([
        (landmarks[i].x * frame_w, landmarks[i].y * frame_h)
        for i in POSE_INDICES
    ], dtype=np.float64)

    focal_length = frame_w
    center = (frame_w / 2, frame_h / 2)
    camera_matrix = np.array([
        [focal_length, 0, center[0]],
        [0, focal_length, center[1]],
        [0, 0, 1]
    ], dtype=np.float64)

    success, rvec, _ = cv2.solvePnP(
        MODEL_POINTS, image_points, camera_matrix,
        np.zeros((4, 1)), flags=cv2.SOLVEPNP_ITERATIVE
    )
    if not success:
        return 0.0, 0.0

    rmat, _ = cv2.Rodrigues(rvec)
    sy = math.sqrt(rmat[0, 0] ** 2 + rmat[1, 0] ** 2)
    yaw = math.atan2(-rmat[2, 0], sy)
    pitch = math.atan2(rmat[2, 1], rmat[2, 2])

    return yaw, pitch


def emit(obj):
    print(json.dumps(obj), flush=True)


def main():
    mp_face_mesh = mp.solutions.face_mesh
    face_mesh = mp_face_mesh.FaceMesh(
        max_num_faces=1,
        refine_landmarks=True,
        min_detection_confidence=0.6,
        min_tracking_confidence=0.6,
    )

    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        emit({"error": "Cannot open camera"})
        sys.exit(1)

    cap.set(cv2.CAP_PROP_FRAME_WIDTH, 640)
    cap.set(cv2.CAP_PROP_FRAME_HEIGHT, 480)
    cap.set(cv2.CAP_PROP_FPS, 30)

    emit({"status": "started"})

    try:
        while True:
            ret, frame = cap.read()
            if not ret:
                continue

            frame_h, frame_w = frame.shape[:2]
            rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            results = face_mesh.process(rgb)

            if not results.multi_face_landmarks:
                emit({"face_detected": False})
                continue

            lm = results.multi_face_landmarks[0].landmark

            # Iris ratios
            r_rx, r_ry = compute_iris_ratio(lm, RIGHT_IRIS_CENTER,
                                            RIGHT_EYE_INNER, RIGHT_EYE_OUTER,
                                            RIGHT_EYE_TOP, RIGHT_EYE_BOTTOM)
            l_rx, l_ry = compute_iris_ratio(lm, LEFT_IRIS_CENTER,
                                            LEFT_EYE_INNER, LEFT_EYE_OUTER,
                                            LEFT_EYE_TOP, LEFT_EYE_BOTTOM)
            avg_ix = (r_rx + (1 - l_rx)) / 2
            avg_iy = (r_ry + l_ry) / 2

            # Head pose
            yaw, pitch = compute_head_pose(lm, frame_w, frame_h)

            # Fuse: head pose (85%) + iris ratio (15%)
            head_x = 0.5 - (yaw / 1.0)
            head_y = 0.5 - (pitch / 0.6)
            gaze_x = max(0.0, min(1.0, 0.85 * head_x + 0.15 * avg_ix))
            gaze_y = max(0.0, min(1.0, 0.85 * head_y + 0.15 * avg_iy))

            # Quadrant
            if gaze_x < 0.5:
                q = "topLeft" if gaze_y < 0.5 else "bottomLeft"
            else:
                q = "topRight" if gaze_y < 0.5 else "bottomRight"

            # Confidence
            conf = min(1.0, max(0.3, 0.5 + 0.5 * (1.0 - abs(avg_ix - 0.5) * 2)))

            # Face bounding box from landmarks
            xs = [l.x for l in lm]
            ys = [l.y for l in lm]
            fx, fy = min(xs), min(ys)
            fw, fh = max(xs) - fx, max(ys) - fy

            # Eye contour points and pupil centers for overlay
            left_eye_pts = [[round(lm[i].x, 4), round(lm[i].y, 4)] for i in LEFT_EYE_CONTOUR]
            right_eye_pts = [[round(lm[i].x, 4), round(lm[i].y, 4)] for i in RIGHT_EYE_CONTOUR]
            left_pupil = [round(lm[LEFT_IRIS_CENTER].x, 4), round(lm[LEFT_IRIS_CENTER].y, 4)]
            right_pupil = [round(lm[RIGHT_IRIS_CENTER].x, 4), round(lm[RIGHT_IRIS_CENTER].y, 4)]

            # Face mesh contour groups for camera preview visualization
            face_oval      = [[round(lm[i].x, 4), round(lm[i].y, 4)] for i in FACE_OVAL_INDICES]
            left_eyebrow   = [[round(lm[i].x, 4), round(lm[i].y, 4)] for i in LEFT_EYEBROW_INDICES]
            right_eyebrow  = [[round(lm[i].x, 4), round(lm[i].y, 4)] for i in RIGHT_EYEBROW_INDICES]
            nose_bridge    = [[round(lm[i].x, 4), round(lm[i].y, 4)] for i in NOSE_BRIDGE_INDICES]
            lips_outer     = [[round(lm[i].x, 4), round(lm[i].y, 4)] for i in LIPS_OUTER_INDICES]

            emit({
                "face_detected": True,
                "gaze_x": round(gaze_x, 4),
                "gaze_y": round(gaze_y, 4),
                "confidence": round(conf, 4),
                "quadrant": q,
                "head_yaw": round(yaw, 4),
                "head_pitch": round(pitch, 4),
                "face_bbox": [round(fx, 4), round(fy, 4), round(fw, 4), round(fh, 4)],
                "left_pupil": left_pupil,
                "right_pupil": right_pupil,
                "left_eye_points": left_eye_pts,
                "right_eye_points": right_eye_pts,
                "iris_ratio_x": round(avg_ix, 4),
                "iris_ratio_y": round(avg_iy, 4),
                "face_oval": face_oval,
                "left_eyebrow": left_eyebrow,
                "right_eyebrow": right_eyebrow,
                "nose_bridge": nose_bridge,
                "lips_outer": lips_outer,
            })

    except KeyboardInterrupt:
        pass
    finally:
        cap.release()
        face_mesh.close()


if __name__ == "__main__":
    main()
