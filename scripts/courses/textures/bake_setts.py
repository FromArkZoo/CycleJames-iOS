# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the detail textures of the procedural setts (kasseien).

    uv run --script scripts/courses/textures/bake_setts.py

No sett layout is baked: WorldShaders.settSurface lays every course and
sett out per pixel from the road coordinates, so no stone, course or patch
repeats, and only borrows surface detail from these. Output goes to
CycleJames/Resources/CourseTextures/ (see bake_materials.py for the
conventions; data textures are `.rgbz`, texlib.save_raw).

cj_sett_grain (0.36 m tile, data): the face of a split porphyry sett,
sampled per sett with its own offset, flip or turn and scale. R, G = normal
x, y (+x along u, +y along v); B = albedo factor (0.5 = mean): matrix
mottling, pale feldspar and dark specks; A = height (0..1, about 2.5 mm of
relief), which also roughens each sett's outline.

cj_sett_fill (0.37 m tile, sRGB colour): the sand and grit in the joints,
with small pebbles and darker soil. The setts material's diffuse.

cj_sett_macro (data): R, G = slope of a gentle unevenness of the road
(+-1.2 cm over a few metres), stored as 0.5 + 4 x dh/du, 0.5 + 4 x dh/ds
for the shader's 6.1 m (across) x 14.3 m (along) mapping; B = wear and
damp noise; A = the unevenness height (0 = hollow), also read as a
stone-batch noise at the 41 m mapping.

The stones' colours are not baked here: CycleJames/Courses/Scene/World/
SettFarMap.swift lays them out at run time from the shader's own hashes and
the climb's palette (CourseArt.SettStyle).
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from texlib import (blur, fbm, normal_xy, rng, save_raw, save_rgb, smoothstep,  # noqa: E402
                    value_noise, voronoi)

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "CycleJames/Resources/CourseTextures"


def bake_grain(r: np.random.Generator, n: int = 512) -> None:
    px_m = 0.36 / n
    undul = fbm(n, n, 4, 4, r)                         # broad undulation of a split face
    xtal = fbm(n, n, 64, 3, r)                         # crystal grain
    f1, _, _ = voronoi(n, n, 60, r)                    # shallow conchoidal scallops
    scallop = blur(np.sqrt(np.clip(f1 / (0.025 / px_m), 0, 1)), 3.0)
    # Specks and pits: irregular discs 0.4-1.6 mm across.
    rough_edge = (fbm(n, n, 96, 2, r) - 0.5) * 1.2
    sf1, _, sid = voronoi(n, n, 1400, r)
    srad = (0.0004 + 0.0012 * r.random(1400) ** 2) / px_m
    kind = r.random(1400)
    disc = smoothstep(-0.6, 0.6, srad[sid] - sf1 + rough_edge)
    pale = disc * (kind[sid] < 0.3)
    dark = disc * ((kind[sid] >= 0.3) & (kind[sid] < 0.5))
    pits = disc * ((kind[sid] >= 0.5) & (kind[sid] < 0.62))
    h = 0.62 * undul + 0.2 * scallop + 0.1 * xtal - 0.18 * pits
    h = (h - h.min()) / (h.max() - h.min())
    nx, ny, _ = normal_xy(h, 0.0025 / px_m)
    matrix = fbm(n, n, 10, 4, r)
    lum = 0.5 + 0.17 * (matrix - 0.5) + 0.22 * pale - 0.16 * dark + 0.05 * (h - 0.5) - 0.08 * pits
    save_raw(OUT / "cj_sett_grain.rgbz", np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, np.clip(lum, 0, 1), h], -1))


def bake_fill(r: np.random.Generator, n: int = 512) -> None:
    sand = np.array([0.43, 0.40, 0.345], np.float32)
    soil = np.array([0.26, 0.23, 0.19], np.float32)
    jn = fbm(n, n, 32, 4, r)
    speck = value_noise(n, n, 300, 300, r)
    col = sand[None, None] * (0.78 + 0.36 * jn[..., None]) * (0.86 + 0.28 * speck[..., None])
    soily = smoothstep(0.45, 0.8, fbm(n, n, 8, 3, r))
    col = col + (soil - col) * (0.55 * soily)[..., None]
    # Pebbles 3-7 mm across, random greys, ragged outlines.
    pf1, _, pid = voronoi(n, n, 900, r)
    prad = (0.0015 + 0.002 * r.random(900)) / (0.37 / n)
    pebble = smoothstep(-0.8, 0.8, prad[pid] - pf1 + (fbm(n, n, 64, 2, r) - 0.5) * 3.0)
    pgrey = (0.28 + 0.3 * r.random(900))[pid]
    col = col * (1 - pebble[..., None]) + (pgrey[..., None] * np.array([1.0, 0.98, 0.95])) * pebble[..., None]
    save_rgb(OUT / "cj_sett_fill.jpg", np.clip(col, 0, 1), 90)


def bake_macro(r: np.random.Generator, n: int = 256) -> None:
    du_m, ds_m = 6.1 / n, 14.3 / n
    hm = fbm(n, n, 3, 4, r, gain=0.45)
    hm_m = (hm - 0.5) * 0.024                           # +-1.2 cm
    su = (np.roll(hm_m, -1, 1) - np.roll(hm_m, 1, 1)) / (2 * du_m)
    ss = (np.roll(hm_m, -1, 0) - np.roll(hm_m, 1, 0)) / (2 * ds_m)
    wear = fbm(n, n, 5, 4, r)
    save_raw(OUT / "cj_sett_macro.rgbz", np.clip(np.stack([0.5 + 4 * su, 0.5 + 4 * ss, wear, hm], -1), 0, 1))


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    r = rng(29)
    for name, fn in [("grain", bake_grain), ("fill", bake_fill), ("macro", bake_macro)]:
        t = time.time()
        fn(r)
        print(f"setts {name}: {time.time() - t:.1f} s")


if __name__ == "__main__":
    main()
