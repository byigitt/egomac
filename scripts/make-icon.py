#!/usr/bin/env python3
"""Generate the EGO Mac app icon from the official EGO Cep'te logo by
masking out the lower "CEP'TE" text and drawing "MAC" in matching red.

Usage:
    python3 scripts/make-icon.py assets/cepte-original.png assets/icon-1024.png
"""
import sys
from PIL import Image, ImageDraw, ImageFont

src_path = sys.argv[1] if len(sys.argv) > 1 else "assets/cepte-original.png"
dst_path = sys.argv[2] if len(sys.argv) > 2 else "assets/icon-1024.png"

# 1. Load original at 1024×1024.
src = Image.open(src_path).convert("RGB")
W, H = src.size

# 2. Mask the "CEP'TE" area. We sample the background gradient by reading the
#    color of pixels along a vertical strip in the corner area where there's
#    no text. Then redraw that gradient over the bottom half.
def sample_bg_column(img, x):
    """Returns a list of RGB tuples down column x, every row."""
    return [img.getpixel((x, y)) for y in range(img.height)]

# We'll use the original's left edge column as the gradient template — the
# logo background has a smooth diagonal wash there.
left_col = sample_bg_column(src, 8)        # background-only column
right_col = sample_bg_column(src, W - 8)   # background-only column

# Build a working copy and erase the bottom region (where CEP'TE lives).
# CEP'TE box: roughly y ∈ [560, 880], x ∈ [80, 940].
out = src.copy()
draw = ImageDraw.Draw(out)

# Reconstruct the gradient over the erased region by horizontally
# interpolating between left_col and right_col for each row.
# We need to replace the lower portion (CEP'TE area) with a clean gradient
# that smoothly continues the upper portion's tone. Strategy:
#  1. Paint the bottom half with a fresh bilinear gradient sampled from the
#     four corners of the source image.
#  2. Use a *vertical alpha mask* so the transition between the original
#     (top half) and our painted gradient (bottom half) fades over ~100 px.
from PIL import ImageFilter

ERASE_TOP = 555    # below EGO baseline
FADE_HEIGHT = 80   # pixel range over which original → painted blend

# Sample four corners (away from any text/sheen).
tl = src.getpixel((20, 20))
tr = src.getpixel((W - 20, 20))
bl = src.getpixel((20, H - 20))
br = src.getpixel((W - 20, H - 20))

# Build a synthetic background image with bilinear interpolation.
synth = Image.new("RGB", (W, H))
synth_pixels = synth.load()
for y in range(H):
    ty = y / (H - 1)
    left  = (
        int(tl[0] * (1 - ty) + bl[0] * ty),
        int(tl[1] * (1 - ty) + bl[1] * ty),
        int(tl[2] * (1 - ty) + bl[2] * ty),
    )
    right = (
        int(tr[0] * (1 - ty) + br[0] * ty),
        int(tr[1] * (1 - ty) + br[1] * ty),
        int(tr[2] * (1 - ty) + br[2] * ty),
    )
    for x in range(W):
        tx = x / (W - 1)
        synth_pixels[x, y] = (
            int(left[0] * (1 - tx) + right[0] * tx),
            int(left[1] * (1 - tx) + right[1] * tx),
            int(left[2] * (1 - tx) + right[2] * tx),
        )

# Build a vertical mask: 0 (= keep original) for y < ERASE_TOP,
# rising linearly to 255 (= take synth) over `FADE_HEIGHT`, full 255 below.
mask = Image.new("L", (W, H), 0)
mpix = mask.load()
for y in range(H):
    if y < ERASE_TOP:
        v = 0
    elif y < ERASE_TOP + FADE_HEIGHT:
        v = int(255 * (y - ERASE_TOP) / FADE_HEIGHT)
    else:
        v = 255
    for x in range(W):
        mpix[x, y] = v

out = Image.composite(synth, src, mask)
# Re-bind draw context to the freshly composited image so the
# `MAC` text below is drawn onto our final output.
draw = ImageDraw.Draw(out)

# 3. Draw "MAC" over the cleared area. Match the EGO Cep'te red and use the
#    heaviest available system font so the type weight reads similar.
RED = (210, 30, 32)
# Sizes are tuned so "MAC" occupies the same visual footprint as the
# original "CEP'TE" (≈ 230 px tall, narrower because of fewer glyphs).
FONT_CANDIDATES = [
    ("/System/Library/Fonts/Supplemental/Arial Black.ttf",         260),
    ("/System/Library/Fonts/Supplemental/Impact.ttf",              320),
    ("/System/Library/Fonts/HelveticaNeue.ttc",                    260),
    ("/System/Library/Fonts/Helvetica.ttc",                        260),
]

font = None
for path, size in FONT_CANDIDATES:
    try:
        font = ImageFont.truetype(path, size)
        print(f"using font: {path} @ {size}pt")
        break
    except Exception as e:
        continue
if font is None:
    raise SystemExit("no usable font found")

text = "MAC"
# Pillow ≥ 10 returns a tuple (left, top, right, bottom).
bbox = draw.textbbox((0, 0), text, font=font)
text_w = bbox[2] - bbox[0]
text_h = bbox[3] - bbox[1]

# Center the text horizontally; vertically place in the lower half so it
# mirrors where "CEP'TE" sat.
TARGET_CY = 770                              # below the "EGO" baseline, well clear
x = (W - text_w) // 2 - bbox[0]
y = TARGET_CY - text_h // 2 - bbox[1]

# Soft drop shadow for depth (matches Cep'te style).
shadow_offset = 3
shadow_color = (0, 0, 0, 32)
# Pillow's ImageDraw on an RGB image doesn't blend alpha; emulate with a
# slightly darker red copy offset by `shadow_offset`.
draw.text((x + shadow_offset, y + shadow_offset), text,
          fill=(170, 25, 27), font=font)
draw.text((x, y), text, fill=RED, font=font)

out.save(dst_path, "PNG")
print(f"✓ wrote {dst_path}  size={out.size}")
