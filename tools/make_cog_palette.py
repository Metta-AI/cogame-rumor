#!/usr/bin/env python3
"""Derive the six extra seat-colour cog sprites from the starter's red one.

Rumor seats ten cogs and the starter ships four sprite colours, so six more
are needed. Roles are HIDDEN until the tally, so the board-scale distinction
that matters is per-SEAT identity, not per-role kit: a seat keeps one colour
for the whole episode and the spectator learns to read the circle by colour.

The transform is a deterministic HSV rotation of `soldier_red_front.png`:
each pixel's hue is set to the target colour's hue and its saturation is
scaled by the target's saturation, preserving value and alpha, so the
shading, the outline and the transparency of the original art survive
exactly. Run offline; the outputs are committed.

    python3 tools/make_cog_palette.py            # write data/soldier_*.png
    python3 tools/make_cog_palette.py --check    # verify the committed PNGs
"""

from __future__ import annotations

import argparse
import colorsys
import pathlib
import sys

from PIL import Image

# The renderer's COLOR_HEX entries for the six seats the starter has no
# sprite for. Keep this table and client/renderer.js in step.
TARGETS = {
    "violet": "#a86fd6",
    "orange": "#e08a3a",
    "teal": "#2fa39b",
    "rose": "#d4638f",
    "lime": "#8cbf3f",
    "sand": "#c2a06a",
}

SOURCE = "soldier_red_front.png"


def recolour(source: Image.Image, hex_colour: str) -> Image.Image:
    value = int(hex_colour.lstrip("#"), 16)
    target = (
        ((value >> 16) & 255) / 255.0,
        ((value >> 8) & 255) / 255.0,
        (value & 255) / 255.0,
    )
    target_h, target_s, _ = colorsys.rgb_to_hsv(*target)

    out = Image.new("RGBA", source.size)
    src = source.load()
    dst = out.load()
    for y in range(source.size[1]):
        for x in range(source.size[0]):
            r, g, b, a = src[x, y]
            if a == 0:
                dst[x, y] = (0, 0, 0, 0)
                continue
            _, s, v = colorsys.rgb_to_hsv(r / 255.0, g / 255.0, b / 255.0)
            nr, ng, nb = colorsys.hsv_to_rgb(target_h, s * target_s, v)
            dst[x, y] = (
                round(nr * 255),
                round(ng * 255),
                round(nb * 255),
                a,
            )
    return out


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="fail if a committed PNG differs from the regenerated one",
    )
    args = parser.parse_args()

    data = pathlib.Path(__file__).resolve().parent.parent / "data"
    source = Image.open(data / SOURCE).convert("RGBA")

    failures = []
    for name, hex_colour in TARGETS.items():
        path = data / f"soldier_{name}_front.png"
        made = recolour(source, hex_colour)
        if args.check:
            if not path.exists():
                failures.append(f"{path.name} is missing")
                continue
            have = Image.open(path).convert("RGBA")
            if list(have.getdata()) != list(made.getdata()):
                failures.append(f"{path.name} differs from the script output")
            continue
        made.save(path, optimize=True)
        print(f"wrote {path}")

    if failures:
        for line in failures:
            print(f"ERROR: {line}", file=sys.stderr)
        return 1
    if args.check:
        print("all six recoloured sprites match the script")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
