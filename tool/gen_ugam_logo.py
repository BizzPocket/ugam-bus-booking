"""Generate the Ugam Booking launcher icon (1024x1024 PNG).

Mirrors the geometry of lib/components/ugam_logo.dart so the launcher icon
matches the in-app logo. One-off generator: re-run if the widget design
ever changes.
"""

import math
from PIL import Image, ImageDraw, ImageFont

SIZE = 1024
BG_COLOR = (255, 247, 237, 255)        # cream #FFF7ED (adaptive bg layer)
RAY_COLOR = (255, 193, 7, 255)         # gold #FFC107
DISC_COLOR = (255, 179, 0, 255)        # amber #FFB300
TEXT_COLOR = (185, 28, 28, 255)        # deep red #B91C1C
BUS_COLOR = (153, 27, 27, 255)         # darker red #991B1B

RAY_COUNT = 12
HORIZON_Y_FRAC = 0.55
DISC_RADIUS_FRAC = 0.35
LONG_RAY_FRAC = 0.35
SHORT_RAY_FRAC = 0.22
RAY_HALF_WIDTH_FRAC = 0.018


def main(out_path: str) -> None:
    img = Image.new("RGBA", (SIZE, SIZE), BG_COLOR)
    d = ImageDraw.Draw(img)

    cx = SIZE / 2
    horizon_y = SIZE * HORIZON_Y_FRAC
    disc_r = SIZE * DISC_RADIUS_FRAC
    long_ray = SIZE * LONG_RAY_FRAC
    short_ray = SIZE * SHORT_RAY_FRAC
    half_w = SIZE * RAY_HALF_WIDTH_FRAC

    _draw_rays(d, cx, horizon_y, disc_r, long_ray, short_ray, half_w)
    _draw_half_disc(d, cx, horizon_y, disc_r)
    _draw_gujarati_text(d, cx, horizon_y + disc_r * 0.35, disc_r)
    _draw_bus(d, cx, horizon_y + disc_r * 0.78, disc_r * 0.9)

    img.save(out_path, "PNG")
    print(f"Wrote {out_path}")


def _draw_rays(d, cx, cy, disc_r, long_r, short_r, half_w):
    for i in range(RAY_COUNT):
        t = (i + 0.5) / RAY_COUNT
        angle = math.pi + t * math.pi
        is_long = (i % 2 == 0)
        length = long_r if is_long else short_r
        tip_d = disc_r + length
        base_d = disc_r * 0.92
        tip = (cx + math.cos(angle) * tip_d, cy + math.sin(angle) * tip_d)
        base_c = (cx + math.cos(angle) * base_d, cy + math.sin(angle) * base_d)
        perp = (-math.sin(angle), math.cos(angle))
        b1 = (base_c[0] + perp[0] * half_w, base_c[1] + perp[1] * half_w)
        b2 = (base_c[0] - perp[0] * half_w, base_c[1] - perp[1] * half_w)
        d.polygon([tip, b1, b2], fill=RAY_COLOR)


def _draw_half_disc(d, cx, cy, r):
    bbox = [cx - r, cy - r, cx + r, cy + r]
    d.pieslice(bbox, start=0, end=180, fill=DISC_COLOR)


def _draw_gujarati_text(d, cx, cy, disc_r):
    candidates = [
        "/System/Library/Fonts/Supplemental/KohinoorGujarati.ttc",
        "/System/Library/Fonts/Supplemental/Gujarati Sangam MN.ttc",
        "/System/Library/Fonts/Supplemental/GujaratiMT.ttc",
    ]
    font = None
    pt = int(disc_r * 0.55)
    for path in candidates:
        try:
            font = ImageFont.truetype(path, size=pt)
            break
        except OSError:
            continue
    if font is None:
        font = ImageFont.load_default()
    text = "ઉગમ"
    bbox = d.textbbox((0, 0), text, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    d.text(
        (cx - tw / 2 - bbox[0], cy - th / 2 - bbox[1]),
        text,
        fill=TEXT_COLOR,
        font=font,
    )


def _draw_bus(d, cx, cy, width):
    h = width * 0.42
    body = [cx - width / 2, cy - h / 2, cx + width / 2, cy + h / 2]
    d.rounded_rectangle(body, radius=h * 0.18, fill=BUS_COLOR)

    # windows
    win_h = h * 0.40
    win_y = cy - h * 0.10
    win_w = width * 0.22
    for sign in (-1, 1):
        wx = cx + sign * width * 0.18
        d.rounded_rectangle(
            [wx - win_w / 2, win_y - win_h / 2, wx + win_w / 2, win_y + win_h / 2],
            radius=win_h * 0.2,
            fill=BG_COLOR,
        )

    # wheels
    wheel_r = h * 0.22
    wheel_y = cy + h * 0.45
    for sign in (-1, 1):
        wx = cx + sign * width * 0.28
        d.ellipse(
            [wx - wheel_r, wheel_y - wheel_r, wx + wheel_r, wheel_y + wheel_r],
            fill=BUS_COLOR,
        )


if __name__ == "__main__":
    import sys
    main(sys.argv[1] if len(sys.argv) > 1 else "ugam_logo.png")
