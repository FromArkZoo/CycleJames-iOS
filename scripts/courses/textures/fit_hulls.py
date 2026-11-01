# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Fit the leaf-card hulls and pick the hedge-core texels for cj_foliage.png.

    uv run --script scripts/courses/textures/fit_hulls.py [path/to/cj_foliage.png]
    uv run --script scripts/courses/textures/fit_hulls.py --med [path/to/cj_foliage_med.png]

Run it after re-baking the foliage atlas (bake_materials.py --only foliage)
and paste its output over the constants in TreeArchetypes.swift; the test
`TreeArchetypeTests.test_hullsEncloseTheirLeaves` fails until they match the
atlas. With `--med`, the same for the Riviera atlas (bake_riviera_plants.py
--only foliage) and the `med*` constants in TreeArchetypes+Riviera.swift,
checked by `test_medHullsEncloseTheirLeaves`.

For each quadrant `TreeArchetype.card` draws (broad, poplar, ivy), in card
units as `card` maps them (-1...1 over the quadrant's inset uv rect, x right,
y up):
- the smallest hexagon found round its leaves (alpha over 0.3, a texel to
  spare), anticlockwise. A hexagon card is about 60 % of the square, so
  fewer fragments are shaded only to be discarded;
- the share of visible texels (alpha 0.42 and over, the leaves' alpha cut)
  outside the new hexagon and outside the one TreeArchetypes.swift holds now.

And the core texel of each quadrant: a leaf at the 35th percentile of the
quadrant's leaf brightness whose 7 x 7 texels are opaque and even in colour.
A clipped hedge's core is drawn with every texture coordinate on its centre
(`VegetationBuilder.buildHedges`), so it takes that leaf's colour at any
distance.
"""
from __future__ import annotations

import math
import re
import sys
from pathlib import Path

import numpy as np
from PIL import Image
from scipy.ndimage import minimum_filter, uniform_filter

ROOT = Path(__file__).resolve().parents[3]
ATLAS = ROOT / "CycleJames/Resources/CourseTextures/cj_foliage.png"
SWIFT = ROOT / "CycleJames/Courses/Scene/World/TreeArchetypes.swift"
ATLAS_MED = ROOT / "CycleJames/Resources/CourseTextures/cj_foliage_med.png"
SWIFT_MED = ROOT / "CycleJames/Courses/Scene/World/TreeArchetypes+Riviera.swift"

# TreeArchetype's quadrants (u0, v0, u1, v1), v down; keep in step.
QUADS = {
    "broad": (0.005, 0.005, 0.495, 0.495),
    "poplar": (0.505, 0.005, 0.995, 0.495),
    "ivy": (0.005, 0.505, 0.495, 0.995),
}


def med_cell(col: int, row: int) -> tuple:
    """A 512 px cell of the 2048 px Riviera atlas, inset 5 px (TreeArchetype.medCell)."""
    i = 5 / 2048
    return (col * 0.25 + i, row * 0.25 + i, (col + 1) * 0.25 - i, (row + 1) * 0.25 - i)


# The Riviera atlas's cells drawn as trimmed cards (TreeArchetype.medHull);
# names as the Swift constants' (`medAleppoHull`, ...).
QUADS_MED = {
    "medAleppo": med_cell(0, 0), "medPinea": med_cell(1, 0), "medOlive": med_cell(2, 0), "medEvergreen": med_cell(3, 0),
    "medCypress": med_cell(0, 1), "medOleander": med_cell(2, 1), "medBougainvillea": med_cell(3, 1),
    "medFan": med_cell(0, 3), "medDeadFan": med_cell(1, 3), "medIceplant": med_cell(2, 3), "medReed": med_cell(3, 3),
}
FIT_ALPHA = 0.3
CUT_ALPHA = 0.42
SIDES = 6


def inside(px: np.ndarray, py: np.ndarray, poly) -> np.ndarray:
    """Points left of every edge of an anticlockwise convex polygon."""
    ok = np.ones_like(px, bool)
    for i in range(len(poly)):
        x0, y0 = poly[i]
        x1, y1 = poly[(i + 1) % len(poly)]
        ok &= (x1 - x0) * (py - y0) - (y1 - y0) * (px - x0) >= -1e-6
    return ok


def fit(px: np.ndarray, py: np.ndarray, texel: float) -> np.ndarray:
    """Hexagon from supporting lines at six evenly spaced directions, turned
    for the least area, a texel outside the outermost points."""
    best = None
    for rot in np.linspace(0, 2 * math.pi / SIDES, 24, endpoint=False):
        angs = rot + np.arange(SIDES) * 2 * math.pi / SIDES
        dirs = np.stack([np.cos(angs), np.sin(angs)], 1)
        d = (np.stack([px, py], 1) @ dirs.T).max(0) + texel
        verts = np.array([np.linalg.solve(np.array([dirs[i], dirs[(i + 1) % SIDES]]),
                                          np.array([d[i], d[(i + 1) % SIDES]])) for i in range(SIDES)])
        verts = np.clip(verts, -1, 1)
        x, y = verts[:, 0], verts[:, 1]
        area = 0.5 * abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1)))
        if best is None or area < best[0]:
            best = (area, verts)
    return best[1]


def current_hulls(swift: Path, quads: dict) -> dict:
    """The hulls the Swift file holds now, by quadrant name."""
    text = swift.read_text() if swift.exists() else ""
    out = {}
    for name in quads:
        m = re.search(rf"static let {name}Hull: \[SIMD2<Float>\] = \[(.*?)\]", text, re.S)
        if m:
            out[name] = [(float(a), float(b)) for a, b in re.findall(r"SIMD2\(([-\d.]+), ([-\d.]+)\)", m.group(1))]
    return out


def main() -> int:
    args = [a for a in sys.argv[1:] if a != "--med"]
    med = "--med" in sys.argv[1:]
    quads, swift = (QUADS_MED, SWIFT_MED) if med else (QUADS, SWIFT)
    path = Path(args[0]) if args else (ATLAS_MED if med else ATLAS)
    im = np.asarray(Image.open(path).convert("RGBA"), np.float32) / 255
    H, W = im.shape[:2]
    a = im[..., 3]
    rgb = np.where(im[..., :3] <= 0.04045, im[..., :3] / 12.92, ((im[..., :3] + 0.055) / 1.055) ** 2.4)
    lum = rgb @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    opaque7 = minimum_filter(a, 7)
    mean7 = uniform_filter(lum, 7)
    sd7 = np.sqrt(np.maximum(uniform_filter(lum * lum, 7) - mean7 * mean7, 0))
    ys, xs = np.mgrid[0:H, 0:W].astype(np.float32)
    U, V = (xs + 0.5) / W, (ys + 0.5) / H
    old = current_hulls(swift, quads)
    for name, (u0, v0, u1, v1) in quads.items():
        sel = (U >= u0) & (U <= u1) & (V >= v0) & (V <= v1)
        tx = (U - u0) / (u1 - u0) * 2 - 1
        ty = (v1 - V) / (v1 - v0) * 2 - 1
        leaves = sel & (a > FIT_ALPHA)
        verts = fit(tx[leaves], ty[leaves], 2.0 / ((u1 - u0) * W))
        visible = sel & (a >= CUT_ALPHA)
        for label, poly in (("now", old.get(name)), ("fitted", [tuple(v) for v in verts])):
            if poly:
                out = visible & ~inside(tx, ty, poly)
                print(f"// {name} {label}: {out.sum()} of {visible.sum()} visible texels outside "
                      f"({100 * out.sum() / visible.sum():.3f} %)")
        x, y = verts[:, 0], verts[:, 1]
        area = 0.5 * abs(np.dot(x, np.roll(y, -1)) - np.dot(y, np.roll(x, -1))) / 4
        print(f"// {name}: the hexagon covers {area:.3f} of the card")
        pts = [f"SIMD2({vx:.3f}, {vy:.3f})" for vx, vy in verts]
        print(f"static let {name}Hull: [SIMD2<Float>] = [\n    {', '.join(pts[:3])},\n    {', '.join(pts[3:])},\n]")
        # The core texel, three texels in from the quadrant's edges.
        inner = sel & (U > u0 + 3 / W) & (U < u1 - 3 / W) & (V > v0 + 3 / H) & (V < v1 - 3 / H)
        target = np.percentile(lum[inner & (a > 0.5)], 35)
        ok = inner & (opaque7 > 0.99) & (sd7 < 0.15 * target + 1e-4)
        if not ok.any():
            print(f"// {name}: no opaque, even 7 x 7 leaf for the core")
            continue
        cost = np.where(ok, np.abs(mean7 - target), np.inf)
        cy, cx = np.unravel_index(np.argmin(cost), cost.shape)
        print(f"static let {name}Core = SIMD2<Float>({(cx + 0.5) / W:.4f}, {(cy + 0.5) / H:.4f})"
              f"  // linear ({', '.join(f'{c:.4f}' for c in rgb[cy, cx])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
