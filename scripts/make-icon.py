#!/usr/bin/env python3
"""Generate the YaYa Status logo, app icon, and small UI marks."""

from pathlib import Path
from PIL import Image, ImageDraw
import subprocess

root = Path(__file__).resolve().parents[1]
resources = root / "Resources"
iconset = resources / "AppIcon.iconset"
iconset.mkdir(parents=True, exist_ok=True)

side = 1024
scale = 4
green = (65, 220, 139, 255)
orange = (255, 153, 76, 255)
dark = (18, 28, 27, 255)


def scaled_box(values):
    return tuple(round(value * scale) for value in values)


def circle(draw, center, radius, color):
    x, y = center
    draw.ellipse(scaled_box((x - radius, y - radius, x + radius, y + radius)), fill=color)


def draw_mark(image, monochrome=False):
    draw = ImageDraw.Draw(image)
    branch_color = (0, 0, 0, 255) if monochrome else green
    signal_color = branch_color if monochrome else orange
    left = (294, 298)
    right = (730, 298)
    fork = (512, 516)
    bottom = (512, 752)
    width = 106 * scale

    for start, end in ((left, fork), (right, fork), (fork, bottom)):
        draw.line((scaled_box(start), scaled_box(end)), fill=branch_color, width=width)
    for point in (left, fork, bottom):
        circle(draw, point, 53, branch_color)
    circle(draw, right, 69, signal_color)


mark = Image.new("RGBA", (side * scale, side * scale), (0, 0, 0, 0))
draw_mark(mark)

icon = Image.new("RGBA", mark.size, (0, 0, 0, 0))
draw = ImageDraw.Draw(icon)
draw.rounded_rectangle(scaled_box((30, 30, 994, 994)), radius=220 * scale, fill=dark)
draw.rounded_rectangle(
    scaled_box((65, 65, 959, 959)), radius=188 * scale,
    outline=(83, 119, 106, 125), width=5 * scale,
)
icon.alpha_composite(mark)
icon = icon.resize((side, side), Image.Resampling.LANCZOS)
icon.resize((512, 512), Image.Resampling.LANCZOS).save(resources / "YaYaStatusLogo.png")

for points in (16, 32, 128, 256, 512):
    for density in (1, 2):
        pixels = points * density
        if pixels > side:
            continue
        suffix = "@2x" if density == 2 else ""
        icon.resize((pixels, pixels), Image.Resampling.LANCZOS).save(
            iconset / f"icon_{points}x{points}{suffix}.png"
        )

crop = scaled_box((210, 210, 814, 814))
mark.crop(crop).resize((256, 256), Image.Resampling.LANCZOS).save(resources / "StatusMark.png")

template = Image.new("RGBA", mark.size, (0, 0, 0, 0))
draw_mark(template, monochrome=True)
template.crop(crop).resize((72, 72), Image.Resampling.LANCZOS).save(
    resources / "MenuBarMark.png"
)

(resources / "YaYaStatusLogo.svg").write_text(
    """<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024">
  <title>丫丫状态</title>
  <rect x="30" y="30" width="964" height="964" rx="220" fill="#121c1b"/>
  <rect x="65" y="65" width="894" height="894" rx="188" fill="none" stroke="#53776a" stroke-opacity=".49" stroke-width="5"/>
  <path d="M294 298 512 516 730 298M512 516v236" fill="none" stroke="#41dc8b" stroke-width="106" stroke-linecap="round" stroke-linejoin="round"/>
  <circle cx="730" cy="298" r="69" fill="#ff994c"/>
</svg>
""",
    encoding="utf-8",
)

subprocess.run(
    ["iconutil", "-c", "icns", str(iconset), "-o", str(resources / "AppIcon.icns")],
    check=True,
)
