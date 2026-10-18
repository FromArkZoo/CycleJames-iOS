# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the generic material textures for the CycleJames 3D courses.

    uv run --script scripts/courses/textures/bake_materials.py [--only cobbles,sky,...]

Everything is procedural (no photos, no downloaded assets) and tiles
seamlessly. Output goes to CycleJames/Resources/CourseTextures/, which the
app bundle flattens, so every file name starts with `cj_`. The Swift side
(CycleJames/Courses/Scene/World/WorldMaterials.swift) relies on the names,
the real-world tile sizes and the channel layouts documented per texture.

Data textures ("*_detail.rgbz", see texlib.save_raw) pack: R, G = tangent-space normal x, y
(+x along u, +y along v = down the image), B = roughness, A = height
(0 = lowest, 1 = highest) unless noted.
"""
from __future__ import annotations

import argparse
import math
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from texlib import (blur, fbm, linear_to_srgb, normal_xy, rng, save_gray, save_raw, save_rgb, save_rgba,  # noqa: E402
                    smoothstep, srgb_to_linear, stamp, to_u8, value_noise, voronoi)

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


# ---------------------------------------------------------------- cobbles

def bake_cobbles(size: int = 1024) -> None:
    """cj_cobble_albedo.jpg + cj_cobble_detail.rgbz.

    One tile is 1.08 m across the road (u) by 1.08 m along it (v): seven
    rough courses of setts laid across the lane, eight setts per course,
    each about 13 cm across by 15 cm along travel but irregular: split
    stones with rounded, chipped outlines, domed tops worn to different
    heights, slightly turned, in courses that wander, with sandy grit in
    joints of uneven width. Mostly grey and blue-grey with some brown, ochre
    and reddish stones (the Koppenberg's porphyry); the app desaturates and
    cools them per course (CourseArt.SettLook) for the blue-grey setts of
    the Kwaremont and the Paterberg. Values are stored as sRGB.
    """
    r = rng(11)
    tile_m = 1.08
    ppm = size / tile_m
    n_rows, n_cols = 7, 8
    ys = np.arange(size, dtype=np.float32)[:, None]
    xs = np.arange(size, dtype=np.float32)

    def partition(total: float, n: int, jitter: float) -> np.ndarray:
        w = 1 + r.uniform(-jitter, jitter, n)
        w = w / w.sum() * total
        return np.concatenate([[0], np.cumsum(w)])

    # Course boundaries wander across the road (periodic in u, so the
    # tile still wraps); the last wraps onto the first.
    row_edges = partition(size, n_rows, 0.16)
    bounds = []
    for k in range(n_rows):
        k1, k2 = int(r.integers(1, 3)), int(r.integers(3, 7))
        wob = (np.sin(2 * math.pi * k1 * xs / size + r.uniform(0, 6.28)) * r.uniform(0.004, 0.009)
               + np.sin(2 * math.pi * k2 * xs / size + r.uniform(0, 6.28)) * r.uniform(0.001, 0.004)) * ppm
        bounds.append(row_edges[k] + wob)
    bounds.append(bounds[0] + size)
    B = np.stack(bounds).astype(np.float32)               # (rows + 1, size)
    Y = (ys - B[0][None, :]) % size + B[0][None, :]       # row 0 starts at its own boundary
    row = np.zeros((size, size), np.int32)
    for k in range(1, n_rows):
        row += (Y >= B[k][None, :]).astype(np.int32)

    # Mostly grey and blue-grey, some brown, ochre and reddish (sRGB).
    palette = np.array([
        [0.40, 0.405, 0.41], [0.35, 0.355, 0.36], [0.365, 0.38, 0.405], [0.315, 0.33, 0.355],
        [0.41, 0.425, 0.45], [0.26, 0.27, 0.285], [0.345, 0.355, 0.35],
        [0.415, 0.39, 0.355], [0.44, 0.405, 0.345], [0.42, 0.365, 0.34],
    ], np.float32)
    weights = np.array([0.15, 0.13, 0.15, 0.12, 0.07, 0.08, 0.06, 0.09, 0.08, 0.07])
    grain = fbm(size, size, 64, 4, r) - 0.5
    edge_wob = fbm(size, size, 16, 3, r) - 0.5
    chip = value_noise(size, size, 150, 150, r) - 0.5
    bumps = fbm(size, size, 36, 3, r) - 0.5
    speck = value_noise(size, size, 300, 300, r)
    mottle = fbm(size, size, 14, 3, r) - 0.5
    h = np.zeros((size, size), np.float32)
    alb = np.zeros((size, size, 3), np.float32)
    rough = np.zeros((size, size), np.float32)
    inside = np.zeros((size, size), np.float32)
    for k in range(n_rows):
        m = row == k
        ly_all = Y - B[k][None, :]
        sh_all = (B[k + 1] - B[k])[None, :]
        col_edges = partition(size, n_cols, 0.3)
        offset = r.uniform(0, size)
        u = (xs[None, :] - offset) % size
        idx = np.broadcast_to(np.clip(np.searchsorted(col_edges, u, side="right") - 1, 0, n_cols - 1), (size, size))
        n = n_cols
        # Per-stone shape and colour.
        cx_jit = r.uniform(-0.005, 0.005, n) * ppm
        cy_jit = r.uniform(-0.006, 0.006, n) * ppm
        rot = r.uniform(-0.1, 0.1, n)
        jw = r.uniform(0.003, 0.0055, n) * ppm            # joint half-gap
        shrink_x = r.uniform(0.0, 0.004, n) * ppm
        shrink_y = r.uniform(0.0, 0.006, n) * ppm
        corner = r.uniform(0.018, 0.04, n) * ppm
        shoulder_r = r.uniform(0.016, 0.03, n) * ppm
        top = r.uniform(0.72, 1.0, n)
        dome_k = r.uniform(0.2, 0.45, n)
        tilt_x = r.uniform(-0.14, 0.14, n)
        tilt_y = r.uniform(-0.14, 0.14, n)
        cols = palette[r.choice(len(palette), n, p=weights / weights.sum())]
        cols = cols * r.uniform(0.9, 1.1, (n, 1))
        wear = r.uniform(0.0, 1.0, n)
        sw = (col_edges[1:] - col_edges[:-1])[idx]
        lx = u - col_edges[:-1][idx] - sw / 2 - cx_jit[idx]
        ly = ly_all - sh_all / 2 - cy_jit[idx]
        c, s_ = np.cos(rot[idx]), np.sin(rot[idx])
        qx = c * lx + s_ * ly
        qy = -s_ * lx + c * ly
        hx = sw / 2 - jw[idx] - shrink_x[idx] - corner[idx]
        hy = sh_all / 2 - jw[idx] - shrink_y[idx] - corner[idx]
        dx = np.abs(qx) - hx
        dy = np.abs(qy) - hy
        sdf = np.sqrt(np.maximum(dx, 0) ** 2 + np.maximum(dy, 0) ** 2) + np.minimum(np.maximum(dx, dy), 0) - corner[idx]
        # Split-stone outlines: wobbling, chipped.
        sdf = sdf + edge_wob * 0.008 * ppm + chip * 0.004 * ppm
        e = np.clip(-sdf / shoulder_r[idx], 0, 1)
        shoulder = 1 - (1 - e) ** 2
        cnx = qx / np.maximum(sw / 2, 1)
        cny = qy / np.maximum(sh_all / 2, 1)
        crown = 1 - dome_k[idx] * (cnx ** 2 + cny ** 2)
        hh = shoulder * crown * top[idx] + (tilt_x[idx] * cnx + tilt_y[idx] * cny) * 0.1 * shoulder
        hh = hh + (grain * 0.05 + bumps * 0.16) * shoulder
        base = cols[idx]
        tone = 1 + mottle[..., None] * 0.18 + (speck[..., None] - 0.5) * 0.18
        # Grime towards the edges, a polish on worn tops.
        edge_dark = 0.8 + 0.2 * smoothstep(0.0, 0.6, shoulder)
        polish = 1 + 0.08 * wear[idx][..., None] * (np.clip(hh, 0, 1)[..., None] ** 3)
        stone = base * tone * edge_dark[..., None] * polish
        rr = 0.66 - 0.16 * wear[idx] * np.clip(hh, 0, 1) ** 2 + grain * 0.1
        h = np.where(m, hh, h)
        alb = np.where(m[..., None], stone, alb)
        rough = np.where(m, rr, rough)
        inside = np.where(m, smoothstep(0.0015 * ppm, -0.0015 * ppm, sdf), inside)

    # Joints: sandy grit, darker soil in places, a little moss.
    sand = np.array([0.43, 0.40, 0.345], np.float32)
    soil = np.array([0.25, 0.225, 0.19], np.float32)
    moss = np.array([0.21, 0.25, 0.11], np.float32)
    jn = fbm(size, size, 28, 4, r)
    soily = smoothstep(0.5, 0.8, fbm(size, size, 9, 3, r))
    mossy = smoothstep(0.72, 0.88, fbm(size, size, 6, 3, r)) * 0.55
    jcol = sand[None, None] * (0.8 + 0.35 * jn[..., None]) * (0.85 + 0.3 * speck[..., None])
    jcol = jcol + (soil - jcol) * (soily * 0.6)[..., None]
    jcol = jcol + (moss - jcol) * mossy[..., None]
    j = 1 - inside
    alb = alb * (1 - j[..., None]) + jcol * j[..., None]
    # Grit sits a little up the joints; the stones stand proud of it.
    grit = 0.04 + 0.06 * jn
    height = np.clip(np.maximum(h, grit), 0, 1)
    rough = rough * (1 - j) + 0.95 * j
    save_rgb(OUT / "cj_cobble_albedo.jpg", np.clip(alb, 0, 1), 92)
    detail_png(OUT / "cj_cobble_detail.png", height, 11.0, np.clip(rough, 0.3, 1))


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
    """cj_ground_detail.png, 2.5 m tile. Four height patterns, one per
    channel: R grass, G crop stubble / rows, B leaf litter and soil,
    A gravel. Mean about 0.5; the terrain shader uses them for both
    brightness modulation and normals."""
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

    # Crop stubble: rows every ~15 cm along v, with stalk stubs.
    ppm = size / 2.5
    yy = np.arange(size, dtype=np.float32)[:, None]
    rows = 0.5 + 0.5 * np.cos(yy / (0.15 * ppm) * 2 * math.pi * (size / (0.15 * ppm) // 1) / (size / (0.15 * ppm)))
    stubs = smoothstep(0.78, 0.95, value_noise(size, size, 400, 400, r))
    crop = np.clip(0.25 + 0.35 * rows ** 3 + 0.5 * stubs * rows + 0.2 * (fbm(size, size, 16, 3, r) - 0.5), 0, 1)
    crop = np.broadcast_to(crop, (size, size)).astype(np.float32)

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


def bake_grass(w: int = 512, h: int = 512) -> None:
    """cj_grass.png: two grass-tuft cards side by side (256 x 512 each),
    blades rooted on the bottom edge. Left: green verge grass; right: taller
    late-summer grass with seed heads."""
    s = 2
    img = Image.new("RGBA", (w * s, h * s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = rng(51)
    for variant in range(2):
        x_off = variant * (w // 2) * s
        n = 150 if variant == 0 else 120
        for _ in range(n):
            bx = x_off + r.uniform(0.15, 0.85) * (w // 2) * s
            height = r.uniform(0.35, 0.95 if variant == 0 else 1.0) * h * s
            lean = r.normal(0, 0.25) * height
            width = r.uniform(3, 7) * s
            dry = r.random() < (0.12 if variant == 0 else 0.4)
            base_col = np.array([0.16, 0.26, 0.07]) if not dry else np.array([0.42, 0.38, 0.18])
            tip_col = np.array([0.42, 0.55, 0.20]) if not dry else np.array([0.70, 0.64, 0.40])
            steps = 10
            pts_l, pts_r = [], []
            for k in range(steps + 1):
                t = k / steps
                y = h * s - t * height
                x = bx + lean * t * t
                wd = width * (1 - t) ** 0.9 / 2
                pts_l.append((x - wd, y)); pts_r.append((x + wd, y))
            for k in range(steps):
                t = (k + 0.5) / steps
                c = base_col + (tip_col - base_col) * t
                c = c * r.uniform(0.85, 1.15)
                col = tuple(int(np.clip(v, 0, 1) * 255) for v in c) + (255,)
                d.polygon([pts_l[k], pts_r[k], pts_r[k + 1], pts_l[k + 1]], fill=col)
            if variant == 1 and r.random() < 0.3:
                x, y = pts_l[-1]
                for _ in range(8):
                    ox, oy = r.normal(0, 4 * s), r.uniform(0, 30 * s)
                    rr = 2.5 * s
                    d.ellipse([x + ox - rr, y + oy - rr, x + ox + rr, y + oy + rr], fill=(196, 182, 130, 255))
    img = img.resize((w, h), Image.LANCZOS)
    arr = np.asarray(img, np.float32) / 255
    rgb, a = arr[..., :3], arr[..., 3:]
    # Ragged, fading base so a tuft melts into the ground.
    yy = np.arange(h, dtype=np.float32)[:, None] / h
    jag = value_noise(h, w, 8, 64, r)
    fade = smoothstep(0.0, 1.0, (1 - yy - 0.015 - jag * 0.05) / 0.06)
    a = a * fade[..., None]
    blurred = blur(rgb * a, 4) / np.maximum(blur(a, 4), 1e-3)
    arr[..., :3] = rgb * a + blurred * (1 - a)
    arr[..., 3:] = a
    save_rgba(OUT / "cj_grass.png", arr)


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


def bake_roofs(size: int = 512) -> None:
    """cj_roof_pantile.jpg / cj_roof_slate.jpg + *_detail.png: 1 m x 1 m.
    u runs along the eaves, v down the slope. Pantiles: S-profile courses
    of 33 cm exposure, four tiles per metre; slate-grey flat tiles in a
    broken bond."""
    r = rng(101)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    # Pantile.
    tiles_x, courses = 4, 3
    tw = size / tiles_x
    ch = size / courses
    course = np.floor(yy / ch)
    lx = (xx % tw) / tw
    ly = (yy % ch) / ch
    wave = np.where(lx < 0.62, np.sin(lx / 0.62 * math.pi) * 0.9, -np.sin((lx - 0.62) / 0.38 * math.pi) * 0.25)
    lap = smoothstep(0.0, 0.12, ly) * (1 - 0.25 * ly)
    height = np.clip(0.45 + 0.4 * wave * (0.6 + 0.4 * ly) + 0.25 * lap - 0.2 * (ly < 0.04), 0, 1)
    ids = (course * tiles_x + np.floor(xx / tw)).astype(int)
    tone = r.uniform(0.85, 1.12, ids.max() + 1)[ids]
    base = np.array([0.60, 0.29, 0.17], np.float32)
    col = base * tone[..., None] * (0.78 + 0.3 * height[..., None])
    moss = smoothstep(0.7, 0.85, fbm(size, size, 6, 4, r)) * (1 - ly)
    col = col + (np.array([0.28, 0.30, 0.16]) - col) * (moss * 0.5)[..., None]
    shadow = 1 - 0.45 * (ly > 0.94)
    col = col * shadow[..., None]
    save_rgb(OUT / "cj_roof_pantile.jpg", np.clip(col, 0, 1), 90)
    detail_png(OUT / "cj_roof_pantile_detail.png", height, 7.0, np.full_like(height, 0.7))
    # Slate / flat tile.
    tw, courses = size / 5, 4
    ch = size / courses
    course = np.floor(yy / ch)
    shift = (course % 2) * tw / 2
    lx = ((xx + shift) % tw) / tw
    ly = (yy % ch) / ch
    edge = np.minimum(np.minimum(lx, 1 - lx) * tw, (1 - ly) * ch)
    height = np.clip(0.3 + 0.7 * ly, 0, 1) * smoothstep(0, 3, edge)
    ids = (course * 6 + np.floor(((xx + shift) % size) / tw)).astype(int)
    tone = r.uniform(0.8, 1.15, ids.max() + 1)[ids]
    base = np.array([0.17, 0.175, 0.19], np.float32)
    col = base * tone[..., None] * (0.85 + 0.25 * height[..., None])
    col = col * (0.92 + 0.12 * fbm(size, size, 24, 3, r)[..., None])
    save_rgb(OUT / "cj_roof_slate.jpg", np.clip(col, 0, 1), 90)
    detail_png(OUT / "cj_roof_slate_detail.png", height, 5.0, np.full_like(height, 0.55))


# ---------------------------------------------------------------- impostors

def bake_impostors(size: int = 1024) -> None:
    """cj_impostor.png: 2 x 2 atlas of distant-tree sprites, trunk base at
    the bottom centre of each cell. Top-left broadleaf, top-right poplar,
    bottom-left conifer, bottom-right orchard tree."""
    cell = size // 2
    atlas = np.zeros((size, size, 4), np.float32)
    r = rng(111)
    cards = [foliage_card(256, k, 200 + i) for i, k in enumerate(["broad", "poplar", "ivy", "needle"])]
    shapes = ["broad", "poplar", "conifer", "fruit"]
    for k, shape in enumerate(shapes):
        oy, ox = (k // 2) * cell, (k % 2) * cell
        rgb = np.zeros((cell, cell, 3), np.float32)
        a = np.zeros((cell, cell), np.float32)
        yy, xx = np.mgrid[0:cell, 0:cell].astype(np.float32)
        cx = cell / 2
        # Trunk.
        trunk_top = {"broad": 0.55, "poplar": 0.25, "conifer": 0.12, "fruit": 0.68}[shape]
        tw = {"broad": 0.035, "poplar": 0.03, "conifer": 0.03, "fruit": 0.04}[shape] * cell
        tm = (np.abs(xx - cx) < tw) & (yy > trunk_top * cell)
        rgb[tm] = [0.22, 0.19, 0.16]
        a[tm] = 1
        # Crown from many shrunken leaf-clump cards, shaded top to bottom.
        card = {"broad": cards[0], "poplar": cards[1], "conifer": cards[3], "fruit": cards[0]}[shape]
        n = {"broad": 70, "poplar": 80, "conifer": 90, "fruit": 60}[shape]
        for _ in range(n):
            # Every crown stays inside its cell (a stamp crossing the edge
            # would be cut straight, giving distant trees flat tops).
            if shape == "broad":
                ang = r.uniform(0, 2 * math.pi); rad = math.sqrt(r.uniform(0, 1))
                py = cell * (0.2 + 0.36 * (0.5 + 0.5 * math.sin(ang) * rad))
                px = cx + math.cos(ang) * rad * cell * 0.33
                br = r.uniform(0.1, 0.14) * cell
            elif shape == "poplar":
                t = r.uniform(0, 1)
                py = cell * (0.13 + 0.68 * t)
                wid = 0.14 * math.sin(math.pi * (0.15 + 0.85 * t)) ** 0.7
                px = cx + r.uniform(-1, 1) * wid * cell
                br = r.uniform(0.07, 0.1) * cell
            elif shape == "conifer":
                t = r.uniform(0, 1) ** 0.8
                py = cell * (0.11 + 0.74 * t)
                wid = 0.28 * t + 0.02
                px = cx + r.uniform(-1, 1) * wid * cell
                br = r.uniform(0.06, 0.09) * cell
            else:
                ang = r.uniform(0, 2 * math.pi); rad = math.sqrt(r.uniform(0, 1))
                py = cell * (0.34 + 0.34 * (0.5 + 0.5 * math.sin(ang) * rad))
                px = cx + math.cos(ang) * rad * cell * 0.33
                br = r.uniform(0.1, 0.14) * cell
            sz = max(int(br * 2), 8)
            spr = np.asarray(Image.fromarray(to_u8(card)).resize((sz, sz), Image.LANCZOS), np.float32) / 255
            light = 0.62 + 0.55 * (1 - py / cell) + r.uniform(-0.08, 0.08)
            stamp(rgb, a, spr[..., :3] * light, spr[..., 3], int(py - sz / 2), int(px - sz / 2))
        # Ragged edges.
        edge_noise = value_noise(cell, cell, 64, 64, r)
        from scipy.ndimage import binary_erosion
        a = np.where(a > 0.5, 1.0, 0.0).astype(np.float32)
        atlas[oy:oy + cell, ox:ox + cell, :3] = rgb
        atlas[oy:oy + cell, ox:ox + cell, 3] = a
    rgb, a = atlas[..., :3], atlas[..., 3:]
    blurred = blur(rgb * a, 8) / np.maximum(blur(a, 8), 1e-3)
    atlas[..., :3] = rgb * a + blurred * (1 - a)
    save_rgba(OUT / "cj_impostor.png", atlas)


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


# Sky look, shared by the background and the lighting environment.
SKY_TURBIDITY = 3.4       # clear but hazy late-summer air over Flanders
SKY_ZENITH_LINEAR = 0.3   # linear luminance the zenith opposite the sun maps to


def sun_vector() -> np.ndarray:
    az, el = math.radians(SUN_AZIMUTH_DEG), math.radians(SUN_ELEVATION_DEG)
    return np.array([math.sin(az) * math.cos(el), math.sin(el), -math.cos(az) * math.cos(el)], np.float32)


def preetham_luminance(d: np.ndarray, T: float = SKY_TURBIDITY) -> np.ndarray:
    """Relative sky luminance Y(d) / Y(zenith) from the Preetham model:
    bright around the sun and towards the horizon, darkest about 90 degrees
    from the sun. Directions below the horizon get the horizon's value."""
    sun = sun_vector()
    ts = math.acos(float(sun[1]))
    theta = np.arccos(np.clip(d[..., 1], 0.02, 1.0))
    gamma = np.arccos(np.clip((d * sun).sum(-1), -1, 1))
    c = _perez_coeffs(T)["Y"]
    return _perez(theta, gamma, c) / _perez(0.0, ts, c)


# Sky colours (sRGB): deep-sky blue at one air mass, the near-white of a
# long, hazy path, and the warmer white of forward scattering round the sun.
SKY_BLUE = np.array([0.37, 0.55, 0.82], np.float32)
SKY_HAZE = np.array([0.80, 0.845, 0.90], np.float32)
SKY_AUREOLE = np.array([1.0, 0.965, 0.9], np.float32)


def sky_chroma(d: np.ndarray) -> np.ndarray:
    """Colour of the clear sky for directions d, unit luminance: Rayleigh
    blue overhead, washing out to haze with optical air mass (Kasten-Young)
    and near the sun (Mie forward scattering). The Preetham chromaticities
    turn pink at the horizon at this turbidity, which reads wrong."""
    sun = sun_vector()
    up = np.clip(d[..., 1], 0.0, 1.0)
    zen = np.degrees(np.arccos(up))
    m = 1 / (np.cos(np.radians(zen)) + 0.50572 * np.maximum(96.07995 - zen, 0.5) ** -1.6364)
    h = 1 - np.exp(-0.34 * (m - 1))
    cosg = np.clip((d * sun).sum(-1), 0, 1)
    h = 1 - (1 - h) * (1 - 0.6 * cosg ** 6)
    w = np.array([0.2126, 0.7152, 0.0722], np.float32)
    # Mixed at equal luminance, so `h` is the share of the colour.
    blue, haze, aur = (c / float(c @ w) for c in (srgb_to_linear(x) for x in (SKY_BLUE, SKY_HAZE, SKY_AUREOLE)))
    white = haze + (aur - haze) * (cosg ** 10)[..., None]
    col = blue + (white - blue) * h[..., None]
    return col / (col @ w)[..., None]


def preetham_rgb(d: np.ndarray, T: float = SKY_TURBIDITY) -> np.ndarray:
    """Linear sRGB clear-sky radiance for unit directions d (..., 3): the
    Preetham luminance distribution in the `sky_chroma` colours, scaled so
    the zenith reads SKY_ZENITH_LINEAR, with the circumsolar glare rolled
    off softly before it clips."""
    Y = preetham_luminance(d, T) * SKY_ZENITH_LINEAR
    knee = 0.6
    Y = np.where(Y > knee, knee + (Y - knee) / (1 + (Y - knee) / 0.55), Y)
    return sky_chroma(d) * Y[..., None]


def horizon_haze() -> np.ndarray:
    """Mean linear sky colour just above the horizon, all round: the fog
    colour the far terrain fades to. Keep SkyLighting.horizon in step."""
    az = np.linspace(0, 2 * math.pi, 256, endpoint=False)
    el = math.radians(1.0)
    d = np.stack([np.sin(az) * math.cos(el), np.full_like(az, math.sin(el)), -np.cos(az) * math.cos(el)], -1)
    return preetham_rgb(d.astype(np.float32)).mean(0)


def sky_radiance(d: np.ndarray, clouds: bool, ground: bool, cloud_tex=None) -> np.ndarray:
    """Linear radiance of the late-summer sky for directions d (..., 3):
    Preetham sky, fair-weather cumulus on a 1.6 km layer, sun disc and a
    haze band at the horizon. Below the horizon: the haze colour (for the
    background, so the fogged far terrain meets it without a seam) or, with
    `ground`, light bounced off sunlit fields (for the lighting
    environment)."""
    sun = sun_vector()
    up = d[..., 1]
    cosg = np.clip((d * sun).sum(-1), -1, 1)
    haze = horizon_haze()
    sky = preetham_rgb(d)
    # The lowest few degrees settle on the all-round haze colour.
    band = 1 - smoothstep(0.0, 0.07, up)
    sky = sky + (haze - sky) * (band * 0.75)[..., None]
    if clouds and cloud_tex is not None:
        cn, cn2 = cloud_tex
        cn_n = cn.shape[0]
        hgt = 1.6  # km
        tt = hgt / np.maximum(up, 0.02)
        cx = d[..., 0] * tt / 9.0
        cz = d[..., 2] * tt / 9.0
        ix = ((cx % 1) * cn_n).astype(int) % cn_n
        iz = ((cz % 1) * cn_n).astype(int) % cn_n
        dens = cn[iz, ix] * 0.8 + cn2[iz, ix] * 0.2
        cover = smoothstep(0.6, 0.8, dens)
        thick = smoothstep(0.62, 0.95, dens)
        mie = np.clip(cosg, 0, 1)
        lum = float(preetham_rgb(np.array([[0, 1, 0]], np.float32)).mean()) / SKY_ZENITH_LINEAR
        lit = np.array([1.0, 0.975, 0.94], np.float32) * (0.95 + 0.35 * mie[..., None] ** 4) * 0.78 * lum
        base = np.array([0.50, 0.53, 0.60], np.float32) * 0.62 * lum
        cloud = lit + (base - lit) * (thick * 0.7)[..., None]
        # Distant clouds dissolve into the haze.
        fade = smoothstep(0.02, 0.3, up)
        cloud = cloud + (haze - cloud) * (1 - smoothstep(0.04, 0.35, up))[..., None] * 0.6
        a = (cover * fade * 0.92)[..., None]
        sky = sky * (1 - a) + cloud * a
    # Sun disc and a tight aureole (the disc clips in 8-bit; the key light
    # carries the sun's energy).
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
        # Fields and hedges in afternoon sun, darkening away from the horizon.
        g = np.array([0.105, 0.11, 0.075], np.float32)
        t = smoothstep(0.0, 0.18, -up)[..., None]
        low = haze + (g - haze) * t
        sky = np.where(below[..., None], low, sky)
    else:
        sky = np.where(below[..., None], haze, sky)
    return sky


def bake_sky(n: int = 768, env_n: int = 96) -> None:
    """cj_sky_{px,nx,py,ny,pz,nz}.jpg: the background, a late-summer
    afternoon sky (Preetham daylight model, turbidity SKY_TURBIDITY) with
    scattered fair-weather cumulus, sun in the south-west. Scene axes: x =
    east, y = up, z = south. Below the horizon the faces carry the haze
    colour so the fogged far terrain meets them without a seam.

    cj_skyenv_*.jpg: the same sky, small and with a ground hemisphere of
    sunlit fields, for image-based lighting (shadows and undersides pick up
    green-brown bounce light instead of blue).

    Both are stored as linear / SKY_SCALE in sRGB encoding, so 8 bits hold
    the bright horizon; the Swift side sets the background and lighting
    environment intensities to SKY_SCALE."""
    r = rng(131)
    cloud_tex_n = 1024
    cn = fbm(cloud_tex_n, cloud_tex_n, 5, 6, r, gain=0.52)
    cn2 = fbm(cloud_tex_n, cloud_tex_n, 14, 4, r)
    names = ["px", "nx", "py", "ny", "pz", "nz"]
    for f in range(6):
        d = cube_dirs(f, n)
        sky = sky_radiance(d, clouds=True, ground=False, cloud_tex=(cn, cn2))
        save_rgb(OUT / f"cj_sky_{names[f]}.jpg", np.clip(linear_to_srgb(sky / SKY_SCALE), 0, 1), 92)
        de = cube_dirs(f, env_n)
        env = sky_radiance(de, clouds=True, ground=True, cloud_tex=(blur(cn, 6), blur(cn2, 6)))
        save_rgb(OUT / f"cj_skyenv_{names[f]}.jpg", np.clip(linear_to_srgb(env / SKY_SCALE), 0, 1), 90)
    haze = horizon_haze()
    print("horizon haze, linear", np.round(haze, 4), "stored sRGB", np.round(linear_to_srgb(haze / SKY_SCALE), 4))


# Stored sky = linear radiance / SKY_SCALE (see bake_sky).
SKY_SCALE = 1.0


def preview_sky(path: Path, w: int = 1024, h: int = 384) -> None:
    """Equirectangular preview of the background sky from 10 degrees below
    the horizon to the zenith, north at the left edge, for checking the look
    without a build."""
    r = rng(131)
    cn = fbm(1024, 1024, 5, 6, r, gain=0.52)
    cn2 = fbm(1024, 1024, 14, 4, r)
    az = (np.arange(w, dtype=np.float32) + 0.5) / w * 2 * math.pi
    el = np.radians(90 - (np.arange(h, dtype=np.float32) + 0.5) / h * 100)
    az, el = np.meshgrid(az, el)
    d = np.stack([np.sin(az) * np.cos(el), np.sin(el), -np.cos(az) * np.cos(el)], -1).astype(np.float32)
    sky = sky_radiance(d, clouds=True, ground=False, cloud_tex=(cn, cn2))
    save_rgb(path, np.clip(linear_to_srgb(sky), 0, 1), 90)


# ---------------------------------------------------------------- main

BAKERS = {
    "cobbles": bake_cobbles, "asphalt": bake_asphalt, "ground": bake_ground,
    "foliage": bake_foliage, "grass": bake_grass, "bark": bake_bark,
    "brick": bake_brick, "facades": bake_facades, "roofs": bake_roofs,
    "impostors": bake_impostors, "farfields": bake_far_fields, "sky": bake_sky,
}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma-separated subset of " + ",".join(BAKERS))
    ap.add_argument("--preview-sky", default="", help="write an equirectangular sky preview here and exit")
    args = ap.parse_args()
    if args.preview_sky:
        preview_sky(Path(args.preview_sky))
        print("horizon haze, linear", np.round(horizon_haze(), 4))
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
