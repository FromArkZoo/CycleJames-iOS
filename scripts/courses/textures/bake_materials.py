# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the generic material textures for the CycleJames 3D courses.

    uv run --script scripts/courses/textures/bake_materials.py [--only ground,sky,...]

Everything is procedural (no photos, no downloaded assets) and tiles
seamlessly. Output goes to CycleJames/Resources/CourseTextures/, which the
app bundle flattens, so every file name starts with `cj_`. The Swift side
(CycleJames/Courses/Scene/World/WorldMaterials.swift) relies on the names,
the real-world tile sizes and the channel layouts documented per texture.
The setts (bake_setts.py) and the roofs (bake_buildings.py) have their own
scripts.

Data textures ("*_detail.rgbz", see texlib.save_raw) pack: R, G = tangent-space normal x, y
(+x along u, +y along v = down the image), B = roughness, A = height
(0 = lowest, 1 = highest) unless noted.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from texlib import (blur, fbm, linear_to_srgb, normal_xy, rng, save_gray, save_raw, save_rgb, save_rgb_dithered,  # noqa: E402
                    save_rgba, smoothstep, srgb_to_linear, stamp, to_u8, value_noise, voronoi)

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "CycleJames/Resources/CourseTextures"
# Bakes the app doesn't read yet: kept for development, out of the bundle.
UNUSED_OUT = ROOT / "scripts/courses/pipeline/textures"

# Keep in step with WorldSun in WorldConfig.swift.
SUN_AZIMUTH_DEG = 232.0
SUN_ELEVATION_DEG = 34.0


def detail_png(path: Path, height: np.ndarray, strength: float, rough: np.ndarray) -> None:
    nx, ny, _ = normal_xy(height, strength)
    rgba = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, rough, height], -1)
    save_raw(path, rgba)


# ---------------------------------------------------------------- asphalt

def bake_asphalt(size: int = 512) -> None:
    """cj_asphalt_albedo.jpg + cj_asphalt_detail.png, 2 m x 2 m tile:
    worn village asphalt with aggregate, patches and a few fine cracks."""
    r = rng(23)
    base = 0.25 + 0.02 * (fbm(size, size, 8, 3, r) - 0.5)
    agg = blur(value_noise(size, size, 256, 256, r), 0.7)
    agg2 = value_noise(size, size, 128, 128, r)
    light = smoothstep(0.7, 0.92, agg) * 0.12
    dark = smoothstep(0.7, 0.95, agg2) * -0.05
    patch = 0.0
    f1, f2, _ = voronoi(size, size, 9, r)
    crack = (1 - smoothstep(0.0, 1.6, f2 - f1)) * smoothstep(0.55, 0.7, fbm(size, size, 6, 2, r))
    lum = base + light + dark - patch - crack * 0.1
    tint = np.stack([lum * 1.0, lum * 0.99, lum * 0.97], -1)
    height = np.clip(0.5 + (agg - 0.5) * 0.5 + light - crack * 0.4, 0, 1)
    rough = np.clip(0.82 - light * 0.4 + crack * 0.1, 0.4, 1)
    save_rgb(OUT / "cj_asphalt_albedo.jpg", tint, 90)
    detail_png(OUT / "cj_asphalt_detail.png", height, 1.4, rough)


def bake_asphalt_fine(size: int = 512) -> None:
    """cj_asphalt_fine_albedo.jpg + cj_asphalt_fine_detail.rgbz, 1.6 m x 1.6 m
    tile: the Riviera's smooth, fine-grained provincial tarmac (the SP55 up
    the Poggio, resurfaced in long stretches). Pale limestone chips of 4-8
    mm sit in a grey binder, worn flat and a little polished; no cracks or
    patches (the shader lays the repairs along the road). Mean about 0.29
    sRGB, neutral with the faintest warmth (the look bible's paint base
    #62625f is reached with the material's intensity)."""
    r = rng(29)
    binder = 0.255 + 0.025 * (fbm(size, size, 16, 4, r) - 0.5)
    chips = blur(value_noise(size, size, 230, 230, r), 0.6)
    chips2 = blur(value_noise(size, size, 120, 120, r), 0.8)
    pits = value_noise(size, size, 170, 170, r)
    light = smoothstep(0.64, 0.9, chips) * 0.13 + smoothstep(0.7, 0.93, chips2) * 0.07
    dark = smoothstep(0.78, 0.96, pits) * -0.045
    lum = binder + light + dark
    # The chips a touch warmer than the binder.
    warm = light / 0.2
    tint = np.stack([lum * (1.0 + 0.02 * warm), lum * (0.995 + 0.01 * warm), lum * (0.975 - 0.01 * warm)], -1)
    # Height: the chips over a gentle swell four cells to the tile. The
    # shader reads the swell, magnified 9 and 32 times, as the road's
    # large-scale mottle (`WorldShaders.rivieraAsphaltCore`).
    swell = fbm(size, size, 4, 3, r)
    height = np.clip(0.2 + 0.45 * swell + (chips - 0.5) * 0.22 + light * 0.8 + dark * 1.3, 0, 1)
    rough = np.clip(0.84 - light * 0.9, 0.55, 1)
    save_rgb(OUT / "cj_asphalt_fine_albedo.jpg", tint, 90)
    detail_png(OUT / "cj_asphalt_fine_detail.rgbz", height, 1.1, rough)


# ---------------------------------------------------------------- ground

def blade_sprite(length: int, width: int, angle: float) -> np.ndarray:
    n = max(length, width) * 2 + 3
    yy, xx = np.mgrid[0:n, 0:n].astype(np.float32) - n / 2
    c, s = math.cos(angle), math.sin(angle)
    u = c * xx + s * yy
    v = -s * xx + c * yy
    t = np.clip(u / (length / 2), -1, 1)
    half_w = width / 2 * (1 - (t * 0.5 + 0.5) ** 2 * 0.9)
    a = (np.abs(u) <= length / 2) * np.clip(1 - np.abs(v) / np.maximum(half_w, 0.3), 0, 1)
    return a.astype(np.float32)


def bake_ground(size: int = 1024) -> None:
    """cj_ground_detail.rgbz, 2.5 m tile. Four height patterns, one per
    channel: R grass, G crop stubble and straw, B leaf litter and soil,
    A gravel. The terrain shader uses them for both brightness modulation
    and normals, and fades them to their means (printed here; keep
    `WorldShaders.terrainSurface` in step) where a pixel spans many
    texels."""
    r = rng(31)
    # Grass: thousands of thin blades in mostly random directions.
    grass = fbm(size, size, 32, 3, r) * 0.35
    canvas = grass[..., None].copy()
    alpha = np.zeros((size, size), np.float32)
    for _ in range(7000):
        L = int(r.uniform(14, 34)); W = int(r.uniform(2, 4))
        sp = blade_sprite(L, W, r.uniform(0, math.pi))
        val = np.full(sp.shape + (1,), r.uniform(0.45, 1.0), np.float32)
        stamp(canvas, alpha, val, sp, int(r.integers(0, size)), int(r.integers(0, size)), wrap=True)
    grass = canvas[..., 0]

    # Crop stubble and straw seen from above: cut-stalk ends as dots, loose
    # straw lying at random angles, soil between. Nothing periodic: rows
    # every 15 cm along the world's z aliased into converging bands across
    # every field seen from the road. Mean 0.37, as the rows had, so fields
    # keep their brightness. Drawn from its own generator; the shared one is
    # moved past the draws the old rows took, so the litter and gravel
    # channels below keep their bytes.
    value_noise(size, size, 400, 400, r)
    fbm(size, size, 16, 3, r)
    rc = rng(37)
    soil = 0.18 + 0.22 * fbm(size, size, 20, 4, rc)
    canvas = soil[..., None].copy()
    alpha = np.zeros((size, size), np.float32)
    for _ in range(14000):  # stalk ends, 5-7 mm
        d = int(rc.uniform(2, 4))
        yy, xx = np.mgrid[0:d * 2 + 1, 0:d * 2 + 1] - d
        sp = np.clip(1.2 - np.hypot(yy, xx) / d, 0, 1).astype(np.float32)
        val = np.full(sp.shape + (1,), rc.uniform(0.52, 0.85), np.float32)
        stamp(canvas, alpha, val, sp, int(rc.integers(0, size)), int(rc.integers(0, size)), wrap=True)
    for _ in range(2600):  # loose straw
        sp = blade_sprite(int(rc.uniform(20, 46)), 2, rc.uniform(0, math.pi))
        val = np.full(sp.shape + (1,), rc.uniform(0.6, 0.9), np.float32)
        stamp(canvas, alpha, val, sp, int(rc.integers(0, size)), int(rc.integers(0, size)), wrap=True)
    crop = np.clip(canvas[..., 0], 0, 1)

    # Leaf litter over soil.
    soil = fbm(size, size, 24, 4, r) * 0.4
    canvas = soil[..., None].copy()
    alpha = np.zeros((size, size), np.float32)
    for _ in range(3200):
        L = int(r.uniform(10, 26)); W = int(L * r.uniform(0.45, 0.7))
        sp = blade_sprite(L, W, r.uniform(0, math.pi))
        sp = np.clip(sp * 2.5, 0, 1)
        val = np.full(sp.shape + (1,), r.uniform(0.4, 1.0), np.float32)
        stamp(canvas, alpha, val, sp, int(r.integers(0, size)), int(r.integers(0, size)), wrap=True)
    litter = canvas[..., 0]

    # Gravel: domed pebbles.
    f1, f2, _ = voronoi(size, size, 3600, r)
    peb = np.clip((f2 - f1) / 4, 0, 1) ** 0.6
    gravel = np.clip(0.32 + peb * 0.36 + (value_noise(size, size, 256, 256, r) - 0.5) * 0.2, 0, 1)

    rgba = np.stack([grass, crop, litter, gravel], -1)
    save_raw(OUT / "cj_ground_detail.rgbz", rgba)
    print("ground detail channel means", np.round(to_u8(rgba).reshape(-1, 4).mean(0) / 255, 3))


# ---------------------------------------------------------------- foliage

def leaf_shape(length: float, width: float, kind: str) -> Image.Image:
    """A single leaf as an RGBA image (white, alpha = shape, midrib darker)."""
    s = 4
    L, W = int(length * s), int(max(width * s, 4))
    img = Image.new("L", (W + 4, L + 4), 0)
    d = ImageDraw.Draw(img)
    if kind == "ivy":
        cx = (W + 4) / 2
        pts = []
        for i in range(0, 361, 12):
            a = math.radians(i)
            lobes = 1 + 0.32 * math.cos(5 * a)
            rr = 0.5 * lobes
            pts.append((cx + math.sin(a) * W / 2 * rr * 1.9, (L + 4) / 2 - math.cos(a) * L / 2 * rr * 1.9))
        d.polygon(pts, fill=255)
    elif kind == "needle":
        d.line([((W + 4) / 2, 2), ((W + 4) / 2, L + 2)], fill=255, width=max(2, W))
    else:
        pts = []
        for i in range(0, 41):
            t = i / 40
            y = 2 + t * L
            prof = math.sin(math.pi * t) ** (0.8 if kind == "broad" else 0.6)
            if kind == "poplar":
                prof = (math.sin(math.pi * min(t * 1.25, 1)) if t < 0.8 else (1 - t) * 5 * 0.6) ** 0.7
            pts.append(((W + 4) / 2 + prof * W / 2, y))
        for i in range(40, -1, -1):
            t = i / 40
            y = 2 + t * L
            prof = math.sin(math.pi * t) ** (0.8 if kind == "broad" else 0.6)
            if kind == "poplar":
                prof = (math.sin(math.pi * min(t * 1.25, 1)) if t < 0.8 else (1 - t) * 5 * 0.6) ** 0.7
            pts.append(((W + 4) / 2 - prof * W / 2, y))
        d.polygon(pts, fill=255)
    img = img.resize((max(1, (W + 4) // s), max(1, (L + 4) // s)), Image.LANCZOS)
    return img


def foliage_card(size: int, kind: str, seed: int) -> np.ndarray:
    """A clump of leaves on twigs filling a roughly round card. RGBA in
    [0, 1]; rgb is the leaf albedo (sRGB), a the cut-out."""
    r = rng(seed)
    rgb = np.zeros((size, size, 3), np.float32)
    a = np.zeros((size, size), np.float32)
    params = {
        "broad": dict(n=900, L=(26, 40), W=(0.45, 0.6), greens=[(0.20, 0.33, 0.10), (0.25, 0.38, 0.12), (0.17, 0.28, 0.09), (0.30, 0.40, 0.14)]),
        "poplar": dict(n=1300, L=(20, 30), W=(0.75, 0.95), greens=[(0.27, 0.40, 0.13), (0.32, 0.44, 0.15), (0.22, 0.34, 0.11)]),
        "ivy": dict(n=1700, L=(28, 44), W=(1.0, 1.1), greens=[(0.15, 0.26, 0.08), (0.19, 0.30, 0.10), (0.12, 0.21, 0.07), (0.23, 0.33, 0.12), (0.27, 0.36, 0.13)]),
        "needle": dict(n=3600, L=(14, 22), W=(0.1, 0.12), greens=[(0.10, 0.20, 0.10), (0.12, 0.23, 0.12), (0.08, 0.17, 0.09)]),
    }[kind]
    cx = cy = size / 2
    # Twigs radiating from near the centre-bottom; leaves along them.
    twigs = []
    for _ in range(9 if kind != "needle" else 7):
        ang = r.uniform(-math.pi * 0.95, math.pi * 0.95) - math.pi / 2
        length = r.uniform(0.32, 0.48) * size
        x0, y0 = cx + r.uniform(-20, 20), cy + size * 0.18
        twigs.append((x0, y0, ang, length))
    canvas_img = Image.new("RGB", (size, size), (0, 0, 0))
    alpha_img = Image.new("L", (size, size), 0)
    dtw = ImageDraw.Draw(canvas_img)
    dta = ImageDraw.Draw(alpha_img)
    if kind == "needle":
        for (x0, y0, ang, length) in twigs:
            x1, y1 = x0 + math.cos(ang) * length * 0.85, y0 + math.sin(ang) * length * 0.85
            dtw.line([(x0, y0), (x1, y1)], fill=(52, 44, 34), width=2)
            dta.line([(x0, y0), (x1, y1)], fill=255, width=2)
    greens = np.array(params["greens"], np.float32)
    n = params["n"]
    # Leaf positions: a ragged disc (a square-ish mat for ivy), densest in
    # the middle; inner leaves are drawn first and darker.
    pts = []
    for i in range(n):
        if kind == "needle":
            x0, y0, ang, length = twigs[i % len(twigs)]
            t = r.uniform(0.05, 1.0)
            px = x0 + math.cos(ang) * length * t + r.normal(0, 10)
            py = y0 + math.sin(ang) * length * t + r.normal(0, 10)
            leaf_ang = ang + r.choice([-1, 1]) * r.uniform(0.5, 1.1)
        elif kind == "ivy":
            # A ragged cushion of ivy and bramble with deep bays and a few
            # stray leaves, so overlapping clumps never show a card outline.
            rad = math.sqrt(r.uniform(0, 1)) * 0.9
            ang = r.uniform(0, 2 * math.pi)
            lobe = 0.74 + 0.14 * math.sin(4 * ang + 1.7) + 0.1 * math.sin(7 * ang + 0.4) + 0.07 * math.sin(11 * ang + 2.9)
            if r.random() < rad ** 2.5 * 0.6:
                continue
            px = cx + math.cos(ang) * rad * lobe * size / 2
            py = cy + math.sin(ang) * rad * lobe * size / 2
            leaf_ang = r.uniform(0, 2 * math.pi)
        else:
            rad = math.sqrt(r.uniform(0, 1)) * 0.92
            ang = r.uniform(0, 2 * math.pi)
            lobe = 0.78 + 0.16 * math.sin(3 * ang + seed) + 0.1 * math.sin(5 * ang + 2 * seed) + 0.06 * math.sin(9 * ang)
            if r.random() < rad ** 3 * 0.55:
                continue
            px = cx + math.cos(ang) * rad * lobe * size / 2
            py = cy + math.sin(ang) * rad * lobe * size / 2 * 0.92
            leaf_ang = ang + r.normal(0, 0.8)
        dist = math.hypot(px - cx, py - cy) / (size / 2)
        if dist > 0.98 or (kind == "ivy" and dist > 0.86):
            continue
        pts.append((dist + r.uniform(-0.15, 0.15), px, py, leaf_ang, dist))
    pts.sort()
    for (_, px, py, leaf_ang, dist) in pts:
        L = r.uniform(*params["L"]) * (1.1 - 0.2 * dist)
        W = L * r.uniform(*params["W"])
        leaf = leaf_shape(L, W, "ivy" if kind == "ivy" else ("needle" if kind == "needle" else ("poplar" if kind == "poplar" else "broad")))
        rot = -math.degrees(leaf_ang) - 90
        leaf = leaf.rotate(rot, resample=Image.BICUBIC, expand=True)
        g = greens[r.integers(0, len(greens))] * r.uniform(0.82, 1.18)
        if kind == "broad" and r.random() < 0.03:
            g = np.array([0.45, 0.42, 0.14]) * r.uniform(0.9, 1.1)  # an early yellowing leaf
        if kind == "ivy" and r.random() < 0.04:
            g = np.array([0.36, 0.27, 0.13]) * r.uniform(0.85, 1.1)  # a dead bramble leaf
        g = g * (0.62 + 0.5 * min(dist + r.uniform(0, 0.25), 1))
        col = tuple(int(np.clip(v, 0, 1) * 255) for v in g)
        lw, lh = leaf.size
        tl = (int(px - lw / 2), int(py - lh / 2))
        solid = Image.new("RGB", leaf.size, col)
        canvas_img.paste(solid, tl, leaf)
        alpha_img.paste(255, tl, leaf)
    rgb = np.asarray(canvas_img, np.float32) / 255
    a = np.asarray(alpha_img, np.float32) / 255
    # Nothing may reach the cell border, where it would be cut straight.
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    border = np.minimum(np.minimum(xx, 1 - xx), np.minimum(yy, 1 - yy))
    a = a * smoothstep(0.012, 0.03, border)
    # Leaf-scale shading noise.
    rgb = rgb * (0.85 + 0.3 * fbm(size, size, 48, 3, r)[..., None])
    return np.concatenate([rgb, a[..., None]], -1)


def bake_foliage(size: int = 1024) -> None:
    """cj_foliage.png: 2 x 2 atlas of leaf-clump cards, each a 512 px quad
    standing for about 1.2 m of foliage. Top-left broadleaf, top-right
    poplar, bottom-left ivy / bramble, bottom-right conifer spray."""
    half = size // 2
    atlas = np.zeros((size, size, 4), np.float32)
    atlas[:half, :half] = foliage_card(half, "broad", 41)
    atlas[:half, half:] = foliage_card(half, "poplar", 42)
    atlas[half:, :half] = foliage_card(half, "ivy", 43)
    atlas[half:, half:] = foliage_card(half, "needle", 44)
    # Bleed colour into transparent texels so mip levels don't go dark.
    rgb, a = atlas[..., :3], atlas[..., 3:]
    blurred = blur(rgb * a, 6) / np.maximum(blur(a, 6), 1e-3)
    atlas[..., :3] = rgb * a + blurred * (1 - a)
    save_rgba(OUT / "cj_foliage.png", atlas)


def _blade(d: ImageDraw.ImageDraw, bx: float, by: float, height: float, lean: float, width: float,
           base_col, tip_col, r, steps: int = 10, dry_tip: bool = False) -> tuple:
    """One grass blade from (bx, by) up, tapering and leaning; returns its tip."""
    pts_l, pts_r = [], []
    for k in range(steps + 1):
        t = k / steps
        x, y = bx + lean * t * t, by - t * height
        wd = width * (1 - t) ** 0.9 / 2
        pts_l.append((x - wd, y)); pts_r.append((x + wd, y))
    for k in range(steps):
        t = (k + 0.5) / steps
        c = base_col + (tip_col - base_col) * t
        if dry_tip and t > 0.75:
            c = np.array([0.72, 0.64, 0.40])
        c = c * r.uniform(0.88, 1.12)
        col = tuple(int(np.clip(v, 0, 1) * 255) for v in c) + (255,)
        d.polygon([pts_l[k], pts_r[k], pts_r[k + 1], pts_l[k + 1]], fill=col)
    return pts_l[-1]


def _leaf(d: ImageDraw.ImageDraw, x: float, y: float, length: float, width: float, ang: float, col, serrate: int = 0) -> None:
    """A pointed leaf from (x, y) along `ang` (radians, 0 = right, image y down)."""
    pts = []
    for i in range(0, 21):
        t = i / 20
        w = math.sin(math.pi * t) ** 0.8 * (1 - 0.35 * t) * width / 2
        if serrate:
            w *= 1 + 0.18 * (math.sin(t * serrate * 2 * math.pi) > 0)
        pts.append((t, w))
    poly = [(x + math.cos(ang) * t * length - math.sin(ang) * w, y + math.sin(ang) * t * length + math.cos(ang) * w) for t, w in pts]
    poly += [(x + math.cos(ang) * t * length + math.sin(ang) * w, y + math.sin(ang) * t * length - math.cos(ang) * w) for t, w in reversed(pts)]
    d.polygon(poly, fill=tuple(int(np.clip(v, 0, 1) * 255) for v in col) + (255,))


GREEN_BASE, GREEN_TIP = np.array([0.16, 0.26, 0.07]), np.array([0.42, 0.55, 0.20])
DRY_BASE, DRY_TIP = np.array([0.42, 0.38, 0.18]), np.array([0.70, 0.64, 0.40])


def _tuft_cell(d, x0, y1, cw, ch, s, r, n, dry_share, seed_heads, tall=1.0):
    """Grass blades rooted on the bottom edge of a cell (x0, top y1 - ch)."""
    for _ in range(n):
        bx = x0 + r.uniform(0.15, 0.85) * cw
        height = r.uniform(0.35, 0.95) * ch * tall
        lean = r.normal(0, 0.25) * height
        dry = r.random() < dry_share
        tip = _blade(d, bx, y1, height, lean, r.uniform(3, 7) * s, DRY_BASE if dry else GREEN_BASE,
                     DRY_TIP if dry else GREEN_TIP, r, dry_tip=not dry and r.random() < 0.35)
        if seed_heads and r.random() < 0.35:
            x, y = tip
            for _ in range(9):
                ox, oy = r.normal(0, 4 * s), r.uniform(0, 30 * s)
                rr = 2.5 * s
                d.ellipse([x + ox - rr, y + oy - rr, x + ox + rr, y + oy + rr], fill=(196, 182, 130, 255))


def _stems_with_heads(d, x0, y1, cw, ch, s, r, n, head) -> None:
    """Flower stems rising from a little grass, each ending in `head(x, y)`."""
    _tuft_cell(d, x0, y1, cw, ch * 0.45, s, r, 40, 0.25, False)
    for _ in range(n):
        bx = x0 + r.uniform(0.2, 0.8) * cw
        height = r.uniform(0.55, 0.92) * ch
        tip = _blade(d, bx, y1, height, r.normal(0, 0.12) * height, 3 * s, np.array([0.20, 0.30, 0.10]),
                     np.array([0.30, 0.40, 0.14]), r, steps=8)
        for _ in range(2):   # a few stem leaves
            t = r.uniform(0.2, 0.6)
            _leaf(d, bx, y1 - t * height, r.uniform(14, 26) * s, r.uniform(4, 7) * s,
                  -math.pi / 2 + r.choice([-1, 1]) * r.uniform(0.6, 1.1), np.array([0.18, 0.30, 0.09]) * r.uniform(0.85, 1.1))
        head(*tip)


def bake_grass(size: int = 1024) -> None:
    """cj_grass.png, 1024 x 1024, straight alpha. Top half: four tuft cards of
    256 x 512, blades rooted on the bottom edge: green verge grass; false
    oat-grass with seed heads; a dry, yellowed tuft; a nettle clump. Below
    (y 512-895): four cards of 256 x 384: wild carrot and hogweed (white
    umbels); knapweed and yarrow; tansy (yellow); hart's-tongue and male
    fern. Two strips across the full width, tileable in u, for the sward
    ribbons on the verge: y 912-967 mown (short blades, clover and plantain
    at the base), y 968-1023 rough (long, dry tips, seed heads), each with
    a ragged foot; a ribbon's strip spans its height, 0.8 m of ribbon per u
    (see `VegetationBuilder.swardRibbon`).
    The layout is mirrored in `VegetationBuilder.GrassCell`."""
    s = 2
    W = size * s
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = rng(51)
    cw = 256 * s
    # Tufts.
    _tuft_cell(d, 0, 512 * s, cw, 512 * s, s, r, 150, 0.12, False)
    _tuft_cell(d, cw, 512 * s, cw, 512 * s, s, r, 120, 0.4, True)
    _tuft_cell(d, 2 * cw, 512 * s, cw, 512 * s, s, r, 130, 0.7, True, tall=0.9)
    # Nettles: upright stems, opposite pairs of dark serrated leaves, each
    # joint spaced, turned and sized its own way, and at some a thin
    # string of green flowers hanging from one side. (Pale tassels the same
    # at every joint stamped a column of chevrons down each clump.)
    x0, y1, ch = 3 * cw, 512 * s, 512 * s
    _tuft_cell(d, x0, y1, cw, ch * 0.4, s, r, 30, 0.2, False)
    for _ in range(7):
        bx = x0 + r.uniform(0.2, 0.8) * cw
        height = r.uniform(0.6, 0.95) * ch
        lean = r.normal(0, 0.06) * height
        _blade(d, bx, y1, height, lean, 4 * s, np.array([0.17, 0.22, 0.08]), np.array([0.22, 0.30, 0.10]), r, steps=8)
        joints = int(r.integers(5, 9))
        t = r.uniform(0.12, 0.22)
        while t < 0.97:
            px, py = bx + lean * t * t, y1 - t * height
            size_l = (1.15 - 0.6 * t) * 34 * s * r.uniform(0.8, 1.2)
            col = np.array([0.10, 0.19, 0.06]) * r.uniform(0.8, 1.2)
            turn = r.uniform(-0.3, 0.3)
            for sgn in (-1, 1):
                ln = size_l * r.uniform(0.85, 1.1)
                _leaf(d, px, py, ln, ln * r.uniform(0.48, 0.62), -math.pi / 2 + sgn * r.uniform(0.6, 1.25) + turn,
                      col * r.uniform(0.92, 1.08), serrate=int(r.integers(6, 9)))
            if 0.35 < t < 0.85 and r.random() < 0.3:
                sgn, n = r.choice([-1, 1]), int(r.integers(4, 7))
                ang, seg = sgn * r.uniform(0.25, 0.6), r.uniform(4, 6) * s
                pts = [(px, py)]
                for _ in range(n):
                    ang *= 0.75   # drooping towards straight down
                    pts.append((pts[-1][0] + math.sin(ang) * seg, pts[-1][1] + math.cos(ang) * seg))
                tone = r.uniform(0.85, 1.1)
                d.line(pts, fill=(int(62 * tone), int(80 * tone), 30, 255), width=s)
            t += 0.8 / joints * r.uniform(0.75, 1.3)
    # Flower cells, 384 px tall, from y 512.
    y1, ch = 896 * s, 384 * s

    def umbel(x, y):
        rad = r.uniform(14, 21) * s
        for _ in range(40):
            a, rr = r.uniform(0, 2 * math.pi), math.sqrt(r.uniform(0, 1)) * rad
            q = 2.2 * s
            d.ellipse([x + math.cos(a) * rr - q, y + math.sin(a) * rr * 0.35 - q, x + math.cos(a) * rr + q, y + math.sin(a) * rr * 0.35 + q],
                      fill=(int(232 * r.uniform(0.92, 1)), int(228 * r.uniform(0.92, 1)), 210, 255))
    _stems_with_heads(d, 0, y1, cw, ch, s, r, 6, umbel)

    def knap_or_yarrow(x, y):
        if r.random() < 0.55:   # knapweed: purple thistle-like head
            q = r.uniform(5, 7) * s
            d.ellipse([x - q * 0.8, y - q * 0.2, x + q * 0.8, y + q * 1.4], fill=(70, 60, 30, 255))
            for _ in range(14):
                a = r.uniform(-math.pi, 0)
                d.line([(x, y + q * 0.3), (x + math.cos(a) * q * 1.6, y + q * 0.3 + math.sin(a) * q * 1.6)],
                       fill=(int(150 * r.uniform(0.9, 1.1)), 72, int(160 * r.uniform(0.9, 1.1)), 255), width=2 * s)
        else:                   # yarrow: a flat white cluster
            for _ in range(18):
                a, rr = r.uniform(0, 2 * math.pi), math.sqrt(r.uniform(0, 1)) * 9 * s
                q = 2 * s
                d.ellipse([x + math.cos(a) * rr - q, y + math.sin(a) * rr * 0.4 - q, x + math.cos(a) * rr + q, y + math.sin(a) * rr * 0.4 + q],
                          fill=(236, 230, 214, 255))
    _stems_with_heads(d, cw, y1, cw, ch, s, r, 8, knap_or_yarrow)

    def tansy(x, y):
        for _ in range(9):
            a, rr = r.uniform(0, 2 * math.pi), math.sqrt(r.uniform(0, 1)) * 11 * s
            q = r.uniform(2.6, 3.6) * s
            d.ellipse([x + math.cos(a) * rr - q, y + math.sin(a) * rr * 0.5 - q, x + math.cos(a) * rr + q, y + math.sin(a) * rr * 0.5 + q],
                      fill=(int(222 * r.uniform(0.92, 1.05)), int(178 * r.uniform(0.9, 1.05)), 26, 255))
    _stems_with_heads(d, 2 * cw, y1, cw, ch, s, r, 7, tansy)
    # Ferns: male-fern fronds arching from the base, hart's-tongue straps.
    # Each frond's pinnae vary in angle, length and shade, and a few are
    # missing or nibbled, so no frond is a ruled herringbone. Drawn on a
    # layer of their own and kept to their cell, which is cleared first:
    # fronds reached into the tansy's cell and a tansy head into theirs.
    x0 = 3 * cw
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    fd = ImageDraw.Draw(layer)
    cx = x0 + cw / 2
    for k in range(9):
        ang = -math.pi / 2 + (k - 4) * 0.28 + r.uniform(-0.1, 0.1)
        length = r.uniform(0.6, 0.95) * ch
        if k % 3 == 1:   # hart's-tongue: a glossy strap
            _leaf(fd, cx + r.uniform(-15, 15) * s, y1, length * 0.7, 30 * s, ang, np.array([0.16, 0.32, 0.08]) * r.uniform(0.9, 1.1))
            continue
        col = np.array([0.15, 0.30, 0.08]) * r.uniform(0.85, 1.1)
        prev = (cx + r.uniform(-12, 12) * s, y1)
        steps = int(r.integers(19, 27))
        arch = r.uniform(0.7, 1.1) * (1 if ang > -math.pi / 2 else -1)
        spread = r.uniform(1.0, 1.3)
        for i in range(1, steps + 1):
            t = i / steps
            a = ang + arch * t * t + r.normal(0, 0.03)   # arching over
            p = (prev[0] + math.cos(a) * length / steps, prev[1] + math.sin(a) * length / steps)
            fd.line([prev, p], fill=(70, 86, 34, 255), width=2 * s)
            pin = (1 - t) ** 0.7 * 40 * s * (0.4 + 0.6 * math.sin(math.pi * min(t * 1.4, 1)))
            for sgn in (-1, 1):
                if r.random() < 0.06:
                    continue
                ln = pin * r.uniform(0.75, 1.1)
                _leaf(fd, p[0], p[1], ln, ln * r.uniform(0.28, 0.36), a + sgn * (spread + r.uniform(-0.15, 0.15)),
                      col * r.uniform(0.88, 1.12))
            prev = p
    d.rectangle([x0, 512 * s, W - 1, y1 - 1], fill=(0, 0, 0, 0))
    img.alpha_composite(layer.crop((x0, 512 * s, W, y1)), (x0, 512 * s))
    # Sward strips, tileable in u: every blade drawn again a width over.
    for (top, bottom, n, hr, dry, rough) in [(912, 968, 2600, (0.45, 1.0), 0.12, False), (968, 1024, 1500, (0.4, 1.0), 0.3, True)]:
        strip = Image.new("RGBA", (W, (bottom - top) * s), (0, 0, 0, 0))
        sd = ImageDraw.Draw(strip)
        sh = (bottom - top) * s - 2 * s
        base_y = (bottom - top) * s
        if not rough:   # clover and plantain at the foot of the mown sward
            for _ in range(700):
                x = r.uniform(0, W)
                for off in (-W, 0, W):
                    if r.random() < 0.5:
                        for k in range(3):
                            sd.ellipse([x + off + (k - 1) * 5 * s - 4 * s, base_y - 9 * s - 4 * s, x + off + (k - 1) * 5 * s + 4 * s, base_y - 9 * s + 3 * s],
                                       fill=(34, 74, 22, 255))
                    else:
                        _leaf(sd, x + off, base_y, 22 * s, 8 * s, -math.pi / 2 + r.uniform(-1.1, 1.1), np.array([0.14, 0.28, 0.08]))
        for _ in range(n):
            x = r.uniform(0, W)
            height = r.uniform(*hr) * sh
            lean = r.normal(0, 0.18) * height
            w_ = r.uniform(2, 4) * s
            dry_ = r.random() < dry
            seed = rough and r.random() < 0.12
            dry_tip = r.random() < 0.35
            for off in (-W, 0, W):
                tip = _blade(sd, x + off, base_y, height, lean, w_, DRY_BASE if dry_ else GREEN_BASE,
                             DRY_TIP if dry_ else GREEN_TIP, rng(int(x * 10) % 100000), steps=6, dry_tip=dry_tip and not dry_)
                if seed:
                    sd.ellipse([tip[0] - 3 * s, tip[1] - 2 * s, tip[0] + 3 * s, tip[1] + 8 * s], fill=(190, 176, 124, 255))
        img.alpha_composite(strip, (0, top * s))
    img = img.resize((size, size), Image.LANCZOS)
    arr = np.asarray(img, np.float32) / 255
    rgb, a = arr[..., :3], arr[..., 3:]
    # Ragged, fading bases so tufts and fins melt into the ground. A strip's
    # foot also rises and falls along it in clumps, by up to half its height
    # every 3 to 16 cm of ribbon, so a ribbon's foot never reads as a ruled
    # line on the ground (its own noise, so the rest of the atlas stays as
    # it was).
    jag = value_noise(size, size, 8, 64, r)
    rr = rng(52)
    rag = (0.45 * value_noise(1, size, 1, 13, rr)[0] + 0.3 * value_noise(1, size, 1, 5, rr)[0]
           + 0.25 * value_noise(1, size, 1, 29, rr)[0])
    fade = np.ones((size, size), np.float32)
    for (top, bottom) in [(0, 512), (512, 896), (912, 968), (968, 1024)]:
        yy = (np.arange(top, bottom, dtype=np.float32) - top)[:, None] / (bottom - top)
        strip = bottom - top < 100
        span = 0.18 if strip else 0.06
        lift = (0.5 if bottom == 1024 else 0.35) * smoothstep(0.3, 0.8, rag)[None, :] if strip else 0.0
        fade[top:bottom] = smoothstep(0.0, 1.0, (1 - yy - 0.015 - jag[top:bottom] * span * 0.8 - lift) / span)
    # Nothing in the rows between regions (roots spill over a cell's foot).
    fade[508:516] = 0
    fade[892:912] = 0
    a = a * fade[..., None]
    blurred = blur(rgb * a, 4) / np.maximum(blur(a, 4), 1e-3)
    arr[..., :3] = rgb * a + blurred * (1 - a)
    arr[..., 3:] = a
    save_rgba(OUT / "cj_grass.png", arr)
    print("grass coverage per region", [round(float(a[t:b].mean()), 3) for t, b in [(0, 512), (512, 896), (912, 968), (968, 1024)]])


# ---------------------------------------------------------------- bark

def bake_bark(size: int = 512) -> None:
    """cj_bark_albedo.jpg + cj_bark_detail.png: 1 m round x 2 m up, deep
    vertical fissures with lichen."""
    r = rng(61)
    ridges = fbm(size, size, 5, 5, r, aspect=7.0)
    fiss = smoothstep(0.3, 0.65, ridges)
    plates = fbm(size, size, 24, 3, r, aspect=1.5)
    height = np.clip(fiss * 0.8 + plates * 0.2, 0, 1)
    base = np.array([0.25, 0.22, 0.185], np.float32)
    dark = np.array([0.085, 0.075, 0.065], np.float32)
    lichen = np.array([0.30, 0.32, 0.25], np.float32)
    col = dark + (base - dark) * height[..., None]
    lm = smoothstep(0.7, 0.85, fbm(size, size, 10, 4, r)) * height
    col = col + (lichen - col) * lm[..., None] * 0.45
    col = col * (0.9 + 0.2 * value_noise(size, size, 128, 128, r)[..., None])
    save_rgb(OUT / "cj_bark_albedo.jpg", col, 90)
    detail_png(OUT / "cj_bark_detail.png", height, 6.0, np.clip(0.9 - lm * 0.1, 0, 1))


# ---------------------------------------------------------------- buildings

def brick_field(w: int, h: int, bricks_x: int, courses: int, mortar_px: float, r) -> tuple:
    """Running-bond brick layout over a w x h tile. Returns (face, mortar,
    brick_id) where face is per-brick tone variation in [0, 1]."""
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    ch = h / courses
    course = np.floor(yy / ch).astype(int)
    bw = w / bricks_x
    shift = (course % 2) * bw / 2
    bx = np.floor(((xx + shift) % w) / bw).astype(int)
    lx = ((xx + shift) % w) - bx * bw
    ly = yy - course * ch
    m = np.minimum(np.minimum(lx, bw - lx), np.minimum(ly, ch - ly))
    mortar = 1 - smoothstep(mortar_px * 0.5, mortar_px, m)
    ids = course * bricks_x + bx
    tones = r.random(courses * bricks_x + 1).astype(np.float32)
    face = tones[ids]
    return face, mortar, ids, m


def bake_brick(size: int = 512) -> None:
    """cj_brick.rgbz, 1 m x 1 m running bond (5 bricks x 13 courses):
    R per-brick tone, G mortar mask, B height, for tinting per building in
    a shader (white paint, red-brown or buff brick). No material reads it
    yet (the walls use cj_facade.jpg), so it goes to UNUSED_OUT rather than
    the app bundle; move it to OUT when one does."""
    r = rng(71)
    face, mortar, _, m = brick_field(size, size, 5, 13, 4.5, r)
    grain = fbm(size, size, 64, 3, r)
    tone = np.clip(face * 0.6 + grain * 0.4, 0, 1)
    height = np.clip((1 - mortar) * (0.85 + 0.15 * grain), 0, 1)
    UNUSED_OUT.mkdir(parents=True, exist_ok=True)
    save_raw(UNUSED_OUT / "cj_brick.rgbz", np.stack([tone, mortar, height, np.ones_like(tone)], -1))


def draw_window(d: ImageDraw.ImageDraw, x0, y0, x1, y1, frame, r, px_per_m, curtains: bool) -> None:
    fw = max(int(0.06 * px_per_m), 3)
    d.rectangle([x0, y0, x1, y1], fill=frame)
    # Glass with a sky reflection gradient.
    gx0, gy0, gx1, gy1 = x0 + fw, y0 + fw, x1 - fw, y1 - fw
    for k in range(gy0, gy1):
        t = (k - gy0) / max(gy1 - gy0, 1)
        c = (int(70 - 40 * t), int(82 - 44 * t), int(96 - 46 * t))
        d.line([(gx0, k), (gx1, k)], fill=c)
    if curtains:
        cw = int((gx1 - gx0) * r.uniform(0.18, 0.3))
        cv = r.uniform(190, 235); cc = (int(cv), int(cv * 0.98), int(cv * 0.93))
        d.rectangle([gx0, gy0, gx0 + cw, gy1], fill=cc)
        d.rectangle([gx1 - cw, gy0, gx1, gy1], fill=cc)
    # Mullion and transom.
    mx = (gx0 + gx1) // 2
    d.rectangle([mx - fw // 2, gy0, mx + fw // 2, gy1], fill=frame)
    ty = gy0 + int((gy1 - gy0) * 0.3)
    d.rectangle([gx0, ty - fw // 3, gx1, ty + fw // 3], fill=frame)


def bake_facades(size: int = 2048) -> None:
    """cj_facade.jpg: 4 x 4 atlas of 3 m x 3 m facade bays (512 px each).
    Rows: white-painted brick, red-brown brick, cream render, dark brown
    brick. Columns: upper-storey window, ground-floor window (with plinth),
    front door bay, blank wall."""
    r = rng(81)
    cell = size // 4
    ppm = cell / 3.0
    atlas = Image.new("RGB", (size, size))
    walls = [
        dict(kind="painted", col=(0.86, 0.85, 0.81), mortar=(0.80, 0.79, 0.75), frame=(232, 232, 228)),
        dict(kind="brick", col=(0.47, 0.24, 0.16), mortar=(0.66, 0.63, 0.58), frame=(238, 238, 234)),
        dict(kind="render", col=(0.84, 0.78, 0.64), mortar=(0.84, 0.78, 0.64), frame=(70, 72, 74)),
        dict(kind="brick", col=(0.33, 0.21, 0.15), mortar=(0.55, 0.52, 0.48), frame=(60, 62, 64)),
    ]
    for row, wall in enumerate(walls):
        rr = rng(90 + row)
        face, mortar, _, _ = brick_field(cell, cell, int(3 / 0.2), int(3 / 0.077), 3.0, rr)
        grain = fbm(cell, cell, 32, 4, rr)
        col = np.array(wall["col"], np.float32)
        mcol = np.array(wall["mortar"], np.float32)
        if wall["kind"] == "brick":
            tone = 0.82 + 0.3 * face[..., None] + 0.12 * (grain[..., None] - 0.5)
            base = col * tone
            base = base * (1 - mortar[..., None]) + mcol * mortar[..., None]
        elif wall["kind"] == "painted":
            relief = 1 - 0.07 * mortar[..., None] + 0.03 * (grain[..., None] - 0.5)
            base = col * relief
        else:
            base = col * (0.96 + 0.08 * (grain[..., None] - 0.5))
        # Weathering streaks.
        streak = fbm(cell, cell, 4, 3, rr, aspect=6.0)
        base = base * (0.94 + 0.08 * streak[..., None])
        tile = (np.clip(base, 0, 1) * 255).astype(np.uint8)
        for colm in range(4):
            img = Image.fromarray(tile.copy(), "RGB")
            d = ImageDraw.Draw(img)
            ground = colm in (1, 2)
            if ground:
                # Plinth: dark painted or stone band at the foot of the wall.
                py = int(cell - 0.38 * ppm)
                pc = (58, 58, 60) if wall["kind"] == "painted" else (92, 88, 82)
                d.rectangle([0, py, cell, cell], fill=pc)
            if colm in (0, 1):
                ww, wh = 1.15 * ppm, 1.4 * ppm
                x0 = int(cell / 2 - ww / 2); x1 = int(cell / 2 + ww / 2)
                sill = 0.95 if colm == 1 else 0.9
                y1 = int(cell - sill * ppm); y0 = int(y1 - wh)
                if wall["kind"] == "brick":
                    d.rectangle([x0 - 6, y0 - int(0.16 * ppm), x1 + 6, y0], fill=(100, 52, 34) if row == 1 else (70, 45, 32))
                draw_window(d, x0, y0, x1, y1, wall["frame"], r, ppm, curtains=r.random() < 0.6)
                d.rectangle([x0 - 8, y1, x1 + 8, y1 + int(0.07 * ppm)], fill=(170, 168, 160))
            elif colm == 2:
                dw, dh = 1.0 * ppm, 2.15 * ppm
                x0 = int(cell * 0.38 - dw / 2); x1 = int(cell * 0.38 + dw / 2)
                y1 = int(cell - 0.12 * ppm); y0 = int(y1 - dh)
                door_cols = [(44, 66, 52), (88, 56, 36), (230, 230, 226), (60, 62, 66)]
                dc = door_cols[row % len(door_cols)]
                d.rectangle([x0 - 5, y0 - 5, x1 + 5, y1], fill=wall["frame"])
                d.rectangle([x0, y0, x1, y1], fill=dc)
                # Panels and a glazed top.
                pw = int(0.08 * ppm)
                d.rectangle([x0 + pw, y0 + pw, x1 - pw, y0 + int(0.6 * ppm)], fill=(64, 74, 86))
                d.rectangle([x0 + pw, y0 + int(0.8 * ppm), x1 - pw, y1 - pw],
                            outline=tuple(max(0, c - 22) for c in dc), width=4)
                d.ellipse([x1 - int(0.16 * ppm), y0 + int(1.1 * ppm), x1 - int(0.1 * ppm), y0 + int(1.16 * ppm)], fill=(190, 180, 120))
                # Step.
                d.rectangle([x0 - 14, y1, x1 + 14, cell], fill=(150, 148, 142))
                # Small window beside the door.
                sx0 = int(cell * 0.68); sx1 = int(cell * 0.68 + 0.7 * ppm)
                sy1 = int(cell - 0.95 * ppm); sy0 = int(sy1 - 1.2 * ppm)
                draw_window(d, sx0, sy0, sx1, sy1, wall["frame"], r, ppm, curtains=True)
            atlas.paste(img, (colm * cell, row * cell))
    atlas.save(OUT / "cj_facade.jpg", quality=88, optimize=True)


# ---------------------------------------------------------------- impostors

# Distant-tree cells, in the order of TreeArchetype.Form.impostorCell:
# crown top and bottom (share of the cell from its top), half width, lobes,
# lobe radius, clump radius (shares of the cell), leaf sprite, share of
# clumps left out (gaps), trunk half width. The trunk base is at the bottom
# centre of each cell.
IMPOSTOR_FORMS = [
    ("beech",        0.03, 0.72, 0.46, 9,  (0.13, 0.17), (0.05, 0.07),   "broad",  0.05, 0.030),
    ("oak",          0.05, 0.68, 0.47, 11, (0.10, 0.14), (0.045, 0.065), "broad",  0.16, 0.032),
    ("ash",          0.03, 0.64, 0.42, 9,  (0.09, 0.13), (0.04, 0.06),   "broad",  0.30, 0.026),
    ("hybridPoplar", 0.02, 0.62, 0.34, 8,  (0.08, 0.12), (0.04, 0.06),   "poplar", 0.25, 0.026),
    ("lombardy",     0.01, 0.95, 0.13, 0,  (0, 0),       (0.03, 0.045),  "poplar", 0.0,  0.022),
    ("willow",       0.10, 0.66, 0.45, 0,  (0, 0),       (0.035, 0.05),  "broad",  0.0,  0.045),
    ("conifer",      0.11, 0.97, 0.30, 0,  (0, 0),       (0.06, 0.09),   "needle", 0.0,  0.030),
    ("orchard",      0.28, 0.74, 0.46, 6,  (0.12, 0.16), (0.05, 0.07),   "broad",  0.10, 0.040),
]


def bake_impostors(cell: int = 256) -> None:
    """cj_impostor.png + cj_impostor_detail.rgbz: 4 x 2 atlas of distant-tree
    sprites (TreeArchetype.Form.impostorCell order: beech, oak, ash and
    sycamore, hybrid poplar, Lombardy poplar, pollard willow, conifer,
    orchard), trunk base at the bottom centre of each cell. The colour is
    the leaves' own (the shader lights it); the detail map holds the
    crown's normal (R, G = x right, y down; a blend of the crown, its lobe
    and each leaf clump as spheres) and its ambient occlusion (B), so a
    distant tree has a sunlit side and a shaded one."""
    cols, rows = 4, 2
    W, H = cols * cell, rows * cell
    rgb_all = np.zeros((H, W, 3), np.float32)
    a_all = np.zeros((H, W), np.float32)
    nrm_all = np.zeros((H, W, 3), np.float32)
    ao_all = np.ones((H, W), np.float32)
    r = rng(111)
    sprites = {k: foliage_card(128, k, 200 + i) for i, k in enumerate(["broad", "poplar", "needle"])}
    yy, xx = np.mgrid[0:cell, 0:cell].astype(np.float32)
    cx = cell / 2
    for k, (name, top, bottom, hw, n_lobes, lobe_r, clump_r, kind, gaps, trunk_w) in enumerate(IMPOSTOR_FORMS):
        oy, ox = (k // cols) * cell, (k % cols) * cell
        rgb = np.zeros((cell, cell, 3), np.float32)
        a = np.zeros((cell, cell), np.float32)
        nrm = np.zeros((cell, cell, 3), np.float32)
        nrm[..., 2] = 1
        ao = np.ones((cell, cell), np.float32)
        # Trunk: a cylinder up into the crown.
        tw = trunk_w * cell
        t_top = (top + bottom) / 2 if name not in ("willow", "lombardy") else (bottom if name == "willow" else 0.5)
        tm = (np.abs(xx - cx) < tw) & (yy > t_top * cell)
        tx = np.clip((xx - cx) / tw, -1, 1)
        rgb[tm] = [0.22, 0.19, 0.16]
        a[tm] = 1
        nrm[tm] = np.stack([tx, np.zeros_like(tx), np.sqrt(np.clip(1 - tx * tx, 0, 1))], -1)[tm]
        ao[tm] = 0.7
        ccy = (top + bottom) / 2 * cell
        crx, cry = hw * cell, (bottom - top) / 2 * cell
        # Lobes (or, for the column, willow and conifer, a stack of them).
        lobes = []
        if n_lobes:
            tries = 0
            while len(lobes) < n_lobes and tries < 400:
                tries += 1
                lr = r.uniform(*lobe_r) * cell
                ang = r.uniform(0, 2 * math.pi)
                rad = math.sqrt(r.uniform(0.15, 1))
                lx = cx + math.cos(ang) * rad * max(crx - lr, 1)
                ly = ccy + math.sin(ang) * rad * max(cry - lr, 1)
                if any(math.hypot(lx - p[0], ly - p[1]) < 0.6 * (lr + p[2]) for p in lobes):
                    continue
                lz = r.uniform(-1, 1) * math.sqrt(max(1 - rad * rad, 0)) * min(crx, cry) * 0.6
                lobes.append((lx, ly, lr, lz))
            lobes.append((cx, ccy + 0.1 * cry, 0.6 * min(crx, cry), -0.3 * min(crx, cry)))   # the core
        elif name == "lombardy":
            for i in range(26):
                t = (i + 0.5) / 26
                w = hw * cell * math.sin(math.pi * min(t * 1.05 + 0.04, 1)) ** 0.6 * (1 - 0.25 * (1 - t))
                lobes.append((cx + r.uniform(-0.2, 0.2) * w, (bottom - (bottom - top) * t) * cell, max(w, 3), r.uniform(-1, 1) * w * 0.5))
        elif name == "willow":
            # Whips fanning up and out from the knot (the crown's bottom).
            for i in range(16):
                ang = -math.pi / 2 + r.uniform(-1.3, 1.3)
                d = r.uniform(0.3, 1.0)
                lobes.append((cx + math.cos(ang) * d * crx * 0.85, bottom * cell + math.sin(ang) * d * cry * 1.6,
                              0.11 * cell, r.uniform(-1, 1) * 10))
        else:  # conifer: tiers narrowing to the top
            for i in range(14):
                t = (i + 0.5) / 14
                w = (hw * t + 0.02) * cell
                lobes.append((cx, (top + (bottom - top) * t) * cell, max(w, 4), 0.0))
        stamps = []
        for (lx, ly, lr, lz) in lobes:
            n = int(2.4 * (lr / (np.mean(clump_r) * cell)) ** 2) + 3
            for _ in range(n):
                if r.random() < gaps:
                    continue
                ang = r.uniform(0, 2 * math.pi)
                rho = math.sqrt(r.uniform(0, 1))
                px = lx + math.cos(ang) * rho * lr
                py = ly + math.sin(ang) * rho * lr
                if name == "conifer":
                    py += r.uniform(-0.6, 0.6) * cell * 0.03
                lsz = math.sqrt(max(1 - rho * rho, 0))
                stamps.append((lz + lsz * lr, px, py, r.uniform(*clump_r) * cell, lx, ly, lr, lsz))
        stamps.sort()                                   # back to front
        for (_, px, py, br, lx, ly, lr, lsz) in stamps:
            sz = max(int(br * 2), 6)
            spr = np.asarray(Image.fromarray(to_u8(sprites[kind])).resize((sz, sz), Image.LANCZOS), np.float32) / 255
            if r.random() < 0.5:
                spr = spr[:, ::-1]
            y0, x0 = int(py - sz / 2), int(px - sz / 2)
            sy_, sx_ = np.mgrid[0:sz, 0:sz].astype(np.float32) + 0.5
            sx = (sx_ - sz / 2) / (sz / 2); sy = (sy_ - sz / 2) / (sz / 2)
            s_z = np.sqrt(np.clip(1 - sx * sx - sy * sy, 0, 1))
            gx, gy = (x0 + sx_ - cx) / crx, (y0 + sy_ - ccy) / max(cry, 1)
            g_z = np.sqrt(np.clip(1 - gx * gx - gy * gy, 0.05, 1))
            lx_, ly_ = (x0 + sx_ - lx) / lr, (y0 + sy_ - ly) / lr
            l_z = np.sqrt(np.clip(1 - lx_ * lx_ - ly_ * ly_, 0.05, 1))
            n = (0.35 * np.stack([gx, gy, g_z], -1) + 0.35 * np.stack([lx_, ly_, l_z], -1)
                 + 0.3 * np.stack([sx, sy, s_z], -1))
            n /= np.linalg.norm(n, axis=-1, keepdims=True)
            occ = (0.6 + 0.4 * s_z) * (0.72 + 0.28 * lsz) * (0.88 + 0.12 * (1 - (py - top * cell) / max(cry * 2, 1)))
            sa = spr[..., 3] * (spr[..., 3] > 0.35)
            stamp(rgb, a, spr[..., :3], sa, y0, x0)
            stamp(nrm, np.zeros_like(a), n, sa, y0, x0)
            stamp_gray(ao, occ, sa, y0, x0)
        a = np.where(a > 0.5, 1.0, 0.0).astype(np.float32)
        rgb_all[oy:oy + cell, ox:ox + cell] = rgb
        a_all[oy:oy + cell, ox:ox + cell] = a
        nrm_all[oy:oy + cell, ox:ox + cell] = nrm
        ao_all[oy:oy + cell, ox:ox + cell] = ao
    # Bleed colour and normals into transparent texels so mips stay clean.
    am = a_all[..., None]
    rgb_all = rgb_all * am + (blur(rgb_all * am, 6) / np.maximum(blur(am, 6), 1e-3)) * (1 - am)
    nrm_b = blur(nrm_all * am, 6) / np.maximum(blur(am, 6), 1e-3)
    nrm_all = nrm_all * am + nrm_b * (1 - am)
    ao_b = blur(ao_all[..., None] * am, 6)[..., 0] / np.maximum(blur(am, 6)[..., 0], 1e-3)
    ao_all = ao_all * a_all + ao_b * (1 - a_all)
    save_rgba(OUT / "cj_impostor.png", np.concatenate([rgb_all, am], -1))
    nl = nrm_all / np.maximum(np.linalg.norm(nrm_all, axis=-1, keepdims=True), 1e-6)
    detail = np.stack([nl[..., 0] * 0.5 + 0.5, nl[..., 1] * 0.5 + 0.5, np.clip(ao_all, 0, 1), np.ones_like(ao_all)], -1)
    save_raw(OUT / "cj_impostor_detail.rgbz", detail)
    print("impostor cells", [f[0] for f in IMPOSTOR_FORMS], "coverage", np.round([a_all[(k // cols) * cell:(k // cols + 1) * cell, (k % cols) * cell:(k % cols + 1) * cell].mean() for k in range(8)], 2))


def stamp_gray(canvas: np.ndarray, value: np.ndarray, sprite_a: np.ndarray, y: int, x: int) -> None:
    """Alpha-composites a single-channel sprite onto canvas at top-left (y, x)."""
    sh, sw = sprite_a.shape
    H, W = canvas.shape
    y0, x0, y1, x1 = max(y, 0), max(x, 0), min(y + sh, H), min(x + sw, W)
    if y1 <= y0 or x1 <= x0:
        return
    a = sprite_a[y0 - y:y1 - y, x0 - x:x1 - x]
    canvas[y0:y1, x0:x1] = canvas[y0:y1, x0:x1] * (1 - a) + value[y0 - y:y1 - y, x0 - x:x1 - x] * a


# ---------------------------------------------------------------- far fields

def bake_far_fields(size: int = 1024) -> None:
    """cj_farfields.jpg: a 2.56 km patchwork of Flemish fields (2.5 m/px)
    for the far terrain beyond the course's own aerial photo: pasture, maize,
    stubble, ploughed land, hedgerows and copses."""
    r = rng(121)
    warp_x = (fbm(size, size, 6, 3, r) - 0.5) * 60
    warp_y = (fbm(size, size, 6, 3, r) - 0.5) * 60
    f1, f2, ids = voronoi(size, size, 230, r)
    # Re-sample ids through the warp for irregular parcels.
    yy, xx = np.mgrid[0:size, 0:size]
    wy = ((yy + warp_y).astype(int)) % size
    wx = ((xx + warp_x).astype(int)) % size
    ids = ids[wy, wx]
    edge = (f2 - f1)[wy, wx]
    crops = np.array([
        [0.33, 0.43, 0.19], [0.30, 0.41, 0.17], [0.36, 0.45, 0.21],   # pasture
        [0.24, 0.34, 0.13],                                             # maize
        [0.62, 0.55, 0.35], [0.66, 0.60, 0.40],                         # stubble
        [0.44, 0.36, 0.27],                                             # ploughed
        [0.52, 0.52, 0.29],                                             # hay
    ], np.float32)
    p = np.array([0.18, 0.16, 0.14, 0.16, 0.1, 0.08, 0.08, 0.1])
    choice = r.choice(len(crops), ids.max() + 1, p=p / p.sum())
    col = crops[choice][ids] * (0.92 + 0.16 * fbm(size, size, 64, 3, r)[..., None])
    stripes = 0.96 + 0.04 * np.sin((xx * r.uniform(0.3, 1) + yy) * 0.8)[..., None]
    col = col * stripes
    hedge = 1 - smoothstep(0.8, 2.2, edge)
    hedge_on = r.random(ids.max() + 1) < 0.55
    hedge = hedge * hedge_on[ids]
    col = col + (np.array([0.13, 0.20, 0.08]) - col) * hedge[..., None] * 0.85
    wood = smoothstep(0.66, 0.72, fbm(size, size, 5, 5, r))
    col = col + (np.array([0.12, 0.19, 0.08]) * (0.8 + 0.4 * fbm(size, size, 96, 2, r)[..., None]) - col) * wood[..., None]
    save_rgb(OUT / "cj_farfields.jpg", np.clip(col, 0, 1), 88)


# ---------------------------------------------------------------- sky

def cube_dirs(face: int, n: int) -> np.ndarray:
    """Unit directions for an n x n face in SceneKit's cube order
    (+x, -x, +y, -y, +z, -z), standard cube-map orientation."""
    v, u = np.mgrid[0:n, 0:n].astype(np.float32)
    u = (u + 0.5) / n * 2 - 1
    v = (v + 0.5) / n * 2 - 1
    one = np.ones_like(u)
    d = [
        (one, -v, -u), (-one, -v, u),
        (u, one, v), (u, -one, -v),
        (u, -v, one), (-u, -v, -one),
    ][face]
    d = np.stack(d, -1)
    return d / np.linalg.norm(d, axis=-1, keepdims=True)


# Preetham, Shirley & Smits (1999), "A Practical Analytic Model for
# Daylight": Perez distribution coefficients for Y, x and y, linear in the
# turbidity T, and the zenith values.
def _perez_coeffs(T: float) -> dict:
    return {
        "Y": (0.1787 * T - 1.4630, -0.3554 * T + 0.4275, -0.0227 * T + 5.3251, 0.1206 * T - 2.5771, -0.0670 * T + 0.3703),
        "x": (-0.0193 * T - 0.2592, -0.0665 * T + 0.0008, -0.0004 * T + 0.2125, -0.0641 * T - 0.8989, -0.0033 * T + 0.0452),
        "y": (-0.0167 * T - 0.2608, -0.0950 * T + 0.0092, -0.0079 * T + 0.2102, -0.0441 * T - 1.6537, -0.0109 * T + 0.0529),
    }


def _perez(theta, gamma, c):
    A, B, C, D, E = c
    return (1 + A * np.exp(B / np.maximum(np.cos(theta), 0.02))) * (1 + C * np.exp(D * gamma) + E * np.cos(gamma) ** 2)


def sun_vector() -> np.ndarray:
    az, el = math.radians(SUN_AZIMUTH_DEG), math.radians(SUN_ELEVATION_DEG)
    return np.array([math.sin(az) * math.cos(el), math.sin(el), -math.cos(az) * math.cos(el)], np.float32)


@dataclass(frozen=True, eq=False)
class SkyStyle:
    """One region's sky, under the same sun (WorldSun). Every sky function
    takes the style it draws, so nothing hangs on a module global (the
    turbidity used to be frozen into default arguments).

    `blue`, `haze` and `aureole` are sRGB: deep-sky blue at one air mass,
    the near-white of a long, hazy path, and the warmer white of forward
    scattering round the sun. The haze takes over from the blue with air
    mass m as 1 - exp(-air_mass_k (m - 1)). The zenith opposite the sun
    is `zenith_linear` bright; `low_gain` is the aerosol brightening of
    the low sky the Preetham fit leaves out (at the horizon, falling off
    over `low_scale` of the sine of elevation), `cyan` a photo's extra
    green above 15 degrees. Clouds are
    fair-weather cumulus on a 1.6 km layer, `cloud_on` the density band
    their edges fade over; with `cloud_inland_km` they only stand that far
    north and beyond (over the hills inland of a coast). `fog`, when set,
    is the sRGB colour below the horizon, which the far land and sea fade
    to: darker than the sky's haze band just above it, as a sea horizon is.
    `ground` is what the lighting environment sees below the horizon.

    SceneKit looks its cube maps up with z the other way round from
    `cube_dirs` (seen in the app: the Riviera's inland clouds, baked to the
    north, stood to the south until the faces were mirrored; the Flemish
    sky's sun disc and clouds stand mirrored north-south too, and are left
    as they were calibrated). A style with `mirror_z` bakes its faces so
    each direction holds the sky SceneKit shows there."""
    suffix: str
    turbidity: float
    blue: np.ndarray
    haze: np.ndarray
    aureole: np.ndarray
    zenith_linear: float = 0.3
    air_mass_k: float = 0.34
    low_gain: float = 0.45
    low_scale: float = 0.12
    cyan: float = 0.05
    cloud_on: tuple = (0.575, 0.665)
    cloud_inland_km: tuple | None = None
    fog: np.ndarray | None = None
    ground: str = "fields"
    mirror_z: bool = False


# Clear but hazy late-summer air over Flanders, scattered fair-weather
# cumulus: cj_sky_* as they have always been.
FLANDERS = SkyStyle(
    suffix="", turbidity=3.4,
    blue=np.array([0.37, 0.55, 0.82], np.float32),
    haze=np.array([0.80, 0.845, 0.90], np.float32),
    aureole=np.array([1.0, 0.965, 0.9], np.float32),
)

# A clear March afternoon on the Ligurian coast (look.md section 2): dry,
# clean air (turbidity 2.9 against 3.4) and a deep blue overhead (paint
# #5f97d8 opposite the sun), whitening with air mass faster than over
# Flanders to a pale, bluer horizon (#bccfe3) and a haze band over the sea
# (#c8d6e4), with a few small cumulus over the Alpi Liguri inland and a
# clean sky over the sea. Below the horizon the far coast and the sea's
# horizon line fade to #9fb3c8-#9db5cc (Commons P1010130 and P1010170, 30
# Mar 2008). The lighting environment keeps the calibrated ambient: 0.452
# against ENV_IRRADIANCE.
RIVIERA = SkyStyle(
    suffix="_lig", turbidity=2.9,
    blue=np.array([0.35, 0.56, 0.83], np.float32),
    haze=np.array([0.74, 0.82, 0.885], np.float32),
    aureole=np.array([1.0, 0.97, 0.92], np.float32),
    zenith_linear=0.33, air_mass_k=0.6, low_gain=0.08, low_scale=0.25, cyan=0.03,
    cloud_on=(0.59, 0.67), cloud_inland_km=(4.0, 9.0),
    fog=np.array([0.625, 0.71, 0.795], np.float32),
    ground="riviera", mirror_z=True,
)


def preetham_luminance(d: np.ndarray, T: float) -> np.ndarray:
    """Relative sky luminance Y(d) / Y(zenith) from the Preetham model at
    turbidity T: bright around the sun and towards the horizon, darkest
    about 90 degrees from the sun. Directions below the horizon get the
    horizon's value."""
    sun = sun_vector()
    ts = math.acos(float(sun[1]))
    theta = np.arccos(np.clip(d[..., 1], 0.02, 1.0))
    gamma = np.arccos(np.clip((d * sun).sum(-1), -1, 1))
    c = _perez_coeffs(T)["Y"]
    return _perez(theta, gamma, c) / _perez(0.0, ts, c)


def sky_chroma(d: np.ndarray, style: SkyStyle) -> np.ndarray:
    """Colour of the clear sky for directions d, unit luminance: Rayleigh
    blue overhead, washing out to haze with optical air mass (Kasten-Young)
    and near the sun (Mie forward scattering). The Preetham chromaticities
    turn pink at the horizon at this turbidity, which reads wrong."""
    sun = sun_vector()
    up = np.clip(d[..., 1], 0.0, 1.0)
    zen = np.degrees(np.arccos(up))
    m = 1 / (np.cos(np.radians(zen)) + 0.50572 * np.maximum(96.07995 - zen, 0.5) ** -1.6364)
    h = 1 - np.exp(-style.air_mass_k * (m - 1))
    cosg = np.clip((d * sun).sum(-1), 0, 1)
    h = 1 - (1 - h) * (1 - 0.6 * cosg ** 6)
    w = np.array([0.2126, 0.7152, 0.0722], np.float32)
    # Mixed at equal luminance, so `h` is the share of the colour.
    blue, haze, aur = (c / float(c @ w) for c in (srgb_to_linear(x) for x in (style.blue, style.haze, style.aureole)))
    white = haze + (aur - haze) * (cosg ** 10)[..., None]
    col = blue + (white - blue) * h[..., None]
    return col / (col @ w)[..., None]


def preetham_rgb(d: np.ndarray, style: SkyStyle) -> np.ndarray:
    """Linear sRGB clear-sky radiance for unit directions d (..., 3): the
    Preetham luminance distribution in the `sky_chroma` colours, scaled so
    the zenith reads the style's `zenith_linear`, with the circumsolar
    glare rolled off softly before it clips."""
    Y = preetham_luminance(d, style.turbidity) * style.zenith_linear
    knee = 0.6
    Y = np.where(Y > knee, knee + (Y - knee) / (1 + (Y - knee) / 0.55), Y)
    return sky_chroma(d, style) * Y[..., None]


# Stored sky = linear radiance / scale, in sRGB encoding. The background's
# scale lets sunlit cloud tops brighter than 1 fit in 8 bits; the lighting
# environment stays at 1, where the ambient was calibrated (the
# `litchart` in WorldDebugShots). Keep SkyLighting.skyScale in step.
SKY_SCALE = 1.6
SKY_ENV_SCALE = 1.0
# The lighting environment sees the clouds from below, by their shaded
# bases more than their sunlit sides; at 0.7 of the background's cloud light
# the ambient stays where it was calibrated (ENV_IRRADIANCE).
ENV_CLOUD_GAIN = 0.7
# Up-facing irradiance / pi (luminance) of the calibrated environment: the
# 0.18 board in `litchart` reads 3.9 : 1 sunlit to shaded. bake_sky prints
# the baked value; keep it within a few per cent.
ENV_IRRADIANCE = 0.454
CLOUD_KM = 1.6        # height of the cumulus layer
CLOUD_TILE_KM = 9.0   # one tile of the cloud fields on that layer


def low_sky_gain(up: np.ndarray, style: SkyStyle) -> np.ndarray:
    """Aerosol brightening of the low sky that the Preetham fit leaves out:
    for Flanders +45 % at the horizon, +11 % at 10 degrees."""
    return 1 + style.low_gain * np.exp(-np.maximum(up, 0) / style.low_scale)


def clear_sky(d: np.ndarray, style: SkyStyle, background: bool = True) -> np.ndarray:
    """Linear clear-sky radiance (`preetham_rgb`). For the background, as a
    photo shows it: brighter and whiter low down, and a touch more cyan
    above 15 degrees (photo G/B 0.80 against 0.73). The lighting
    environment keeps the plain model it was calibrated with."""
    sky = preetham_rgb(d, style)
    if background:
        up = d[..., 1]
        sky = sky * low_sky_gain(up, style)[..., None]
        sky = sky * (1 + np.array([0.0, style.cyan, 0.0], np.float32) * smoothstep(0.25, 0.6, up)[..., None])
    return sky


def horizon_haze(style: SkyStyle, background: bool = True) -> np.ndarray:
    """Mean linear sky colour just above the horizon, all round: the colour
    the lowest few degrees of sky settle on, and (without `style.fog`) the
    fog colour the far terrain fades to. Keep SkyLighting's horizonLinear
    in step (bake_sky writes the fog colour to cj_sky_horizon*.json;
    SkyBakeTests checks it)."""
    az = np.linspace(0, 2 * math.pi, 256, endpoint=False)
    el = math.radians(1.0)
    d = np.stack([np.sin(az) * math.cos(el), np.full_like(az, math.sin(el)), -np.cos(az) * math.cos(el)], -1)
    return clear_sky(d.astype(np.float32), style, background).mean(0)


def fog_colour(style: SkyStyle) -> np.ndarray:
    """Linear colour below the horizon and of the fog: the all-round haze,
    or the style's own."""
    return horizon_haze(style) if style.fog is None else srgb_to_linear(style.fog)


def cloud_fields(r: np.random.Generator) -> tuple:
    """The cloud density fields, 1024 px per tile: two octaves of cloud
    and a finer field that erodes their rims (drawn last, so the first two
    keep the sequence they have always had)."""
    cn = fbm(1024, 1024, 5, 6, r, gain=0.52)
    cn2 = fbm(1024, 1024, 14, 4, r)
    cn3 = fbm(1024, 1024, 48, 3, r)
    return cn, cn2, cn3


def sample_wrap(tex: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Bilinear lookup in a wrapping square field, (u, v) in tiles. A nearest
    lookup would alias the crisp cloud rims."""
    n = tex.shape[0]
    x = (u % 1) * n
    y = (v % 1) * n
    x0 = np.floor(x).astype(int)
    y0 = np.floor(y).astype(int)
    fx = x - x0
    fy = y - y0
    x0 %= n
    y0 %= n
    x1 = (x0 + 1) % n
    y1 = (y0 + 1) % n
    return (tex[y0, x0] * (1 - fx) + tex[y0, x1] * fx) * (1 - fy) + (tex[y1, x0] * (1 - fx) + tex[y1, x1] * fx) * fy


def cloud_density(f: tuple, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Fair-weather cumulus density: the two-octave field with its rims
    eroded by the finer one (cauliflower edges, solid cores)."""
    cn, cn2, cn3 = f
    base = sample_wrap(cn, u, v) * 0.8 + sample_wrap(cn2, u, v) * 0.2
    edge = 1 - np.abs(smoothstep(0.52, 0.72, base) * 2 - 1)
    return base + (sample_wrap(cn3, u, v) - 0.5) * 0.12 * edge


def cloud_layer(d: np.ndarray, f: tuple, style: SkyStyle) -> tuple:
    """Where directions d meet the cloud layer, in tiles (u, v), the density
    there and the cloud cover. The threshold rises near the horizon, where
    clouds are small on screen, so there are fewer specks; the rims are soft
    enough not to stair-step on a cube face magnified about 2.5 times. A
    style with `cloud_inland_km` keeps only the clouds that far north (the
    scene's -z) of the viewer and beyond, fading in over that range."""
    up = d[..., 1]
    tt = CLOUD_KM / np.maximum(up, 0.02)
    u = d[..., 0] * tt / CLOUD_TILE_KM
    v = d[..., 2] * tt / CLOUD_TILE_KM
    dens = cloud_density(f, u, v) - 0.035 * (1 - smoothstep(0.05, 0.25, up))
    lo, hi = style.cloud_on
    cover = smoothstep(lo, hi, dens)
    if style.cloud_inland_km is not None:
        cover = cover * smoothstep(*style.cloud_inland_km, -d[..., 2] * tt)
    return u, v, dens, cover


def cloud_cover(f: tuple, style: SkyStyle, lo_deg: float = 5, hi_deg: float = 35) -> float:
    """Share of the sky between lo_deg and hi_deg of elevation (by solid
    angle) under cloud: what a chase camera sees. Fair weather is 25-35 %."""
    az = (np.arange(1440, dtype=np.float32) + 0.5) / 1440 * 2 * math.pi
    s = np.linspace(math.sin(math.radians(lo_deg)), math.sin(math.radians(hi_deg)), 256, dtype=np.float32)
    az, s = np.meshgrid(az, s)
    c = np.sqrt(1 - s * s)
    d = np.stack([np.sin(az) * c, s, -np.cos(az) * c], -1)
    return float(cloud_layer(d, f, style)[3].mean())


def riviera_ground(d: np.ndarray, haze: np.ndarray) -> np.ndarray:
    """What the lighting environment sees below the horizon on the Poggio:
    the sea to the south, in a band below the horizon (a road 100-160 m up
    sees it down to about 20 degrees), and sunlit hillsides of dry grass,
    pale walls and greenhouses to the north, under pale asphalt and
    sun-baked banks close by."""
    up = d[..., 1]
    south = smoothstep(-0.2, 0.5, d[..., 2])[..., None]
    near = np.array([0.125, 0.118, 0.095], np.float32)
    hills = np.array([0.105, 0.11, 0.085], np.float32)
    sea = np.array([0.05, 0.085, 0.13], np.float32)
    far = hills + (sea - hills) * south
    t = smoothstep(0.0, 0.06, -up)[..., None]
    low = haze + (far - haze) * t
    return low + (near - low) * smoothstep(0.12, 0.45, -up)[..., None]


def sky_radiance(d: np.ndarray, style: SkyStyle, clouds: bool, ground: bool, cloud_tex=None,
                 background: bool = True, cloud_gain: float = 1.0, sun_disc: bool = True) -> np.ndarray:
    """Linear radiance of the style's sky for directions d (..., 3): the
    clear sky (`clear_sky`), crisp self-shadowed fair-weather cumulus on a
    1.6 km layer, sun disc and a haze band at the horizon. Seen from the
    sun's side a cloud shows its lit faces, sunlit tops brighter than 1;
    towards the sun, its shaded core with a bright rim. Below the horizon:
    the fog colour (for the background, so the fogged far terrain meets it
    without a seam) or, with `ground`, light bounced off the land (for the
    lighting environment). `cloud_gain` scales the clouds' own light;
    without `sun_disc` the sun and its aureole are left out."""
    sun = sun_vector()
    up = d[..., 1]
    cosg = np.clip((d * sun).sum(-1), -1, 1)
    haze = horizon_haze(style, background)
    sky = clear_sky(d, style, background)
    # The lowest few degrees settle on the all-round haze colour, all of
    # the way at the horizon itself, so the sky meets the haze below it
    # (and the fogged far terrain) without a line.
    band = 1 - smoothstep(0.0, 0.07, up)
    sky = sky + (haze - sky) * (band * (0.75 + 0.25 * band))[..., None]
    if clouds and cloud_tex is not None:
        u, v, dens, cover = cloud_layer(d, cloud_tex, style)
        # Light reaching the cloud: density marched towards the sun's
        # ground track over 0.15-0.9 km.
        sh = np.array([sun[0], sun[2]]) / math.hypot(sun[0], sun[2])
        tau = sum(np.maximum(cloud_density(cloud_tex, u + sh[0] * km / CLOUD_TILE_KM,
                                           v + sh[1] * km / CLOUD_TILE_KM) - 0.6, 0)
                  for km in (0.15, 0.35, 0.6, 0.9))
        lit = np.exp(-tau * 7.0 * (0.25 + 0.75 * smoothstep(-0.3, 0.9, cosg)))
        lum = float(preetham_rgb(np.array([[0, 1, 0]], np.float32), style).mean()) / style.zenith_linear
        sunlit = np.array([1.0, 0.97, 0.93], np.float32) * 1.25 * lum
        # Shaded sides and bases: a fair-weather grey, not a shower's.
        shade = np.array([0.56, 0.59, 0.66], np.float32) * 0.70 * lum
        silver = (np.clip(cosg, 0, 1) ** 8 * (1 - smoothstep(0.6, 0.75, dens)))[..., None] * 0.9
        cloud = shade + (sunlit - shade) * lit[..., None] + silver * sunlit
        # Thick cores show flatter, greyer bases overhead.
        core = smoothstep(0.66, 0.85, dens) * smoothstep(0.25, 0.8, up)
        cloud = cloud * (1 - 0.20 * core[..., None]) * cloud_gain
        # Distant clouds dissolve into the haze.
        cloud = cloud + (haze - cloud) * (1 - smoothstep(0.04, 0.35, up))[..., None] * 0.6
        a = (cover * smoothstep(0.02, 0.3, up) * 0.97)[..., None]
        sky = sky * (1 - a) + cloud * a
    # Sun disc and a tight aureole (the disc clips in 8-bit; the key light
    # carries the sun's energy).
    if sun_disc:
        disc = smoothstep(0.99985, 0.99995, cosg)[..., None]
        aureole = (np.clip(cosg, 0, 1) ** 400)[..., None] * 0.6
        sky = sky + (disc * 8 + aureole) * np.array([1.0, 0.95, 0.85], np.float32)
    below = up < 0
    if ground:
        # Light, not a picture: real skylight is whiter than a photo of the
        # deep blue overhead suggests (haze, clouds and the bright sky round
        # the sun all add to it), so the lighting environment is a little
        # less saturated than the background.
        lum = (sky @ np.array([0.2126, 0.7152, 0.0722], np.float32))[..., None]
        sky = lum + (sky - lum) * 0.45
        if style.ground == "riviera":
            low = riviera_ground(d, haze)
        else:
            # Fields and hedges in afternoon sun, darkening away from the horizon.
            g = np.array([0.105, 0.11, 0.075], np.float32)
            t = smoothstep(0.0, 0.18, -up)[..., None]
            low = haze + (g - haze) * t
        sky = np.where(below[..., None], low, sky)
    elif style.fog is not None:
        # A sea horizon: the far water and coast, at the fog colour, meet
        # the paler haze band in a soft line over the first half degree.
        fog = fog_colour(style)
        sky = fog + (sky - fog) * smoothstep(-0.002, 0.009, up)[..., None]
    else:
        sky = np.where(below[..., None], haze, sky)
    return sky


def up_irradiance(faces: list) -> float:
    """Irradiance / pi (luminance) on an up-facing surface from six cube
    faces of linear radiance (`cube_dirs` order)."""
    e = 0.0
    for k, face in enumerate(faces):
        n = face.shape[0]
        v, u = np.mgrid[0:n, 0:n].astype(np.float32)
        u = (u + 0.5) / n * 2 - 1
        v = (v + 0.5) / n * 2 - 1
        dw = (2 / n) ** 2 / (1 + u * u + v * v) ** 1.5
        cos_up = np.clip(cube_dirs(k, n)[..., 1], 0, None)
        e += float(((face @ np.array([0.2126, 0.7152, 0.0722], np.float32)) * cos_up * dw).sum())
    return e / math.pi


def bake_sky(n: int = 1024, env_n: int = 96, style: SkyStyle = FLANDERS) -> None:
    """cj_sky{suffix}_{px,nx,py,ny,pz,nz}.jpg: the background, the style's
    afternoon sky (Preetham daylight model) with fair-weather cumulus, sun
    in the south-west. Scene axes: x = east, y = up, z = south. Below the
    horizon the faces carry the fog colour so the fogged far terrain meets
    them without a seam. Stored as linear / SKY_SCALE, with a little dither
    and at JPEG quality 95 so the smooth blue doesn't band.

    cj_skyenv{suffix}_*.jpg: the same sky, small, without the background's
    photo look, and with a ground hemisphere of sunlit land (and, on the
    Riviera, the sea), for image-based lighting (shadows and undersides
    pick up bounce light instead of blue). Stored as linear / SKY_ENV_SCALE.

    The Swift side draws the background at SkyLighting.skyScale and fades
    the far terrain to the region's horizonLinear (WorldLook+Sky): the fog
    colour printed here and written to cj_sky_horizon{suffix}.json (beside
    this script, out of the app)."""
    r = rng(131)
    f = cloud_fields(r)
    f_env = tuple(blur(c, 6) for c in f)
    dither = rng(137)
    names = ["px", "nx", "py", "ny", "pz", "nz"]
    flip = np.array([1, 1, -1 if style.mirror_z else 1], np.float32)
    envs = []
    for k in range(6):
        d = cube_dirs(k, n) * flip
        sky = sky_radiance(d, style, clouds=True, ground=False, cloud_tex=f)
        save_rgb_dithered(OUT / f"cj_sky{style.suffix}_{names[k]}.jpg", np.clip(linear_to_srgb(sky / SKY_SCALE), 0, 1),
                          dither, 95)
        del d, sky
        de = cube_dirs(k, env_n) * flip
        env = np.clip(sky_radiance(de, style, clouds=True, ground=True, cloud_tex=f_env, background=False,
                                   cloud_gain=ENV_CLOUD_GAIN) / SKY_ENV_SCALE, 0, 1)
        save_rgb(OUT / f"cj_skyenv{style.suffix}_{names[k]}.jpg", linear_to_srgb(env), 90)
        envs.append(env * SKY_ENV_SCALE)
    haze = horizon_haze(style)
    fog = fog_colour(style)
    cover = cloud_cover(f, style)
    print("horizon haze, linear", np.round(haze, 4), "stored sRGB", np.round(linear_to_srgb(haze / SKY_SCALE), 4))
    if style.fog is not None:
        print("fog (below the horizon), linear", np.round(fog, 4))
    print(f"cloud cover 5-35 degrees: {cover * 100:.1f} %")
    print(f"lighting environment: up-facing irradiance {up_irradiance(envs):.3f} (calibrated {ENV_IRRADIANCE})")
    record = {"horizonLinear": [round(float(x), 4) for x in fog], "skyScale": SKY_SCALE,
              "cloudCover5to35Deg": round(cover, 3)}
    (Path(__file__).resolve().parent / f"cj_sky_horizon{style.suffix}.json").write_text(json.dumps(record, indent=2) + "\n")
    print("Keep the region's horizonLinear (WorldLook+Sky.swift) and SkyLighting.skyScale in step with "
          f"cj_sky_horizon{style.suffix}.json.")


def bake_sky_riviera() -> None:
    """The Riviera's sky (`RIVIERA`): cj_sky_lig_*, cj_skyenv_lig_*, the
    sea's reflection of it (`bake_sea_sky`) and its waves (`bake_sea_detail`)."""
    bake_sky(style=RIVIERA)
    bake_sea_sky()
    bake_sea_detail()


def bake_sea_sky(w: int = 1024, h: int = 256) -> None:
    """cj_sea_sky.jpg: the Riviera's sky above the horizon for the sea to
    reflect (WorldShaders+Sea), the background's radiance with its clouds
    softened and without the sun (the sea shader draws its glitter), stored
    as linear / SKY_SCALE like the background. Column u is the compass
    azimuth (north at u = 0, east at a quarter), row v is 1 - sin(elevation),
    so the low sky the sea mostly mirrors gets the most rows."""
    f = tuple(blur(c, 2) for c in cloud_fields(rng(131)))
    az = (np.arange(w, dtype=np.float32) + 0.5) / w * 2 * math.pi
    s = 1 - (np.arange(h, dtype=np.float32) + 0.5) / h
    az, s = np.meshgrid(az, s)
    c = np.sqrt(1 - s * s)
    d = np.stack([np.sin(az) * c, s, -np.cos(az) * c], -1).astype(np.float32)
    sky = sky_radiance(d, RIVIERA, clouds=True, ground=False, cloud_tex=f, sun_disc=False)
    save_rgb_dithered(OUT / "cj_sea_sky.jpg", np.clip(linear_to_srgb(sky / SKY_SCALE), 0, 1), rng(139), 92)


def preview_sky(path: Path, style: SkyStyle = FLANDERS, w: int = 1024, h: int = 384) -> None:
    """Equirectangular preview of the background sky from 10 degrees below
    the horizon to the zenith, north at the left edge, for checking the look
    without a build (linear / SKY_SCALE, as stored)."""
    f = cloud_fields(rng(131))
    az = (np.arange(w, dtype=np.float32) + 0.5) / w * 2 * math.pi
    el = np.radians(90 - (np.arange(h, dtype=np.float32) + 0.5) / h * 100)
    az, el = np.meshgrid(az, el)
    d = np.stack([np.sin(az) * np.cos(el), np.sin(el), -np.cos(az) * np.cos(el)], -1).astype(np.float32)
    sky = sky_radiance(d, style, clouds=True, ground=False, cloud_tex=f)
    save_rgb(path, np.clip(linear_to_srgb(sky / SKY_SCALE), 0, 1), 90)
    print(f"cloud cover 5-35 degrees: {cloud_cover(f, style) * 100:.1f} %")


# ---------------------------------------------------------------- sea

# Wind over the sea on the Riviera's spring afternoon: an onshore breeze
# from the south-west at about 4 m/s (Cox & Munk 1954 put the mean square
# slope of the sea at 0.003 + 0.00512 U, 0.023 at 4 m/s).
SEA_WIND_MS = 4.0
SEA_WIND_FROM_DEG = 225.0
SEA_TILE_M = 32.0


def bake_sea_detail(n: int = 512) -> None:
    """cj_sea_detail.rgbz, a SEA_TILE_M square of wind sea that tiles: R, G
    = the wave slopes along +u (east) and +v (south, down the image) as 0.5
    + slope, B = whitecap and wash foam where the waves break (0-1), A = the
    wave height, normalised (0 lowest). A Phillips spectrum (Tessendorf
    2001, "Simulating Ocean Water") for SEA_WIND_MS from SEA_WIND_FROM_DEG,
    the ripples under about 12 cm left out (two pixels), and its slopes
    scaled to a mean square of 0.012: the half of Cox & Munk's 0.023 that
    a map can hold; the sea shader adds the rest as roughness."""
    r = rng(151)
    g = 9.81
    L = SEA_WIND_MS ** 2 / g
    k1 = np.fft.fftfreq(n, SEA_TILE_M / n) * 2 * math.pi
    kx, kz = np.meshgrid(k1, k1)
    k = np.hypot(kx, kz)
    k[0, 0] = 1
    # Towards where the wind blows (scene x east, z south).
    a = math.radians(SEA_WIND_FROM_DEG + 180)
    wx, wz = math.sin(a), -math.cos(a)
    align = (kx * wx + kz * wz) / k
    spread = align ** 2 * 0.85 + 0.15
    cut = 2 * math.pi / (2 * SEA_TILE_M / n * 2)
    ph = np.exp(-1 / (k * L) ** 2) / k ** 4 * spread * np.exp(-(k / cut) ** 2)
    ph[0, 0] = 0
    amp = np.sqrt(ph / 2) * (r.standard_normal((n, n)) + 1j * r.standard_normal((n, n)))
    h = np.real(np.fft.ifft2(amp))
    sx = np.real(np.fft.ifft2(amp * 1j * kx))
    sz = np.real(np.fft.ifft2(amp * 1j * kz))
    scale = math.sqrt(0.012 / float((sx ** 2 + sz ** 2).mean()))
    sx *= scale
    sz *= scale
    h *= scale
    # Foam: breaking crests, where the sea is steepest and highest, in
    # streaks along the wind, and a fine froth for the wash at the rocks.
    steep = smoothstep(0.18, 0.4, np.hypot(sx, sz)) * smoothstep(0.3, 0.9, (h - h.min()) / np.ptp(h))
    froth = fbm(n, n, 32, 4, r)
    foam = np.clip(steep * 0.7 + smoothstep(0.45, 0.8, froth) * 0.6, 0, 1)
    hn = (h - h.min()) / np.ptp(h)
    rgba = np.stack([0.5 + sx, 0.5 + sz, foam, hn], -1)
    print(f"sea slopes: rms {math.sqrt(float((sx ** 2 + sz ** 2).mean())):.3f}, "
          f"clipped {float(((np.abs(sx) > 0.5) | (np.abs(sz) > 0.5)).mean()) * 100:.2f} %, "
          f"wave height rms {float(h.std()):.3f} m")
    save_raw(OUT / "cj_sea_detail.png", np.clip(rgba, 0, 1).astype(np.float32))


# ---------------------------------------------------------------- main

BAKERS = {
    "asphalt": bake_asphalt, "asphalt_fine": bake_asphalt_fine, "ground": bake_ground,
    "foliage": bake_foliage, "grass": bake_grass, "bark": bake_bark,
    "brick": bake_brick, "facades": bake_facades,
    "impostors": bake_impostors, "farfields": bake_far_fields, "sky": bake_sky,
    "sky_lig": bake_sky_riviera,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma-separated subset of " + ",".join(BAKERS))
    ap.add_argument("--preview-sky", default="", help="write an equirectangular sky preview here and exit")
    ap.add_argument("--sky-style", default="flanders", choices=["flanders", "riviera"],
                    help="the sky --preview-sky draws")
    args = ap.parse_args()
    if args.preview_sky:
        style = RIVIERA if args.sky_style == "riviera" else FLANDERS
        preview_sky(Path(args.preview_sky), style)
        print("horizon haze, linear", np.round(horizon_haze(style), 4), "fog, linear", np.round(fog_colour(style), 4))
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    names = [n for n in args.only.split(",") if n] or list(BAKERS)
    for n in names:
        t = time.time()
        BAKERS[n]()
        print(f"{n}: {time.time() - t:.1f} s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
