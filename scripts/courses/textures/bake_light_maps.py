# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the per-course light raster for the 3D world.

    uv run --script scripts/courses/textures/bake_light_maps.py koppenberg [--out DIR]

One course per run (Kwaremont peaks at about 0.6 GB). Writes
<id>_light.rgbz (default into CycleJames/Resources/CourseTextures/) on the
near grid: 1 px per metre, the splat map's footprint, row 0 at the north
edge. A preview (R, G, B as colour) goes to scripts/courses/debug/<id>/,
outside the app bundle. Channels:

  R  sky visibility: the cosine-weighted share of the sky that a
     horizontal receiver 0.3 m above the ground sees (16 azimuths x 7
     elevation bands). Terrain and roofs are opaque; tree crowns are a
     turbid volume (extinction SIGMA per metre) from 40 % of their height
     to the top, hedges and shrubs from 0.3 m. Inside building footprints
     it is filled from the ground around them.
  G  sun visibility for WorldSun (azimuth 232, elevation 34), same
     occluders, blurred 0.6 m: the sun's shade beyond the shadow map.
  B  canopy height above the ground / 40 m (LiDAR).
  A  ground height, (h - zmin) / (zmax - zmin) over the raster, zmin and
     zmax from the same terrain_near.u16.

Read by WorldMaterials+Light (shader argument lightTex: ambient occlusion
on the ground and the road, the baked sun shadow past the shadow map, and
the setts' micro-shadows switched off in shade). 10-60 s per course.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import gaussian_filter

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / "scripts/courses/textures"))
from texlib import save_raw  # noqa: E402

# Keep in step with WorldSun in WorldConfig.swift and bake_materials.py.
SUN_AZIMUTH_DEG = 232.0
SUN_ELEVATION_DEG = 34.0
SIGMA = 0.30          # crown extinction per metre: ~8 m of summer beech passes ~9 %
Z_OBS = 0.3           # receiver height above the ground, m
RISE = 40.0           # a ray is done once it is this far above the receiver
REACH = 300.0         # and at most this far out, m
N_AZ = 16
BANDS = [(0, 8), (8, 16), (16, 26), (26, 38), (38, 52), (52, 68), (68, 90)]
CANOPY_SCALE = 40.0   # B = canopy height / CANOPY_SCALE


def load_u16(path: Path, hdr: dict) -> np.ndarray:
    raw = np.fromfile(path, dtype="<u2").reshape(hdr["rows"], hdr["cols"]).astype(np.float32)
    out = hdr["baseM"] + raw / 100
    out[raw == 65535] = np.nan
    return out


def rasters(course_id: str):
    d = ROOT / "CycleJames/Resources/Courses" / course_id
    course = json.loads((d / "course.json").read_text())
    scenery = json.loads((d / course["scenery"]).read_text()) if course.get("scenery") else {}
    th, ch = course["terrain"]["near"], course["canopy"]
    for k in ("originEast", "originNorth", "cellM", "cols", "rows"):
        assert th[k] == ch[k], f"canopy and terrain footprints differ in {k}"
    dtm = load_u16(d / th["file"], th)
    dtm = np.where(np.isfinite(dtm), dtm, np.nanmin(dtm)).astype(np.float32)
    canopy = np.nan_to_num(load_u16(d / ch["file"], ch), nan=0.0)
    R, C = dtm.shape
    # Roof heights above the ground, rasterised from the GRB footprints.
    img = Image.new("F", (C, R), 0.0)
    dr = ImageDraw.Draw(img)
    for b in scenery.get("buildings", []):
        pts = [((p[0] - th["originEast"]) / th["cellM"], (th["originNorth"] - p[1]) / th["cellM"]) for p in b["ring"]]
        if len(pts) >= 3:
            dr.polygon(pts, fill=float(max(b.get("heightM", 0.0), 2.4)))
    roof = np.asarray(img, np.float32)
    return course, th, dtm, canopy, roof


def occluders(dtm, canopy, roof):
    opaque = dtm + roof
    top = dtm + canopy
    base = dtm + np.where(canopy > 4.0, canopy * 0.4, np.minimum(canopy, 0.3))
    return opaque, top, base, canopy > 0.5


def sky_visibility(dtm, canopy, roof, cell: float) -> np.ndarray:
    R, C = dtm.shape
    opaque, top, base, leafy = occluders(dtm, canopy, roof)
    z0 = dtm + Z_OBS
    s2 = [(math.sin(math.radians(a)) ** 2, math.sin(math.radians(b)) ** 2) for a, b in BANDS]
    weights = np.array([b - a for a, b in s2], np.float32)
    tans = np.array([math.tan(math.asin(math.sqrt((a + b) / 2))) for a, b in s2], np.float32)
    secs = np.sqrt(1 + tans * tans)
    tmax = np.minimum(RISE / tans, REACH)
    # Horizontal steps in cells: every cell to 24 m, then 3 m, then 5 m.
    c = lambda m: max(1, int(round(m / cell)))
    steps = list(range(1, c(24) + 1)) + list(range(c(24) + c(3), c(60), c(3))) + list(range(c(60), c(REACH) + 1, c(5)))
    pad = steps[-1] + 1
    P = lambda a: np.pad(a, pad, mode="edge")
    Po, Pt, Pb, Pl = P(opaque), P(top), P(base), P(leafy)
    sky = np.zeros((R, C), np.float32)
    for k in range(N_AZ):
        az = math.radians((k + 0.5) * 360.0 / N_AZ)
        se, cn = math.sin(az), math.cos(az)
        depth = np.zeros((len(BANDS), R, C), np.float32)
        blocked = np.zeros((len(BANDS), R, C), bool)
        prev = 0.0
        for st in steps:
            t = st * cell
            if t > tmax.max():
                break
            dt, prev = t - prev, t
            dc, drr = int(round(se * st)), int(round(-cn * st))
            sl = (slice(pad + drr, pad + drr + R), slice(pad + dc, pad + dc + C))
            o, tp, bs, lf = Po[sl], Pt[sl], Pb[sl], Pl[sl]
            for b in range(len(BANDS)):
                if t > tmax[b]:
                    continue
                y = z0 + np.float32(t * tans[b])
                blocked[b] |= o > y
                depth[b] += (lf & (y > bs) & (y < tp)) * np.float32(dt * secs[b])
        sky += (weights[:, None, None] * np.exp(-SIGMA * depth) * ~blocked).sum(0)
    sky /= N_AZ
    # The crown straight over the receiver also dims the zenith band.
    over = np.where(leafy & (top > z0), top - np.maximum(base, z0), 0.0)
    sky *= 1 - weights[-1] * (1 - np.exp(-SIGMA * over))
    return np.clip(sky, 0, 1).astype(np.float32)


def sun_visibility(dtm, canopy, roof, cell: float) -> np.ndarray:
    R, C = dtm.shape
    opaque, top, base, leafy = occluders(dtm, canopy, roof)
    z0 = dtm + Z_OBS
    az, tn = math.radians(SUN_AZIMUTH_DEG), math.tan(math.radians(SUN_ELEVATION_DEG))
    se, cn = math.sin(az), math.cos(az)
    n = int(RISE / tn / cell) + 2
    pad = n + 1
    P = lambda a: np.pad(a, pad, mode="edge")
    Po, Pt, Pb, Pl = P(opaque), P(top), P(base), P(leafy)
    depth = np.zeros((R, C), np.float32)
    blocked = np.zeros((R, C), bool)
    for st in range(1, n):
        t = st * cell
        dc, drr = int(round(se * st)), int(round(-cn * st))
        sl = (slice(pad + drr, pad + drr + R), slice(pad + dc, pad + dc + C))
        y = z0 + np.float32(t * tn)
        blocked |= Po[sl] > y
        depth += (Pl[sl] & (y > Pb[sl]) & (y < Pt[sl])) * np.float32(cell * math.sqrt(1 + tn * tn))
    return gaussian_filter((np.exp(-SIGMA * depth) * ~blocked).astype(np.float32), 0.6 / cell)


def fill_footprints(a: np.ndarray, inside: np.ndarray) -> np.ndarray:
    """Inside building footprints (which nothing samples but roofs and
    mips) take the surrounding ground's value."""
    m = ~inside
    num = gaussian_filter(np.where(m, a, 0), 2.0)
    den = gaussian_filter(m.astype(np.float32), 2.0)
    return np.where(m, a, num / np.maximum(den, 1e-3))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("course")
    ap.add_argument("--out", default=str(ROOT / "CycleJames/Resources/CourseTextures"))
    args = ap.parse_args()
    t0 = time.time()
    course, th, dtm, canopy, roof = rasters(args.course)
    cell = th["cellM"]
    sky = fill_footprints(sky_visibility(dtm, canopy, roof, cell), roof > 0)
    sun = sun_visibility(dtm, canopy, roof, cell)
    zmin, zmax = float(dtm.min()), float(dtm.max())
    rgba = np.stack([sky, sun, np.clip(canopy / CANOPY_SCALE, 0, 1), (dtm - zmin) / max(zmax - zmin, 1e-3)], -1)
    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    save_raw(out / f"{args.course}_light.rgbz", rgba)
    # The preview stays out of the bundle (CourseTextures ships as is).
    dbg = ROOT / "scripts/courses/debug" / args.course
    dbg.mkdir(parents=True, exist_ok=True)
    Image.fromarray((np.clip(rgba[..., :3], 0, 1) * 255).astype(np.uint8)).save(dbg / f"{args.course}_light_preview.png")
    # Along the route, for the log.
    r = course["route"]
    s, e, n = np.array(r["s"]), np.array(r["east"]), np.array(r["north"])
    col = ((e - th["originEast"]) / cell).astype(int).clip(0, dtm.shape[1] - 1)
    row = ((th["originNorth"] - n) / cell).astype(int).clip(0, dtm.shape[0] - 1)
    print(f"{args.course}: {dtm.shape[1]} x {dtm.shape[0]}, {time.time() - t0:.1f} s, ground {zmin:.2f}-{zmax:.2f} m")
    for a in range(0, int(s[-1]), 100):
        i = (s >= a) & (s < a + 100)
        if i.any():
            print(f"  s {a:5d}: sky {sky[row[i], col[i]].mean():.2f} (min {sky[row[i], col[i]].min():.2f}), "
                  f"sun {sun[row[i], col[i]].mean():.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
