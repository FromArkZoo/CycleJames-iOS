# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the roof atlas and the weathering map of the village buildings.

    uv run --script scripts/courses/textures/bake_buildings.py [--only roof,grime] [--preview DIR]

Procedural like bake_materials.py (no photos, no downloaded assets), whose
conventions this follows; output goes to CycleJames/Resources/CourseTextures/.
The walls keep bake_materials.py's cj_facade.jpg.

cj_roof.jpg (sRGB colour) and cj_roof_detail.rgbz (data: R, G = normal x, y,
+x along u, +y along v; B = roughness; A = height, 0 lowest): a 2 x 2 atlas
of 2 m x 2 m tiles at 256 px/m, 1024 px in all. u runs along the eaves, v
down the slope (image rows from the ridge side down). Tile index
(WorldShaders.roofSurface, BuildingBuilder.RoofCover):
  0 orange-red clay pantiles ("Vlaamse pan"), 7 across x 8 courses;
  1 smoked, blue-black glazed pantiles ("gesmoorde pan"), the same lay;
  2 fibre-cement slates, 7 x 7 in a broken bond;
  3 grey corrugated fibre-cement sheet (barns and sheds), 11 waves, a lap
    every metre.
No moss is baked: the shader grows it per roof on the north slopes, so it
never repeats with the tile. Ridge caps are drawn with a pantile's crown
(u 0 to 0.18 m of each 2/7 m tile).

cj_grime.rgbz (512 px, data, tileable): R rain streaks (long in v), G
blotches, B algae and moss patches, A low-frequency mottling. The wall and
roof shaders read it at several scales, offset per building.

The Ligurian Riviera (the Poggio di Sanremo, WorldLook.riviera) has its own
atlases on the same grids, so neither a shader's layout nor a builder's UVs
change with the region:

cj_facade_lig.jpg (sRGB, 2048 px, 4 x 4 cells of 3 m as cj_facade.jpg; the
openings inside BuildingBuilder.OpeningCut's boxes). Rows: 0 smooth render
with louvred persiane, 1 the render of the 1950s-80s palazzine with roll
shutters (tapparelle) and aluminium doors, 2 old render flaking to the
rubble stone under it, with painted surrounds and an arched door, 3 bare
board-marked concrete (cisterns, sheds, greenhouse plinths). Columns as the
Flemish atlas: upper window, ground window, door bay, blank wall. The render
is a neutral warm white for the wall shader to colour per building, the
shutters a neutral grey-green for it to paint dark green, brown or light
blue; cj_facade_lig_mask.rgbz (1024 px, data) says where: R render, G
shutters and painted doors, B, A unused (0, 1).

cj_roof_lig.jpg and cj_roof_lig_detail.rgbz, laid out as cj_roof: 0
terracotta Marseille tiles (tegole marsigliesi, measured aerial #c28b78,
#c98264, #cc8767), 8 across x 6 courses; 1 old canal tiles (coppi), caps
and channels 8 across x 6 courses, browner (#a86d55), whose cap over u 0 to
0.18 m makes the ridge and hip tiles; 2 a flat roof terrace in pale clinker
squares (#e8e2d8); 3 grey corrugated fibre-cement sheet.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from texlib import fbm, normal_xy, rng, save_raw, save_rgb, smoothstep, to_u8  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "CycleJames/Resources/CourseTextures"

ROOF_TILE = 512           # px per 2 m tile (256 px/m)
ROOF_M = 2.0


def pantile(r, palette, rough: float, size: int = ROOF_TILE):
    """Pantile courses over one tile: albedo (sRGB), height, roughness.

    Seven tiles of 28.6 cm across by eight 25 cm courses. Each tile's cross
    section is an S: a high roll then a shallow pan. Down the slope a tile
    rises towards its lower edge, which laps over the course below and casts
    a shadow onto it. Tiles sit a few millimetres off true and differ in
    colour (drawn from `palette`, a list of (weight, sRGB colour))."""
    across, courses = 7, 8
    tw, ch = size / across, size / courses
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    course0 = np.floor(yy / ch).astype(np.int64)
    col = np.floor(xx / tw).astype(np.int64)
    n = across * courses
    # Per tile: a vertical offset of up to +-5 mm, then the course it lands in.
    off = r.uniform(-1.3, 1.3, n).astype(np.float32)
    ids0 = (course0 % courses) * across + col % across
    y = yy - off[ids0]
    course = np.floor(y / ch).astype(np.int64)
    ids = (course % courses) * across + col % across
    ly = (y - course * ch) / ch                   # 0 under the course above .. 1 at the lower edge
    skew = r.uniform(-0.03, 0.03, n).astype(np.float32)[ids]
    lx = ((xx - col * tw) / tw + skew * (ly - 0.5)) % 1.0
    roll = np.where(lx < 0.62, np.sin(lx / 0.62 * np.pi), -0.35 * np.sin((lx - 0.62) / 0.38 * np.pi))
    rise = 0.22 * ly
    lap = 1 - smoothstep(0.0, 0.16, ly)          # in the shadow of the lap above
    grain = fbm(size, size, 64, 4, r)
    height = np.clip(0.42 + 0.36 * roll * (0.75 + 0.25 * ly) + rise - 0.3 * lap + 0.03 * grain, 0, 1)
    w = np.array([p[0] for p in palette], np.float64)
    pick = r.choice(len(palette), n, p=w / w.sum())
    base = np.array([p[1] for p in palette], np.float32)[pick] * r.uniform(0.9, 1.1, (n, 1)).astype(np.float32)
    alb = base[ids] * (0.9 + 0.2 * grain[..., None])
    # Firing streaks along each tile and a paler, weathered crown.
    streak = fbm(size, size, 24, 3, r, aspect=0.15)
    alb *= (0.94 + 0.12 * streak)[..., None]
    # Occlusion baked in: the pan sits in the roll's shade, and the lap
    # throws a deeper shadow beside the high roll.
    alb *= (0.84 + 0.22 * roll)[..., None]
    alb *= (1 - (0.45 + 0.2 * np.clip(roll, 0, 1)) * lap)[..., None]
    ro = np.clip(rough + 0.12 * (grain - 0.5) + 0.15 * lap, 0, 1)
    return alb, height, ro


def slates(r, size: int = ROOF_TILE):
    """Fibre-cement slates, 28.6 cm square exposures in a broken bond: a
    thick lower edge throwing a shadow line onto the course below, hairline
    head joints, and per-slate tone and a slight tilt."""
    across, courses = 7, 7
    tw, ch = size / across, size / courses
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    course = np.floor(yy / ch).astype(np.int64)
    x = (xx + (course % 2) * tw / 2) % size
    col = np.floor(x / tw).astype(np.int64)
    ids = (course % courses) * across + col % across
    n = across * courses
    lx = (x - col * tw) / tw
    ly = (yy - course * ch) / ch
    joint = 1 - smoothstep(0.0, 0.022, np.minimum(lx, 1 - lx))
    shadow = 1 - smoothstep(0.0, 0.1, ly)
    tilt = r.uniform(-0.12, 0.12, n).astype(np.float32)[ids]
    grain = fbm(size, size, 96, 4, r)
    height = np.clip(0.25 + 0.55 * ly + tilt * (lx - 0.5) - 0.4 * joint + 0.04 * grain, 0, 1)
    height *= 1 - 0.6 * shadow
    tone = r.uniform(0.86, 1.14, n).astype(np.float32)[ids]
    hue = r.uniform(-0.02, 0.02, n).astype(np.float32)[ids]
    base = np.array([0.31, 0.325, 0.35], np.float32)
    alb = base * tone[..., None] * (0.92 + 0.12 * grain[..., None])
    alb[..., 0] += hue
    alb[..., 2] -= hue
    # Worn, paler lower edges; dark joints and lap shadow.
    alb *= (1 + 0.08 * smoothstep(0.85, 1.0, ly))[..., None]
    alb *= (1 - 0.6 * joint)[..., None] * (1 - 0.55 * shadow)[..., None]
    ro = np.clip(0.62 + 0.08 * (grain - 0.5) + 0.15 * shadow, 0, 1)
    return alb, height, ro


def corrugated(r, size: int = ROOF_TILE):
    """Grey corrugated fibre-cement sheet: 11 waves per 2 m across the
    slope, a lap every metre, run-off streaks down the troughs and pale
    lichen specks."""
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    wave = np.cos(xx / size * 11 * 2 * np.pi)
    lv = (yy % (size / 2)) / (size / 2)
    lap = 1 - smoothstep(0.0, 0.05, lv)
    grain = fbm(size, size, 128, 3, r)
    height = np.clip(0.5 + 0.38 * wave + 0.06 * lv - 0.25 * lap + 0.02 * grain, 0, 1)
    streak = fbm(size, size, 16, 4, r, aspect=0.1)
    trough = smoothstep(0.2, -0.9, wave)
    alb = np.array([0.56, 0.56, 0.53], np.float32) * (0.9 + 0.14 * grain)[..., None] * (0.9 + 0.1 * wave)[..., None]
    alb *= (1 - 0.18 * streak * (0.4 + 0.6 * trough))[..., None]
    alb *= (1 - 0.35 * lap)[..., None]
    specks = smoothstep(0.82, 0.9, fbm(size, size, 64, 3, r)) * smoothstep(0.3, 0.6, fbm(size, size, 8, 3, r))
    alb = alb + (np.array([0.68, 0.66, 0.5], np.float32) - alb) * (0.8 * specks)[..., None]
    ro = np.clip(0.9 + 0.05 * (grain - 0.5), 0, 1)
    return alb, height, ro


def bake_roof(size: int = ROOF_TILE) -> list:
    r = rng(301)
    tiles = [
        pantile(r, [(5, (0.66, 0.33, 0.19)), (3, (0.58, 0.27, 0.16)), (2, (0.5, 0.24, 0.15)),
                    (1, (0.72, 0.42, 0.26)), (1, (0.42, 0.21, 0.15))], rough=0.72),
        pantile(r, [(6, (0.27, 0.28, 0.305)), (2, (0.23, 0.235, 0.25)), (1, (0.32, 0.31, 0.31)),
                    (1, (0.29, 0.265, 0.25))], rough=0.36),
        slates(r),
        corrugated(r),
    ]
    strengths = [9.0, 9.0, 4.0, 5.0]
    atlas = np.zeros((2 * size, 2 * size, 3), np.float32)
    det = np.zeros((2 * size, 2 * size, 4), np.float32)
    for k, ((alb, h, ro), s) in enumerate(zip(tiles, strengths)):
        y0, x0 = (k // 2) * size, (k % 2) * size
        atlas[y0:y0 + size, x0:x0 + size] = np.clip(alb, 0, 1)
        nx, ny, _ = normal_xy(h, s)              # wraps within the tile
        det[y0:y0 + size, x0:x0 + size] = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, ro, h], -1)
    save_rgb(OUT / "cj_roof.jpg", atlas, 90)
    save_raw(OUT / "cj_roof_detail.rgbz", det)
    return [atlas]


def bake_grime(size: int = 512) -> list:
    r = rng(311)
    streak = smoothstep(0.35, 0.8, fbm(size, size, 24, 4, r, aspect=0.08))
    blot = fbm(size, size, 6, 5, r)
    algae = smoothstep(0.42, 0.72, fbm(size, size, 10, 5, r))
    mott = fbm(size, size, 3, 4, r)
    g = np.stack([streak, blot, algae, mott], -1)
    save_raw(OUT / "cj_grime.rgbz", g)
    return [g[..., :3]]


# ---------------------------------------------------------------- Liguria

def hexrgb(h: str) -> tuple:
    """'#c4876a' as an sRGB triple in [0, 1]."""
    return tuple(int(h[i:i + 2], 16) / 255 for i in (1, 3, 5))


def marseille(r, size: int = ROOF_TILE):
    """Terracotta Marseille tiles (tegole marsigliesi): interlocking pressed
    tiles laid in straight columns, 25 cm across by 33 cm courses. Across a
    tile: a flat field with two low ribs, the raised interlock roll at its
    left edge; down it, a nose at the lower edge lapping over the course
    below and throwing a thin shadow. Per-tile tone from the measured roof
    colours of the climb (aerial #c28b78, #c98264, #cc8767; paint #c4876a)
    with the odd darker, browner replacement tile."""
    across, courses = 8, 6
    tw, ch = size / across, size / courses
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    col = np.floor(xx / tw).astype(np.int64)
    course = np.floor(yy / ch).astype(np.int64)
    ids = (course % courses) * across + col % across
    n = across * courses
    lx = (xx - col * tw) / tw
    ly = (yy - course * ch) / ch
    rib = np.exp(-((lx - 0.42) / 0.035) ** 2) + np.exp(-((lx - 0.62) / 0.035) ** 2)
    roll = smoothstep(0.0, 0.07, lx) * (1 - smoothstep(0.07, 0.16, lx))
    edge = 1 - smoothstep(0.9, 1.0, lx)
    groove = np.exp(-((lx - 0.185) / 0.022) ** 2)
    nose = smoothstep(0.82, 0.97, ly) * (1 - smoothstep(0.97, 1.0, ly))
    lap = 1 - smoothstep(0.0, 0.1, ly)
    grain = fbm(size, size, 64, 4, r)
    height = np.clip(0.35 + 0.2 * roll + 0.08 * rib + 0.18 * ly + 0.12 * nose - 0.3 * lap
                     + 0.03 * grain - 0.15 * (1 - edge) - 0.12 * groove, 0, 1)
    palette = [(5, hexrgb("#c4876a")), (3, hexrgb("#c98264")), (3, hexrgb("#cc8767")), (2, hexrgb("#c28b78")),
               (0.6, hexrgb("#b0705a")), (0.4, hexrgb("#a86d55")), (0.4, hexrgb("#d39a7c"))]
    w = np.array([p[0] for p in palette], np.float64)
    pick = r.choice(len(palette), n, p=w / w.sum())
    base = np.array([p[1] for p in palette], np.float32)[pick] * r.uniform(0.96, 1.04, (n, 1)).astype(np.float32)
    alb = base[ids] * (0.92 + 0.16 * grain[..., None])
    # Firing streaks and a dusty, paler top face; occlusion in the laps and
    # beside the interlock roll.
    streak = fbm(size, size, 24, 3, r, aspect=0.15)
    alb *= (0.95 + 0.1 * streak)[..., None]
    alb *= (1 - 0.5 * lap)[..., None] * (0.9 + 0.1 * edge)[..., None] * (1 - 0.08 * rib)[..., None]
    alb *= (1 + 0.1 * roll - 0.35 * groove)[..., None]
    ro = np.clip(0.78 + 0.1 * (grain - 0.5) + 0.12 * lap, 0, 1)
    return alb, height, ro


def coppi(r, size: int = ROOF_TILE):
    """Old canal tiles (coppi): channels laid concave side up, caps over
    their joints concave side down, eight pairs across 2 m (a cap over u 0
    to 0.17 m of each 25 cm pair, the dark channel between) in six 33 cm
    courses, each lapping the one below. Browner than the Marseille tiles,
    faded and darkened unevenly with age (the ridge tiles' #a86d55)."""
    across, courses = 8, 6
    tw, ch = size / across, size / courses
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    col = np.floor(xx / tw).astype(np.int64)
    off = r.uniform(-1.5, 1.5, across * courses).astype(np.float32)
    course0 = np.floor(yy / ch).astype(np.int64)
    y = yy - off[(course0 % courses) * across + col % across]
    course = np.floor(y / ch).astype(np.int64)
    ids = (course % courses) * across + col % across
    n = across * courses
    lx = (xx - col * tw) / tw
    ly = (y - course * ch) / ch
    capw = 0.68
    cap = np.where(lx < capw, np.sin(np.clip(lx / capw, 0, 1) * np.pi), 0.0)
    chan = np.where(lx >= capw, -0.5 * np.sin(np.clip((lx - capw) / (1 - capw), 0, 1) * np.pi), 0.0)
    lap = 1 - smoothstep(0.0, 0.14, ly)
    grain = fbm(size, size, 64, 4, r)
    height = np.clip(0.4 + 0.42 * cap + 0.25 * chan + 0.15 * ly - 0.25 * lap * (lx < capw) + 0.03 * grain, 0, 1)
    palette = [(4, hexrgb("#a86d55")), (3, hexrgb("#b07258")), (2, hexrgb("#9a644e")), (2, hexrgb("#bb7d60")),
               (1, hexrgb("#8a6250")), (1, hexrgb("#c08868"))]
    w = np.array([p[0] for p in palette], np.float64)
    pick = r.choice(len(palette), n, p=w / w.sum())
    base = np.array([p[1] for p in palette], np.float32)[pick] * r.uniform(0.9, 1.1, (n, 1)).astype(np.float32)
    alb = base[ids] * (0.88 + 0.22 * grain[..., None])
    alb *= (0.8 + 0.25 * np.clip(cap, 0, 1))[..., None]
    alb *= (1 - 0.55 * np.clip(-chan * 2, 0, 1))[..., None]
    alb *= (1 - 0.4 * lap * (lx < capw))[..., None]
    ro = np.clip(0.82 + 0.1 * (grain - 0.5) + 0.1 * lap, 0, 1)
    return alb, height, ro


def terrace(r, size: int = ROOF_TILE):
    """A flat roof terrace paved in pale clinker squares 25 cm on 6 mm
    grey joints (#e8e2d8), sun-bleached and stained by standing water."""
    n = 8
    t = size / n
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32)
    lx = (xx % t) / t
    ly = (yy % t) / t
    joint = 1 - smoothstep(0.0, 0.03, np.minimum(np.minimum(lx, 1 - lx), np.minimum(ly, 1 - ly)))
    ids = (np.floor(yy / t) * n + np.floor(xx / t)).astype(np.int64)
    tone = r.uniform(0.93, 1.05, n * n).astype(np.float32)[ids]
    grain = fbm(size, size, 64, 4, r)
    stain = smoothstep(0.55, 0.85, fbm(size, size, 4, 4, r))
    base = np.array(hexrgb("#e8e2d8"), np.float32)
    alb = base * (tone * (0.95 + 0.08 * grain))[..., None]
    alb *= (1 - 0.07 * stain)[..., None]
    alb = alb * (1 - joint[..., None]) + np.array(hexrgb("#9a948a"), np.float32) * joint[..., None]
    height = np.clip(0.6 - 0.5 * joint + 0.03 * grain, 0, 1)
    ro = np.clip(0.8 + 0.08 * (grain - 0.5) + 0.1 * joint, 0, 1)
    return alb, height, ro


def bake_roof_lig(size: int = ROOF_TILE) -> list:
    r = rng(331)
    tiles = [marseille(r), coppi(r), terrace(r), corrugated(r)]
    strengths = [7.0, 9.0, 3.0, 5.0]
    atlas = np.zeros((2 * size, 2 * size, 3), np.float32)
    det = np.zeros((2 * size, 2 * size, 4), np.float32)
    for k, ((alb, h, ro), s) in enumerate(zip(tiles, strengths)):
        y0, x0 = (k // 2) * size, (k % 2) * size
        atlas[y0:y0 + size, x0:x0 + size] = np.clip(alb, 0, 1)
        nx, ny, _ = normal_xy(h, s)
        det[y0:y0 + size, x0:x0 + size] = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, ro, h], -1)
    save_rgb(OUT / "cj_roof_lig.jpg", atlas, 90)
    save_raw(OUT / "cj_roof_lig_detail.rgbz", det)
    return [atlas]


class Painter:
    """Draws one 3 m facade cell twice: the colour, and the mask that tells
    the wall shader what it may recolour (R render, G shutters and painted
    doors). Coordinates in metres from the cell's lower left, as
    BuildingBuilder.OpeningCut gives them."""

    def __init__(self, rgb: np.ndarray, mask: np.ndarray, ppm: float):
        from PIL import Image, ImageDraw
        self.img = Image.fromarray(to_u8(rgb), "RGB")
        self.mask = Image.fromarray(to_u8(mask), "RGB")
        self.d = ImageDraw.Draw(self.img)
        self.m = ImageDraw.Draw(self.mask)
        self.ppm = ppm
        self.h = rgb.shape[0]

    def box(self, u0, v0, u1, v1):
        p = self.ppm
        return [int(round(u0 * p)), int(round(self.h - v1 * p)), int(round(u1 * p)) - 1, int(round(self.h - v0 * p)) - 1]

    def rect(self, u0, v0, u1, v1, colour, render=0.0, shutter=0.0):
        self.d.rectangle(self.box(u0, v0, u1, v1), fill=tuple(int(c * 255 + 0.5) for c in colour))
        self.m.rectangle(self.box(u0, v0, u1, v1), fill=(int(render * 255), int(shutter * 255), 0))

    def ellipse(self, u0, v0, u1, v1, colour, render=0.0, shutter=0.0):
        self.d.ellipse(self.box(u0, v0, u1, v1), fill=tuple(int(c * 255 + 0.5) for c in colour))
        self.m.ellipse(self.box(u0, v0, u1, v1), fill=(int(render * 255), int(shutter * 255), 0))

    def arrays(self):
        return np.asarray(self.img, np.float32) / 255, np.asarray(self.mask, np.float32) / 255


# The shutters and painted doors are baked a neutral grey-green with their
# louvre shading; the shader paints them by luminance (WorldShaders
# `rivieraWallSurface`, `shutterRef`).
SHUTTER_GREY = (0.42, 0.45, 0.43)
GLASS_TOP = np.array([70, 82, 96], np.float32) / 255
GLASS_LOW = np.array([30, 38, 50], np.float32) / 255


def glass(p: Painter, u0, v0, u1, v1, rr):
    """Dark window glass with a sky reflection fading down it (the wall
    shader turns dark bluish texels smooth), and a curtain or the dim room
    behind on some."""
    rows = max(int((v1 - v0) * p.ppm), 1)
    for k in range(rows):
        t = k / rows
        c = GLASS_TOP * (1 - t) + GLASS_LOW * t
        v = v1 - (k + 1) / p.ppm
        p.rect(u0, v, u1, v + 1 / p.ppm, tuple(c))
    if rr.random() < 0.5:
        cw = (u1 - u0) * rr.uniform(0.15, 0.3)
        cv = rr.uniform(0.72, 0.9)
        p.rect(u0, v0, u0 + cw, v1, (cv, cv * 0.97, cv * 0.92))


def louvres(p: Painter, u0, v0, u1, v1, pitch=0.045):
    """A louvred shutter leaf: a frame, then slats every `pitch` metres,
    each lit along its top and shaded under it."""
    g = np.array(SHUTTER_GREY, np.float32)
    p.rect(u0, v0, u1, v1, tuple(g * 0.8), shutter=1)
    f = 0.035
    v = v0 + f
    while v + pitch <= v1 - f:
        p.rect(u0 + f, v, u1 - f, v + pitch * 0.55, tuple(g * 1.12), shutter=1)
        p.rect(u0 + f, v + pitch * 0.55, u1 - f, v + pitch, tuple(g * 0.62), shutter=1)
        v += pitch
    # A middle rail on tall leaves.
    if v1 - v0 > 1.0:
        mid = (v0 + v1) / 2
        p.rect(u0 + f, mid - 0.03, u1 - f, mid + 0.03, tuple(g * 0.9), shutter=1)


def persiane(p: Painter, u0, v0, u1, v1, open_share=0.0, rr=None):
    """A pair of persiane in an opening: both leaves closed, or the right
    one opened (`open_share` of its width shows the glass behind)."""
    mid = (u0 + u1) / 2
    louvres(p, u0, v0, mid, v1)
    if open_share > 0:
        g0 = u1 - (u1 - mid) * open_share
        glass(p, g0, v0, u1, v1, rr)
        louvres(p, mid, v0, g0, v1)
    else:
        louvres(p, mid, v0, u1, v1)
    p.rect(mid - 0.008, v0, mid + 0.008, v1, tuple(np.array(SHUTTER_GREY) * 0.45), shutter=1)


def tapparella(p: Painter, u0, v0, u1, v1, lowered: float, rr, colour):
    """A window in an anodised aluminium frame with its roll shutter
    (tapparella) let down `lowered` of the way: plastic slats 5 cm high."""
    alu = (0.55, 0.53, 0.5)
    p.rect(u0, v0, u1, v1, alu)
    f = 0.05
    glass(p, u0 + f, v0 + f, u1 - f, v1 - f, rr)
    p.rect((u0 + u1) / 2 - 0.02, v0 + f, (u0 + u1) / 2 + 0.02, v1 - f, alu)
    top = v1 - f
    bottom = top - (v1 - v0 - 2 * f) * lowered
    c = np.array(colour, np.float32)
    v = top
    while v - 0.05 >= bottom:
        p.rect(u0 + f, v - 0.05, u1 - f, v, tuple(c * 1.05))
        p.rect(u0 + f, v - 0.05, u1 - f, v - 0.042, tuple(c * 0.72))
        v -= 0.05
    p.rect(u0 + f, bottom - 0.03, u1 - f, bottom, tuple(c * 0.6))


def sill(p: Painter, u0, u1, v, colour=(0.86, 0.85, 0.82)):
    """A projecting stone or marble sill, its shadow under it."""
    p.rect(u0, v - 0.06, u1, v, colour)
    p.rect(u0 + 0.02, v - 0.09, u1 - 0.02, v - 0.06, (0.55, 0.53, 0.5), render=0.6)


def grille(p: Painter, u0, v0, u1, v1):
    """A black iron window grille: bars every 12 cm and two rails."""
    k = u0 + 0.06
    while k < u1 - 0.04:
        p.rect(k - 0.008, v0, k + 0.008, v1, (0.06, 0.06, 0.065))
        k += 0.12
    for v in (v0 + 0.12, v1 - 0.12):
        p.rect(u0, v - 0.012, u1, v + 0.012, (0.06, 0.06, 0.065))


def bake_facade_lig(size: int = 2048) -> list:
    """cj_facade_lig.jpg and cj_facade_lig_mask.rgbz (see the module notes)."""
    r = rng(341)
    cell = size // 4
    ppm = cell / 3.0
    atlas = np.zeros((size, size, 3), np.float32)
    masks = np.zeros((size, size, 3), np.float32)
    render = np.array(hexrgb("#ebe5d9"), np.float32)
    for row in range(4):
        rr = rng(350 + row)
        grain = fbm(cell, cell, 48, 4, rr)
        trowel = fbm(cell, cell, 6, 4, rr)
        streak = fbm(cell, cell, 4, 3, rr, aspect=6.0)
        mask = np.zeros((cell, cell, 3), np.float32)
        if row < 3:
            # Lime render: fine grain, trowel-swept clouds, faint run-off
            # streaks; the shader colours it per building.
            base = render * (0.97 + 0.06 * (grain - 0.5) + 0.05 * (trowel - 0.5))[..., None]
            base *= (0.95 + 0.06 * streak)[..., None]
            mask[..., 0] = 1
            if row == 2:
                # Old render worn through to rubble in patches: honey and
                # grey sandstone in loose courses with dark joints.
                patch = smoothstep(0.66, 0.74, fbm(cell, cell, 3, 4, rr) * 0.7 + grain * 0.3)
                stones = fbm(cell, cell, 24, 2, rr)
                yy, xx = np.mgrid[0:cell, 0:cell].astype(np.float32)
                course = np.floor(yy / (0.22 * ppm))
                sx = (xx / (0.4 * ppm) + course * 0.5) % 1.0
                sy = (yy / (0.22 * ppm)) % 1.0
                joint = 1 - smoothstep(0.0, 0.08, np.minimum(np.minimum(sx, 1 - sx), np.minimum(sy, 1 - sy)) * 2.5)
                stone = np.stack([0.66 + 0.14 * stones, 0.58 + 0.12 * stones, 0.45 + 0.1 * stones], -1)
                stone = stone * (1 - 0.55 * joint[..., None])
                base = base * (1 - patch[..., None]) + stone * patch[..., None]
                # The rim of the render round a patch, a little proud and pale.
                rim = smoothstep(0.55, 0.66, fbm(cell, cell, 3, 4, rng(360)) * 0.7 + grain * 0.3) * (1 - patch)
                base *= (1 + 0.04 * rim)[..., None]
                mask[..., 0] = 1 - patch
        else:
            # Board-marked concrete: grey, the boards' grain and joints every
            # 15 cm, tie holes, darker run-off.
            yy, xx = np.mgrid[0:cell, 0:cell].astype(np.float32)
            board = (yy / (0.15 * ppm)) % 1.0
            bj = 1 - smoothstep(0.0, 0.06, np.minimum(board, 1 - board))
            wood = fbm(cell, cell, 64, 3, rr, aspect=0.08)
            base = np.array(hexrgb("#a49d92"), np.float32) * (0.92 + 0.1 * grain + 0.05 * wood)[..., None]
            base *= (1 - 0.12 * bj)[..., None] * (0.9 + 0.12 * streak)[..., None]
            for ty in (0.5, 1.25, 2.0, 2.75):
                for tx in (0.375, 1.125, 1.875, 2.625):
                    cy, cx = int(cell - ty * ppm), int(tx * ppm)
                    base[cy - 3:cy + 3, cx - 3:cx + 3] *= 0.55
        for col in range(4):
            p = Painter(base, mask, ppm)
            if row == 0:
                surround = (0.97, 0.96, 0.93)
                if col == 0:
                    # Upper window: persiane closed (now and then one leaf
                    # ajar) in a painted band, a stone sill.
                    p.rect(0.87, 0.89, 2.13, 2.47, surround, render=0.35)
                    persiane(p, 0.99, 0.95, 2.01, 2.33, open_share=0.0)
                    sill(p, 0.9, 2.1, 0.95)
                elif col == 1:
                    # Ground window: open, behind an iron grille.
                    p.rect(0.87, 0.94, 2.13, 2.52, surround, render=0.35)
                    glass(p, 0.99, 1.0, 2.01, 2.38, rr)
                    p.rect(1.48, 1.0, 1.52, 2.38, (0.9, 0.89, 0.86))
                    grille(p, 0.99, 1.0, 2.01, 2.38)
                    sill(p, 0.9, 2.1, 1.0)
                elif col == 2:
                    # Door: a panelled leaf the colour of the shutters, a
                    # fanlight, a stone step; a small shuttered window.
                    p.rect(0.6, 0.0, 1.67, 2.31, surround, render=0.35)
                    p.rect(0.7, 0.08, 1.57, 2.2, tuple(np.array(SHUTTER_GREY) * 0.85), shutter=1)
                    for v0, v1 in ((0.25, 1.0), (1.15, 1.75)):
                        for u0, u1 in ((0.8, 1.1), (1.17, 1.47)):
                            p.rect(u0, v0, u1, v1, tuple(np.array(SHUTTER_GREY) * 0.7), shutter=1)
                    glass(p, 0.8, 1.88, 1.47, 2.12, rr)
                    p.rect(0.6, 0.0, 1.67, 0.08, (0.7, 0.69, 0.66))
                    p.rect(2.03, 0.98, 2.75, 2.16, surround, render=0.35)
                    persiane(p, 2.11, 1.03, 2.67, 2.08)
                    sill(p, 2.05, 2.73, 1.03)
            elif row == 1:
                shade = [(0.62, 0.6, 0.55), (0.45, 0.34, 0.25), (0.7, 0.68, 0.64)][col % 3]
                if col == 0:
                    tapparella(p, 0.95, 0.9, 2.05, 2.4, 0.62, rr, shade)
                    sill(p, 0.88, 2.12, 0.9, (0.9, 0.9, 0.88))
                elif col == 1:
                    tapparella(p, 0.95, 0.95, 2.05, 2.45, 0.35, rr, shade)
                    grille(p, 1.0, 1.0, 2.0, 2.4)
                    sill(p, 0.88, 2.12, 0.95, (0.9, 0.9, 0.88))
                elif col == 2:
                    # A bronze-anodised aluminium entrance door, glazed, in
                    # a marble surround; a frosted bathroom window.
                    p.rect(0.6, 0.0, 1.67, 2.31, (0.88, 0.87, 0.84))
                    p.rect(0.7, 0.06, 1.57, 2.2, (0.3, 0.24, 0.17))
                    glass(p, 0.78, 0.9, 1.49, 2.1, rr)
                    p.rect(0.78, 0.14, 1.49, 0.8, (0.36, 0.29, 0.21))
                    p.rect(0.6, 0.0, 1.67, 0.06, (0.75, 0.74, 0.71))
                    p.rect(2.09, 1.0, 2.69, 2.1, (0.55, 0.53, 0.5))
                    p.rect(2.13, 1.04, 2.65, 2.06, (0.74, 0.76, 0.76))
                    sill(p, 2.05, 2.73, 1.0, (0.9, 0.9, 0.88))
            elif row == 2:
                surround = (0.93, 0.88, 0.76)
                if col == 0:
                    # Persiane in a painted stone surround with a cornice.
                    p.rect(0.87, 0.89, 2.13, 2.47, surround, render=0.5)
                    p.rect(0.87, 2.33, 2.13, 2.47, (0.85, 0.8, 0.68), render=0.5)
                    persiane(p, 1.0, 0.95, 2.0, 2.26, open_share=0.45, rr=rr)
                    sill(p, 0.9, 2.1, 0.95, (0.74, 0.72, 0.66))
                elif col == 1:
                    p.rect(0.87, 0.94, 2.13, 2.52, (0.72, 0.68, 0.6))
                    glass(p, 1.0, 1.04, 2.0, 2.38, rr)
                    grille(p, 1.0, 1.04, 2.0, 2.38)
                    sill(p, 0.9, 2.1, 1.04, (0.7, 0.68, 0.62))
                elif col == 2:
                    # An arched timber door in a stone surround.
                    p.rect(0.6, 0.0, 1.67, 2.31, (0.74, 0.7, 0.62))
                    p.rect(0.72, 0.06, 1.55, 1.78, (0.3, 0.2, 0.13), shutter=0.6)
                    p.ellipse(0.72, 1.36, 1.55, 2.2, (0.3, 0.2, 0.13), shutter=0.6)
                    for k in range(1, 6):
                        u = 0.72 + 0.83 * k / 6
                        p.rect(u - 0.006, 0.06, u + 0.006, 1.9, (0.2, 0.13, 0.08), shutter=0.6)
                    p.rect(0.6, 0.0, 1.67, 0.06, (0.6, 0.58, 0.54))
                    p.rect(2.03, 0.98, 2.75, 2.16, surround, render=0.5)
                    persiane(p, 2.11, 1.03, 2.67, 2.08)
                    sill(p, 2.05, 2.73, 1.03, (0.74, 0.72, 0.66))
            else:
                if col == 0:
                    p.rect(1.0, 1.6, 2.0, 2.4, (0.3, 0.31, 0.32))
                    glass(p, 1.05, 1.65, 1.95, 2.35, rr)
                    p.rect(1.48, 1.65, 1.52, 2.35, (0.3, 0.31, 0.32))
                elif col == 1:
                    p.rect(0.95, 1.0, 2.05, 2.4, (0.3, 0.31, 0.32))
                    glass(p, 1.0, 1.05, 2.0, 2.35, rr)
                    grille(p, 1.0, 1.05, 2.0, 2.35)
                elif col == 2:
                    p.rect(0.62, 0.0, 1.65, 2.25, (0.4, 0.42, 0.42))
                    p.rect(0.66, 0.04, 1.61, 2.21, (0.48, 0.5, 0.49))
                    p.rect(1.45, 1.0, 1.55, 1.08, (0.2, 0.2, 0.2))
                    p.rect(2.15, 1.5, 2.65, 2.1, (0.3, 0.31, 0.32))
                    glass(p, 2.19, 1.54, 2.61, 2.06, rr)
            rgb, msk = p.arrays()
            y0, x0 = row * cell, col * cell
            atlas[y0:y0 + cell, x0:x0 + cell] = rgb
            masks[y0:y0 + cell, x0:x0 + cell] = msk
    save_rgb(OUT / "cj_facade_lig.jpg", atlas, 88)
    small = masks.reshape(size // 2, 2, size // 2, 2, 3).mean(axis=(1, 3))
    save_raw(OUT / "cj_facade_lig_mask.rgbz",
             np.concatenate([small[..., :2], np.zeros_like(small[..., :1]), np.ones_like(small[..., :1])], -1))
    return [atlas, masks]


BAKERS = {"roof": bake_roof, "grime": bake_grime, "roof_lig": bake_roof_lig, "facade_lig": bake_facade_lig}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma-separated subset of " + ",".join(BAKERS))
    ap.add_argument("--preview", default="", help="also write the colour images here as PNG")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    for n in [n for n in args.only.split(",") if n] or list(BAKERS):
        t = time.time()
        images = BAKERS[n]()
        if args.preview:
            d = Path(args.preview)
            d.mkdir(parents=True, exist_ok=True)
            from PIL import Image
            for k, img in enumerate(images):
                Image.fromarray((np.clip(img, 0, 1) * 255).astype(np.uint8)).save(d / f"{n}_{k}.png")
        print(f"{n}: {time.time() - t:.1f} s", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
