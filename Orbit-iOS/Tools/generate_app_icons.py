"""Generate every Orbit app icon from one procedural scene.

The scene is a glass planet with a tilted ring that passes in front of it and an amber moon, on a bright
blue-violet gradient (bright enough for the circular Apple Watch icon, see App Review guideline 4).

Writes:
  Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png         iPhone/iPad (1024, opaque)
  Orbit/Assets.xcassets/OrbitMark.imageset/OrbitMark.png          in-app logo (1024, opaque)
  OrbitWatch/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png     Apple Watch (1024, opaque)
  OrbitMac/Assets.xcassets/AppIcon.appiconset/icon_*.png          Mac squircle on the 824/1024 grid, 16–1024
  OrbitTV/Assets.xcassets/AppIcon.brandassets/…                   tvOS parallax icon (Back/Middle/Front) + Top Shelf

The Orbit Pro alternate icons (AppIcon-Matrix, -Minimal, -Crimson, -Gold, -Neon) are not touched.

Run from the repository root with a Python that has numpy, scipy and Pillow:
    python3 Orbit-iOS/Tools/generate_app_icons.py [--preview DIR]
"""
import argparse
import json
import math
import shutil
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont
from scipy.ndimage import gaussian_filter

F = np.float32
TILT = math.radians(-22)  # the ring rises to the right


# ---------------------------------------------------------------------------------------------- helpers

def smooth(e0, e1, x):
    t = np.clip((x - e0) / (e1 - e0), 0.0, 1.0)
    return t * t * (3 - 2 * t)


def hex_color(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4)], dtype=F)


def blur(rgba, sigma):
    """Gaussian blur of a premultiplied RGBA image, done on a reduced grid (glows are smooth anyway)."""
    H, W = rgba.shape[:2]
    k = max(1, int(sigma // 4))
    out = np.empty_like(rgba)
    for c in range(4):
        small = np.asarray(Image.fromarray(rgba[..., c].astype(F), "F").resize((max(1, W // k), max(1, H // k)), Image.BOX))
        small = gaussian_filter(small, sigma / k, mode="constant", truncate=3.0)
        out[..., c] = np.asarray(Image.fromarray(small.astype(F), "F").resize((W, H), Image.BILINEAR))
    return out


def over(dst, src):
    """Premultiplied src over premultiplied dst."""
    return src + dst * (1 - src[..., 3:4])


def add_light(dst, glow):
    out = dst.copy()
    out[..., :3] = dst[..., :3] + glow[..., :3]
    out[..., 3] = np.clip(dst[..., 3] + glow[..., 3], 0, 1)
    return out


def flatten(*layers):
    out = layers[0].copy()
    for layer in layers[1:]:
        out = over(out, layer)
    out[..., :3] = np.clip(out[..., :3], 0, 1)
    out[..., 3] = np.clip(out[..., 3], 0, 1)
    return out


def to_image(rgba, opaque):
    if opaque:
        return Image.fromarray((np.clip(rgba[..., :3], 0, 1) * 255 + 0.5).astype(np.uint8), "RGB")
    a = np.clip(rgba[..., 3:4], 0, 1)
    rgb = np.where(a > 1e-6, np.clip(rgba[..., :3] / np.maximum(a, 1e-6), 0, 1), 0)
    return Image.fromarray((np.concatenate([rgb, a], axis=2) * 255 + 0.5).astype(np.uint8), "RGBA")


# ---------------------------------------------------------------------------------------------- scene

class Palette:
    bg = [hex_color(c) for c in ("#46A6FF", "#2A5CEB", "#5022C9")]
    planet_light, planet_mid = hex_color("#9FE4FF"), hex_color("#2F74EE")
    planet_dark, planet_night = hex_color("#17288A"), hex_color("#080D3A")
    rim, ring_core, ring_edge, glow = hex_color("#7DEBFF"), hex_color("#FFFFFF"), hex_color("#86E9FF"), hex_color("#9BE9FF")
    moon_light, moon_dark, moon_glow = hex_color("#FFE7A8"), hex_color("#FF7A1A"), hex_color("#FFB04D")


def scene(W, H, cx, cy, u, pal=Palette, stars=True, keep_clear=()):
    """Draw the scene on a W×H canvas. (cx, cy) is the planet centre, u the icon unit (side of the square
    icon). keep_clear: canvas rectangles (x0, y0, x1, y1) without stars. Returns premultiplied float RGBA layers: background (opaque), middle (far side of the ring +
    planet) and front (near side of the ring + moon)."""
    yy, xx = np.mgrid[0:H, 0:W].astype(F)
    x, y = xx + F(0.5) - F(cx), yy + F(0.5) - F(cy)
    aa = 1.0

    # background: diagonal gradient across the canvas, soft light behind the planet, a few stars
    t = np.clip((xx * 0.62 + yy * 0.78) / (0.62 * W + 0.78 * H), 0, 1)[..., None]
    c0, c1, c2 = pal.bg
    bg = np.where(t < 0.5, c0 * (1 - t / 0.5) + c1 * (t / 0.5), c1 * (1 - (t - 0.5) / 0.5) + c2 * ((t - 0.5) / 0.5))
    r = np.sqrt(x ** 2 + y ** 2)
    halo = np.exp(-(r / (0.36 * u)) ** 2)[..., None]
    bg = bg + (np.array([0.75, 0.92, 1.0], dtype=F) - bg) * halo * 0.30
    bg = bg * (1 - 0.18 * smooth(0.45 * u, 0.85 * u, r)[..., None])
    if stars:
        rng = np.random.default_rng(7)
        count = int(14 * (W * H) / (u * u))
        for _ in range(count):
            sx, sy = rng.uniform(-W / 2, W / 2) * 0.96, rng.uniform(-H / 2, H / 2) * 0.96
            sx, sy = sx + W / 2 - cx, sy + H / 2 - cy
            sr = rng.uniform(0.0025, 0.0060) * u
            sa = rng.uniform(0.25, 0.60)
            if math.hypot(sx, sy) < 0.30 * u:
                continue
            if any(r[0] <= cx + sx <= r[2] and r[1] <= cy + sy <= r[3] for r in keep_clear):
                continue
            x0, x1 = int(max(0, cx + sx - 6 * sr)), int(min(W, cx + sx + 6 * sr + 1))
            y0, y1 = int(max(0, cy + sy - 6 * sr)), int(min(H, cy + sy + 6 * sr + 1))
            if x0 >= x1 or y0 >= y1:
                continue
            d = np.sqrt((x[y0:y1, x0:x1] - sx) ** 2 + (y[y0:y1, x0:x1] - sy) ** 2)
            light = (smooth(sr + aa, sr - aa, d) + np.exp(-(d / (sr * 3.5)) ** 2) * 0.35) * sa
            bg[y0:y1, x0:x1] = bg[y0:y1, x0:x1] + (1 - bg[y0:y1, x0:x1]) * light[..., None]
    background = np.concatenate([np.clip(bg, 0, 1), np.ones((H, W, 1), F)], axis=2)

    # ring (ring frame: xr along the major axis, yr > 0 is the near side)
    A, B = 0.405 * u, 0.138 * u
    ca, sa_ = math.cos(TILT), math.sin(TILT)
    xr, yr = x * ca + y * sa_, -x * sa_ + y * ca
    rho = np.sqrt((xr / A) ** 2 + (yr / B) ** 2) + 1e-9
    grad = np.sqrt((xr / A ** 2) ** 2 + (yr / B ** 2) ** 2) / rho + 1e-9
    dist = (rho - 1) / grad
    sinp = (yr / B) / rho
    near = smooth(-0.12, 0.12, sinp)
    half = (0.020 + 0.026 * (1 + sinp) / 2) * u / 2          # 0.020u wide at the back, 0.046u at the front
    ring_a = smooth(half + aa, half - aa, np.abs(dist))
    core = np.clip(1 - (np.abs(dist) / half) ** 2, 0, 1) ** 0.6
    ring_rgb = pal.ring_edge * (1 - core[..., None]) + pal.ring_core * core[..., None]
    far = (1 - near)[..., None]
    ring_rgb = ring_rgb * (1 - 0.35 * far) + pal.ring_edge * 0.35 * far
    back_a = ring_a * (1 - near) * 0.92
    front_a = ring_a * near
    ring_back = np.concatenate([ring_rgb * back_a[..., None], back_a[..., None]], axis=2)
    ring_front = np.concatenate([ring_rgb * front_a[..., None], front_a[..., None]], axis=2)

    def glow_of(layer, sigma, strength, color):
        g = np.zeros_like(layer)
        g[..., :3] = color * layer[..., 3:4]
        g[..., 3] = layer[..., 3]
        g = blur(g, sigma)
        g[..., :3] *= strength
        g[..., 3] *= strength * 0.85
        return g

    # planet
    L = np.array([-0.52, -0.62, 0.59]); L /= np.linalg.norm(L)
    Hv = L + np.array([0, 0, 1.0]); Hv /= np.linalg.norm(Hv)
    Rp = 0.222 * u
    nx, ny = x / Rp, y / Rp
    q = nx ** 2 + ny ** 2
    p_a = smooth(1 + aa / Rp, 1 - aa / Rp, np.sqrt(q))
    nz = np.sqrt(np.clip(1 - q, 0, 1))
    wrap = np.clip((nx * L[0] + ny * L[1] + nz * L[2] + 0.30) / 1.30, 0, 1)
    band_v = -nx * sa_ + ny * ca                               # bands parallel to the ring plane
    bands = 0.045 * np.sin(band_v * 9.0 + 0.9 * np.sin(nx * 3.1 + 0.4)) + 0.022 * np.sin(band_v * 23.0)
    s = np.clip(wrap + bands * (0.4 + 0.6 * wrap), 0, 1)[..., None]
    col = np.where(s < 0.33, pal.planet_night * (1 - s / 0.33) + pal.planet_dark * (s / 0.33),
          np.where(s < 0.70, pal.planet_dark * (1 - (s - 0.33) / 0.37) + pal.planet_mid * ((s - 0.33) / 0.37),
                   pal.planet_mid * (1 - (s - 0.70) / 0.30) + pal.planet_light * ((s - 0.70) / 0.30)))
    ndh = np.clip(nx * Hv[0] + ny * Hv[1] + nz * Hv[2], 0, 1)
    col = col + pal.rim * ((1 - nz) ** 2.4)[..., None] * 1.05 * (0.45 + 0.55 * (1 - wrap))[..., None]
    col = col + ((ndh ** 30) * 0.16 + (ndh ** 260) * 1.0)[..., None]
    # shadow of the near side of the ring on the planet
    sx_, sy_ = x - 0.012 * u, y + 0.030 * u
    sh = (np.sqrt((sx_ * ca + sy_ * sa_) ** 2 / A ** 2 + (-sx_ * sa_ + sy_ * ca) ** 2 / B ** 2) - 1) / grad
    col = col * (1 - (smooth(0.030 * u, 0.0, np.abs(sh)) * near * 0.35)[..., None])
    planet = np.concatenate([np.clip(col, 0, 1.4) * p_a[..., None], p_a[..., None]], axis=2)
    atmosphere = np.zeros_like(planet)
    atmosphere[..., :3] = pal.glow * p_a[..., None]
    atmosphere[..., 3] = p_a
    atmosphere = blur(atmosphere, 0.045 * u)
    atmosphere[..., :3] *= 0.75
    atmosphere[..., 3] *= 0.55

    # moon, on the far side of the ring at the upper right
    phm = math.radians(-52)
    mxr, myr = A * math.cos(phm), B * math.sin(phm)
    mx, my = mxr * ca - myr * sa_, mxr * sa_ + myr * ca
    Rm = 0.050 * u
    mnx, mny = (x - mx) / Rm, (y - my) / Rm
    mq = mnx ** 2 + mny ** 2
    m_a = smooth(1 + aa / Rm, 1 - aa / Rm, np.sqrt(mq))
    mnz = np.sqrt(np.clip(1 - mq, 0, 1))
    mdl = np.clip((mnx * L[0] + mny * L[1] + mnz * L[2] + 0.25) / 1.25, 0, 1)[..., None]
    mcol = pal.moon_dark * (1 - mdl) + pal.moon_light * mdl
    mcol = mcol + (np.clip(mnx * Hv[0] + mny * Hv[1] + mnz * Hv[2], 0, 1) ** 60)[..., None] * 0.9
    mcol = mcol + pal.moon_light * ((1 - mnz) ** 3)[..., None] * 0.35
    moon = np.concatenate([np.clip(mcol, 0, 1.3) * m_a[..., None], m_a[..., None]], axis=2)

    ring_all = ring_back + ring_front
    ring_glow = glow_of(ring_all, 0.022 * u, 0.95, pal.glow) + glow_of(ring_all, 0.070 * u, 0.45, pal.glow)
    zero = np.zeros((H, W, 4), F)
    middle = add_light(zero, atmosphere)
    middle = add_light(middle, ring_glow * (1 - near)[..., None])
    middle = over(middle, ring_back)
    middle = over(middle, planet)
    front = add_light(zero, ring_glow * near[..., None])
    front = over(front, ring_front)
    front = add_light(front, glow_of(moon, 0.040 * u, 1.1, pal.moon_glow))
    front = over(front, moon)
    return background.astype(F), middle.astype(F), front.astype(F)


def square_art(size, supersample=2):
    S = size * supersample
    layers = scene(S, S, S / 2, S / 2 + 0.01 * S, S)
    return to_image(flatten(*layers), opaque=True).resize((size, size), Image.LANCZOS)


# ---------------------------------------------------------------------------------------------- formats

def write_json(obj, directory):
    directory.mkdir(parents=True, exist_ok=True)
    (directory / "Contents.json").write_text(json.dumps(obj, indent=2) + "\n")


def mac_icon(art1024):
    """Squircle on Apple's macOS grid: 824×824 shape at (100, 100) on a 1024 canvas, with a soft shadow."""
    mask = Image.new("L", (4096, 4096), 0)
    ImageDraw.Draw(mask).rounded_rectangle((400, 400, 3695, 3695), radius=740, fill=255)
    mask = mask.resize((1024, 1024), Image.LANCZOS)
    # shadow: the shape, 12 px lower, blurred
    shifted = Image.new("L", (1024, 1024), 0)
    shifted.paste(mask.crop((0, 0, 1024, 1012)), (0, 12))
    shadow = Image.new("RGBA", (1024, 1024), (8, 14, 60, 0))
    shadow.putalpha(shifted.point(lambda v: int(v * 0.32)).filter(ImageFilter.GaussianBlur(14)))
    tile = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
    tile.paste(art1024.resize((824, 824), Image.LANCZOS), (100, 100))
    tile.putalpha(mask)
    canvas = Image.alpha_composite(Image.new("RGBA", (1024, 1024), (0, 0, 0, 0)), shadow)
    canvas = Image.alpha_composite(canvas, tile)
    # faint light edge along the upper part of the squircle, like the system icons
    inner = mask.filter(ImageFilter.MinFilter(5))
    edge = np.clip(np.asarray(mask, np.int16) - np.asarray(inner, np.int16), 0, 255).astype(F)
    fade = np.clip(1 - np.linspace(0, 1, 1024, dtype=F) * 2.2, 0, 1)[:, None] * 0.30
    highlight = Image.new("RGBA", (1024, 1024), (255, 255, 255, 0))
    highlight.putalpha(Image.fromarray((edge * fade).astype(np.uint8)))
    return Image.alpha_composite(canvas, highlight)


def tv_layers(width, height, supersample):
    W, H = width * supersample, height * supersample
    u = 1.10 * H
    bg, mid, fr = scene(W, H, W / 2, H / 2 + 0.01 * u, u)
    out = []
    for layer, opaque in ((bg, True), (mid, False), (fr, False)):
        out.append(to_image(layer, opaque).resize((width, height), Image.LANCZOS))
    return out   # back, middle, front


def font(size, weight):
    f = ImageFont.truetype("/System/Library/Fonts/SFNS.ttf", size)
    try:
        f.set_variation_by_axes([100, min(96, max(17, size)), 400, weight])
    except Exception:
        pass
    return f


def top_shelf(width, scale):
    W, H = width * scale, 720 * scale
    group = 1160 * scale
    start = (W - group) / 2
    u = 0.92 * H
    text_box = (start + 660 * scale, 220 * scale, start + group + 60 * scale, 470 * scale)
    layers = scene(W, H, start + 0.47 * H, H / 2 + 0.01 * u, u, keep_clear=[text_box])
    img = to_image(flatten(*layers), opaque=True)
    draw = ImageDraw.Draw(img)
    title_font, sub_font = font(118 * scale, 700), font(35 * scale, 500)
    x = start + 690 * scale
    for ch in "ORBIT":
        draw.text((x, 360 * scale), ch, font=title_font, fill=(255, 255, 255), anchor="ls")
        x += title_font.getlength(ch) + 9 * scale
    draw.text((start + 694 * scale, 428 * scale), "Your PC. Within reach.", font=sub_font,
              fill=(226, 238, 255), anchor="ls")
    return img


def generate(repo, preview=None):
    ios = repo / "Orbit-iOS"
    info = {"author": "xcode", "version": 1}
    art = square_art(1024)

    art.save(ios / "Orbit/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png")
    art.save(ios / "Orbit/Assets.xcassets/OrbitMark.imageset/OrbitMark.png")
    art.save(ios / "OrbitWatch/Assets.xcassets/AppIcon.appiconset/OrbitIcon.png")

    mac = mac_icon(art)
    mac_dir = ios / "OrbitMac/Assets.xcassets/AppIcon.appiconset"
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            mac.resize((px, px), Image.LANCZOS).save(mac_dir / name)

    brand = ios / "OrbitTV/Assets.xcassets/AppIcon.brandassets"
    for name, (w, h), scales in (("App Icon - App Store", (1280, 768), [1]), ("App Icon", (400, 240), [1, 2])):
        stack = brand / f"{name}.imagestack"
        if stack.exists():
            shutil.rmtree(stack)
        names = ["Front", "Middle", "Back"]
        write_json({"info": info, "layers": [{"filename": f"{n}.imagestacklayer"} for n in names]}, stack)
        renders = {s: dict(zip(["Back", "Middle", "Front"], tv_layers(w * s, h * s, 2))) for s in scales}
        for n in names:
            layer_dir = stack / f"{n}.imagestacklayer"
            write_json({"info": info}, layer_dir)
            images = []
            for s in scales:
                filename = f"{n.lower()}@{s}x.png"
                (layer_dir / "Content.imageset").mkdir(parents=True, exist_ok=True)
                renders[s][n].save(layer_dir / "Content.imageset" / filename)
                images.append({"filename": filename, "idiom": "tv", "scale": f"{s}x"})
            write_json({"images": images, "info": info}, layer_dir / "Content.imageset")
    for name, width in (("Top Shelf Image", 1920), ("Top Shelf Image Wide", 2320)):
        shelf2 = top_shelf(width, 2)
        shelf2.save(brand / f"{name}.imageset" / "shelf@2x.png")
        shelf2.resize((width, 720), Image.LANCZOS).save(brand / f"{name}.imageset" / "shelf@1x.png")

    if preview:
        preview.mkdir(parents=True, exist_ok=True)
        art.save(preview / "icon-1024.png")
        mac.save(preview / "mac-1024.png")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--preview", type=Path, help="also save the square and Mac icons here")
    args = parser.parse_args()
    generate(Path.cwd(), args.preview)
    print("Orbit icons generated.")
