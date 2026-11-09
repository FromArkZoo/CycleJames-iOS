# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the surface detail of the Riviera's roadside walls.

    uv run --script scripts/courses/textures/bake_roadside.py [--out DIR] [--preview DIR]

Procedural like bake_materials.py and bake_buildings.py (no photos, no
downloaded assets); output goes to CycleJames/Resources/CourseTextures/.

Two data textures, each a tileable 1 m x 1 m tile at 512 px/m:
  cj_stone_lig_detail.rgbz, a dressed stone face: the hand-squared Sanremo
    sandstone of the SP55's retaining walls (look.md section 3:
    rough-squared blocks, pitted and chisel-bumped, iron-stained here and
    there), also the grey squared stone and the terraces' rubble;
  cj_concrete_lig_detail.rgbz, cast concrete: copings, parapets, precast
    blocks and render, fine aggregate pits and pores over a gentle
    float-finish wave.
Channels: R, G = normal x, y (+x along u, +y down the tile) at the face's
real slopes, B = cavity (1 on the face, lower in pits, pores and hollows),
A = mottle (0-1: weathering and staining from a whole stone's down to its
speckle, which the shader turns into tone).

The block layout itself, the joints, the colours and the weeds are drawn
by WorldShaders.masonrySurface at run time, so no course of stones repeats
with the tile; the tile only gives each stone a surface.
"""
from __future__ import annotations

import argparse
from pathlib import Path

import numpy as np

import texlib as T

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "CycleJames/Resources/CourseTextures"
PX = 512                      # pixels per metre, one tile


MM = 1000.0 / PX              # millimetres per pixel


def scallops(n: int, r: np.random.Generator, power: float) -> np.ndarray:
    """Shallow bowls meeting in ridges, n to the tile: 0 at each bowl's
    middle, 1 on the ridges, each bowl its own depth."""
    f1, f2, ids = T.voronoi(PX, PX, n, r)
    depth = (0.35 + 0.65 * r.random(n)).astype(np.float32)
    return (np.clip(f1 / (0.5 * (f1 + f2) + 1e-6), 0, 1) ** power * depth[ids]).astype(np.float32)


def relief(height_mm: np.ndarray, pits: np.ndarray, mottle: np.ndarray) -> tuple[np.ndarray, ...]:
    """Normal, cavity and mottle from a height in millimetres: the normal
    at the face's true slopes, the cavity where the face lies under its
    surroundings (within a centimetre) and in its pits."""
    h = height_mm / MM
    nx, ny, _ = T.normal_xy(h, 1.0)
    rel = h - T.blur(h, 5.0)
    cavity = np.clip(0.84 + rel * 0.2, 0.25, 1.0) * (0.55 + 0.45 * pits)
    lo, hi = np.percentile(mottle, 1), np.percentile(mottle, 99)
    return nx, ny, cavity.astype(np.float32), np.clip((mottle - lo) / (hi - lo), 0, 1).astype(np.float32)


def stone(r: np.random.Generator) -> tuple[np.ndarray, ...]:
    """A rough-dressed sandstone face, at its real relief: lumps a hand
    across, the scallops the punch and the pitching tool left (5 cm, and
    finer ones of 2-3 cm) with ridges between them, the stone's bedding
    showing in places as fine level ridges, grain, and scattered pits. A
    millimetre of relief every centimetre: in a raking sun each stone has
    a lit and a shaded side to every bump. The mottle carries staining at
    three scales, from the weathering of a whole stone down to its speckle."""
    lumps = T.fbm(PX, PX, 4, 4, r, gain=0.5)
    chips = scallops(420, r, 1.6)
    fine = scallops(1500, r, 1.4)
    yy = (np.arange(PX, dtype=np.float32)[:, None] + 0.5) / PX
    warp = T.fbm(PX, PX, 3, 3, r) * 0.05 + T.fbm(PX, PX, 9, 2, r) * 0.012
    beds = 0.5 + 0.5 * np.sin((yy + warp) * (2 * np.pi * 34))
    bedded = T.smoothstep(0.5, 0.75, T.fbm(PX, PX, 4, 3, r))
    grain = T.fbm(PX, PX, 128, 2, r)
    f1, _, ids = T.voronoi(PX, PX, 300, r)
    pits = np.where((r.random(300) < 0.4)[ids], T.smoothstep(0.0, 3.0, f1), 1.0)
    # (The scallops' ridges rounded over a couple of millimetres: weathered,
    # not freshly broken.)
    height = lumps * 7.0 + T.blur(chips * 3.2 + fine * 1.3, 0.9) + beds * bedded * 0.9 + grain * 0.5 + pits * 2.2
    mottle = 0.5 * T.fbm(PX, PX, 3, 4, r, gain=0.6) + 0.3 * T.fbm(PX, PX, 14, 3, r) + 0.2 * T.fbm(PX, PX, 70, 2, r)
    return relief(height, pits, mottle)


def concrete(r: np.random.Generator) -> tuple[np.ndarray, ...]:
    """Cast concrete, weathered: a float-finish wave, the aggregate's
    fines washed out to a sandpaper grain, dense pores and blow-holes, the
    shutter boards' joints faint across it."""
    wave = T.fbm(PX, PX, 6, 4, r, gain=0.5)
    f1, _, ids = T.voronoi(PX, PX, 900, r)
    pores = np.where((r.random(900) < 0.45)[ids], T.smoothstep(0.0, 2.6, f1), 1.0)
    sand = scallops(2600, r, 1.2)
    grit = T.fbm(PX, PX, 128, 2, r, gain=0.5)
    height = wave * 3.0 + pores * 1.6 + sand * 0.7 + grit * 0.45
    mottle = 0.55 * T.fbm(PX, PX, 4, 4, r, gain=0.6) + 0.3 * T.fbm(PX, PX, 18, 3, r) + 0.15 * T.fbm(PX, PX, 80, 2, r)
    return relief(height, pores, mottle)


def bake(out: Path, preview: Path | None) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for name, (nx, ny, cavity, mottle) in [("cj_stone_lig_detail", stone(T.rng(4101))),
                                          ("cj_concrete_lig_detail", concrete(T.rng(4102)))]:
        data = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, cavity, mottle], -1).astype(np.float32)
        T.save_raw(out / f"{name}.rgbz", data)
        print(f"{name}.rgbz: {PX} x {PX}, cavity mean {cavity.mean():.3f}, normal xy rms {float(np.sqrt((nx ** 2 + ny ** 2).mean())):.3f}, "
              f"mottle mean {mottle.mean():.3f}")
        if preview:
            preview.mkdir(parents=True, exist_ok=True)
            shade = np.clip(0.5 + (data[..., 0] - 0.5) * 1.6 - (data[..., 1] - 0.5) * 1.6, 0, 1) * cavity
            T.save_gray(preview / f"{name}_shade.png", shade)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description="Bake the Riviera roadside walls' surface detail.")
    ap.add_argument("--out", type=Path, default=OUT)
    ap.add_argument("--preview", type=Path, default=None)
    a = ap.parse_args()
    bake(a.out, a.preview)
