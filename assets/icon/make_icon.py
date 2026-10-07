#!/usr/bin/env python3
"""Render the X-Trans Darkroom app icon and build assets/AppIcon.icns.

Usage: python3 assets/icon/make_icon.py
Needs Pillow and macOS iconutil.
"""
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = Path(__file__).resolve().parent.parent
MASTER_PATH = ROOT / "icon" / "AppIcon-1024.png"
ICNS_PATH = ROOT / "AppIcon.icns"

CANVAS = 1024
BODY = 824                      # Big Sur+ icon body inside the 1024 canvas
MARGIN = (CANVAS - BODY) // 2
CORNER = 0.2237                 # squircle corner radius as a fraction of body
SS = 2                          # supersampling factor
TILT_DEG = -9

BG_TOP = (42, 10, 10)
BG_BOTTOM = (22, 5, 5)
STRIP = (13, 6, 6)
HOLE = (74, 22, 18)
FRAME_TOP = (139, 58, 42)
FRAME_BOTTOM = (106, 38, 28)
MOUNTAIN_BACK = (92, 33, 25)
MOUNTAIN_FRONT = (62, 22, 17)
CREAM = (243, 233, 216)
ORANGE = (232, 138, 42)

FONT_X = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"
FONT_MONO = "/System/Library/Fonts/SFNSMono.ttf"


def load_font(path, size, variation=None):
    if not Path(path).exists():
        sys.exit(f"Missing system font: {path}. Edit FONT_X/FONT_MONO in make_icon.py.")
    font = ImageFont.truetype(path, size)
    if variation:
        try:
            font.set_variation_by_name(variation)
        except Exception:
            pass
    return font


def squircle_mask(size):
    mask = Image.new("L", (size, size), 0)
    m, b = MARGIN * SS, BODY * SS
    ImageDraw.Draw(mask).rounded_rectangle(
        (m, m, m + b - 1, m + b - 1), radius=int(b * CORNER), fill=255)
    return mask


def vertical_gradient(size, top, bottom):
    w, h = size
    col = Image.new("RGB", (1, h))
    for y in range(h):
        t = y / max(h - 1, 1)
        col.putpixel((0, y), tuple(int(top[i] + (bottom[i] - top[i]) * t) for i in range(3)))
    return col.resize((w, h))


def draw_sprockets(d, y, strip_w, hole_w, hole_h, pitch):
    x = -pitch // 2
    while x < strip_w:
        d.rounded_rectangle((x, y, x + hole_w, y + hole_h), radius=hole_h // 4, fill=HOLE)
        x += pitch


def draw_frame(layer, box):
    """Warm film frame with two mountain ridges."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    grad = vertical_gradient((w, h), FRAME_TOP, FRAME_BOTTOM)
    shape = Image.new("L", (w, h), 0)
    ImageDraw.Draw(shape).rounded_rectangle((0, 0, w - 1, h - 1), radius=h // 14, fill=255)
    scene = ImageDraw.Draw(grad)
    scene.polygon([(0, h * .72), (w * .22, h * .5), (w * .38, h * .62), (w * .6, h * .38),
                   (w * .82, h * .6), (w, h * .5), (w, h), (0, h)], fill=MOUNTAIN_BACK)
    scene.polygon([(0, h * .88), (w * .3, h * .66), (w * .55, h * .82), (w * .8, h * .64),
                   (w, h * .78), (w, h), (0, h)], fill=MOUNTAIN_FRONT)
    layer.paste(grad, (x0, y0), shape)


def draw_edge_text(d, strip_w, y, font):
    d.text((strip_w * 0.29, y), "X-TRANS 400 ▸ 12", font=font, fill=ORANGE)


def build_strip(size):
    """Horizontal film strip, drawn large then tilted."""
    s = SS
    sw, sh = int(1700 * s), int(BODY * 0.74 * s)
    strip = Image.new("RGBA", (sw, sh), STRIP + (255,))
    d = ImageDraw.Draw(strip)
    hole_w, hole_h, pitch = 54 * s, 40 * s, 104 * s
    draw_sprockets(d, 30 * s, sw, hole_w, hole_h, pitch)
    draw_sprockets(d, sh - 30 * s - hole_h, sw, hole_w, hole_h, pitch)
    fw, fh = 560 * s, int(sh - 2 * (30 + 40 + 36) * s)
    fy = (sh - fh) // 2
    fx = (sw - fw) // 2
    for off in (-(fw + 34 * s), 0, fw + 34 * s):
        draw_frame(strip, (fx + off, fy, fx + off + fw, fy + fh))
    font = load_font(FONT_MONO, 21 * s, "Bold")
    draw_edge_text(d, sw, 78 * s, font)
    return strip, (fx, fy, fw, fh)


def draw_hero_x(size):
    """Cream X with soft dark shadow."""
    s = SS
    font = load_font(FONT_X, 600 * s)
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    c = size // 2
    d.text((c, c + 6 * s), "X", font=font, fill=CREAM, anchor="mm")
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).text((c, c + 26 * s), "X", font=font, fill=(10, 2, 2, 190), anchor="mm")
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * s))
    return Image.alpha_composite(shadow, layer)


def render_master():
    size = CANVAS * SS
    body = vertical_gradient((size, size), BG_TOP, BG_BOTTOM).convert("RGBA")
    strip, _ = build_strip(size)
    strip = strip.rotate(TILT_DEG, resample=Image.BICUBIC, expand=True)
    body.alpha_composite(strip, ((size - strip.width) // 2, (size - strip.height) // 2))
    body.alpha_composite(draw_hero_x(size))
    mask = squircle_mask(size)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    shadow.putalpha(mask.point(lambda v: v * 0.45))
    shadow = shadow.filter(ImageFilter.GaussianBlur(14 * SS))
    shadow = ImageChops.offset(shadow, 0, 10 * SS)
    icon.alpha_composite(shadow)
    body.putalpha(mask)
    icon.alpha_composite(body)
    return icon.resize((CANVAS, CANVAS), Image.LANCZOS)


def build_icns(master):
    iconset = Path(tempfile.mkdtemp()) / "AppIcon.iconset"
    iconset.mkdir()
    for base in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = base * scale
            name = f"icon_{base}x{base}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(iconset / name)
    subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ICNS_PATH)], check=True)
    shutil.rmtree(iconset.parent)


def main():
    master = render_master()
    MASTER_PATH.parent.mkdir(parents=True, exist_ok=True)
    master.save(MASTER_PATH)
    build_icns(master)
    print(f"wrote {MASTER_PATH} and {ICNS_PATH}")


if __name__ == "__main__":
    main()
