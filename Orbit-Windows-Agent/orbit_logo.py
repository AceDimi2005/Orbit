"""The Orbit mark: a white ring open at the top with a blue satellite in the opening,
like a power symbol with its LED.

Geometry, relative to the ring's outer diameter D (the master drawing is 676 units):
  ring centreline radius 290/676·D, stroke 96/676·D with round caps,
  satellite radius 66/676·D, centred on the ring's centreline at the top,
  opening half-angle (66 + 40 + 48)/290 rad: satellite radius + a 40-unit gap + the round cap.
The satellite rises 18 units above the ring's outer circle, so the whole mark is 676 x 694.

The same numbers draw the inline SVG of the companion window and, through Pillow, every
frame of orbit.ico (`python orbit_logo.py` regenerates it).
"""
import io
import math
from pathlib import Path
import struct

ORBIT_BLUE = "#0A84FF"
UNITS = 676.0
RING_RADIUS = 290.0
STROKE = 96.0
SATELLITE = 66.0
HALF_ANGLE = (66.0 + 40.0 + 48.0) / 290.0  # radians
TOP = RING_RADIUS + SATELLITE  # 356: from the centre to the top of the satellite
BOTTOM = RING_RADIUS + STROKE / 2  # 338: from the centre to the bottom of the ring
HEIGHT = TOP + BOTTOM  # 694
TRAY_SIZES = (16, 20, 24, 32, 40)
TILE_SIZES = (48, 64, 256)
GRAPHITE_TOP = (0x2C, 0x2E, 0x34)
GRAPHITE_BOTTOM = (0x0A, 0x0A, 0x0C)


def arc_endpoints(cx=UNITS / 2, cy=UNITS / 2):
    """Where the ring's centreline ends, either side of the opening."""
    dx, dy = RING_RADIUS * math.sin(HALF_ANGLE), RING_RADIUS * math.cos(HALF_ANGLE)
    return (cx + dx, cy - dy), (cx - dx, cy - dy)


def logo_svg(size=None, ring="#FFFFFF", satellite=ORBIT_BLUE, title="Orbit"):
    """The mark as inline SVG, square viewBox, centred."""
    (x1, y1), (x2, y2) = arc_endpoints()
    side = HEIGHT
    left = UNITS / 2 - side / 2
    top = UNITS / 2 - TOP
    dimensions = f' width="{size}" height="{size}"' if size else ""
    label = f'<title>{title}</title>' if title else ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{left:g} {top:g} {side:g} {side:g}"{dimensions} '
            f'role="img" aria-label="{title}">{label}'
            f'<path d="M{x1:.2f} {y1:.2f}A{RING_RADIUS:g} {RING_RADIUS:g} 0 1 1 {x2:.2f} {y2:.2f}" fill="none" '
            f'stroke="{ring}" stroke-width="{STROKE:g}" stroke-linecap="round"/>'
            f'<circle cx="{UNITS / 2:g}" cy="{UNITS / 2 - RING_RADIUS:g}" r="{SATELLITE:g}" fill="{satellite}"/></svg>')


def _hex(color):
    color = color.lstrip("#")
    return tuple(int(color[index:index + 2], 16) for index in (0, 2, 4))


def render_mark(size, ring="#FFFFFF", satellite=ORBIT_BLUE, scale=1.0, supersample=8):
    """The mark alone on a transparent square, anti-aliased by drawing large and scaling down."""
    from PIL import Image, ImageDraw

    big = size * supersample
    unit = big * scale / HEIGHT  # pixels per drawing unit
    cx = big / 2
    cy = big / 2 + (TOP - HEIGHT / 2) * unit  # centre the 676 x 694 mark vertically
    ring_mask = Image.new("L", (big, big), 0)
    draw = ImageDraw.Draw(ring_mask)
    outer, inner = (RING_RADIUS + STROKE / 2) * unit, (RING_RADIUS - STROKE / 2) * unit
    draw.ellipse((cx - outer, cy - outer, cx + outer, cy + outer), fill=255)
    draw.ellipse((cx - inner, cy - inner, cx + inner, cy + inner), fill=0)
    degrees = math.degrees(HALF_ANGLE)
    reach = outer + 2
    draw.pieslice((cx - reach, cy - reach, cx + reach, cy + reach), 270 - degrees, 270 + degrees, fill=0)
    cap = STROKE / 2 * unit
    for x, y in arc_endpoints(0, 0):
        px, py = cx + x * unit, cy + y * unit
        draw.ellipse((px - cap, py - cap, px + cap, py + cap), fill=255)
    dot_mask = Image.new("L", (big, big), 0)
    dot = ImageDraw.Draw(dot_mask)
    radius, dot_y = SATELLITE * unit, cy - RING_RADIUS * unit
    dot.ellipse((cx - radius, dot_y - radius, cx + radius, dot_y + radius), fill=255)
    canvas = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    canvas.paste(Image.new("RGBA", (big, big), _hex(ring) + (255,)), (0, 0), ring_mask)
    canvas.paste(Image.new("RGBA", (big, big), _hex(satellite) + (255,)), (0, 0), dot_mask)
    return canvas.resize((size, size), Image.Resampling.LANCZOS)


def render_tile(size, supersample=4):
    """The mark on a graphite rounded square (#2C2E34 to #0A0A0C), for the large icon sizes."""
    from PIL import Image, ImageDraw

    big = size * supersample
    tile = Image.new("RGBA", (big, big), (0, 0, 0, 0))
    column = Image.new("RGBA", (1, big))
    column.putdata([tuple(round(a + (b - a) * y / max(1, big - 1)) for a, b in zip(GRAPHITE_TOP, GRAPHITE_BOTTOM)) + (255,)
                    for y in range(big)])
    shade = column.resize((big, big), Image.Resampling.NEAREST)
    mask = Image.new("L", (big, big), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, big - 1, big - 1), radius=round(big * 0.22), fill=255)
    tile.paste(shade, (0, 0), mask)
    tile = tile.resize((size, size), Image.Resampling.LANCZOS)
    mark = render_mark(size, scale=0.6)
    tile.alpha_composite(mark)
    return tile


def icon_frames(ring="#FFFFFF"):
    """{size: RGBA image}: the bare mark for tray sizes, the graphite tile for large ones."""
    frames = {size: render_mark(size, ring=ring, scale=0.94 if size >= 24 else 1.0) for size in TRAY_SIZES}
    frames.update({size: render_tile(size) for size in TILE_SIZES})
    return frames


def build_ico(frames):
    """A Windows .ico: 32-bit BGRA DIB frames with an AND mask, and PNG for 256 px."""
    entries, payloads = [], []
    for size in sorted(frames):
        frame = frames[size].convert("RGBA")
        if size >= 256:
            buffer = io.BytesIO()
            frame.save(buffer, format="PNG")
            data = buffer.getvalue()
        else:
            from PIL import Image
            flipped = frame.transpose(Image.Transpose.FLIP_TOP_BOTTOM)
            raw = flipped.tobytes("raw", "BGRA")
            row_bytes = ((size + 31) // 32) * 4
            mask = bytearray(row_bytes * size)
            alpha = flipped.getchannel("A").tobytes()
            for y in range(size):
                for x in range(size):
                    if alpha[y * size + x] == 0:
                        mask[y * row_bytes + (x >> 3)] |= 0x80 >> (x & 7)
            header = struct.pack("<IIIHHIIIIII", 40, size, size * 2, 1, 32, 0, len(raw) + len(mask), 0, 0, 0, 0)
            data = header + raw + bytes(mask)
        entries.append((0 if size >= 256 else size, len(data)))
        payloads.append(data)
    directory = bytearray(struct.pack("<HHH", 0, 1, len(entries)))
    offset = 6 + 16 * len(entries)
    for dimension, length in entries:
        directory += struct.pack("<BBBBHHII", dimension, dimension, 0, 0, 1, 32, length, offset)
        offset += length
    return bytes(directory) + b"".join(payloads)


def write_icon(path, ring="#FFFFFF"):
    Path(path).write_bytes(build_ico(icon_frames(ring)))
    return Path(path)


if __name__ == "__main__":
    target = Path(__file__).resolve().with_name("orbit.ico")
    write_icon(target)
    print(f"Wrote {target}")
