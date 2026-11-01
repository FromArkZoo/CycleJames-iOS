# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the per-course ground maps for the 3D world.

    uv run --script scripts/courses/textures/bake_course_maps.py koppenberg [--out DIR]

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

A course on the coast (course.json "sea") keeps the sea out: the photo's sea
pixels are filled from the land beside them, so the terrain the waterline
cuts shows beach and rock, never painted water (the app draws the sea). The
Riviera (COURSE_OPTS) also bakes at 0.75 m per pixel, synthesises its forest
floor in dry needles and ochre earth instead of beech litter, keeps its
greenhouse roofs and its terraces as photographed, and fits the photo's sun
round the middle of the climb.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import binary_dilation, distance_transform_edt, gaussian_filter, zoom

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "CycleJames/Resources/CourseTextures"

# Per-course settings, all opt-in (the Flemish courses bake as before).
COURSE_OPTS = {
    "poggio": {
        # WorldTextures caps the ground photo at max(width, height) / 0.75 m pixels on the device, so 0.75 m
        # is all the app ever samples (and keeps this bake of a 2 x 1.8 km grid near 1 GB).
        "m_per_px": 0.75,
        "riviera": True,
    },
}
# The Riviera's ground where the photo is filled under trees (look.md section 3, ground cover): dry pine
# needles and ochre earth (#6e5c45) under the woods, straw and ochre-brown earth (#8c7d62) round single
# crowns, instead of the Flemish beech litter.
RIVIERA_FLOOR = np.array([0.43, 0.36, 0.27], np.float32)
RIVIERA_LITTER = np.array([0.55, 0.49, 0.38], np.float32)


def load_u16(path: Path, hdr: dict) -> np.ndarray:
    raw = np.fromfile(path, dtype="<u2").reshape(hdr["rows"], hdr["cols"]).astype(np.float32)
    out = hdr["baseM"] + raw / 100
    out[raw == 65535] = np.nan
    return out


def normalized_blur(img: np.ndarray, valid: np.ndarray, sigma: float) -> tuple[np.ndarray, np.ndarray]:
    w = gaussian_filter(valid.astype(np.float32), sigma)
    if img.ndim == 3:
        # One channel at a time, divided in place: these are full-size.
        num = np.empty(img.shape, np.float32)
        for c in range(img.shape[2]):
            num[..., c] = gaussian_filter(img[..., c] * valid, sigma)
        num /= np.maximum(w, 1e-4)[..., None]
        return num, w
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
        del est, w, take
    est, _ = normalized_blur(rgb, valid, 96)
    out[~filled] = est[~filled]
    return out


def dehaze(rgb: np.ndarray, land: np.ndarray | None = None) -> np.ndarray:
    """Takes out the aerial photo's haze and flare: the darkest pixels, which
    should be near black (deep shadow under trees), carry a bluish veil of
    path radiance, which tints every field mint when the photo is used as
    albedo. Dark-object subtraction in linear light, white kept white. With
    `land`, the dark objects are looked for on land only (deep water is dark
    by its own colour, not by shadow)."""
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    lum = lin @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    if land is None:
        dark = lin[lum < np.percentile(lum, 0.5)].mean(0)
    else:
        dark = lin[land & (lum < np.percentile(lum[land], 0.5))].mean(0)
    haze = dark * 0.9
    print("photo haze (linear):", np.round(haze, 4))
    lin = np.clip((lin - haze) / (1 - haze), 0, 1)
    return np.where(lin <= 0.0031308, lin * 12.92, 1.055 * np.power(lin, 1 / 2.4) - 0.055).astype(np.float32)


def main(course_id: str, out: Path = OUT) -> int:
    d = ROOT / "CycleJames/Resources/Courses" / course_id
    course = json.loads((d / "course.json").read_text())
    scenery = json.loads((d / course["scenery"]).read_text()) if course.get("scenery") else {}
    opts = COURSE_OPTS.get(course_id, {})
    riviera = opts.get("riviera", False)
    oh = course["ortho"]
    # The raw photo isn't shipped (only the ground photo baked here is);
    # an older course folder may still hold it.
    ortho_path = ROOT / "scripts/courses/pipeline" / course_id / oh["file"]
    if not ortho_path.exists():
        ortho_path = d / oh["file"]
    img = Image.open(ortho_path).convert("RGB")
    if opts.get("m_per_px"):
        img = img.resize((int(round(oh["widthM"] / opts["m_per_px"])), int(round(oh["heightM"] / opts["m_per_px"]))),
                         Image.Resampling.BOX)
    ortho = (np.asarray(img).astype(np.float32) / 255)
    del img
    H, W = ortho.shape[:2]
    ppm = W / oh["widthM"]  # pixels per metre
    nh = course["terrain"]["near"]
    sea_px = None
    if course.get("sea"):
        # The sea: near-grid cells the terrain leaves out (at or below levelM - 0.5 m; build_course.py holds
        # levelM - 1 m there, cut along the 2022 coastline), on the photo's pixels.
        dtm = load_u16(d / nh["file"], nh)
        sea_px = zoom((dtm <= course["sea"]["levelM"] - 0.5).astype(np.float32), (H / dtm.shape[0], W / dtm.shape[1]),
                      order=0) > 0.5
        del dtm
        print(f"sea: {float(sea_px.mean()) * 100:.1f}% of the photo")
    ortho = dehaze(ortho) if sea_px is None else dehaze(ortho, ~sea_px)
    ch = course["canopy"]
    canopy = load_u16(d / ch["file"], ch)
    canopy = np.nan_to_num(canopy, nan=0.0)
    # Canopy on the ortho grid (same footprint by construction).
    can_o = zoom(canopy, (H / canopy.shape[0], W / canopy.shape[1]), order=1)

    def to_px(e, n):
        return ((e - oh["originEast"]) * ppm, (oh["originNorth"] - n) * ppm)

    # Building footprints, slightly grown for leaning roofs in the photo. On the Riviera the
    # greenhouses stay in the photo: their glass and film are the white specks of every slope, and
    # the scene draws them only near the road.
    bmask_img = Image.new("L", (W, H), 0)
    dr = ImageDraw.Draw(bmask_img)
    gh_img = Image.new("L", (W, H), 0) if riviera else None
    for b in scenery.get("buildings", []):
        pts = [to_px(p[0], p[1]) for p in b["ring"]]
        if len(pts) >= 3:
            if riviera and b.get("kind") == "greenhouse":
                ImageDraw.Draw(gh_img).polygon(pts, fill=255)
            else:
                dr.polygon(pts, fill=255)
    bmask = np.asarray(bmask_img) > 0
    bmask = binary_dilation(bmask, iterations=int(1.0 * ppm))

    lum = ortho @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    trees = can_o > 2.5
    if riviera:
        # The canopy model is the 2008-2010 LiDAR: crowns felled and greenhouses pulled down since are in
        # it. Take out only what the scene draws in 3D (the scenery's trees, checked against the 2022
        # photo) and canopy that is still green in the photo, never a greenhouse roof.
        tr_img = Image.new("L", (W, H), 0)
        td = ImageDraw.Draw(tr_img)
        for t in scenery.get("trees", []):
            x, y = to_px(t["e"], t["n"])
            r = t["crownRadiusM"] * ppm
            td.ellipse([x - r, y - r, x + r, y + r], fill=255)
        s_ = ortho.sum(-1) + 1e-3
        green = (2 * ortho[..., 1] - ortho[..., 0] - ortho[..., 2]) / s_ > 0.02
        del s_
        gh = binary_dilation(np.asarray(gh_img) > 0, iterations=max(1, int(0.5 * ppm)))
        trees = ((np.asarray(tr_img) > 0) | (trees & green)) & ~gh
        del tr_img, td, green, gh_img
        if sea_px is not None:
            trees &= ~sea_px

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
    if riviera:
        # Route-relative: 500 x 800 m round the middle of the climb (the fixed window above sits on the
        # Flemish grids' middle; on the Poggio's it would be the sea).
        cs = 0.5 * (course["climb"]["startS"] + course["climb"]["endS"])
        rt = course["route"]
        mc = int((np.interp(cs, rt["s"], rt["east"]) - nh["originEast"]) / nh["cellM"])
        mr = int((nh["originNorth"] - np.interp(cs, rt["s"], rt["north"])) / nh["cellM"])
        r0 = int(np.clip(mr - 250, 0, max(canopy.shape[0] - 500, 0))); r1 = r0 + 500
        c0 = int(np.clip(mc - 400, 0, max(canopy.shape[1] - 800, 0))); c1 = c0 + 800
        if sea_px is not None:
            sea1 = zoom(sea_px.astype(np.float32), (canopy.shape[0] / H, canopy.shape[1] / W), order=0) > 0.5
            ground1 &= ~sea1
            del sea1
        print(f"sun fit window: rows {r0}-{r1}, cols {c0}-{c1} (the middle of the climb)")
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
    if sea_px is not None:
        ground &= ~sea_px
    dark = ground & (shadow > 0.6)
    # Treat shadowed ground as a hole filled from the sunlit ground round
    # it, keeping the photo's own fine detail (pixel / local mean).
    dark_l, _ = normalized_blur(lum, dark.astype(np.float32), 2 * ppm)
    detail = np.clip(lum / np.maximum(dark_l, 1e-3), 0.6, 1.6)
    # Full-size arrays are freed as soon as they are done with: the
    # Kwaremont's photo is 13 Mpx.
    del dark_l, dark, lum, can_o
    sun_fill = inpaint(ortho, ground & (shadow > 0.3), sigmas=(2 * ppm, 4 * ppm, 8 * ppm, 16 * ppm))
    wgt = (shadow * ground)[..., None]
    lifted = sun_fill * detail[..., None]
    lifted -= ortho
    lifted *= wgt
    lifted += ortho
    del sun_fill, detail, wgt, ground

    # 2. Take out tree crowns and roofs, which the scene draws in 3D. Lone
    #    trees and roofs are filled from the ground round them; inside woods
    #    the floor is the crowns' own colour, darkened and browned.
    hole = binary_dilation(trees, iterations=int(0.8 * ppm)) | bmask
    filled = inpaint(lifted, hole)
    del lifted, bmask
    wood = gaussian_filter(trees.astype(np.float32), 6 * ppm)
    forest = np.clip((wood - 0.45) / 0.3, 0, 1)
    floor = ortho * 0.62 + (RIVIERA_FLOOR if riviera else np.array([0.20, 0.17, 0.11], np.float32)) * 0.38
    del ortho
    filled = filled + (floor - filled) * (forest * trees)[..., None]
    under = gaussian_filter(binary_dilation(trees, iterations=int(0.5 * ppm)).astype(np.float32), ppm)
    litter = RIVIERA_LITTER if riviera else np.array([0.33, 0.29, 0.21], np.float32)
    filled = filled + (filled * 0.85 + litter * 0.15 - filled) * (under * 0.6)[..., None]
    del wood, forest, floor, under
    # 3. Fields: tramlines and mowing swaths are sharp, regular stripes in
    #    the photo that read as painted bands from road level, magnified
    #    about 50 times. Keep each parcel's colour and its broad patches (a
    #    2.5 m blur) and lose the stripes; the terrain shader's detail
    #    texture gives the texture close up. Hedgerow edges stay sharp.
    # (Not on the Riviera: its stripes are terrace walls and greenhouse rows, which are real.)
    fmask_img = Image.new("L", (W, H), 0)
    fd = ImageDraw.Draw(fmask_img)
    strength = {} if riviera else {"farmland": 230, "meadow": 160, "grass": 110}
    for l in scenery.get("landuse", []):
        k = strength.get(l["kind"])
        if k and len(l["ring"]) >= 3:
            fd.polygon([to_px(p[0], p[1]) for p in l["ring"]], fill=k)
    fmask = np.asarray(fmask_img, np.float32) / 255
    del fmask_img, fd
    fmask *= 1 - gaussian_filter(trees.astype(np.float32), 2 * ppm)
    soft, _ = normalized_blur(filled, (fmask > 0).astype(np.float32), 2.5 * ppm)
    ease = gaussian_filter(fmask, 1.5 * ppm)  # in over about 2 m from a field's edge
    filled = filled + (soft - filled) * ease[..., None]
    print(f"fields de-striped: {float((ease > 0.5).mean()) * 100:.1f}% of the photo")
    del fmask, soft, ease
    # With the haze gone, a touch more saturation and contrast.
    l = (filled @ np.array([0.2126, 0.7152, 0.0722], np.float32))[..., None]
    filled = l + (filled - l) * 1.1
    filled = 0.5 + (filled - 0.5) * 1.03
    if sea_px is not None:
        # The sea out of the photo: each sea pixel takes the nearest land pixel's colour, softened (the
        # shore's sand and rock run on under the waterline the terrain is cut at, and no mip level of
        # the photo mixes water into the beach).
        # The colours come from 6 m inland of the cut, past the photo's surf and wet sand.
        hole_s = binary_dilation(sea_px, iterations=max(1, int(1.0 * ppm)))
        src = ~binary_dilation(sea_px, iterations=max(1, int(6.0 * ppm)))
        _, (ir, ic) = distance_transform_edt(~src, return_indices=True)
        near = filled[ir, ic]
        del ir, ic, src
        for c in range(3):
            near[..., c] = gaussian_filter(near[..., c], 8 * ppm)
        filled[hole_s] = near[hole_s]
        del near, hole_s
    res = np.clip(filled, 0, 1)
    Image.fromarray((res * 255 + 0.5).astype(np.uint8), "RGB").save(out / f"{course_id}_ortho_ground.jpg", quality=88, optimize=True)
    print("ortho:", W, "x", H, f"shadow px {float((shadow > 0.5).mean()) * 100:.1f}%, filled {float(hole.mean()) * 100:.1f}%")
    del filled, res

    # ---- splat map on the near grid (1 px per cell)
    nh = course["terrain"]["near"]
    R, C = nh["rows"], nh["cols"]
    cell = nh["cellM"]

    def to_cell(e, n):
        return ((e - nh["originEast"]) / cell, (nh["originNorth"] - n) / cell)

    def poly_mask(rings, width=None, ss=1):
        """Coverage of the rings (or of lines `width` metres wide); with `ss`, drawn at ss x ss samples a
        cell and averaged, so an edge is a coverage ramp along the true line instead of a 1 m staircase."""
        img = Image.new("L", (C * ss, R * ss), 0)
        g = ImageDraw.Draw(img)
        widths = width if isinstance(width, list) else [width] * len(rings)
        for ring, w_ in zip(rings, widths):
            pts = [to_cell(p[0], p[1]) for p in ring]
            if ss > 1:
                pts = [(x * ss, y * ss) for x, y in pts]
            if w_ is None:
                if len(pts) >= 3:
                    g.polygon(pts, fill=255)
            elif len(pts) >= 2:
                g.line(pts, fill=255, width=max(1, int(round(w_ / cell * ss))), joint="curve")
        m = np.asarray(img, np.float32) / 255
        return m.reshape(R, ss, C, ss).mean(axis=(1, 3)) if ss > 1 else m

    grass = np.ones((R, C), np.float32)
    crop = np.zeros((R, C), np.float32)
    litter = np.zeros((R, C), np.float32)
    paved = np.zeros((R, C), np.float32)
    by_kind: dict[str, list] = {}
    for l in scenery.get("landuse", []):
        by_kind.setdefault(l["kind"], []).append(l["ring"])
    if riviera:
        # Dry grass on terraces and under olives with a little bare earth (crop = stubble and straw,
        # litter = earth and needles), more soil among the greenhouses. Light weights: the photo has the
        # colours, and the terrain shader already gives every steep face (each terrace riser) its earth.
        for k, (cw, lw) in {"terraces": (0.25, 0.1), "farmland": (0.25, 0.1), "olive": (0.2, 0.15),
                             "greenhouse": (0.1, 0.25)}.items():
            if k in by_kind:
                m = poly_mask(by_kind[k])
                crop = np.maximum(crop, m * cw); litter = np.maximum(litter, m * lw)
                grass *= 1 - m * (cw + lw)
        by_kind.pop("farmland", None)
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
    if riviera:
        # Under the trees the scene draws (the canopy model is 2008-2010 and holds greenhouses too).
        ut = Image.new("L", (C, R), 0)
        ud = ImageDraw.Draw(ut)
        for t in scenery.get("trees", []):
            x, y = to_cell(t["e"], t["n"])
            r = t["crownRadiusM"] / cell
            ud.ellipse([x - r, y - r, x + r, y + r], fill=255)
        under_trees = gaussian_filter(np.asarray(ut, np.float32) / 255, 1.5)
        del ut, ud
        litter = np.maximum(litter, under_trees * 0.5)
    else:
        under_trees = gaussian_filter((can > 3).astype(np.float32), 1.5)
        litter = np.maximum(litter, under_trees * 0.85)
    grass *= 1 - under_trees * 0.6
    crop *= 1 - under_trees
    # Paving round buildings and on side roads (they're in the photo too;
    # this sharpens them up close).
    # On the Riviera only round houses and other buildings: greenhouses stand on bare terraces, not in yards.
    bm = poly_mask([b["ring"] for b in scenery.get("buildings", [])
                    if not (riviera and b.get("kind") in ("greenhouse", "cistern"))])
    yard = gaussian_filter(binary_dilation(bm > 0.5, iterations=3).astype(np.float32), 1.0)
    paved = np.maximum(paved, yard * 0.55)
    if riviera:
        # Side roads at 4 x 4 samples a cell, one mask per surface: the drives and lanes that wind over the
        # terraces get edges along their true lines (at 1 px a cell they were 1 m stair-steps).
        for val in (1.0, 0.6):
            rds = [rd for rd in scenery.get("roads", [])
                   if (1.0 if rd.get("surface") in ("asphalt", "cobbles", "gravel") else 0.6) == val]
            if rds:
                m = poly_mask([rd["points"] for rd in rds], width=[rd.get("widthM") or 3.0 for rd in rds], ss=4)
                paved = np.maximum(paved, m * val)
                grass *= 1 - m * val; crop *= 1 - m * val
    for rd in ([] if riviera else scenery.get("roads", [])):
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
    save_raw(out / f"{course_id}_splat.rgbz", rgba)
    print("splat:", C, "x", R, "means", [round(float(rgba[..., k].mean()), 3) for k in range(4)])
    return 0


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("course", nargs="?", default="koppenberg")
    ap.add_argument("--out", type=Path, default=OUT, help="where to write the two maps (default CourseTextures)")
    a = ap.parse_args()
    a.out.mkdir(parents=True, exist_ok=True)
    sys.exit(main(a.course, a.out))
