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
Channels: R, G = normal x, y (+x along u, +y down the tile), B = cavity
(1 on the face, lower in pits and pores), A = mottle (0-1, low frequency:
weathering and staining, which the shader turns into tone).

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


def stone(r: np.random.Generator) -> tuple[np.ndarray, ...]:
    """A dressed sandstone face: bumps from the punch and pitching tool a
    few centimetres across, finer grain, scattered pits."""
    bumps = T.fbm(PX, PX, 10, 5, r, gain=0.55)
    grain = T.fbm(PX, PX, 64, 3, r, gain=0.5)
    f1, f2, _ = T.voronoi(PX, PX, 260, r)
    pits = T.smoothstep(0.0, 3.5, f1)            # small round pits, 1-3 px deep
    keep = r.random(260) < 0.35                  # only some sites are pits
    _, _, ids = T.voronoi(PX, PX, 260, r)
    pits = np.where(keep[ids], pits, 1.0)
    height = bumps * 6.0 + grain * 1.2 + pits * 2.0
    nx, ny, _ = T.normal_xy(height, 0.35)
    cavity = 0.55 + 0.45 * pits * T.smoothstep(0.15, 0.6, bumps)
    mottle = T.fbm(PX, PX, 3, 4, r, gain=0.6)
    return nx, ny, cavity, mottle


def concrete(r: np.random.Generator) -> tuple[np.ndarray, ...]:
    """Cast concrete: dense pores and aggregate pits, a float-finish wave."""
    wave = T.fbm(PX, PX, 6, 4, r, gain=0.5)
    f1, _, ids = T.voronoi(PX, PX, 900, r)
    pore = r.random(900) < 0.45
    pores = np.where(pore[ids], T.smoothstep(0.0, 2.2, f1), 1.0)
    grit = T.fbm(PX, PX, 128, 2, r, gain=0.5)
    height = wave * 2.5 + pores * 1.5 + grit * 0.6
    nx, ny, _ = T.normal_xy(height, 0.3)
    cavity = 0.62 + 0.38 * pores
    mottle = T.fbm(PX, PX, 4, 4, r, gain=0.6)
    return nx, ny, cavity, mottle


def bake(out: Path, preview: Path | None) -> None:
    out.mkdir(parents=True, exist_ok=True)
    for name, (nx, ny, cavity, mottle) in [("cj_stone_lig_detail", stone(T.rng(4101))),
                                          ("cj_concrete_lig_detail", concrete(T.rng(4102)))]:
        data = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, cavity, mottle], -1).astype(np.float32)
        T.save_raw(out / f"{name}.rgbz", data)
        print(f"{name}.rgbz: {PX} x {PX}, cavity mean {cavity.mean():.3f}")
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
