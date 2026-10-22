"""Generates Orbit's app icons from one geometry: a ring that opens at the top for its
satellite (the same mark the apps draw in SwiftUI, see Shared/Design/OrbitMark.swift).

- Liquid Glass `.icon` documents (Icon Composer format) for iPhone, iPad, Mac and
  Apple Watch: the default icon and the Orbit Pro alternates.
- Layered PNGs for Apple TV (tvOS has no `.icon` support): Home Screen and App Store
  image stacks plus the Top Shelf images.

Run from the repository root:  python3 Orbit-iOS/Tools/generate_orbit_icons.py
Needs Pillow for the tvOS PNGs.
"""
import json
import math
import os
import shutil
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[2]
ICONS = ROOT / "Orbit-iOS/Shared/Icons"
TV_ASSETS = ROOT / "Orbit-iOS/OrbitTV/Assets.xcassets/AppIcon.brandassets"

# Geometry on a 1024 canvas (the Icon Composer artboard).
CENTER = 512.0
RADIUS = 270.0       # ring center line
STROKE = 90.0        # ring weight (about 9% of the canvas)
SATELLITE = 62.0     # satellite radius
MARGIN = 38.0        # air between the satellite and the ring ends
HALF_GAP = (SATELLITE + MARGIN + STROKE / 2) / RADIUS  # radians


def point(angle, radius):
    """SVG coordinates of a point at a math angle (counterclockwise, y up)."""
    return CENTER + radius * math.cos(angle), CENTER - radius * math.sin(angle)


def ring_path():
    """The ring as a filled outline: outer arc, round cap, inner arc, round cap."""
    start = math.pi / 2 + HALF_GAP          # left end of the opening
    end = math.pi / 2 - HALF_GAP + 2 * math.pi  # right end, the long way round
    outer, inner, cap = RADIUS + STROKE / 2, RADIUS - STROKE / 2, STROKE / 2
    o1, o2 = point(start, outer), point(end, outer)
    i1, i2 = point(start, inner), point(end, inner)
    f = lambda p: f"{p[0]:.3f} {p[1]:.3f}"
    return (f"M {f(o1)} "
            f"A {outer:.3f} {outer:.3f} 0 1 0 {f(o2)} "   # outer arc, counterclockwise on screen
            f"A {cap:.3f} {cap:.3f} 0 0 0 {f(i2)} "       # round cap at the right end
            f"A {inner:.3f} {inner:.3f} 0 1 1 {f(i1)} "   # inner arc back
            f"A {cap:.3f} {cap:.3f} 0 0 0 {f(o1)} Z")     # round cap at the left end


def svg(body):
    return ('<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">\n'
            f"  {body}\n</svg>\n")


RING_SVG = svg(f'<path fill="#FFFFFF" d="{ring_path()}"/>')
SATELLITE_SVG = svg(f'<circle cx="{CENTER:.0f}" cy="{CENTER - RADIUS:.0f}" r="{SATELLITE:.0f}" fill="#FFFFFF"/>')


def p3(r, g, b, a=1.0):
    return f"display-p3:{r:.5f},{g:.5f},{b:.5f},{a:.5f}"


def vertical(top, bottom):
    return {"linear-gradient": [top, bottom],
            "orientation": {"start": {"x": 0.5, "y": 0}, "stop": {"x": 0.5, "y": 1}}}


# name: (title, light background top/bottom, dark background top/bottom, ring color, satellite color)
GRAPHITE = ((0.235, 0.247, 0.282), (0.063, 0.066, 0.078))
GRAPHITE_DARK = ((0.141, 0.145, 0.165), (0.0, 0.0, 0.0))
WHITE = (1.0, 1.0, 1.0)
ORBIT_BLUE = (0.039, 0.518, 1.0)
VARIANTS = {
    "AppIcon": ("Graphite", GRAPHITE, GRAPHITE_DARK, WHITE, ORBIT_BLUE),
    "AppIcon-Neon": ("Blue", ((0.169, 0.471, 1.0), (0.035, 0.153, 0.502)), ((0.078, 0.255, 0.651), (0.0, 0.039, 0.161)), WHITE, WHITE),
    "AppIcon-Gold": ("Gold", ((0.204, 0.180, 0.141), (0.051, 0.043, 0.031)), ((0.125, 0.110, 0.086), (0.0, 0.0, 0.0)), (0.902, 0.722, 0.298), WHITE),
    "AppIcon-Crimson": ("Red", GRAPHITE, GRAPHITE_DARK, WHITE, (1.0, 0.271, 0.227)),
    "AppIcon-Matrix": ("Green", GRAPHITE, GRAPHITE_DARK, WHITE, (0.188, 0.820, 0.345)),
    "AppIcon-Minimal": ("Light", ((0.965, 0.965, 0.973), (0.820, 0.824, 0.847)), ((0.300, 0.304, 0.322), (0.110, 0.110, 0.118)), (0.110, 0.110, 0.122), ORBIT_BLUE),
}


def layer_fill(color):
    """A glyph color that turns white in the Clear and Tinted appearances."""
    return [{"value": {"solid": p3(*color)}},
            {"appearance": "tinted", "value": {"solid": "srgb:1.00000,1.00000,1.00000,1.00000"}}]


def icon_json(light, dark, ring, satellite):
    watch = [{"idiom": "watchOS", "value": {"scale": 0.9, "translation-in-points": [0, 8]}}]
    return {
        "color-space-for-untagged-svg-colors": "display-p3",
        "features": ["refractivity", "specular-location"],
        "fill-specializations": [
            {"value": vertical(p3(*light[0]), p3(*light[1]))},
            {"appearance": "dark", "value": vertical(p3(*dark[0]), p3(*dark[1]))},
        ],
        "groups": [
            {   # Front: the satellite, the light that tells you the PC is on.
                "name": "Satellite",
                "layers": [{"name": "satellite", "image-name": "satellite.svg", "glass": True,
                            "fill-specializations": layer_fill(satellite)}],
                "lighting": "combined",
                "shadow": {"kind": "layer-color", "opacity": 0.55},
                "specular": "outside",
                "translucency": {"enabled": True, "value": 0.15},
                "position-specializations": watch,
            },
            {
                "name": "Ring",
                "layers": [{"name": "ring", "image-name": "ring.svg", "glass": True,
                            "fill-specializations": layer_fill(ring)}],
                "lighting": "combined",
                "shadow": {"kind": "neutral", "opacity": 0.45},
                "specular": "outside",
                "translucency": {"enabled": True, "value": 0.2},
                "position-specializations": watch,
            },
        ],
        "supported-platforms": {"circles": ["watchOS"], "squares": "shared"},
    }


def write_icons():
    ICONS.mkdir(parents=True, exist_ok=True)
    for name, (_, light, dark, ring, satellite) in VARIANTS.items():
        package = ICONS / f"{name}.icon"
        if package.exists():
            shutil.rmtree(package)
        (package / "Assets").mkdir(parents=True)
        (package / "Assets/ring.svg").write_text(RING_SVG)
        (package / "Assets/satellite.svg").write_text(SATELLITE_SVG)
        (package / "icon.json").write_text(json.dumps(icon_json(light, dark, ring, satellite), indent=2) + "\n")
        print("wrote", package.relative_to(ROOT))


# MARK: - Mac menu bar

MAC_ASSETS = ROOT / "Orbit-iOS/OrbitMac/Assets.xcassets"


def write_menu_bar_mark():
    """The mark as a template image for the Mac menu bar (the system colors it)."""
    imageset = MAC_ASSETS / "OrbitMenuBarMark.imageset"
    imageset.mkdir(parents=True, exist_ok=True)
    # Square view box around the ring and the satellite above it.
    body = (f'<path fill="#000000" d="{ring_path()}"/>\n'
            f'  <circle cx="{CENTER:.0f}" cy="{CENTER - RADIUS:.0f}" r="{SATELLITE:.0f}" fill="#000000"/>')
    (imageset / "mark.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="185 177 654 654">\n'
        f"  {body}\n</svg>\n")
    (imageset / "Contents.json").write_text(json.dumps({
        "images": [{"filename": "mark.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True, "template-rendering-intent": "template"},
    }, indent=2) + "\n")
    print("wrote", imageset.relative_to(ROOT))


# MARK: - Apple TV

SS = 4  # supersampling for smooth edges


def gradient(size, top, bottom):
    width, height = size
    image = Image.new("RGB", (width, height))
    pixels = ImageDraw.Draw(image)
    for y in range(height):
        t = y / max(1, height - 1)
        pixels.line([(0, y), (width, y)], fill=tuple(int(255 * (top[i] + (bottom[i] - top[i]) * t)) for i in range(3)))
    return image


def mark_layer(size, mark_height, center=None, ring=WHITE, satellite=ORBIT_BLUE):
    """The mark alone on a transparent layer, its ring `mark_height` pixels tall."""
    width, height = size
    canvas = Image.new("RGBA", (width * SS, height * SS), (0, 0, 0, 0))
    draw = ImageDraw.Draw(canvas)
    scale = mark_height / (2 * (RADIUS + STROKE / 2)) * SS
    cx, cy = center if center else (width / 2, height / 2)
    cx, cy = cx * SS, cy * SS + (SATELLITE - STROKE / 2) * scale / 2

    def to_canvas(p):
        return cx + (p[0] - CENTER) * scale, cy + (p[1] - CENTER) * scale

    start, end = math.pi / 2 + HALF_GAP, math.pi / 2 - HALF_GAP + 2 * math.pi
    steps = 720
    outline = [to_canvas(point(start + (end - start) * i / steps, RADIUS + STROKE / 2)) for i in range(steps + 1)]
    outline += [to_canvas(point(start + (end - start) * i / steps, RADIUS - STROKE / 2)) for i in range(steps, -1, -1)]
    ring_color = tuple(int(255 * c) for c in ring) + (255,)
    draw.polygon(outline, fill=ring_color)
    for angle in (start, end):
        x, y = to_canvas(point(angle, RADIUS))
        r = STROKE / 2 * scale
        draw.ellipse([x - r, y - r, x + r, y + r], fill=ring_color)
    x, y = to_canvas((CENTER, CENTER - RADIUS))
    r = SATELLITE * scale
    draw.ellipse([x - r, y - r, x + r, y + r], fill=tuple(int(255 * c) for c in satellite) + (255,))
    return canvas.resize((width, height), Image.LANCZOS)


def save_rgb(image, path):
    image.convert("RGB").save(path, optimize=True)


def write_tv():
    light = GRAPHITE
    stacks = {"App Icon.imagestack": [(400, 240, "1x"), (800, 480, "2x")],
              "App Icon - App Store.imagestack": [(1280, 768, "1x")]}
    for stack, sizes in stacks.items():
        for width, height, scale in sizes:
            back = TV_ASSETS / stack / "Back.imagestacklayer/Content.imageset" / f"back@{scale}.png"
            front = TV_ASSETS / stack / "Front.imagestacklayer/Content.imageset" / f"front@{scale}.png"
            save_rgb(gradient((width, height), *light), back)
            mark_layer((width, height), height * 0.6).save(front, optimize=True)
            print("wrote", back.relative_to(ROOT), "and front")
    font_path = "/System/Library/Fonts/SFNS.ttf"
    shelves = {"Top Shelf Image.imageset": [(1920, 720, "1x"), (3840, 1440, "2x")],
               "Top Shelf Image Wide.imageset": [(2320, 720, "1x"), (4640, 1440, "2x")]}
    for shelf, sizes in shelves.items():
        for width, height, scale in sizes:
            image = gradient((width, height), *light).convert("RGBA")
            mark_height = height * 0.36
            left = width * 0.5 - height * 0.62
            image.alpha_composite(mark_layer((width, height), mark_height, center=(left, height / 2)))
            if os.path.exists(font_path):
                draw = ImageDraw.Draw(image)
                font = ImageFont.truetype(font_path, int(height * 0.2))
                draw.text((left + mark_height * 0.85, height / 2), "Orbit", font=font, fill=(255, 255, 255, 255), anchor="lm")
            path = TV_ASSETS / shelf / f"shelf@{scale}.png"
            save_rgb(image, path)
            print("wrote", path.relative_to(ROOT))


if __name__ == "__main__":
    write_icons()
    write_menu_bar_mark()
    write_tv()
