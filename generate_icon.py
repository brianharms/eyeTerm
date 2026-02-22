#!/usr/bin/env python3
"""Generate eyeTerm app icon: clean blue eye on white background."""

from PIL import Image, ImageDraw
import math

SIZE = 1024
# Use supersampling for smooth lines
SCALE = 4
BIG = SIZE * SCALE
img = Image.new("RGBA", (BIG, BIG), (255, 255, 255, 255))
draw = ImageDraw.Draw(img)

blue = (40, 110, 210)
stroke_w = 28 * SCALE

cx = BIG // 2
cy = BIG // 2

eye_w = 400 * SCALE
eye_h = 220 * SCALE

def almond(t, h_scale=1.0):
    return h_scale * eye_h * (max(0, 1 - t * t) ** 1.2)

num_pts = 800

# Build closed upper almond (thick stroke via filled polygon)
def make_almond_band(h_upper, h_lower, thickness):
    """Create a closed polygon representing a thick stroke of an almond curve."""
    outer = []
    inner = []
    half = thickness / 2

    for i in range(num_pts + 1):
        t = -1.0 + 2.0 * i / num_pts
        x = cx + eye_w * t
        y_up = cy - almond(t, h_upper)
        y_lo = cy + almond(t, h_lower)

        # Normal direction (approximate via finite difference)
        dt = 0.001
        t2 = min(1.0, t + dt)
        y_up2 = cy - almond(t2, h_upper)
        y_lo2 = cy + almond(t2, h_lower)
        x2 = cx + eye_w * t2

        # Upper curve normals
        dx_u = x2 - x
        dy_u = y_up2 - y_up
        length_u = math.sqrt(dx_u * dx_u + dy_u * dy_u) or 1
        nx_u = -dy_u / length_u * half
        ny_u = dx_u / length_u * half

        outer.append((x + nx_u, y_up + ny_u))
        inner.append((x - nx_u, y_up - ny_u))

    return outer + list(reversed(inner))

def make_lower_band(h_lower, thickness):
    outer = []
    inner = []
    half = thickness / 2

    for i in range(num_pts + 1):
        t = -1.0 + 2.0 * i / num_pts
        x = cx + eye_w * t
        y = cy + almond(t, h_lower)

        dt = 0.001
        t2 = min(1.0, t + dt)
        x2 = cx + eye_w * t2
        y2 = cy + almond(t2, h_lower)

        dx = x2 - x
        dy = y2 - y
        length = math.sqrt(dx * dx + dy * dy) or 1
        nx = -dy / length * half
        ny = dx / length * half

        outer.append((x + nx, y + ny))
        inner.append((x - nx, y - ny))

    return outer + list(reversed(inner))

def make_upper_band(h_upper, thickness):
    outer = []
    inner = []
    half = thickness / 2

    for i in range(num_pts + 1):
        t = -1.0 + 2.0 * i / num_pts
        x = cx + eye_w * t
        y = cy - almond(t, h_upper)

        dt = 0.001
        t2 = min(1.0, t + dt)
        x2 = cx + eye_w * t2
        y2 = cy - almond(t2, h_upper)

        dx = x2 - x
        dy = y2 - y
        length = math.sqrt(dx * dx + dy * dy) or 1
        nx = -dy / length * half
        ny = dx / length * half

        outer.append((x + nx, y + ny))
        inner.append((x - nx, y - ny))

    return outer + list(reversed(inner))

# Draw upper lid as filled polygon band
upper_band = make_upper_band(1.0, stroke_w)
draw.polygon(upper_band, fill=blue)

# Draw lower lid
lower_band = make_lower_band(0.7, stroke_w)
draw.polygon(lower_band, fill=blue)

# Iris circle (outline via two filled circles)
iris_r = 120 * SCALE
draw.ellipse((cx - iris_r, cy - iris_r, cx + iris_r, cy + iris_r), fill=blue)
iris_inner = iris_r - stroke_w
draw.ellipse((cx - iris_inner, cy - iris_inner, cx + iris_inner, cy + iris_inner), fill=(255, 255, 255))

# Pupil (filled)
pupil_r = 48 * SCALE
draw.ellipse((cx - pupil_r, cy - pupil_r, cx + pupil_r, cy + pupil_r), fill=blue)

# Downsample with antialiasing
img = img.resize((SIZE, SIZE), Image.LANCZOS)

output = "/Users/brianharms/Desktop/Claude Projects/eyeTerm/Sources/EyeTerm/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png"
img.save(output, "PNG")
print(f"Saved: {output}")
