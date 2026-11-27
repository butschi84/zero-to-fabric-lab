#!/usr/bin/env python3
"""Render a text evidence file as a dark terminal PNG (1920x1080, 120x30).

Same look for every shot: dark background, Menlo (macOS) or DejaVu Sans Mono,
prompt lines ("<node># ...") highlighted. Long lines are cut at 120 columns
and marked with a trailing "…" so nothing is silently reflowed.
usage: render_term.py file.txt [file2.txt ...]   -> writes file.png next to it
"""
import pathlib, sys
from PIL import Image, ImageDraw, ImageFont

W, H, COLS, ROWS, PAD = 1920, 1080, 120, 30, 28
BG, FG, PROMPT, DIM = (13, 17, 23), (220, 225, 232), (110, 200, 140), (130, 140, 155)
FONTS = ["/System/Library/Fonts/Menlo.ttc", "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf"]


def font(size):
    for f in FONTS:
        if pathlib.Path(f).exists():
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def render(path):
    lines = pathlib.Path(path).read_text(encoding="utf-8").splitlines()[:ROWS]
    size = 30
    while size > 10:
        f = font(size)
        cw = f.getlength("M")
        if cw * COLS <= W - 2 * PAD and (size * 1.18) * ROWS <= H - 2 * PAD:
            break
        size -= 1
    lh = int(size * 1.18)
    img = Image.new("RGB", (W, H), BG)
    d = ImageDraw.Draw(img)
    for i, ln in enumerate(lines):
        if len(ln) > COLS:
            ln = ln[: COLS - 1] + "…"
        color = PROMPT if "# " in ln[:24] and not ln.startswith("#") else (DIM if ln.startswith("#") else FG)
        d.text((PAD, PAD + i * lh), ln, font=f, fill=color)
    out = pathlib.Path(path).with_suffix(".png")
    img.save(out, optimize=True)
    return out


if __name__ == "__main__":
    for p in sys.argv[1:]:
        print(render(p))
