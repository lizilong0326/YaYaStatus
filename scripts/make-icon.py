#!/usr/bin/env python3
"""Generate the native macOS icon. Requires Pillow only when regenerating it."""

from pathlib import Path
from PIL import Image, ImageDraw
import subprocess

root = Path(__file__).resolve().parents[1]
iconset = root / "Resources" / "AppIcon.iconset"
iconset.mkdir(parents=True, exist_ok=True)

scale = 4
side = 1024
image = Image.new("RGBA", (side * scale, side * scale), (0, 0, 0, 0))
draw = ImageDraw.Draw(image)
def box(values):
    return tuple(round(v * scale) for v in values)

draw.rounded_rectangle(box((30, 30, 994, 994)), radius=220 * scale, fill=(15, 22, 28, 255))
draw.rounded_rectangle(box((64, 64, 960, 960)), radius=185 * scale, outline=(69, 90, 90, 150), width=8 * scale)

for offset, color in [
    (105, (23, 93, 66, 255)),
    (55, (31, 145, 92, 255)),
    (0, (53, 222, 135, 255)),
]:
    draw.rounded_rectangle(
        box((234 + offset, 225 + offset, 700 + offset, 690 + offset)),
        radius=82 * scale,
        fill=color,
    )
    draw.rounded_rectangle(
        box((292 + offset, 289 + offset, 642 + offset, 337 + offset)),
        radius=23 * scale,
        fill=(14, 54, 38, 170),
    )

image = image.resize((side, side), Image.Resampling.LANCZOS)
for points in (16, 32, 128, 256, 512):
    for density in (1, 2):
        pixels = points * density
        if pixels > 1024:
            continue
        suffix = "@2x" if density == 2 else ""
        image.resize((pixels, pixels), Image.Resampling.LANCZOS).save(
            iconset / f"icon_{points}x{points}{suffix}.png"
        )

subprocess.run(
    ["iconutil", "-c", "icns", str(iconset), "-o", str(root / "Resources" / "AppIcon.icns")],
    check=True,
)
