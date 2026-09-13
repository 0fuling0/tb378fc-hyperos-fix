#!/usr/bin/env python3
"""Generate the stylus artwork used by the bridge app.

Three artefacts are produced:

  res/drawable-nodpi/ic_pen.png       light glyph   -- for MIUI's dark island pill
  res/drawable-nodpi/ic_pen_dark.png  dark glyph    -- for light backgrounds
  res/mipmap-xxhdpi/ic_launcher.png   app icon      -- rounded tile + glyph

They are referenced from the notification as `miui.focus.pic_pen`, resolved
through the `miui.focus.pics` Bundle, per Xiaomi's Super Island documentation.

The glyph is drawn upright and then rotated, so the geometry below is written in
the natural "pen standing on its tip" orientation.
"""
import os
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
APK = os.path.dirname(HERE)

BASE = 192          # final edge length; docs ask for >= 88 px for island icons
SS = 8              # supersample factor, downscaled at the end for clean edges
W = BASE * SS
U = W / 192.0       # one design unit


def pen_layer(color):
    """An upright stylus (tip at the bottom) on a transparent canvas."""
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    cx = W / 2.0

    cap_top = 24 * U
    cap_h = 30 * U
    body_bot = 100 * U          # body stops here; the gap below reads as a collar
    gap = 9 * U
    collar_bot = 126 * U
    tip_y = 168 * U
    half_cap = 25 * U           # half width of the rounded cap
    half_body = 22 * U          # half width where the body meets the gap
    half_collar = 18 * U

    # rounded cap
    d.rounded_rectangle(
        [cx - half_cap, cap_top, cx + half_cap, cap_top + cap_h],
        radius=half_cap, fill=color,
    )
    # gently tapered body
    d.polygon(
        [
            (cx - half_cap, cap_top + cap_h - 2 * U),
            (cx + half_cap, cap_top + cap_h - 2 * U),
            (cx + half_body, body_bot),
            (cx - half_body, body_bot),
        ],
        fill=color,
    )
    # collar between body and tip
    d.polygon(
        [
            (cx - half_body, body_bot + gap),
            (cx + half_body, body_bot + gap),
            (cx + half_collar, collar_bot),
            (cx - half_collar, collar_bot),
        ],
        fill=color,
    )
    # nib
    d.polygon(
        [
            (cx - half_collar, collar_bot),
            (cx + half_collar, collar_bot),
            (cx, tip_y),
        ],
        fill=color,
    )
    return img


def rotated(layer, degrees=-45):
    """Rotate about the centre, keeping the canvas size."""
    return layer.rotate(degrees, resample=Image.BICUBIC, center=(W / 2.0, W / 2.0))


def glyph(color, degrees=-45, scale=1.0):
    layer = rotated(pen_layer(color), degrees)
    if scale != 1.0:
        side = int(W * scale)
        small = layer.resize((side, side), Image.LANCZOS)
        layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
        off = (W - side) // 2
        layer.paste(small, (off, off), small)
    return layer.resize((BASE, BASE), Image.LANCZOS)


def vertical_gradient(size, top, bottom):
    grad = Image.new("RGB", (1, size), top)
    px = grad.load()
    for y in range(size):
        t = y / max(1, size - 1)
        px[0, y] = tuple(round(top[i] + (bottom[i] - top[i]) * t) for i in range(3))
    return grad.resize((size, size), Image.BILINEAR)


def launcher(size=192):
    """Rounded tile with a gradient, plus the glyph in white."""
    tile = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    radius = int(W * 0.22)                       # MIUI/most launchers round heavily
    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, W - 1, W - 1], radius=radius, fill=255)
    tile.paste(vertical_gradient(W, (0x5B, 0x7C, 0xFF), (0x27, 0x3A, 0xC9)), (0, 0), mask)
    pen = rotated(pen_layer((255, 255, 255, 255)))
    pen = pen.resize((int(W * 0.70), int(W * 0.70)), Image.LANCZOS)
    tile.paste(pen, ((W - pen.width) // 2, (W - pen.height) // 2), pen)
    return tile.resize((size, size), Image.LANCZOS)


def write(path, image):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    image.save(path)
    print("wrote %s (%dx%d)" % (path, image.width, image.height))


def main():
    if "--preview" in sys.argv:
        # contact sheet: rotation candidates side by side on a dark and a light band
        sheet = Image.new("RGB", (BASE * 3, BASE * 2), (0x14, 0x14, 0x16))
        white = (255, 255, 255, 255)
        dark = (0x14, 0x16, 0x1A, 255)
        for col, deg in enumerate((0, 45, -45)):
            sheet.paste(glyph(white, deg).convert("RGB"), (col * BASE, 0))
            sheet.paste(glyph(dark, deg).convert("RGB"), (col * BASE, BASE))
        sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
        out = os.path.join(HERE, "preview.png")
        sheet.save(out)
        print("wrote", out, "columns: upright, rotate(+45), rotate(-45)")
        return

    write(os.path.join(APK, "res", "drawable-nodpi", "ic_pen.png"),
          glyph((255, 255, 255, 255)))
    write(os.path.join(APK, "res", "drawable-nodpi", "ic_pen_dark.png"),
          glyph((0x14, 0x16, 0x1A, 255)))
    write(os.path.join(APK, "res", "mipmap-xxhdpi", "ic_launcher.png"), launcher())


if __name__ == "__main__":
    main()
