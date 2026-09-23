#!/usr/bin/env python3
"""Build the Solaro share image: the editor, darkened, with white bold text."""
from PIL import Image, ImageDraw, ImageFont, ImageEnhance
import sys

SRC = "/Users/kris/Projects/ARO/ARO-Lang/Book/SolaroTheAroPlatform/screenshots/04-run-finished.png"
OUT = sys.argv[1] if len(sys.argv) > 1 else "/tmp/solaro-social.png"
W, H = 1280, 640                      # matches the existing Graphics/social.png

MENLO = "/System/Library/Fonts/Menlo.ttc"
def mono(size, bold=True):
    return ImageFont.truetype(MENLO, size, index=1 if bold else 0)

# ---- 1. The editor, cropped to the live canvas and scaled to cover ----------
shot = Image.open(SRC).convert("RGB")
sw, sh = shot.size
# Crop to the canvas alone: no file tree, no inspector — just the statement
# nodes and the values the run bound to them, which is the thing being sold.
box = (int(sw * 0.19), int(sh * 0.17), int(sw * 0.74), int(sh * 0.58))
shot = shot.crop(box)
# Scale to cover 1280x640.
scale = max(W / shot.width, H / shot.height)
shot = shot.resize((int(shot.width * scale), int(shot.height * scale)), Image.LANCZOS)
left = (shot.width - W) // 2
shot = shot.crop((left, 0, left + W, H))

# Knock the whole frame back so white type reads cleanly on top of it.
shot = ImageEnhance.Brightness(shot).enhance(0.62)

# ---- 2. Scrim: heaviest on the left, clearing to the right -----------------
scrim = Image.new("L", (W, 1))
for x in range(W):
    t = x / (W - 1)
    scrim.putpixel((x, 0), int(232 * (1 - t) ** 1.35 + 40))
scrim = scrim.resize((W, H))
canvas = Image.composite(Image.new("RGB", (W, H), (7, 6, 14)), shot, scrim)

# A touch of vignette at the bottom so the footer line sits on something solid.
foot = Image.new("L", (1, H))
for y in range(H):
    foot.putpixel((0, y), 0 if y < H - 130 else int(110 * ((y - (H - 130)) / 130)))
canvas = Image.composite(Image.new("RGB", (W, H), (7, 6, 14)), canvas, foot.resize((W, H)))

d = ImageDraw.Draw(canvas)
X = 74

# ---- 3. The promotional type ----------------------------------------------
d.text((X, 198), "SOLARO", font=mono(104), fill=(255, 255, 255))

# Accent rule under the wordmark, in the site's cyan.
d.rectangle([X, 334, X + 132, 340], fill=(0, 194, 209))

d.text((X, 372), "The ARO IDE", font=mono(46), fill=(255, 255, 255))

# ---- 4. Footer ------------------------------------------------------------
d.text((X, 552), "arolang.github.io/aro", font=mono(24), fill=(150, 150, 162))

canvas.save(OUT, "PNG", optimize=True)
print(f"wrote {OUT}  {canvas.size[0]}x{canvas.size[1]}")
