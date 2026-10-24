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
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from texlib import fbm, normal_xy, rng, save_raw, save_rgb, smoothstep  # noqa: E402

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


BAKERS = {"roof": bake_roof, "grime": bake_grime}


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
