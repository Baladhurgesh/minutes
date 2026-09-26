#!/usr/bin/env python3
"""Build the macOS app icon set and in-app logo from branding/logo-source.png.

The source is the rounded-square artwork on a white background with a glow. We crop the square,
mask it with a continuous-corner rounded rect (dropping the glow), and place it on Apple's 1024 grid
(824 px body, 100 px margin) with a soft shadow.

Usage: uv run --with pillow --with numpy python scripts/make_icon.py
"""

from __future__ import annotations

import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "branding" / "logo-source.png"
ASSETS = ROOT / "app" / "Sources" / "Minutes" / "Assets.xcassets"
BODY, CANVAS = 824, 1024
CORNER = 0.2237  # Apple macOS icon corner radius as a fraction of the body size


def body_bounds(img: Image.Image, threshold: float = 0.45) -> tuple[int, int, int, int]:
    a = np.asarray(img.convert("RGB")).astype(float)
    mx, mn = a.max(2), a.min(2)
    sat = (mx - mn) / np.maximum(mx, 1)
    ys, xs = np.where(sat > threshold)
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def rounded_mask(size: int, radius_frac: float, scale: int = 4) -> Image.Image:
    big = Image.new("L", (size * scale, size * scale), 0)
    ImageDraw.Draw(big).rounded_rectangle((0, 0, size * scale - 1, size * scale - 1),
                                          radius=int(size * scale * radius_frac), fill=255)
    return big.resize((size, size), Image.LANCZOS)


def build_body() -> Image.Image:
    src = Image.open(SOURCE).convert("RGBA")
    x0, y0, x1, y1 = body_bounds(src)
    side = max(x1 - x0, y1 - y0)
    inset = max(2, side // 64)  # trim the light rim and anti-aliased fringe
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    half = side / 2 - inset
    crop = src.crop((int(cx - half), int(cy - half), int(cx + half), int(cy + half))).resize((BODY, BODY), Image.LANCZOS)
    crop.putalpha(rounded_mask(BODY, CORNER))
    return crop


def build_icon(body: Image.Image) -> Image.Image:
    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    offset = (CANVAS - BODY) // 2
    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow_mask = Image.new("L", (CANVAS, CANVAS), 0)
    shadow_mask.paste(body.getchannel("A"), (offset, offset + 12))
    shadow.putalpha(shadow_mask.point(lambda v: int(v * 0.30)).filter(ImageFilter.GaussianBlur(18)))
    canvas.alpha_composite(shadow)
    canvas.alpha_composite(body, (offset, offset))
    return canvas


def write_iconset(icon: Image.Image) -> None:
    out = ASSETS / "AppIcon.appiconset"
    out.mkdir(parents=True, exist_ok=True)
    images = []
    for pt in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = pt * scale
            name = f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"
            icon.resize((px, px), Image.LANCZOS).save(out / name)
            images.append({"idiom": "mac", "size": f"{pt}x{pt}", "scale": f"{scale}x", "filename": name})
    (out / "Contents.json").write_text(json.dumps({"images": images, "info": {"version": 1, "author": "xcode"}}, indent=2))


def write_logo(body: Image.Image) -> None:
    out = ASSETS / "Logo.imageset"
    out.mkdir(parents=True, exist_ok=True)
    body.resize((256, 256), Image.LANCZOS).save(out / "logo.png")
    body.resize((512, 512), Image.LANCZOS).save(out / "logo@2x.png")
    (out / "Contents.json").write_text(json.dumps({
        "images": [{"idiom": "universal", "filename": "logo.png", "scale": "1x"},
                   {"idiom": "universal", "filename": "logo@2x.png", "scale": "2x"}],
        "info": {"version": 1, "author": "xcode"}}, indent=2))


def main() -> None:
    ASSETS.mkdir(parents=True, exist_ok=True)
    (ASSETS / "Contents.json").write_text(json.dumps({"info": {"version": 1, "author": "xcode"}}, indent=2))
    body = build_body()
    icon = build_icon(body)
    write_iconset(icon)
    write_logo(body)
    icon.save(ROOT / "branding" / "icon-1024.png")
    print(f"wrote {ASSETS} and branding/icon-1024.png")


if __name__ == "__main__":
    main()
