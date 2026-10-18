# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the per-course ground maps for the 3D world.

    uv run --script scripts/courses/textures/bake_course_maps.py koppenberg

Reads the baked course folder (course.json, canopy_near.u16, scenery.json)
and the raw aerial photo ortho_near.jpg, which build_course.py keeps out of
the app in scripts/courses/pipeline/<id>/, and writes, into
CycleJames/Resources/CourseTextures/:

  <id>_ortho_ground.jpg  the summer aerial photo with what the 3D scene draws
                         itself taken out: tree crowns and roofs are filled
                         from the surrounding ground, and the photo's own
                         shadows (cast by a midday sun from the south) are
                         lifted, so the scene's late-afternoon sun from the
                         south-west is the only one you see. Same size and
                         footprint as ortho_near.jpg.
  <id>_splat.rgbz        1 px per near-grid cell: weights of the four tiled
                         ground details the terrain shader blends:
                         R grass, G crops / stubble, B leaf litter and soil,
                         A gravel and paving. They sum to 1.

Both are read by CycleJames/Courses/Scene/World/WorldMaterials.swift.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import binary_dilation, gaussian_filter, zoom

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "CycleJames/Resources/CourseTextures"


def load_u16(path: Path, hdr: dict) -> np.ndarray:
    raw = np.fromfile(path, dtype="<u2").reshape(hdr["rows"], hdr["cols"]).astype(np.float32)
    out = hdr["baseM"] + raw / 100
    out[raw == 65535] = np.nan
    return out


def normalized_blur(img: np.ndarray, valid: np.ndarray, sigma: float) -> tuple[np.ndarray, np.ndarray]:
    w = gaussian_filter(valid.astype(np.float32), sigma)
    if img.ndim == 3:
        num = np.stack([gaussian_filter(img[..., c] * valid, sigma) for c in range(img.shape[2])], -1)
        return num / np.maximum(w, 1e-4)[..., None], w
    return gaussian_filter(img * valid, sigma) / np.maximum(w, 1e-4), w


def inpaint(rgb: np.ndarray, hole: np.ndarray, sigmas=(3, 6, 12, 24, 48)) -> np.ndarray:
    """Fills `hole` pixels from the surrounding valid ones, finest scale
    first."""
    out = rgb.copy()
    valid = (~hole).astype(np.float32)
    filled = ~hole
    for s in sigmas:
        est, w = normalized_blur(rgb, valid, s)
        take = (~filled) & (w > 0.15)
        out[take] = est[take]
        filled |= take
    est, _ = normalized_blur(rgb, valid, 96)
    out[~filled] = est[~filled]
    return out


def dehaze(rgb: np.ndarray) -> np.ndarray:
    """Takes out the aerial photo's haze and flare: the darkest pixels, which
    should be near black (deep shadow under trees), carry a bluish veil of
    path radiance, which tints every field mint when the photo is used as
    albedo. Dark-object subtraction in linear light, white kept white."""
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    lum = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    dark = lin[lum < np.percentile(lum, 0.5)].mean(0)
    haze = dark * 0.9
    print("photo haze (linear):", np.round(haze, 4))
    lin = np.clip((lin - haze) / (1 - haze), 0, 1)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1 / 2.4) - 0.055).astype(np.float32)


def main(course_id: str) -> int:
    d = ROOT / "CycleJames/Resources/Courses" / course_id
    course = json.loads((d / "course.json").read_text())
    scenery = json.loads((d / course["scenery"]).read_text()) if course.get("scenery") else {}
    oh = course["ortho"]
    # The raw photo isn't shipped (only the ground photo baked here is);
    # an older course folder may still hold it.
    ortho_path = ROOT / "scripts/courses/pipeline" / course_id / oh["file"]
    if not ortho_path.exists():
        ortho_path = d / oh["file"]
    ortho = (np.asarray(Image.open(ortho_path).convert("RGB")).astype(np.float32) / 255)
    ortho = dehaze(ortho)
    H, W = ortho.shape[:2]
    ppm = W / oh["widthM"]  # pixels per metre
    ch = course["canopy"]
    canopy = load_u16(d / ch["file"], ch)
    canopy = np.nan_to_num(canopy, nan=0.0)
    # Canopy on the ortho grid (same footprint by construction).
    can_o = zoom(canopy, (H / canopy.shape[0], W / canopy.shape[1]), order=1)

    def to_px(e, n):
        return ((e - oh["originEast"]) * ppm, (oh["originNorth"] - n) * ppm)

    # Building footprints, slightly grown for leaning roofs in the photo.
    bmask_img = Image.new("L", (W, H), 0)
    dr = ImageDraw.Draw(bmask_img)
    for b in scenery.get("buildings", []):
        pts = [to_px(p[0], p[1]) for p in b["ring"]]
        if len(pts) >= 3:
            dr.polygon(pts, fill=255)
    bmask = np.asarray(bmask_img) > 0
    bmask = binary_dilation(bmask, iterations=int(1.0 * ppm))

    lum = ortho @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    trees = can_o > 2.5

    # 1. Find the photo's sun by fitting the shadows the canopy model would
    #    cast to the dark patches in the photo (on a 1 m grid, over the
    #    middle of the course), then take those shadows out.
    lum1 = zoom(lum, (canopy.shape[0] / H, canopy.shape[1] / W), order=1)
    bm1 = zoom(bmask.astype(np.float32), (canopy.shape[0] / H, canopy.shape[1] / W), order=0) > 0.5
    ground1 = (canopy < 0.8) & ~bm1

    def cast(can: np.ndarray, az: float, el: float, reach: int = 32) -> np.ndarray:
        """Shadow mask from a height field for a sun at (az, el) degrees."""
        sc, sr = np.sin(np.radians(az)), -np.cos(np.radians(az))  # towards the sun, (col, row)
        tan_el = np.tan(np.radians(el))
        out = np.zeros(can.shape, bool)
        for t in range(1, reach):
            dc, dr = int(round(sc * t)), int(round(sr * t))
            shifted = np.roll(np.roll(can, -dr, 0), -dc, 1)
            out |= shifted > t * tan_el + 0.5
        return out

    r0, r1, c0, c1 = 150, 650, 350, 1150
    sub_c, sub_l, sub_g = canopy[r0:r1, c0:c1], lum1[r0:r1, c0:c1], ground1[r0:r1, c0:c1]
    # Dark ground: well below the local brightness of open ground.
    local, _ = normalized_blur(sub_l, sub_g.astype(np.float32), 12)
    dark_obs = sub_g & (sub_l < 0.72 * local)

    def score(az, el):
        m = cast(sub_c, az, el) & sub_g
        inter = (m & dark_obs).sum()
        union = (m | dark_obs).sum()
        return inter / max(union, 1)

    best = (-1.0, 180.0, 50.0)
    for az in range(90, 271, 10):
        for el in range(30, 71, 5):
            sc_ = score(az, el)
            if sc_ > best[0]:
                best = (sc_, float(az), float(el))
    for az in np.arange(best[1] - 8, best[1] + 9, 4):
        for el in np.arange(max(best[2] - 4, 25), min(best[2] + 5, 75), 2):
            sc_ = score(az, el)
            if sc_ > best[0]:
                best = (sc_, float(az), float(el))
    print(f"photo sun: azimuth {best[1]:.0f}, elevation {best[2]:.0f}, shadow IoU {best[0]:.2f}")
    sh1 = cast(canopy, best[1], best[2]) & ground1
    shadow = zoom(sh1.astype(np.float32), (H / canopy.shape[0], W / canopy.shape[1]), order=1)
    shadow = np.clip(gaussian_filter(shadow, 0.7 * ppm) * 1.3, 0, 1)
    del lum1, bm1, sh1
    ground = (can_o < 0.8) & ~bmask
    lit = ground & (shadow < 0.2)
    dark = ground & (shadow > 0.6)
    sig = 7 * ppm
    lit_col, _ = normalized_blur(ortho, lit.astype(np.float32), sig)
    dark_col, wd = normalized_blur(ortho, dark.astype(np.float32), sig)
    # Treat shadowed ground as a hole filled from the sunlit ground round
    # it, keeping the photo's own fine detail (pixel / local mean).
    dark_l, _ = normalized_blur(lum, dark.astype(np.float32), 2 * ppm)
    detail = np.clip(lum / np.maximum(dark_l, 1e-3), 0.6, 1.6)
    sun_fill = inpaint(ortho, ground & (shadow > 0.3), sigmas=(2 * ppm, 4 * ppm, 8 * ppm, 16 * ppm))
    wgt = (shadow * ground)[..., None]
    lifted = ortho + (sun_fill * detail[..., None] - ortho) * wgt
    del lit_col, dark_col, sun_fill, detail

    # 2. Take out tree crowns and roofs, which the scene draws in 3D. Lone
    #    trees and roofs are filled from the ground round them; inside woods
    #    the floor is the crowns' own colour, darkened and browned.
    hole = binary_dilation(trees, iterations=int(0.8 * ppm)) | bmask
    filled = inpaint(lifted, hole)
    wood = gaussian_filter(trees.astype(np.float32), 6 * ppm)
    forest = np.clip((wood - 0.45) / 0.3, 0, 1)
    floor = ortho * 0.62 + np.array([0.20, 0.17, 0.11], np.float32) * 0.38
    filled = filled + (floor - filled) * (forest * trees)[..., None]
    under = gaussian_filter(binary_dilation(trees, iterations=int(0.5 * ppm)).astype(np.float32), ppm)
    litter = np.array([0.33, 0.29, 0.21], np.float32)
    filled = filled + (filled * 0.85 + litter * 0.15 - filled) * (under * 0.6)[..., None]
    # With the haze gone, a touch more saturation and contrast.
    l = (filled @ np.array([0.2126, 0.7152, 0.0722], np.float32))[..., None]
    filled = l + (filled - l) * 1.1
    filled = 0.5 + (filled - 0.5) * 1.03
    out = np.clip(filled, 0, 1)
    Image.fromarray((out * 255 + 0.5).astype(np.uint8), "RGB").save(OUT / f"{course_id}_ortho_ground.jpg", quality=88, optimize=True)
    print("ortho:", W, "x", H, f"shadow px {float((shadow > 0.5).mean()) * 100:.1f}%, filled {float(hole.mean()) * 100:.1f}%")
    del filled, lifted, ortho, out

    # ---- splat map on the near grid (1 px per cell)
    nh = course["terrain"]["near"]
    R, C = nh["rows"], nh["cols"]
    cell = nh["cellM"]

    def to_cell(e, n):
        return ((e - nh["originEast"]) / cell, (nh["originNorth"] - n) / cell)

    def poly_mask(rings, width=None):
        img = Image.new("L", (C, R), 0)
        g = ImageDraw.Draw(img)
        for ring in rings:
            pts = [to_cell(p[0], p[1]) for p in ring]
            if width is None:
                if len(pts) >= 3:
                    g.polygon(pts, fill=255)
            elif len(pts) >= 2:
                g.line(pts, fill=255, width=max(1, int(round(width / cell))), joint="curve")
        return np.asarray(img, np.float32) / 255

    grass = np.ones((R, C), np.float32)
    crop = np.zeros((R, C), np.float32)
    litter = np.zeros((R, C), np.float32)
    paved = np.zeros((R, C), np.float32)
    by_kind: dict[str, list] = {}
    for l in scenery.get("landuse", []):
        by_kind.setdefault(l["kind"], []).append(l["ring"])
    if "farmland" in by_kind:
        m = poly_mask(by_kind["farmland"])
        crop = np.maximum(crop, m); grass *= 1 - m
    for k in ("forest", "scrub"):
        if k in by_kind:
            m = poly_mask(by_kind[k])
            litter = np.maximum(litter, m * 0.8)
    if "residential" in by_kind:
        m = poly_mask(by_kind["residential"])
        paved = np.maximum(paved, m * 0.15)
    can = canopy
    under_trees = gaussian_filter((can > 3).astype(np.float32), 1.5)
    litter = np.maximum(litter, under_trees * 0.85)
    grass *= 1 - under_trees * 0.6
    crop *= 1 - under_trees
    # Paving round buildings and on side roads (they're in the photo too;
    # this sharpens them up close).
    bm = poly_mask([b["ring"] for b in scenery.get("buildings", [])])
    yard = gaussian_filter(binary_dilation(bm > 0.5, iterations=3).astype(np.float32), 1.0)
    paved = np.maximum(paved, yard * 0.55)
    for rd in scenery.get("roads", []):
        w = rd.get("widthM") or 3.0
        m = poly_mask([rd["points"]], width=w)
        val = 1.0 if rd.get("surface") in ("asphalt", "cobbles", "gravel") else 0.6
        paved = np.maximum(paved, m * val)
        grass *= 1 - m * val; crop *= 1 - m * val
    # The route and its extensions past both ends.
    r = course["route"]
    e = np.array(r["east"]); n = np.array(r["north"])
    d0 = np.array([e[1] - e[0], n[1] - n[0]]); d0 /= np.linalg.norm(d0)
    d1 = np.array([e[-1] - e[-2], n[-1] - n[-2]]); d1 /= np.linalg.norm(d1)
    pre = [[e[0] - d0[0] * t, n[0] - d0[1] * t] for t in (80, 40)]
    post = [[e[-1] + d1[0] * t, n[-1] + d1[1] * t] for t in (40, 80)]
    # Only past the ends: along the route the road mesh covers the ground.
    m = poly_mask([pre + [[e[0], n[0]]], [[e[-1], n[-1]]] + post], width=3.5)
    paved = np.maximum(paved, m)
    grass *= 1 - m; crop *= 1 - m
    total = grass + crop + litter + paved
    rgba = np.stack([grass, crop, litter, paved], -1) / np.maximum(total, 1e-3)[..., None]
    rgba = np.stack([gaussian_filter(rgba[..., k], 0.6) for k in range(4)], -1)
    rgba /= np.maximum(rgba.sum(-1, keepdims=True), 1e-3)
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from texlib import save_raw
    save_raw(OUT / f"{course_id}_splat.rgbz", rgba)
    print("splat:", C, "x", R, "means", [round(float(rgba[..., k].mean()), 3) for k in range(4)])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "koppenberg"))
