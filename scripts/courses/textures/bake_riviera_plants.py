# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the Riviera plant textures: the trees, palms, shrubs and verge flora
of the Ligurian coast, for the Poggio di Sanremo.

    uv run --script scripts/courses/textures/bake_riviera_plants.py [--only foliage,impostors,bark,grass] [--preview DIR]

The Riviera look (`WorldLook.riviera`; WorldMaterials+Plants.swift) draws
these in place of bake_materials.py's foliage, impostor, bark and grass
atlases, which stay as they are, so the Flemish climbs keep their look.
Everything is procedural, painted in the colours measured on photos of the
climb in late March (the research look bible, section 3): no photo is traced
or baked in.

Outputs, in CycleJames/Resources/CourseTextures/:
- cj_foliage_med.png, 2048 x 2048, straight alpha: 4 x 4 cells of 512 px,
  each about 1.2 m of foliage unless noted. Row 0: Aleppo pine tufts,
  stone-pine tufts, olive, glossy evergreen (pittosporum, laurel, holm oak).
  Row 1: cypress sprays, a metre of Norfolk Island pine branch (1 m across,
  tileable along u, the axis along the middle), oleander, bougainvillea.
  Row 2, the whole width: one Canary date palm frond, 5 m from its base
  (left) to its tip, 1.25 m across, the rachis along the middle. Row 3: a
  fan-palm leaf (1.5 m, the hastula a little below the middle, the petiole
  down to the bottom edge), a dead fan hanging from the top edge, ice plant
  (1 m), giant reed (4 m, rooted on the bottom edge). Mirrored in
  TreeArchetype's `med*` rectangles (TreeArchetypes+Riviera.swift); fit the
  hulls with `fit_hulls.py --med` after a re-bake.
- cj_impostor_med.png + cj_impostor_med_detail.rgbz: 4 x 2 distant-tree cells
  of 512 px, in the order of `TreeArchetype.Form.impostorCell` for the
  Riviera forms (Aleppo pine, stone pine, cypress, Canary palm and the small
  fan palms, Washingtonia, olive, Norfolk Island pine, holm oak and
  eucalyptus), trunk base at the bottom centre; the detail map as
  cj_impostor_detail's (R, G normal x right, y down; B ambient occlusion).
- cj_bark_med_albedo.jpg + cj_bark_med_detail.rgbz: 4 x 2 tiles of 512 px,
  each 1 m round x 2 m up (the pads and leaves of the succulents: 0.5 m
  square), a 496 px periodic core in an 8 px wrap gutter, which
  `WorldShaders.barkAtlasSurface` samples with fract: stone pine, Aleppo
  pine, Canary palm trunk, Washingtonia trunk, windmill-palm fibre, olive,
  prickly-pear pad, agave leaf. Detail: R, G normal, B roughness, A height.
- cj_grass_med.png, 1024 x 1024: cj_grass.png's layout (`VegetationBuilder.
  GrassCell`) with the Riviera verge in late March: spring grass, grass in
  seed (wild oats), last year's straw tussocks (Hyparrhenia), wild fennel;
  Bermuda buttercup (Oxalis pes-caprae), red valerian, crown daisies,
  acanthus; a spring sward strip with clover and a dry rough one.
"""
from __future__ import annotations

import argparse
import math
import sys
import time
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw
from scipy.ndimage import binary_closing, zoom

sys.path.insert(0, str(Path(__file__).resolve().parent))
from texlib import blur, fbm, normal_xy, rng, save_raw, save_rgb, save_rgba, smoothstep, to_u8, value_noise, voronoi  # noqa: E402
from bake_materials import _blade, _leaf, leaf_shape  # noqa: E402

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "CycleJames/Resources/CourseTextures"
S = 2   # supersampling of the PIL drawings


def hx(h: str) -> np.ndarray:
    """A '#rrggbb' paint colour as sRGB floats."""
    return np.array([int(h[i:i + 2], 16) / 255 for i in (1, 3, 5)], np.float32)


def fill(c, r=None, k: float = 0.0, a: int = 255) -> tuple:
    """A PIL fill from sRGB floats, jittered in brightness by +-k."""
    c = np.asarray(c, np.float32)
    if r is not None and k:
        c = c * r.uniform(1 - k, 1 + k)
    return tuple(int(v) for v in np.clip(c, 0, 1) * 255 + 0.5) + (a,)


def pick(r, pal):
    return pal[int(r.integers(0, len(pal)))]


def finish(img: Image.Image, w: int, h: int, r, border: float = 0.012, noise: float = 0.25) -> np.ndarray:
    """Down-samples a supersampled drawing to w x h RGBA floats, fades the
    alpha off the cell's border (nothing may be cut straight there) and adds
    leaf-scale shading noise. (Sparse needles and leaflets keep their
    coverage down the mip chain in the shader, `mipCoverage`, rather than
    by filling their gaps here, which turned the tufts into blobs.)"""
    arr = np.asarray(img.resize((w, h), Image.LANCZOS), np.float32) / 255
    rgb, a = arr[..., :3], arr[..., 3]
    if border > 0:
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        edge = np.minimum(np.minimum(xx / w, 1 - xx / w), np.minimum(yy / h, 1 - yy / h))
        a = a * smoothstep(border, border * 2.5, edge)
    if noise:
        rgb = rgb * (1 - noise / 2 + noise * fbm(h, w, 32, 3, r)[..., None])
    return np.concatenate([rgb, a[..., None]], -1)


def bleed(atlas: np.ndarray, radius: float = 6) -> np.ndarray:
    """Colour bled into the transparent texels, so mip levels don't darken."""
    rgb, a = atlas[..., :3], atlas[..., 3:]
    blurred = blur(rgb * a, radius) / np.maximum(blur(a, radius), 1e-3)
    out = atlas.copy()
    out[..., :3] = rgb * a + blurred * (1 - a)
    return out


# ---------------------------------------------------------------- leaf cards

def pine_card(size: int, seed: int, kind: str) -> np.ndarray:
    """Pine foliage: shoots ending in shaving-brush tufts of needles on bare
    twigs. Aleppo pine: short (6-10 cm) yellowish grey-green needles in
    separate tufts with sky between; stone pine: long (10-15 cm) dark needles
    in tufts crowded into a mat."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if kind == "aleppo":
        pal = [hx("#4a5a3e"), hx("#56664a"), hx("#3e4c33"), hx("#62704a"), hx("#4d5c36"), hx("#5c6a3c")]
        nl, tufts, per, spread, twig = (0.06, 0.095), 46, 80, 0.31, hx("#5e5044")
    else:
        pal = [hx("#2d3a28"), hx("#34452e"), hx("#263222"), hx("#3d4f33"), hx("#2f3d24"), hx("#455a38")]
        nl, tufts, per, spread, twig = (0.08, 0.125), 80, 80, 0.33, hx("#4a3c30")
    cx, cy = W / 2, W / 2
    tips = []
    for _ in range(tufts):
        ang = r.uniform(0, 2 * math.pi)
        rad = math.sqrt(r.uniform(0.0, 1.0)) * spread * W
        lobe = 0.8 + 0.14 * math.sin(3 * ang + seed) + 0.08 * math.sin(5 * ang + 2 * seed)
        tips.append((cx + math.cos(ang) * rad * lobe, cy + math.sin(ang) * rad * lobe * 0.88, ang))
    # A few bare twigs into the clump, and each tuft's shoot pointing out
    # from its middle (seen in the gaps between the tufts).
    base = (cx + r.uniform(-0.03, 0.03) * W, cy + 0.3 * W)
    for k in range(4):
        tx, ty, _ = tips[k]
        d.line([base, ((base[0] + tx) / 2 + r.uniform(-0.03, 0.03) * W, (base[1] + ty) / 2), (tx, ty)],
               fill=fill(twig, r, 0.15), width=max(2, int(0.006 * W)))
    order = sorted(range(len(tips)), key=lambda k: r.random())
    for n, k in enumerate(order):
        tx, ty, ang = tips[k]
        shoot = ang + r.normal(0, 0.5) if math.hypot(tx - cx, ty - cy) > 0.05 * W else r.uniform(0, 2 * math.pi)
        back = r.uniform(0.05, 0.09) * W
        d.line([(tx - math.cos(shoot) * back, ty - math.sin(shoot) * back), (tx, ty)], fill=fill(twig, r, 0.15),
               width=max(2, int(0.004 * W)))
        depth = n / max(len(order) - 1, 1)       # later tufts are in front, lighter
        for i in range(per):
            a = shoot + r.normal(0, 1.2)
            L = r.uniform(*nl) * W * r.uniform(0.7, 1.0)
            along = r.uniform(0, 0.45) * nl[1] * W
            sx, sy = tx - math.cos(shoot) * along, ty - math.sin(shoot) * along
            ex, ey = sx + math.cos(a) * L, sy + math.sin(a) * L
            c = pick(r, pal) * (0.7 + 0.36 * depth + 0.2 * (i / per))
            if r.random() < 0.02:
                c = hx("#7a6a48")                 # a browned needle
            d.line([(sx, sy), (ex, ey)], fill=fill(c, r, 0.1), width=max(2, int(0.0028 * W)))
    return finish(img, size, size, r, border=0.012, noise=0.2)


def olive_card(size: int, seed: int) -> np.ndarray:
    """An olive spray: thin twigs with narrow leaves (6-7 cm by 1-1.5 cm) in
    pairs, dark grey-green above and silvery below; loose, with gaps (the
    measured mean is #7d8a6a)."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    upper = [hx("#56634a"), hx("#4c5a40"), hx("#616e50"), hx("#5a6844")]
    under = [hx("#a7b096"), hx("#97a387"), hx("#b3baa2"), hx("#9eaa8c")]
    cx, cy = W / 2, W / 2 + 0.3 * W
    leaves = []
    for k in range(13):
        ang = -math.pi / 2 + r.uniform(-1.4, 1.4)
        length = r.uniform(0.32, 0.47) * W
        pts = [(cx + r.uniform(-0.02, 0.02) * W, cy)]
        a = ang
        for j in range(6):
            a += r.normal(0, 0.12)
            pts.append((pts[-1][0] + math.cos(a) * length / 6, pts[-1][1] + math.sin(a) * length / 6))
        d.line(pts, fill=fill(hx("#6b6655"), r, 0.1), width=max(2, int(0.005 * W)))
        shoots = [pts]
        for _ in range(2):
            j = int(r.integers(2, 5))
            sa = a + r.choice([-1, 1]) * r.uniform(0.5, 0.9)
            sp = [pts[j]]
            for _ in range(3):
                sp.append((sp[-1][0] + math.cos(sa) * length / 7, sp[-1][1] + math.sin(sa) * length / 7))
            d.line(sp, fill=fill(hx("#6b6655"), r, 0.1), width=max(1, int(0.003 * W)))
            shoots.append(sp)
        for sp in shoots:
            for j in range(1, len(sp)):
                (x0, y0), (x1, y1) = sp[j - 1], sp[j]
                seg = math.atan2(y1 - y0, x1 - x0)
                for t in (0.17, 0.5, 0.83):
                    x, y = x0 + (x1 - x0) * t, y0 + (y1 - y0) * t
                    for sgn in (-1, 1):
                        leaves.append((r.random(), x, y, seg + sgn * r.uniform(0.35, 0.8)))
            tx, ty = sp[-1]
            leaves.append((r.random(), tx, ty, math.atan2(sp[-1][1] - sp[-2][1], sp[-1][0] - sp[-2][0])))
    leaves.sort()
    for (_, x, y, ang) in leaves:
        L = r.uniform(0.045, 0.06) * W
        c = pick(r, under) if r.random() < 0.38 else pick(r, upper)
        _leaf(d, x, y, L, L * r.uniform(0.17, 0.22), ang, c * r.uniform(0.9, 1.08))
    return finish(img, size, size, r, border=0.012, noise=0.18)


def broadleaf_card(size: int, seed: int, greens: list, n: int, length: tuple, width: tuple) -> np.ndarray:
    """A round clump of entire leaves (obovate, glossy): the evergreens of
    Riviera gardens and hedges. As bake_materials.foliage_card's broadleaf,
    in other greens."""
    r = rng(seed)
    canvas = Image.new("RGB", (size, size), (0, 0, 0))
    alpha = Image.new("L", (size, size), 0)
    cx = cy = size / 2
    pts = []
    for _ in range(n):
        rad = math.sqrt(r.uniform(0, 1)) * 0.92
        ang = r.uniform(0, 2 * math.pi)
        lobe = 0.8 + 0.14 * math.sin(3 * ang + seed) + 0.08 * math.sin(5 * ang + 2 * seed) + 0.05 * math.sin(9 * ang)
        if r.random() < rad ** 3 * 0.5:
            continue
        px = cx + math.cos(ang) * rad * lobe * size / 2
        py = cy + math.sin(ang) * rad * lobe * size / 2 * 0.92
        dist = math.hypot(px - cx, py - cy) / (size / 2)
        if dist > 0.97:
            continue
        pts.append((dist + r.uniform(-0.15, 0.15), px, py, ang + r.normal(0, 0.8), dist))
    pts.sort()
    for (_, px, py, la, dist) in pts:
        L = r.uniform(*length) * (1.1 - 0.2 * dist)
        leaf = leaf_shape(L, L * r.uniform(*width), "broad").rotate(-math.degrees(la) - 90, resample=Image.BICUBIC, expand=True)
        g = pick(r, greens) * r.uniform(0.85, 1.15) * (0.66 + 0.46 * min(dist + r.uniform(0, 0.25), 1))
        lw, lh = leaf.size
        tl = (int(px - lw / 2), int(py - lh / 2))
        canvas.paste(Image.new("RGB", leaf.size, fill(g)[:3]), tl, leaf)
        alpha.paste(255, tl, leaf)
    img = Image.merge("RGBA", (*canvas.split(), alpha))
    return finish(img, size, size, r, border=0.012, noise=0.22)


def cypress_card(size: int, seed: int) -> np.ndarray:
    """Italian cypress: dense flame-like sprays of scale leaves pointing up,
    very dark (#1f2a1f), the outer sprays a little lighter."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    pal = [hx("#1f2a1f"), hx("#263424"), hx("#1a231a"), hx("#2c3b28"), hx("#233020")]
    sprays = []
    for _ in range(760):
        rad = math.sqrt(r.uniform(0, 1)) * 0.37
        ang = r.uniform(0, 2 * math.pi)
        x = W / 2 + math.cos(ang) * rad * W
        y = W / 2 + math.sin(ang) * rad * W * 1.05 + 0.04 * W
        sprays.append((rad + r.uniform(-0.08, 0.08), x, y, rad))
    sprays.sort()
    for (_, x, y, rad) in sprays:
        a = -math.pi / 2 + r.normal(0, 0.45)
        L = r.uniform(0.05, 0.1) * W
        c = pick(r, pal) * (0.75 + 0.6 * rad / 0.37)
        pts = [(x, y)]
        for k in range(4):
            a += r.normal(0, 0.15)
            pts.append((pts[-1][0] + math.cos(a) * L / 4, pts[-1][1] + math.sin(a) * L / 4))
        d.line(pts, fill=fill(c, r, 0.12), width=max(3, int(0.011 * W)))
        for k in range(1, len(pts)):
            for sgn in (-1, 1):
                if r.random() < 0.15:
                    continue
                sa = a + sgn * r.uniform(0.45, 0.8)
                ln = L * r.uniform(0.22, 0.38) * (1.2 - 0.25 * k)
                px, py = pts[k]
                d.line([(px, py), (px + math.cos(sa) * ln, py + math.sin(sa) * ln)], fill=fill(c, r, 0.15),
                       width=max(3, int(0.009 * W)))
    return finish(img, size, size, r, border=0.012, noise=0.25)


def araucaria_card(size: int, seed: int) -> np.ndarray:
    """A metre of Norfolk Island pine branch seen from above: the axis along
    the middle, branchlets like green ropes 35-45 cm long every 2 cm or so in
    two ranks, angled 55 degrees forward and curving on. Tileable along u."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (3 * W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    mid = W / 2
    reach = mid - 0.035 * W
    items = []
    x = 0.0
    side = 1
    while x < W:
        items.append((x, side, r.uniform(0.86, 1.06), r.uniform(-0.12, 0.12), r.uniform(0.72, 1.0), r.uniform(0.85, 1.15)))
        x += r.uniform(0.011, 0.017) * W
        side = -side
    for off in (-W, 0, W):
        for (x0, sd, a0, da, ln, tone) in items:
            a = a0 + da
            L = ln * reach / math.sin(a)
            pts = [(W + off + x0, mid)]
            for k in range(1, 9):
                t = k / 8
                aa = a - 0.3 * t * t
                px, py = pts[-1]
                pts.append((px + math.cos(aa) * L / 8, py + sd * math.sin(aa) * L / 8))
            for k in range(1, len(pts)):
                t = k / 8
                c = (hx("#30482c") * (1 - t) + hx("#5a7a4c") * t) * tone
                d.line([pts[k - 1], pts[k]], fill=fill(c, r, 0.06), width=max(3, int((0.016 - 0.008 * t) * W)))
            # Needle texture along the rope.
            for k in range(1, len(pts), 2):
                px, py = pts[k]
                d.ellipse([px - 0.004 * W, py - 0.004 * W, px + 0.004 * W, py + 0.004 * W], fill=fill(hx("#6a8a58"), r, 0.1))
        d.line([(off + W, mid), (off + 2 * W, mid)], fill=fill(hx("#5a4c3a")), width=max(4, int(0.014 * W)))
    img = img.crop((W, 0, 2 * W, W))
    out = finish(img, size, size, r, border=0.0, noise=0.15)
    # Fade only across (top and bottom); along u it runs on.
    yy = np.arange(size, dtype=np.float32)[:, None] / size
    out[..., 3] *= smoothstep(0.008, 0.025, np.minimum(yy, 1 - yy))
    return out


def oleander_card(size: int, seed: int, flowers: bool = False) -> np.ndarray:
    """Oleander: stiff narrow leaves (12-14 cm by 2 cm) in whorls of three
    on upright shoots, dull dark green; with `flowers`, clusters of pink
    flowers (#d87a9a) at the shoot tips. They flower from May to October,
    so the Poggio's late-March bushes are drawn in leaf only."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    greens = [hx("#3d5236"), hx("#465d3d"), hx("#33472f"), hx("#50663f")]
    pinks = [hx("#d87a9a"), hx("#e391ad"), hx("#c96a8a"), hx("#ea9fb8")]
    cx, cy = W / 2, W / 2 + 0.34 * W
    tips = []
    leaves = []
    for k in range(19):
        ang = -math.pi / 2 + r.uniform(-1.3, 1.3)
        length = r.uniform(0.28, 0.46) * W
        pts = [(cx + r.uniform(-0.04, 0.04) * W, cy)]
        a = ang
        for j in range(5):
            a += r.normal(0, 0.08)
            pts.append((pts[-1][0] + math.cos(a) * length / 5, pts[-1][1] + math.sin(a) * length / 5))
        d.line(pts, fill=fill(hx("#6a6448"), r, 0.1), width=max(2, int(0.006 * W)))
        for j in range(1, len(pts)):
            for w in range(3):
                la = a + (w - 1) * r.uniform(0.7, 1.0) + r.normal(0, 0.12)
                leaves.append((r.random(), pts[j][0], pts[j][1], la))
        tips.append(pts[-1])
    leaves.sort()
    for (_, x, y, la) in leaves:
        L = r.uniform(0.09, 0.12) * W
        _leaf(d, x, y, L, L * r.uniform(0.15, 0.19), la, pick(r, greens) * r.uniform(0.85, 1.12))
    for (tx, ty) in tips[: int(r.integers(5, 8))] if flowers else []:
        for _ in range(int(r.integers(6, 11))):
            fx, fy = tx + r.normal(0, 0.025) * W, ty + r.normal(0, 0.02) * W
            rr = r.uniform(0.014, 0.019) * W
            c = pick(r, pinks)
            rot = r.uniform(0, 2 * math.pi)
            for p in range(5):
                pa = rot + p * 2 * math.pi / 5
                px, py = fx + math.cos(pa) * rr * 0.55, fy + math.sin(pa) * rr * 0.55
                d.ellipse([px - rr * 0.55, py - rr * 0.55, px + rr * 0.55, py + rr * 0.55], fill=fill(c, r, 0.08))
            d.ellipse([fx - rr * 0.22, fy - rr * 0.22, fx + rr * 0.22, fy + rr * 0.22], fill=fill(hx("#f3d2dc")))
    return finish(img, size, size, r, border=0.012, noise=0.18)


def bougainvillea_card(size: int, seed: int) -> np.ndarray:
    """Bougainvillea in flower: masses of papery magenta bracts (#b0306a)
    in threes round tiny cream flowers, a few leaves showing between."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    mags = [hx("#b0306a"), hx("#c23a78"), hx("#9a2a5c"), hx("#cc4a86"), hx("#a52f63")]
    greens = [hx("#3d5a2a"), hx("#4a6a30"), hx("#355024")]
    items = []
    for _ in range(1500):
        rad = math.sqrt(r.uniform(0, 1)) * 0.9
        ang = r.uniform(0, 2 * math.pi)
        lobe = 0.78 + 0.14 * math.sin(4 * ang + seed) + 0.09 * math.sin(7 * ang) + 0.06 * math.sin(11 * ang + 1)
        if r.random() < rad ** 2.5 * 0.55:
            continue
        x = W / 2 + math.cos(ang) * rad * lobe * W / 2
        y = W / 2 + math.sin(ang) * rad * lobe * W / 2
        items.append((rad + r.uniform(-0.2, 0.2), x, y, rad, r.random() < 0.22))
    items.sort()
    for (_, x, y, rad, leafy) in items:
        shade = 0.7 + 0.4 * min(rad + r.uniform(0, 0.2), 1)
        if leafy:
            L = r.uniform(0.028, 0.04) * W
            _leaf(d, x, y, L, L * 0.55, r.uniform(0, 2 * math.pi), pick(r, greens) * shade)
            continue
        c = pick(r, mags) * shade
        rot = r.uniform(0, 2 * math.pi)
        br = r.uniform(0.012, 0.017) * W
        for k in range(3):
            a = rot + k * 2.094
            px, py = x + math.cos(a) * br * 0.7, y + math.sin(a) * br * 0.7
            poly = [(px + math.cos(a + q) * br * f, py + math.sin(a + q) * br * f)
                    for q, f in ((0, 1.0), (1.9, 0.75), (math.pi, 0.4), (-1.9, 0.75))]
            d.polygon(poly, fill=fill(c, r, 0.1))
        d.ellipse([x - br * 0.18, y - br * 0.18, x + br * 0.18, y + br * 0.18], fill=fill(hx("#efe6c8")))
    return finish(img, size, size, r, border=0.012, noise=0.2)


def frond_strip(w: int, h: int, seed: int) -> np.ndarray:
    """One Canary date palm frond, 5 m long, base on the left: a yellowish
    rachis tapering to the tip, stiff spines on the first sixth, then about
    140 leaflets a side (25-50 cm, 2.5 cm wide) at 50-65 degrees, longest a
    third of the way out, a few missing. #5b7a3a, yellower at the base."""
    r = rng(seed)
    Wd, Hd = w * S, h * S
    img = Image.new("RGBA", (Wd, Hd), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    x0, x1, mid = 0.012 * Wd, 0.988 * Wd, Hd / 2
    span = x1 - x0
    reach = mid - 0.04 * Hd
    greens = [hx("#5b7a3a"), hx("#4d6a30"), hx("#6a8a45"), hx("#557035"), hx("#62803c")]

    def rachis_w(t):
        return (0.032 - 0.026 * t) * Hd

    # Leaflets, base to tip, both sides; drawn before the rachis.
    t = 0.16
    k = 0
    while t < 0.985:
        for sd in (-1, 1):
            if r.random() < 0.04:
                continue
            prof = (0.45 + 0.55 * min((t - 0.16) / 0.22, 1)) * (1 - max(t - 0.38, 0) / 0.62 * 0.72)
            a = r.uniform(0.86, 1.14) + 0.12 * math.sin(k * 1.7)
            L = prof * reach / math.sin(a) * r.uniform(0.86, 1.0)
            x = x0 + t * span
            base_c = hx("#7a8a45") * (1 - t) + pick(r, greens) * t if t < 0.3 else pick(r, greens)
            c = base_c * r.uniform(0.88, 1.1)
            if r.random() < 0.03:
                c = hx("#9a8a50")                  # a yellowing leaflet
            sy = mid + sd * rachis_w(t) * 0.4
            droop = r.uniform(-0.06, 0.1)
            pts_l, pts_r = [], []
            wd = r.uniform(0.0085, 0.011) * Hd
            for j in range(9):
                u = j / 8
                aa = a + droop * u
                px = x + math.cos(aa) * L * u
                py = sy + sd * math.sin(aa) * L * u
                half = wd * (1 - u) ** 0.6 * (0.6 + 0.4 * min(u * 5, 1))
                nx, ny = -sd * math.sin(aa), math.cos(aa)
                pts_l.append((px + nx * half * sd, py + ny * half * sd))
                pts_r.append((px - nx * half * sd, py - ny * half * sd))
            d.polygon(pts_l + pts_r[::-1], fill=fill(c))
            # The fold down each leaflet's middle, darker.
            d.line([(x, sy), (x + math.cos(a) * L * 0.9, sy + sd * math.sin(a) * L * 0.9)],
                   fill=fill(c * 0.78), width=max(1, int(0.0025 * Hd)))
        k += 1
        t += r.uniform(0.0048, 0.0068)
    # Spines on the petiole.
    t = 0.02
    sd = 1
    while t < 0.165:
        L = (0.12 + 0.6 * t / 0.165) * reach * r.uniform(0.8, 1.1)
        a = r.uniform(0.8, 1.1)
        x = x0 + t * span
        d.line([(x, mid), (x + math.cos(a) * L, mid + sd * math.sin(a) * L)], fill=fill(hx("#b6a868"), r, 0.08),
               width=max(2, int(0.008 * Hd)))
        t += r.uniform(0.006, 0.011)
        sd = -sd
    # The rachis, tapering, yellowish at the base.
    n = 60
    for j in range(n):
        ta, tb = j / n, (j + 1) / n
        c = hx("#a39a5c") * (1 - ta) + hx("#647c3c") * ta
        xa, xb = x0 + ta * span, x0 + tb * span
        wa, wb = rachis_w(ta), rachis_w(tb)
        d.polygon([(xa, mid - wa / 2), (xb, mid - wb / 2), (xb, mid + wb / 2), (xa, mid + wa / 2)], fill=fill(c))
    out = finish(img, w, h, r, border=0.0, noise=0.15)
    yy = np.arange(h, dtype=np.float32)[:, None] / h
    xx = np.arange(w, dtype=np.float32)[None, :] / w
    out[..., 3] *= smoothstep(0.006, 0.02, np.minimum(yy, 1 - yy)) * smoothstep(0.002, 0.006, np.minimum(xx, 1 - xx))
    return out


def fan_card(size: int, seed: int, dead: bool = False) -> np.ndarray:
    """A palmate fan leaf face on (Washingtonia, the windmill palm), the
    hastula a little below the middle and the petiole stub down to the
    bottom edge: some 46 pleated segments, light and dark in turn, their
    free tips split and drooping. `dead`: a dead leaf hanging from the top
    edge, folded shut, brown and straw (a palm's skirt)."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    if dead:
        hx0, hy0 = W / 2, 0.06 * W
        browns = [hx("#8a6a45"), hx("#a08050"), hx("#6e5236"), hx("#b8a070"), hx("#7a5c3a")]
        for i in range(34):
            th = math.pi / 2 + r.normal(0, 0.28)          # hanging down
            L = r.uniform(0.62, 0.86) * W
            c = pick(r, browns) * r.uniform(0.85, 1.12)
            w0 = r.uniform(0.012, 0.022) * W
            pts_l, pts_r = [], []
            for j in range(10):
                u = j / 9
                a = th + r.normal(0, 0.03) + 0.15 * u * math.copysign(1, math.cos(th))
                px = hx0 + math.cos(a) * L * u + math.sin(u * 7 + i) * 0.006 * W
                py = hy0 + math.sin(a) * L * u
                half = w0 * (0.5 + 0.5 * math.sin(math.pi * min(u * 1.3, 1))) * (1 - 0.7 * u)
                pts_l.append((px - half, py)); pts_r.append((px + half, py))
            d.polygon(pts_l + pts_r[::-1], fill=fill(c))
            d.line([pts_l[2], pts_l[-1]], fill=fill(c * 0.7), width=max(1, int(0.003 * W)))
        return finish(img, size, size, r, border=0.012, noise=0.25)
    hx0, hy0 = W / 2, 0.56 * W
    lights = [hx("#6f8f45"), hx("#7a9a4e"), hx("#668640")]
    darks = [hx("#557235"), hx("#4a6630"), hx("#5b7a3a")]
    # Petiole stub, toothed.
    d.polygon([(hx0 - 0.012 * W, hy0), (hx0 + 0.012 * W, hy0), (hx0 + 0.009 * W, 0.975 * W), (hx0 - 0.009 * W, 0.975 * W)],
              fill=fill(hx("#8a7a48")))
    for y in np.arange(hy0 + 0.03 * W, 0.95 * W, 0.03 * W):
        for sd in (-1, 1):
            d.line([(hx0 + sd * 0.01 * W, y), (hx0 + sd * 0.02 * W, y - 0.012 * W)], fill=fill(hx("#9a8a55")), width=S)
    N = 46
    segs = []
    for i in range(N):
        th = math.radians(-150 + 300 * (i + 0.5) / N + r.uniform(-1.5, 1.5))     # from straight up
        R = 0.43 * W * r.uniform(0.9, 1.0) * (1 - 0.3 * (abs(th) / math.radians(150)) ** 2)
        segs.append((abs(th), th, R, i))
    # The upper segments overlap the lower ones.
    for (_, th, R, i) in sorted(segs, reverse=True):
        half = math.radians(300 / N) / 2 * 1.3
        c = (pick(r, lights) if i % 2 == 0 else pick(r, darks)) * r.uniform(0.9, 1.08)
        web = 0.68                                # the webbed blade, then free tips
        pts_l =[(hx0 + math.sin(th - half) * R * u, hy0 - math.cos(th - half) * R * u) for u in np.linspace(0.05, web, 7)]
        pts_r = [(hx0 + math.sin(th + half) * R * u, hy0 - math.cos(th + half) * R * u) for u in np.linspace(0.05, web, 7)]
        d.polygon(pts_l + pts_r[::-1], fill=fill(c))
        # The free tips: two narrow points, drooping more out at the sides.
        droop = 0.35 * abs(math.sin(th)) * (1 - 0.6 * max(abs(th) - 1.6, 0)) + 0.1
        for sgn in (-0.45, 0.45):
            a0 = th + sgn * half
            tip = []
            for j in range(6):
                u = web + (1 - web) * j / 5
                a = a0 + math.copysign(droop * ((u - web) / (1 - web)) ** 1.5, th if abs(th) > 0.05 else 1)
                tip.append((hx0 + math.sin(a) * R * u, hy0 - math.cos(a) * R * u))
            wl = half * R * web * 0.45
            left = [(x - math.cos(th) * wl * (1 - j / 5), y - math.sin(th) * wl * (1 - j / 5)) for j, (x, y) in enumerate(tip)]
            right = [(x + math.cos(th) * wl * (1 - j / 5), y + math.sin(th) * wl * (1 - j / 5)) for j, (x, y) in enumerate(tip)]
            d.polygon(left + right[::-1], fill=fill(c * (0.95 if sgn < 0 else 1.0)))
        # The rib, lighter.
        d.line([(hx0, hy0), (hx0 + math.sin(th) * R * web, hy0 - math.cos(th) * R * web)], fill=fill(c * 1.25),
               width=max(1, int(0.003 * W)))
    d.ellipse([hx0 - 0.02 * W, hy0 - 0.02 * W, hx0 + 0.02 * W, hy0 + 0.02 * W], fill=fill(hx("#6a6a38")))
    return finish(img, size, size, r, border=0.012, noise=0.15)


def iceplant_card(size: int, seed: int) -> np.ndarray:
    """Ice plant (Carpobrotus) mat: curved fleshy leaves of triangular
    section, 6-10 cm, olive to grey green with reddish tips, and a few
    magenta and yellow flowers (late March is their start)."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    greens = [hx("#626938"), hx("#6f7a42"), hx("#8a9a5a"), hx("#5a6334"), hx("#7a864a")]
    items = []
    for _ in range(1700):
        rad = math.sqrt(r.uniform(0, 1)) * 0.92
        ang = r.uniform(0, 2 * math.pi)
        lobe = 0.8 + 0.12 * math.sin(4 * ang + seed) + 0.08 * math.sin(9 * ang)
        if r.random() < rad ** 3 * 0.5:
            continue
        items.append((rad + r.uniform(-0.25, 0.25), W / 2 + math.cos(ang) * rad * lobe * W / 2,
                      W / 2 + math.sin(ang) * rad * lobe * W / 2, rad))
    items.sort()
    for (_, x, y, rad) in items:
        a = r.uniform(0, 2 * math.pi)
        L = r.uniform(0.05, 0.08) * W
        bend = r.uniform(-0.5, 0.5)
        pts_l, pts_r = [], []
        wd = r.uniform(0.008, 0.011) * W
        for j in range(7):
            u = j / 6
            aa = a + bend * u
            px, py = x + math.cos(aa) * L * u, y + math.sin(aa) * L * u
            half = wd * (1 - 0.8 * u)
            pts_l.append((px - math.sin(aa) * half, py + math.cos(aa) * half))
            pts_r.append((px + math.sin(aa) * half, py - math.cos(aa) * half))
        c = pick(r, greens) * (0.72 + 0.4 * min(rad + 0.1, 1))
        d.polygon(pts_l + pts_r[::-1], fill=fill(c, r, 0.1))
        if r.random() < 0.3:
            d.polygon(pts_l[-3:] + pts_r[-3:][::-1], fill=fill(hx("#9a5a40"), r, 0.1))
    for _ in range(int(r.integers(7, 11))):
        rad = math.sqrt(r.uniform(0, 1)) * 0.7
        ang = r.uniform(0, 2 * math.pi)
        fx, fy = W / 2 + math.cos(ang) * rad * W / 2, W / 2 + math.sin(ang) * rad * W / 2
        c = hx("#c8408c") if r.random() < 0.7 else hx("#e8d070")
        R = r.uniform(0.028, 0.038) * W
        for p in range(40):
            pa = p * 2 * math.pi / 40 + r.uniform(-0.05, 0.05)
            d.line([(fx, fy), (fx + math.cos(pa) * R, fy + math.sin(pa) * R)], fill=fill(c, r, 0.08), width=max(2, int(0.004 * W)))
        d.ellipse([fx - R * 0.25, fy - R * 0.25, fx + R * 0.25, fy + R * 0.25], fill=fill(hx("#e8c84a")))
    return finish(img, size, size, r, border=0.012, noise=0.18)


def reed_card(size: int, seed: int) -> np.ndarray:
    """Giant reed (Arundo donax) on a sea-side bank in March: a clump of
    straight canes 3-4 m tall rooted on the bottom edge, strap leaves
    arching from the nodes, a third of them last year's straw, and a few
    old plumes."""
    r = rng(seed)
    W = size * S
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    green, grey, straw = hx("#5f8364"), hx("#7a9070"), hx("#b8a878")
    canes = []
    for _ in range(17):
        bx = W / 2 + r.normal(0, 0.06) * W
        tx = W / 2 + r.uniform(-0.38, 0.38) * W
        top = r.uniform(0.04, 0.3) * W
        canes.append((r.random(), bx, tx, top, r.random() < 0.35))
    canes.sort()
    for (_, bx, tx, top, dry) in canes:
        foot = 0.985 * W
        pts = [(bx + (tx - bx) * u ** 1.4, foot + (top - foot) * u) for u in np.linspace(0, 1, 12)]
        d.line(pts, fill=fill(straw if dry else hx("#8a9a68"), r, 0.08), width=max(3, int(0.008 * W)))
        nodes = int((foot - top) / (0.06 * W))
        for k in range(1, nodes):
            u = k / nodes
            px, py = bx + (tx - bx) * u ** 1.4, foot + (top - foot) * u
            for sgn in ((-1,) if k % 2 else (1,)):
                L = r.uniform(0.09, 0.16) * W * (1.1 - 0.4 * u)
                a = -math.pi / 2 + sgn * r.uniform(0.5, 1.2)
                c = straw if (dry or r.random() < 0.3) else (green if r.random() < 0.6 else grey)
                lp_l, lp_r = [], []
                wd = r.uniform(0.008, 0.012) * W
                for j in range(8):
                    t = j / 7
                    aa = a + sgn * 1.4 * t * t       # arching over and down
                    qx = px + math.cos(aa) * L * t
                    qy = py + math.sin(aa) * L * t
                    half = wd * (1 - t) ** 0.7
                    lp_l.append((qx - math.sin(aa) * half, qy + math.cos(aa) * half))
                    lp_r.append((qx + math.sin(aa) * half, qy - math.cos(aa) * half))
                d.polygon(lp_l + lp_r[::-1], fill=fill(c, r, 0.1))
        if dry and r.random() < 0.5:
            for _ in range(30):
                a = -math.pi / 2 + r.normal(0, 0.3)
                L = r.uniform(0.02, 0.06) * W
                d.line([(tx, top), (tx + math.cos(a) * L, top + math.sin(a) * L)], fill=fill(hx("#cdbf98"), r, 0.08), width=S)
    out = finish(img, size, size, r, border=0.0, noise=0.12)
    yy, xx = np.mgrid[0:size, 0:size].astype(np.float32) / size
    out[..., 3] *= smoothstep(0.006, 0.02, np.minimum(np.minimum(xx, 1 - xx), yy))
    return out


def bake_foliage(size: int = 2048) -> None:
    """cj_foliage_med.png (see the module docstring for the layout)."""
    c = size // 4
    atlas = np.zeros((size, size, 4), np.float32)

    def put(col, row, card):
        atlas[row * c:row * c + card.shape[0], col * c:col * c + card.shape[1]] = card
    put(0, 0, pine_card(c, 301, "aleppo"))
    put(1, 0, pine_card(c, 302, "pinea"))
    put(2, 0, olive_card(c, 303))
    put(3, 0, broadleaf_card(c, 304, [hx("#2f3d22"), hx("#3a4a2a"), hx("#263219"), hx("#43552f")], 1000, (34, 50), (0.5, 0.62)))
    put(0, 1, cypress_card(c, 305))
    put(1, 1, araucaria_card(c, 306))
    put(2, 1, oleander_card(c, 307))
    put(3, 1, bougainvillea_card(c, 308))
    put(0, 2, frond_strip(size, c, 309))
    put(0, 3, fan_card(c, 310))
    put(1, 3, fan_card(c, 311, dead=True))
    put(2, 3, iceplant_card(c, 312))
    put(3, 3, reed_card(c, 313))
    save_rgba(OUT / "cj_foliage_med.png", bleed(atlas))
    print("foliage cells coverage", [round(float(atlas[r * c:(r + 1) * c, k * c:(k + 1) * c, 3].mean()), 3)
                                     for r in range(4) for k in range(4)])


# ---------------------------------------------------------------- impostors

class Sprite:
    """One distant-tree cell drawn in PIL: colour with alpha, and the crown's
    normal and ambient occlusion (`nrm`: R, G = normal x right, y down;
    B = ao), drawn with the same shapes."""

    def __init__(self, n: int):
        self.n = n
        self.img = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        self.nrm = Image.new("RGB", (n, n), (128, 128, 255))
        self.d = ImageDraw.Draw(self.img)
        self.dn = ImageDraw.Draw(self.nrm)

    @staticmethod
    def code(nx: float, ny: float, ao: float) -> tuple:
        l = max(math.sqrt(nx * nx + ny * ny + 1e-9), 1)
        return (int((nx / l * 0.5 + 0.5) * 255), int((ny / l * 0.5 + 0.5) * 255), int(np.clip(ao, 0, 1) * 255))

    def polygon(self, pts, colour, normal, ao):
        self.d.polygon(pts, fill=fill(colour))
        self.dn.polygon(pts, fill=self.code(normal[0], normal[1], ao))

    def line(self, pts, colour, width, normal, ao):
        self.d.line(pts, fill=fill(colour), width=max(1, int(width)))
        self.dn.line(pts, fill=self.code(normal[0], normal[1], ao), width=max(1, int(width)))

    def stroke(self, pts, widths, colour, normal, ao):
        """A tapering stroke along `pts` (a limb, a trunk)."""
        for k in range(1, len(pts)):
            (xa, ya), (xb, yb) = pts[k - 1], pts[k]
            ang = math.atan2(yb - ya, xb - xa)
            nx, ny = -math.sin(ang), math.cos(ang)
            wa, wb = widths[k - 1] / 2, widths[k] / 2
            poly = [(xa + nx * wa, ya + ny * wa), (xb + nx * wb, yb + ny * wb), (xb - nx * wb, yb - ny * wb), (xa - nx * wa, ya - ny * wa)]
            self.polygon(poly, colour, normal, ao)

    def stamp(self, card: np.ndarray, x: float, y: float, size: float, normal, ao, r, flip=False, rot=0.0):
        """A leaf-card sprite centred at (x, y), its normal blended per texel
        with a sphere's, so a clump has a lit side."""
        sz = max(int(size), 4)
        spr = Image.fromarray(to_u8(card)).resize((sz, sz), Image.LANCZOS)
        if flip:
            spr = spr.transpose(Image.FLIP_LEFT_RIGHT)
        if rot:
            spr = spr.rotate(rot, resample=Image.BICUBIC)
        a = np.asarray(spr, np.float32)[..., 3] / 255
        mask = Image.fromarray(((a > 0.35) * 255).astype(np.uint8))
        yy, xx = (np.mgrid[0:sz, 0:sz].astype(np.float32) + 0.5 - sz / 2) / (sz / 2)
        sz_ = np.sqrt(np.clip(1 - xx * xx - yy * yy, 0, 1))
        n = 0.65 * np.array(normal, np.float32)[None, None, :] + 0.35 * np.stack([xx, yy, sz_], -1)
        n /= np.maximum(np.linalg.norm(n, axis=-1, keepdims=True), 1e-6)
        occ = ao * (0.75 + 0.25 * sz_)
        code = np.stack([n[..., 0] * 0.5 + 0.5, n[..., 1] * 0.5 + 0.5, occ], -1)
        tl = (int(x - sz / 2), int(y - sz / 2))
        self.img.paste(spr.convert("RGB").convert("RGBA"), tl, mask)
        self.nrm.paste(Image.fromarray(to_u8(code)), tl, mask)


def sphere_normal(x, y, cx, cy, rx, ry):
    nx, ny = (x - cx) / max(rx, 1), (y - cy) / max(ry, 1)
    nz = math.sqrt(max(1 - nx * nx - ny * ny, 0.05))
    return (nx, ny, nz)


def imp_aleppo(sp: Sprite, cards, r) -> None:
    """Aleppo pine: a leaning, kinked trunk forking high, and five to eight
    flattened clouds of tufts with sky between, the crown irregular and
    flat-topped."""
    n = sp.n
    bark = hx("#6e6258")
    lean = r.uniform(0.05, 0.1) * n
    trunk = [(n / 2, n), (n / 2 + lean * 0.3, 0.75 * n), (n / 2 + lean * 0.8, 0.52 * n), (n / 2 + lean, 0.4 * n)]
    sp.stroke(trunk, [0.05 * n, 0.042 * n, 0.032 * n, 0.024 * n], bark, (0.1, 0, 1), 0.7)
    clouds = []
    for k in range(7):
        cx = n / 2 + lean + r.uniform(-0.36, 0.36) * n
        cy = r.uniform(0.08, 0.42) * n
        clouds.append((cx, cy, r.uniform(0.09, 0.15) * n, r.uniform(0.05, 0.075) * n))
    for (cx, cy, rx, ry) in clouds:
        sp.stroke([(n / 2 + lean * 0.9, 0.45 * n), ((n / 2 + lean + cx) / 2, (0.45 * n + cy) / 2 + 0.02 * n), (cx, cy + ry * 0.4)],
                  [0.018 * n, 0.012 * n, 0.007 * n], bark, (0, 0, 1), 0.6)
    for (cx, cy, rx, ry) in sorted(clouds, key=lambda c: -c[1]):
        for _ in range(int(rx * ry / (0.035 * n) ** 2 * 3) + 4):
            px, py = cx + r.uniform(-1, 1) * rx * 0.85, cy + r.uniform(-0.8, 0.9) * ry
            nx, ny, nz = sphere_normal(px, py, cx, cy - ry * 0.5, rx * 1.2, ry * 2.2)
            ao = 0.65 + 0.35 * (1 - (py - cy + ry) / (2 * ry))
            sp.stamp(cards["aleppo"], px, py, r.uniform(0.07, 0.1) * n, (nx, ny, nz), ao, r, flip=r.random() < 0.5)


def imp_stone_pine(sp: Sprite, cards, r) -> None:
    """Stone pine: a clean bole to 60 % of the height forking into rising
    limbs, under a broad flat-topped umbrella with a dark underside."""
    n = sp.n
    bark = hx("#8a7a6a")
    fork = (n / 2 + r.uniform(-0.02, 0.02) * n, 0.5 * n)
    sp.stroke([(n / 2, n), (n / 2 + 0.01 * n, 0.75 * n), fork], [0.06 * n, 0.05 * n, 0.045 * n], bark, (0, 0, 1), 0.7)
    for k in range(4):
        tx = n / 2 + (k - 1.5) * 0.17 * n + r.uniform(-0.03, 0.03) * n
        sp.stroke([fork, ((fork[0] + tx) / 2, 0.4 * n), (tx, 0.3 * n)], [0.03 * n, 0.022 * n, 0.014 * n], bark, (0, 0, 1), 0.55)
    top, bottom = 0.04 * n, 0.33 * n
    for _ in range(170):
        px = n / 2 + r.uniform(-0.46, 0.46) * n
        edge = 1 - (abs(px - n / 2) / (0.47 * n)) ** 2
        y_top = top + (1 - edge) * 0.11 * n
        py = r.uniform(y_top, bottom - (1 - edge) * 0.04 * n)
        nx, ny, nz = sphere_normal(px, py, n / 2, bottom, 0.55 * n, (bottom - top) * 1.6)
        ao = 0.55 + 0.45 * (1 - (py - y_top) / max(bottom - y_top, 1))
        sp.stamp(cards["pinea"], px, py, r.uniform(0.07, 0.1) * n, (nx, ny, nz), ao, r, flip=r.random() < 0.5)


def imp_cypress(sp: Sprite, cards, r) -> None:
    """Italian cypress: a dark flame from the ground to a sharp point,
    widest a quarter of the way up."""
    n = sp.n
    sp.stroke([(n / 2, n), (n / 2, 0.9 * n)], [0.06 * n, 0.05 * n], hx("#5a4a3c"), (0, 0, 1), 0.6)
    for k in range(700):
        t = r.uniform(0, 1) ** 1.1
        y = (0.965 - 0.95 * t) * n
        w = 0.4 * n * (0.78 + 0.22 * min(t / 0.15, 1) if t < 0.5 else ((1 - t) / 0.5) ** 0.8)
        px = n / 2 + r.uniform(-1, 1) * max(w - 0.025 * n, 0)
        nx, ny, nz = sphere_normal(px, y, n / 2, y, w + 1, n)
        sp.stamp(cards["cypress"], px, y, r.uniform(0.05, 0.07) * n * (1 - 0.5 * t), (nx, -0.25, nz), 0.62 + 0.33 * t, r,
                 flip=r.random() < 0.5)


def palm_crown(sp: Sprite, r, cx: float, cy: float, R: float, count: int, colour_fn, width: float) -> None:
    """Fronds radiating from (cx, cy) in 3D, drawn back to front as
    rachises with leaflet ticks, upper ones rising, lower ones drooping."""
    golden = 2.39996
    fronds = []
    for k in range(count):
        az = k * golden + r.uniform(-0.2, 0.2)
        el = 1.15 - 1.55 * (k / count) ** 0.9 + r.uniform(-0.12, 0.12)
        fronds.append((math.sin(az), az, el, k))
    for (_, az, el, k) in sorted(fronds):
        dx, dz = math.cos(az), math.sin(az)
        L = R * r.uniform(0.85, 1.05)
        pts = []
        for j in range(9):
            u = j / 8
            e = el - 0.7 * u * u
            # Arc length u along a frond rising at e (radians above horizontal).
            x3 = sum(math.cos(el - 0.7 * (q / 16) ** 2) for q in range(int(u * 16) + 1)) / 16 * L
            y3 = sum(math.sin(el - 0.7 * (q / 16) ** 2) for q in range(int(u * 16) + 1)) / 16 * L
            pts.append((cx + dx * x3, cy - y3, dz * x3, e))
        normal = (dx * 0.6, -0.5 - 0.3 * math.cos(el), 0.6 + 0.4 * dz)
        ao = 0.55 + 0.45 * (0.5 + 0.5 * dz) * (0.7 + 0.3 * (k / count))
        colour = colour_fn(r)
        flat = [(p[0], p[1]) for p in pts]
        sp.line(flat, colour * 1.1, max(2, width * 0.35), normal, ao)
        fore = abs(dz) * 0.6 + 0.4
        for j in range(1, len(pts) - 1):
            (xa, ya), (xb, yb) = flat[j - 1], flat[j + 1]
            ang = math.atan2(yb - ya, xb - xa)
            half = width * (1.5 - 1.0 * (j / 8)) * fore
            for t in np.linspace(0, 1, 5, endpoint=False):
                qx, qy = flat[j][0] + (flat[j + 1][0] - flat[j][0]) * t, flat[j][1] + (flat[j + 1][1] - flat[j][1]) * t
                for sd in (-1, 1):
                    a2 = ang + sd * 1.0
                    sp.line([(qx, qy), (qx + math.cos(a2) * half, qy + math.sin(a2) * half + half * 0.35)], colour, max(2, width * 0.3),
                            normal, ao)


def imp_phoenix(sp: Sprite, cards, r) -> None:
    """Canary date palm: a thick trunk with a knob of leaf bases under a
    round crown of arching fronds."""
    n = sp.n
    trunk_top = 0.44 * n
    sp.stroke([(n / 2, n), (n / 2, 0.7 * n), (n / 2, trunk_top)], [0.1 * n, 0.095 * n, 0.12 * n], hx("#7a6a55"), (0, 0, 1), 0.7)
    sp.polygon([(n / 2 - 0.08 * n, trunk_top + 0.04 * n), (n / 2 + 0.08 * n, trunk_top + 0.04 * n),
                (n / 2 + 0.05 * n, trunk_top - 0.04 * n), (n / 2 - 0.05 * n, trunk_top - 0.04 * n)], hx("#8a7a50"), (0, -0.2, 1), 0.6)
    palm_crown(sp, r, n / 2, trunk_top - 0.02 * n, 0.46 * n, 90,
               lambda rr: pick(rr, [hx("#4f6c32"), hx("#46602b"), hx("#5b7a3a")]) * rr.uniform(0.9, 1.08), 0.022 * n)


def imp_washingtonia(sp: Sprite, cards, r) -> None:
    """Washingtonia: a tall slim grey trunk, a short skirt of dead leaves and
    a small round crown of fans."""
    n = sp.n
    top = 0.17 * n
    sp.stroke([(n / 2, n), (n / 2, 0.6 * n), (n / 2, top)], [0.09 * n, 0.07 * n, 0.065 * n], hx("#8c8579"), (0, 0, 1), 0.75)
    for _ in range(26):
        x = n / 2 + r.uniform(-0.14, 0.14) * n
        y = r.uniform(top + 0.03 * n, top + 0.1 * n)
        sp.stamp(cards["dead"], x, y, r.uniform(0.12, 0.17) * n, (r.uniform(-0.3, 0.3), 0.1, 1), 0.6, r, flip=r.random() < 0.5)
    for k in range(50):
        az = k * 2.39996
        el = 1.2 - 1.9 * k / 50
        x = n / 2 + math.cos(az) * math.cos(el) * 0.32 * n
        y = top - 0.02 * n - math.sin(el) * 0.1 * n
        nx, ny, nz = math.cos(az) * math.cos(el) * 0.8, -math.sin(el) * 0.8, 0.6 + 0.4 * math.sin(az)
        sp.stamp(cards["fan"], x, y, r.uniform(0.17, 0.22) * n, (nx, ny, nz), 0.6 + 0.35 * (0.5 + 0.5 * math.sin(az)), r,
                 flip=r.random() < 0.5, rot=math.degrees(-math.cos(az) * math.cos(el) * 0.9))


def imp_olive(sp: Sprite, cards, r) -> None:
    """Olive: a short gnarled trunk splitting low into twisting stems, and
    an open, rounded, silvery crown with gaps."""
    n = sp.n
    bark = hx("#7d786d")
    for k in range(3):
        tx = n / 2 + (k - 1) * 0.16 * n + r.uniform(-0.04, 0.04) * n
        sp.stroke([(n / 2, n), (n / 2 + (tx - n / 2) * 0.3 + r.uniform(-0.03, 0.03) * n, 0.82 * n), (tx, 0.55 * n)],
                  [0.07 * n, 0.045 * n, 0.025 * n], bark, (0, 0, 1), 0.65)
    lobes = []
    for _ in range(9):
        ang = r.uniform(0, 2 * math.pi)
        rad = math.sqrt(r.uniform(0.1, 1))
        lobes.append((n / 2 + math.cos(ang) * rad * 0.33 * n, 0.37 * n + math.sin(ang) * rad * 0.25 * n, r.uniform(0.1, 0.15) * n))
    for (lx, ly, lr) in lobes:
        for _ in range(9):
            if r.random() < 0.3:
                continue
            px, py = lx + r.uniform(-1, 1) * lr * 0.8, ly + r.uniform(-1, 1) * lr * 0.8
            nx, ny, nz = sphere_normal(px, py, n / 2, 0.37 * n, 0.48 * n, 0.36 * n)
            sp.stamp(cards["olive"], px, py, r.uniform(0.12, 0.16) * n, (nx, ny, nz), 0.65 + 0.3 * (1 - py / n), r,
                     flip=r.random() < 0.5)


def imp_araucaria(sp: Sprite, cards, r) -> None:
    """Norfolk Island pine: a straight trunk and level tiers of branches
    with sky between, a narrow cone tapering to the leader."""
    n = sp.n
    sp.stroke([(n / 2, n), (n / 2, 0.02 * n)], [0.05 * n, 0.012 * n], hx("#6a5a48"), (0, 0, 1), 0.7)
    y = 0.86 * n
    k = 0
    while y > 0.04 * n:
        t = 1 - y / n
        half = 0.47 * n * min(1, (1 - t) / 0.7) * (0.6 + 0.4 * min(t / 0.25, 1))
        for sd in (-1, 1):
            for j in range(2):
                reach = half * r.uniform(0.78, 1.0) * (1 if j == 0 else 0.72)
                sag = r.uniform(0.006, 0.014) * n
                pts = [(n / 2 + sd * reach * q, y + 0.004 * n * j + sag * math.sin(math.pi * q) - 0.016 * n * q ** 3)
                       for q in np.linspace(0, 1, 7)]
                normal = (sd * 0.2, -0.6, 0.8)
                ao = 0.6 + 0.3 * (0.5 + 0.5 * math.sin(k * 1.3 + j))
                sp.stroke(pts, [0.012 * n] * 6 + [0.006 * n], hx("#5a4c3a"), normal, ao * 0.8)
                # Branchlets hanging from the branch and curving up at the tips.
                for q in np.linspace(0.06, 0.98, 22):
                    qx = n / 2 + sd * reach * q
                    qy = y + sag * math.sin(math.pi * q) - 0.016 * n * q ** 3
                    ln = (0.022 + 0.012 * r.random()) * n * (1.1 - 0.5 * q)
                    c = hx("#3e5a3a") * r.uniform(0.82, 1.15)
                    sp.line([(qx, qy - 0.006 * n), (qx + sd * 0.006 * n, qy + ln * 0.6), (qx + sd * 0.014 * n, qy + ln * 0.75)], c,
                            0.008 * n, normal, ao)
                    sp.line([(qx, qy), (qx + sd * 0.01 * n, qy - ln * 0.45)], c * 1.1, 0.007 * n, normal, ao + 0.1)
        k += 1
        y -= (0.05 + 0.025 * t) * n * r.uniform(0.85, 1.15)


def imp_holm_oak(sp: Sprite, cards, r) -> None:
    """Holm oak (and the other evergreen broadleaves): a dense, dark,
    rounded crown on a short trunk."""
    n = sp.n
    sp.stroke([(n / 2, n), (n / 2, 0.55 * n)], [0.07 * n, 0.05 * n], hx("#4a4038"), (0, 0, 1), 0.6)
    lobes = []
    for _ in range(11):
        ang = r.uniform(0, 2 * math.pi)
        rad = math.sqrt(r.uniform(0.1, 1))
        lobes.append((n / 2 + math.cos(ang) * rad * 0.32 * n, 0.4 * n + math.sin(ang) * rad * 0.27 * n, r.uniform(0.11, 0.15) * n))
    lobes.append((n / 2, 0.42 * n, 0.22 * n))
    for (lx, ly, lr) in lobes:
        for _ in range(12):
            px, py = lx + r.uniform(-1, 1) * lr * 0.8, ly + r.uniform(-1, 1) * lr * 0.8
            nx, ny, nz = sphere_normal(px, py, n / 2, 0.4 * n, 0.5 * n, 0.4 * n)
            sp.stamp(cards["evergreen"], px, py, r.uniform(0.11, 0.15) * n, (nx, ny, nz), 0.6 + 0.35 * (1 - py / n), r,
                     flip=r.random() < 0.5)


IMPOSTOR_MED = [("aleppoPine", imp_aleppo), ("stonePine", imp_stone_pine), ("cypress", imp_cypress),
                ("phoenixPalm", imp_phoenix), ("washingtonia", imp_washingtonia), ("olive", imp_olive),
                ("araucaria", imp_araucaria), ("holmOak", imp_holm_oak)]


def bake_impostors(cell: int = 512) -> None:
    """cj_impostor_med.png + cj_impostor_med_detail.rgbz (module docstring)."""
    cols, rows = 4, 2
    olive = olive_card(128, 403)
    olive[..., :3] *= 0.86
    cards = {"aleppo": pine_card(128, 401, "aleppo"), "pinea": pine_card(128, 402, "pinea"), "olive": olive,
             "evergreen": broadleaf_card(128, 404, [hx("#2f3d22"), hx("#3a4a2a"), hx("#263219")], 260, (10, 14), (0.5, 0.6)),
             "cypress": cypress_card(128, 405), "fan": fan_card(128, 406), "dead": fan_card(128, 407, dead=True)}
    rgba = np.zeros((rows * cell, cols * cell, 4), np.float32)
    det = np.zeros((rows * cell, cols * cell, 3), np.float32)
    r = rng(411)
    for k, (name, painter) in enumerate(IMPOSTOR_MED):
        sp = Sprite(cell * S)
        # Draw at twice the size, so thin limbs and fronds keep their width.
        painter(sp, cards, r)
        img = np.asarray(sp.img.resize((cell, cell), Image.LANCZOS), np.float32) / 255
        nrm = np.asarray(sp.nrm.resize((cell, cell), Image.BILINEAR), np.float32) / 255
        oy, ox = (k // cols) * cell, (k % cols) * cell
        rgba[oy:oy + cell, ox:ox + cell] = img
        det[oy:oy + cell, ox:ox + cell] = nrm
    a0 = rgba[..., 3] > 0.5
    # Gaps of a few texels inside a crown or a frond closed, so the mip
    # levels of a distant tree keep their alpha (the closed texels take
    # the shaded colour round them).
    yy, xx = np.mgrid[-3:4, -3:4]
    a1 = binary_closing(a0, structure=(xx * xx + yy * yy) <= 9) | a0
    a = a1[..., None].astype(np.float32)
    rgb = rgba[..., :3] / np.maximum(rgba[..., 3:], 1e-3) * (rgba[..., 3:] > 0.02)
    w0 = a0[..., None].astype(np.float32)
    filled = blur(rgb * w0, 3) / np.maximum(blur(w0, 3), 1e-3) * 0.7
    rgb = rgb * w0 + filled * (a - w0)
    rgb = rgb * a + (blur(rgb * a, 6) / np.maximum(blur(a, 6), 1e-3)) * (1 - a)
    det = det * a + (blur(det * a, 6) / np.maximum(blur(a, 6), 1e-3)) * (1 - a)
    save_rgba(OUT / "cj_impostor_med.png", np.concatenate([np.clip(rgb, 0, 1), a], -1))
    n = det[..., :2] * 2 - 1
    nz = np.sqrt(np.clip(1 - (n * n).sum(-1), 0, 1))
    l = np.sqrt((n * n).sum(-1) + nz * nz)
    detail = np.stack([n[..., 0] / l * 0.5 + 0.5, n[..., 1] / l * 0.5 + 0.5, np.clip(det[..., 2], 0, 1), np.ones_like(l)], -1)
    save_raw(OUT / "cj_impostor_med_detail.rgbz", detail)
    print("impostor cells", [f[0] for f in IMPOSTOR_MED], "coverage",
          np.round([a[(k // cols) * cell:(k // cols + 1) * cell, (k % cols) * cell:(k % cols + 1) * cell].mean() for k in range(8)], 2))


# ---------------------------------------------------------------- bark

TILE, GUTTER = 512, 8
CORE = TILE - 2 * GUTTER


def zoom_wrap(a: np.ndarray, fy: float, fx: float) -> np.ndarray:
    return zoom(a, (fy, fx), order=1, mode="grid-wrap")


def bark_stone_pine(r):
    """Deep fissures between tall plates, orange-brown where freshly
    flaked, grey where weathered (#8a7a6a)."""
    f1, f2, ids = voronoi(CORE, CORE, 90, r)
    edge = f2 - f1
    tone = r.random(90)[ids]
    plate = smoothstep(0.0, 5.0, edge)
    flake = fbm(CORE, CORE, 12, 4, r)
    height = plate * (0.75 + 0.25 * flake)
    grey, orange, dark = hx("#8a7a6a"), hx("#9a6a48"), hx("#3a2e26")
    face = grey[None, None] * (1 - tone[..., None] * 0.6) + orange[None, None] * tone[..., None] * 0.6
    face = face * (0.85 + 0.3 * flake[..., None])
    col = dark + (face - dark) * plate[..., None]
    return col, height, 0.85 + 0.1 * (1 - plate)


def bark_aleppo(r):
    """Aleppo pine: grey-brown (#6e6258), cracked into long ridges, reddish
    in the fissures."""
    ridges = fbm(CORE, CORE, 5, 5, r, aspect=6.0)
    fiss = smoothstep(0.3, 0.62, ridges)
    plates = fbm(CORE, CORE, 20, 3, r, aspect=1.6)
    height = np.clip(fiss * 0.8 + plates * 0.2, 0, 1)
    base, dark, inner = hx("#6e6258"), hx("#2f2722"), hx("#7a5240")
    col = inner + (base - inner) * smoothstep(0.15, 0.5, height)[..., None]
    col = dark + (col - dark) * smoothstep(0.0, 0.25, height)[..., None]
    col = col * (0.9 + 0.2 * value_noise(CORE, CORE, 62, 62, r)[..., None])
    return col, height, np.full_like(height, 0.9)


def bark_phoenix(r):
    """Canary palm trunk: rows of diamond leaf bases (12 cm across, 9 cm
    high), each cut flat across its top, in brown-grey."""
    yy, xx = np.mgrid[0:CORE, 0:CORE].astype(np.float32)
    cols_, rows_ = 8, 22
    u = xx / CORE * cols_
    v = yy / CORE * rows_
    row = np.floor(v)
    u = u + (row % 2) * 0.5
    fu, fv = u - np.floor(u) - 0.5, v - row - 0.5
    dia = 1 - (np.abs(fu) * 2 + np.abs(fv) * 2)
    cell_id = (np.floor(u) % cols_) + row * cols_
    tone = r.random(cols_ * rows_ + 1)[cell_id.astype(int)]
    height = np.clip(dia * 1.6, 0, 1) ** 0.7
    scar = smoothstep(0.08, 0.0, np.abs(fv + 0.12)) * (np.abs(fu) < 0.3)
    fib = fbm(CORE, CORE, 24, 3, r, aspect=0.4)
    base, groove, cut = hx("#7a6a55"), hx("#3e3428"), hx("#a39272")
    face = base[None, None] * (0.8 + 0.35 * tone[..., None]) * (0.85 + 0.3 * fib[..., None])
    col = groove + (face - groove) * smoothstep(0.0, 0.3, height)[..., None]
    col = col + (cut - col) * scar[..., None] * 0.7
    return col, np.clip(height - scar * 0.15, 0, 1), np.full_like(height, 0.9)


def bark_washingtonia(r):
    """Washingtonia trunk: smooth grey (#8c8579) with close horizontal ring
    scars and fine vertical cracks."""
    yy = np.arange(CORE, dtype=np.float32)[:, None]
    wob = value_noise(1, CORE, 1, 9, r)[0][None, :] * 3
    ring = np.abs(np.sin(math.pi * (yy + wob) / (CORE / 33)))
    rings = smoothstep(0.0, 0.25, ring)
    cracks = smoothstep(0.75, 0.9, fbm(CORE, CORE, 4, 4, r, aspect=12.0))
    height = rings * 0.7 + 0.3 * (1 - cracks)
    base = hx("#8c8579")
    col = base[None, None] * (0.82 + 0.25 * fbm(CORE, CORE, 8, 3, r)[..., None]) * (0.75 + 0.25 * rings[..., None])
    col = col * (1 - 0.35 * cracks[..., None])
    return col, height, np.full_like(height, 0.8)


def bark_windmill(r):
    """Windmill palm (Trachycarpus): a mat of dark brown fibre round the
    leaf bases, in bands 8 cm apart."""
    img = Image.new("L", (CORE * 3, CORE * 3), 0)
    d = ImageDraw.Draw(img)
    col_img = Image.new("RGB", (CORE * 3, CORE * 3), (0, 0, 0))
    dc = ImageDraw.Draw(col_img)
    for _ in range(9000):
        x, y = r.uniform(CORE, 2 * CORE), r.uniform(CORE, 2 * CORE)
        a = math.pi / 2 + r.normal(0, 0.5)
        L = r.uniform(10, 30)
        tone = r.uniform(0.6, 1.2)
        for ox in (-CORE, 0, CORE):
            for oy in (-CORE, 0, CORE):
                p = [(x + ox, y + oy), (x + ox + math.cos(a) * L, y + oy + math.sin(a) * L)]
                d.line(p, fill=int(150 + 100 * r.random()), width=2)
                dc.line(p, fill=tuple(int(v * 255) for v in np.clip(hx("#4a3a2a") * tone, 0, 1)), width=2)
    h = np.asarray(img.crop((CORE, CORE, 2 * CORE, 2 * CORE)), np.float32) / 255
    col = np.asarray(col_img.crop((CORE, CORE, 2 * CORE, 2 * CORE)), np.float32) / 255
    yy = np.arange(CORE, dtype=np.float32)[:, None]
    band = smoothstep(0.6, 0.95, np.abs(np.sin(math.pi * yy / (CORE / 25))))
    col = col * (h[..., None] > 0) + hx("#2a2018") * (h[..., None] == 0)
    col = col + (hx("#6a5038") - col) * band[..., None] * 0.5
    return col, np.clip(h * 0.7 + band * 0.3, 0, 1), np.full_like(h, 0.95)


def bark_olive(r):
    """Olive: grey (#7d786d), twisted and knobbly, deep wavy fissures,
    pale lichen."""
    yy, xx = np.mgrid[0:CORE, 0:CORE].astype(np.float32)
    warp = (np.sin(2 * math.pi * yy / CORE * 2) * 18 + np.sin(2 * math.pi * yy / CORE * 5 + 1) * 6).astype(np.float32)
    ridges = fbm(CORE, CORE, 6, 5, r, aspect=4.0)
    shift = np.round(warp).astype(int)
    tw = np.stack([np.roll(ridges[y], shift[y, 0]) for y in range(CORE)])
    fiss = smoothstep(0.32, 0.6, tw)
    knobs = smoothstep(0.6, 0.9, fbm(CORE, CORE, 6, 3, r))
    height = np.clip(fiss * 0.7 + knobs * 0.3, 0, 1)
    base, dark, lichen = hx("#7d786d"), hx("#4e4a44"), hx("#a8a898")
    col = dark + (base - dark) * smoothstep(0.0, 0.35, height)[..., None]
    lm = smoothstep(0.72, 0.85, fbm(CORE, CORE, 10, 4, r)) * height
    col = col + (lichen - col) * lm[..., None] * 0.5
    return col * (0.9 + 0.2 * value_noise(CORE, CORE, 62, 62, r)[..., None]), height, np.full_like(height, 0.88)


def bark_opuntia(r):
    """Prickly-pear pad (0.5 m square): waxy green (#5b6b3a), mottled, with
    areoles on a diagonal lattice every 3 cm, each a brown tuft in a pale
    ring."""
    mott = fbm(CORE, CORE, 8, 4, r)
    col = hx("#5b6b3a")[None, None] * (0.85 + 0.3 * mott[..., None])
    col = col + (hx("#7a8a4a") - col) * smoothstep(0.65, 0.85, fbm(CORE, CORE, 5, 3, r))[..., None] * 0.6
    yy, xx = np.mgrid[0:CORE, 0:CORE].astype(np.float32)
    n = 16
    u, v = xx / CORE * n, yy / CORE * n
    u = u + (np.floor(v) % 2) * 0.5
    jit = r.uniform(-0.15, 0.15, (n + 1, n + 1, 2))
    iu, iv = (np.floor(u) % n).astype(int), (np.floor(v) % n).astype(int)
    du = (u - np.floor(u) - 0.5 + jit[iv, iu, 0]) * CORE / n
    dv = (v - np.floor(v) - 0.5 + jit[iv, iu, 1]) * CORE / n
    rr = np.sqrt(du * du + dv * dv)
    dot = smoothstep(3.5, 2.0, rr)
    ring = smoothstep(6.0, 4.0, rr) * (1 - dot)
    col = col + (hx("#a9b07a") - col) * ring[..., None] * 0.35
    col = col + (hx("#6a4a2a") - col) * dot[..., None]
    height = 0.6 + 0.2 * mott - 0.25 * ring + 0.35 * dot
    return col, np.clip(height, 0, 1), np.full_like(height, 0.5) - 0.1 * dot


def bark_agave(r):
    """Agave leaf (0.5 m square, along v): glaucous blue-grey (#8a9a8a),
    faint long striations and pale imprints of the neighbouring leaves'
    teeth."""
    stri = fbm(CORE, CORE, 4, 4, r, aspect=16.0)
    yy = np.arange(CORE, dtype=np.float32)[:, None]
    ghost = smoothstep(0.85, 1.0, np.abs(np.sin(math.pi * yy / (CORE / 9)))) * smoothstep(0.4, 0.7, fbm(CORE, CORE, 4, 2, r))
    col = hx("#8a9a8a")[None, None] * (0.9 + 0.15 * stri[..., None])
    col = col + (hx("#b2bcae") - col) * ghost[..., None] * 0.5
    col = col * (0.92 + 0.12 * fbm(CORE, CORE, 10, 3, r)[..., None])
    return col, np.clip(0.5 + 0.2 * stri + 0.1 * ghost, 0, 1), np.full_like(stri, 0.45)


BARK_MED = [bark_stone_pine, bark_aleppo, bark_phoenix, bark_washingtonia, bark_windmill, bark_olive, bark_opuntia, bark_agave]


def bake_bark() -> None:
    """cj_bark_med_albedo.jpg + cj_bark_med_detail.rgbz (module docstring)."""
    cols = 4
    alb = np.zeros((2 * TILE, cols * TILE, 3), np.float32)
    det = np.zeros((2 * TILE, cols * TILE, 4), np.float32)
    for k, fn in enumerate(BARK_MED):
        r = rng(500 + k)
        col, height, rough = fn(r)
        nx, ny, _ = normal_xy(height, 5.0 if k < 6 else 2.5)
        tile_det = np.stack([nx * 0.5 + 0.5, ny * 0.5 + 0.5, np.clip(rough, 0, 1), height], -1)
        pad = ((GUTTER, GUTTER), (GUTTER, GUTTER), (0, 0))
        oy, ox = (k // cols) * TILE, (k % cols) * TILE
        alb[oy:oy + TILE, ox:ox + TILE] = np.pad(np.clip(col, 0, 1), pad, mode="wrap")
        det[oy:oy + TILE, ox:ox + TILE] = np.pad(tile_det, pad, mode="wrap")
    save_rgb(OUT / "cj_bark_med_albedo.jpg", alb, 90)
    save_raw(OUT / "cj_bark_med_detail.rgbz", det)
    print("bark tiles mean albedo", [np.round(alb[(k // cols) * TILE:(k // cols + 1) * TILE, (k % cols) * TILE:(k % cols + 1) * TILE].reshape(-1, 3).mean(0), 3).tolist() for k in range(8)])


# ---------------------------------------------------------------- grass

SPRING_BASE, SPRING_TIP = hx("#2e3c16"), hx("#6e7c3e")
STRAW_BASE, STRAW_TIP = hx("#6e6448"), hx("#a89e7a")


def _tuft_med(d, x0, y1, cw, ch, s, r, n, dry_share, oats=False, tall=1.0):
    """Riviera grass blades rooted on a cell's bottom edge; `oats`: some
    stems end in drooping wild-oat spikelets."""
    for _ in range(n):
        bx = x0 + r.uniform(0.15, 0.85) * cw
        height = r.uniform(0.35, 0.95) * ch * tall
        lean = r.normal(0, 0.25) * height
        dry = r.random() < dry_share
        tip = _blade(d, bx, y1, height, lean, r.uniform(3, 6) * s, STRAW_BASE if dry else SPRING_BASE,
                     STRAW_TIP if dry else SPRING_TIP, r, dry_tip=not dry and r.random() < 0.2)
        if oats and r.random() < 0.3:
            x, y = tip
            for k in range(7):
                a = math.pi / 2 + r.normal(0, 0.5)
                sx, sy = x + r.normal(0, 6 * s), y + k * 6 * s
                L = r.uniform(10, 16) * s
                d.line([(sx, sy), (sx + math.cos(a) * L * 0.3, sy + math.sin(a) * L * 0.3)], fill=(150, 150, 96, 255), width=s)
                d.ellipse([sx + math.cos(a) * L * 0.3 - 2 * s, sy + math.sin(a) * L * 0.3 - 1 * s,
                           sx + math.cos(a) * L * 0.3 + 2 * s, sy + math.sin(a) * L + 2 * s], fill=(178, 172, 110, 255))


def bake_grass(size: int = 1024) -> None:
    """cj_grass_med.png: cj_grass.png's layout (bake_materials.bake_grass),
    Riviera plants in late March (module docstring)."""
    s = 2
    W = size * s
    img = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    r = rng(551)
    cw = 256 * s
    _tuft_med(d, 0, 512 * s, cw, 512 * s, s, r, 150, 0.18)
    _tuft_med(d, cw, 512 * s, cw, 512 * s, s, r, 120, 0.3, oats=True)
    _tuft_med(d, 2 * cw, 512 * s, cw, 512 * s, s, r, 150, 0.85, tall=0.95)
    # Wild fennel: a few old straw stalks and feathery blue-green leaves of
    # thread-fine segments.
    x0, y1, ch = 3 * cw, 512 * s, 512 * s
    _tuft_med(d, x0, y1, cw, ch * 0.35, s, r, 25, 0.3)
    for k in range(6):
        bx = x0 + r.uniform(0.2, 0.8) * cw
        height = r.uniform(0.55, 0.95) * ch
        dry = k < 2
        _blade(d, bx, y1, height, r.normal(0, 0.05) * height, 4 * s, STRAW_BASE if dry else hx("#55703e"),
               STRAW_TIP if dry else hx("#6a8a50"), r, steps=8)
        for _ in range(int(r.integers(5, 9))):
            t = r.uniform(0.15, 0.95)
            px, py = bx, y1 - t * height
            for _ in range(5):
                a0 = r.uniform(-math.pi, 0)
                qx, qy = px + math.cos(a0) * r.uniform(8, 20) * s, py + math.sin(a0) * r.uniform(8, 20) * s
                d.line([(px, py), (qx, qy)], fill=fill(hx("#5a7044")), width=s)
                for _ in range(14):
                    a = r.uniform(0, 2 * math.pi)
                    L = r.uniform(5, 14) * s
                    c = (hx("#b8ae80") if dry else hx("#6f8c56")) * r.uniform(0.85, 1.12)
                    d.line([(qx, qy), (qx + math.cos(a) * L, qy + math.sin(a) * L)], fill=fill(c), width=s)
    y1, ch = 896 * s, 384 * s

    def oxalis(x, y):
        for _ in range(int(r.integers(4, 8))):
            a, rr = r.uniform(-math.pi, 0), r.uniform(6, 14) * s
            fx, fy = x + math.cos(a) * rr, y + math.sin(a) * rr
            q = r.uniform(5, 7) * s
            d.line([(x, y), (fx, fy)], fill=(90, 120, 50, 255), width=s)
            for p in range(5):
                pa = p * 1.2566 + r.uniform(0, 0.3)
                d.ellipse([fx + math.cos(pa) * q * 0.5 - q * 0.55, fy + math.sin(pa) * q * 0.5 - q * 0.55,
                           fx + math.cos(pa) * q * 0.5 + q * 0.55, fy + math.sin(pa) * q * 0.5 + q * 0.55],
                          fill=fill(hx("#f0d020"), r, 0.06))
    # Oxalis: a low mat of trefoil leaves, then the flower stalks.
    for _ in range(60):
        x = r.uniform(0.15, 0.85) * cw
        yb = y1 - r.uniform(0, 0.25) * ch
        for p in range(3):
            pa = -math.pi / 2 + (p - 1) * 2.1
            q = r.uniform(5, 8) * s
            d.ellipse([x + math.cos(pa) * q - q, yb + math.sin(pa) * q - q, x + math.cos(pa) * q + q, yb + math.sin(pa) * q + q],
                      fill=fill(hx("#4e7a2a"), r, 0.12))
    for _ in range(7):
        bx = r.uniform(0.2, 0.8) * cw
        height = r.uniform(0.45, 0.85) * ch
        tip = _blade(d, bx, y1, height, r.normal(0, 0.1) * height, 3 * s, hx("#5a7a34"), hx("#6a8a3c"), r, steps=8)
        oxalis(*tip)

    def valerian(x, y):
        for _ in range(int(r.integers(20, 32))):
            a, rr = r.uniform(0, 2 * math.pi), math.sqrt(r.uniform(0, 1)) * 13 * s
            q = r.uniform(2.2, 3.2) * s
            c = hx("#c84860") if r.random() < 0.8 else hx("#e6a0b0")
            d.ellipse([x + math.cos(a) * rr - q, y + math.sin(a) * rr * 0.6 - q, x + math.cos(a) * rr + q, y + math.sin(a) * rr * 0.6 + q],
                      fill=fill(c, r, 0.08))
    # Red valerian: glaucous leaves, domed red-pink heads.
    for _ in range(7):
        bx = cw + r.uniform(0.2, 0.8) * cw
        height = r.uniform(0.5, 0.92) * ch
        tip = _blade(d, bx, y1, height, r.normal(0, 0.08) * height, 4 * s, hx("#6a7a5a"), hx("#7a8a68"), r, steps=8)
        for k in range(3):
            t = r.uniform(0.15, 0.6)
            for sgn in (-1, 1):
                _leaf(d, bx, y1 - t * height, r.uniform(26, 40) * s, r.uniform(8, 12) * s, -math.pi / 2 + sgn * r.uniform(0.5, 0.9),
                      hx("#7a8a6c") * r.uniform(0.85, 1.1))
        valerian(*tip)

    def daisy(x, y):
        yellow = r.random() < 0.6
        q = r.uniform(8, 11) * s
        for p in range(14):
            pa = p * 2 * math.pi / 14
            d.line([(x, y), (x + math.cos(pa) * q, y + math.sin(pa) * q * 0.6)],
                   fill=fill(hx("#f2d23c") if yellow else hx("#f4f0dc"), r, 0.05), width=3 * s)
        d.ellipse([x - q * 0.3, y - q * 0.2, x + q * 0.3, y + q * 0.2], fill=fill(hx("#d8a020")))
    # Crown daisies: branched stems, dissected leaves.
    _tuft_med(d, 2 * cw, y1, cw, ch * 0.3, s, r, 30, 0.1)
    for _ in range(16):
        bx = 2 * cw + r.uniform(0.2, 0.8) * cw
        height = r.uniform(0.4, 0.9) * ch
        tip = _blade(d, bx, y1, height, r.normal(0, 0.12) * height, 3 * s, hx("#4a6a2a"), hx("#5a7a34"), r, steps=8)
        for _ in range(4):
            t = r.uniform(0.1, 0.6)
            for sgn in (-1, 1):
                a = -math.pi / 2 + sgn * r.uniform(0.6, 1.1)
                px, py = bx, y1 - t * height
                for q in range(4):
                    d.line([(px, py), (px + math.cos(a) * 9 * s, py + math.sin(a) * 9 * s)], fill=(78, 112, 44, 255), width=2 * s)
                    px, py = px + math.cos(a) * 7 * s, py + math.sin(a) * 7 * s
                    a += sgn * 0.3
        daisy(*tip)
    # Acanthus: broad, deeply lobed, glossy dark leaves arching from the
    # base (on shaded banks, where the Flemish atlas has its ferns).
    x0 = 3 * cw
    layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    fd = ImageDraw.Draw(layer)
    cx = x0 + cw / 2
    for k in range(7):
        ang = -math.pi / 2 + (k - 3) * 0.36 + r.uniform(-0.1, 0.1)
        length = r.uniform(0.55, 0.9) * ch
        col = hx("#2f4a22") * r.uniform(0.85, 1.15)
        prev = (cx + r.uniform(-10, 10) * s, y1)
        steps = 14
        arch = r.uniform(0.5, 0.9) * (1 if ang > -math.pi / 2 else -1)
        for i in range(1, steps + 1):
            t = i / steps
            a = ang + arch * t * t
            p = (prev[0] + math.cos(a) * length / steps, prev[1] + math.sin(a) * length / steps)
            fd.line([prev, p], fill=(58, 80, 40, 255), width=3 * s)
            lob = (math.sin(math.pi * min(t * 1.2, 1)) * 52 * s) * (0.7 + 0.3 * math.sin(i * 1.9))
            for sgn in (-1, 1):
                _leaf(fd, p[0], p[1], lob, lob * 0.7, a + sgn * 1.2, col * r.uniform(0.9, 1.1))
            prev = p
    d.rectangle([x0, 512 * s, W - 1, y1 - 1], fill=(0, 0, 0, 0))
    img.alpha_composite(layer.crop((x0, 512 * s, W, y1)), (x0, 512 * s))
    # Sward strips, tileable in u.
    for (top, bottom, n, hr, dry, rough) in [(912, 968, 2400, (0.45, 1.0), 0.2, False), (968, 1024, 1500, (0.4, 1.0), 0.5, True)]:
        strip = Image.new("RGBA", (W, (bottom - top) * s), (0, 0, 0, 0))
        sd = ImageDraw.Draw(strip)
        sh = (bottom - top) * s - 2 * s
        base_y = (bottom - top) * s
        if not rough:   # clover and the odd buttercup at the foot of the spring sward
            for _ in range(700):
                x = r.uniform(0, W)
                yellow = r.random() < 0.06
                for off in (-W, 0, W):
                    for k in range(3):
                        c = (220, 190, 40, 255) if yellow else (52, 88, 30, 255)
                        sd.ellipse([x + off + (k - 1) * 5 * s - 4 * s, base_y - 9 * s - 4 * s, x + off + (k - 1) * 5 * s + 4 * s,
                                    base_y - 9 * s + 3 * s], fill=c)
        for _ in range(n):
            x = r.uniform(0, W)
            height = r.uniform(*hr) * sh
            lean = r.normal(0, 0.18) * height
            w_ = r.uniform(2, 4) * s
            dry_ = r.random() < dry
            seed = rough and r.random() < 0.15
            for off in (-W, 0, W):
                tip = _blade(sd, x + off, base_y, height, lean, w_, STRAW_BASE if dry_ else SPRING_BASE,
                             STRAW_TIP if dry_ else SPRING_TIP, rng(int(x * 10) % 100000), steps=6)
                if seed:
                    sd.ellipse([tip[0] - 3 * s, tip[1] - 2 * s, tip[0] + 3 * s, tip[1] + 8 * s], fill=(196, 186, 140, 255))
        img.alpha_composite(strip, (0, top * s))
    img = img.resize((size, size), Image.LANCZOS)
    arr = np.asarray(img, np.float32) / 255
    rgb, a = arr[..., :3], arr[..., 3:]
    jag = value_noise(size, size, 8, 64, r)
    rr = rng(552)
    rag = (0.45 * value_noise(1, size, 1, 13, rr)[0] + 0.3 * value_noise(1, size, 1, 5, rr)[0]
           + 0.25 * value_noise(1, size, 1, 29, rr)[0])
    fade = np.ones((size, size), np.float32)
    for (top, bottom) in [(0, 512), (512, 896), (912, 968), (968, 1024)]:
        yy = (np.arange(top, bottom, dtype=np.float32) - top)[:, None] / (bottom - top)
        strip = bottom - top < 100
        span = 0.18 if strip else 0.06
        lift = (0.5 if bottom == 1024 else 0.35) * smoothstep(0.3, 0.8, rag)[None, :] if strip else 0.0
        fade[top:bottom] = smoothstep(0.0, 1.0, (1 - yy - 0.015 - jag[top:bottom] * span * 0.8 - lift) / span)
    fade[508:516] = 0
    fade[892:912] = 0
    a = a * fade[..., None]
    blurred = blur(rgb * a, 4) / np.maximum(blur(a, 4), 1e-3)
    arr[..., :3] = rgb * a + blurred * (1 - a)
    arr[..., 3:] = a
    save_rgba(OUT / "cj_grass_med.png", arr)
    # The tufts' mean linear colour, for VegetationBuilder.grassCardColorMed.
    lin = np.where(rgb <= 0.04045, rgb / 12.92, ((rgb + 0.055) / 1.055) ** 2.4)
    top = a[:512, :, 0] > 0.5
    print("grass coverage per region", [round(float(a[t:b].mean()), 3) for t, b in [(0, 512), (512, 896), (912, 968), (968, 1024)]],
          "tuft mean linear", np.round(lin[:512][top].mean(0), 4).tolist())


# ---------------------------------------------------------------- main

BAKERS = {"foliage": bake_foliage, "impostors": bake_impostors, "bark": bake_bark, "grass": bake_grass}


def preview(out_dir: Path) -> None:
    """Small JPEG previews of the outputs over a sky-blue ground, for a
    look before a build."""
    out_dir.mkdir(parents=True, exist_ok=True)
    for name in ["cj_foliage_med.png", "cj_impostor_med.png", "cj_grass_med.png"]:
        p = OUT / name
        if not p.exists():
            continue
        im = Image.open(p).convert("RGBA")
        bg = Image.new("RGBA", im.size, (140, 175, 220, 255))
        bg.alpha_composite(im)
        bg = bg.convert("RGB")
        bg.thumbnail((1600, 1600))
        bg.save(out_dir / (p.stem + "_preview.jpg"), quality=80)
    p = OUT / "cj_bark_med_albedo.jpg"
    if p.exists():
        im = Image.open(p)
        im.thumbnail((1600, 1600))
        im.save(out_dir / "cj_bark_med_preview.jpg", quality=80)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="", help="comma-separated subset of " + ",".join(BAKERS))
    ap.add_argument("--preview", default="", help="write JPEG previews of the outputs to this folder")
    args = ap.parse_args()
    OUT.mkdir(parents=True, exist_ok=True)
    names = [n for n in args.only.split(",") if n] or list(BAKERS)
    for n in names:
        t = time.time()
        BAKERS[n]()
        print(f"{n}: {time.time() - t:.1f} s", flush=True)
    if args.preview:
        preview(Path(args.preview))
    return 0


if __name__ == "__main__":
    sys.exit(main())
