# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Bake the Riviera's sky in high dynamic range, with volumetric cumulus.

    uv run --script scripts/courses/textures/bake_sky_hdr.py [--preview out.jpg] [--size 1024]

The Poggio is drawn through a camera response curve (`CoursePost`), so its
sky keeps its real radiance: the glare round the sun runs to several times
white, the sun's disc to thousands, and sunlit cloud tops to nearly twice
it. Everything is procedural (no photos, no downloaded assets).

Writes, in CycleJames/Resources/CourseTextures/:

- cj_sky_lig.hdrc: the background cube (see `save_hdr_cube`), linear
  radiance, faces in SceneKit's order (+x, -x, +y, -y, +z, -z).
- cj_sky_lig_{px,...}.jpg: the same sky clipped at SKY_SCALE and stored as
  the 8-bit faces have always been, for a device that can't take the HDR
  cube.
- cj_skyenv_lig_*.jpg: the lighting environment, as bake_materials.py wrote
  it (the same calibrated ambient), under the new clouds.
- cj_sea_sky.jpg: the sky above the horizon for the sea and the greenhouse
  glass to mirror.

and beside this script cj_sky_horizon_lig.json: the haze the far land and
sea fade to, by direction (`WorldLook+Sky.swift` keeps its numbers).

The clouds are fair-weather cumulus marched through a slab 1.3-3.0 km up:
flat bases, cauliflower tops, lit by the sun through their own depth (with
an approximation of multiple scattering) and by the sky. More of them stand
over the hills inland than over the sea (look.md section 2).
"""
from __future__ import annotations

import argparse
import json
import math
import struct
import sys
import time
import zlib
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import bake_materials as bm  # noqa: E402
from texlib import (blur, fbm, linear_to_srgb, rng, save_rgb, save_rgb_dithered, smoothstep,  # noqa: E402
                    srgb_to_linear, value_noise)

OUT = bm.OUT
STYLE = bm.RIVIERA
LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)

# ---------------------------------------------------------------- clear sky

# The glare round the sun: forward scattering by the haze, in two tight
# lobes (a couple of degrees and half a dozen across), on top of the
# Preetham distribution's own circumsolar term, which already puts the sky
# twenty degrees from the sun at the brightness of sunlit paper.
AUREOLE = ((2500.0, 2.0), (260.0, 0.3))
AUREOLE_COLOUR = np.array([1.0, 0.95, 0.86], np.float32)
# The sun's disc: 0.267 degrees in radius, at the radiance that carries the
# key light's irradiance (a white board facing the sun reads 4.8 times the
# ambient 0.454, WorldMaterials.lightK), capped where the HDR format and the
# bloom can use it.
SUN_DISC_RADIANCE = 1500.0
SUN_COS = math.cos(math.radians(0.267))


def clear_sky_hdr(d: np.ndarray) -> np.ndarray:
    """Linear clear-sky radiance for unit directions d, as bake_materials'
    `clear_sky`, without the roll-off that kept the glare under an 8-bit
    face's white."""
    Y = bm.preetham_luminance(d, STYLE.turbidity) * STYLE.zenith_linear
    sky = bm.sky_chroma(d, STYLE) * Y[..., None]
    up = d[..., 1]
    sky = sky * bm.low_sky_gain(up, STYLE)[..., None]
    sky = sky * (1 + np.array([0.0, STYLE.cyan, 0.0], np.float32) * smoothstep(0.25, 0.6, up)[..., None])
    return sky.astype(np.float32)


def horizon_ring(n: int = 720) -> tuple[np.ndarray, np.ndarray]:
    """The clear sky a degree above the horizon, all round: (compass
    azimuths in radians, linear colours)."""
    az = (np.arange(n, dtype=np.float32) + 0.5) / n * 2 * math.pi
    el = math.radians(1.0)
    d = np.stack([np.sin(az) * math.cos(el), np.full_like(az, math.sin(el)), -np.cos(az) * math.cos(el)], -1)
    return az, clear_sky_hdr(d.astype(np.float32))


def fit_horizon() -> dict:
    """The horizon's haze by azimuth as `base + glow * ((1 + cos(a)) / 2)^p`,
    a the azimuth from the sun's: what the far land and sea fade to in the
    shaders (`WorldShaders.aerialFragment`), and the lowest band of the
    sky. Fitted to the clear sky a degree up."""
    az, ring = horizon_ring()
    sun_az = math.radians(bm.SUN_AZIMUTH_DEG)
    x = 0.5 + 0.5 * np.cos(az - sun_az)
    best = None
    for p in np.arange(1.0, 12.01, 0.25):
        g = x ** p
        A = np.stack([np.ones_like(g), g], -1)
        coef, *_ = np.linalg.lstsq(A, ring, rcond=None)
        err = float(((A @ coef - ring) ** 2).sum())
        if best is None or err < best[0]:
            best = (err, p, coef)
    _, p, coef = best
    return {"power": float(p), "base": coef[0].astype(np.float32), "glow": coef[1].astype(np.float32)}


def horizon_haze_dir(d: np.ndarray, fit: dict) -> np.ndarray:
    """The fitted horizon haze towards directions d (by azimuth only)."""
    sun = bm.sun_vector()
    s2 = np.array([sun[0], sun[2]]) / math.hypot(sun[0], sun[2])
    h = np.hypot(d[..., 0], d[..., 2])
    c = np.clip((d[..., 0] * s2[0] + d[..., 2] * s2[1]) / np.maximum(h, 1e-6), -1, 1)
    g = (0.5 + 0.5 * c) ** fit["power"]
    return fit["base"] + fit["glow"] * g[..., None]


# The fog (what the far land and sea fade to, below the horizon) as a share
# of the haze band just above it: a sea horizon is a little darker and bluer
# than the sky it meets (bake_materials: fog #9fb5cb under haze #c8d6e4).
def fog_ratio() -> np.ndarray:
    return (bm.fog_colour(STYLE) / bm.horizon_haze(STYLE)).astype(np.float32)


# ---------------------------------------------------------------- clouds

CLOUD_BASE_KM = 1.3
CLOUD_TOP_KM = 2.3
COVER_TILE_KM = 44.0
# Where on the cover tile the viewer stands: picked from `--plan` for a few
# good clouds 10-30 degrees up all round and none near the sun.
COVER_OFFSET = [0.775, 0.041]
SHAPE_TILE_KM = 3.3
DETAIL_TILE_KM = 0.74
EXTINCTION = 55.0       # per km of full density
EYE_KM = 0.1


def worley(n: int, cells: int, r: np.random.Generator, dims: int = 2) -> np.ndarray:
    """Tiling Worley noise over an n^dims lattice: 1 at a cell's centre
    falling to 0 at its rim (round puffs), one jittered site per cell."""
    from scipy.spatial import cKDTree
    grid = np.stack(np.meshgrid(*[np.arange(cells)] * dims, indexing="ij"), -1).reshape(-1, dims)
    pts = (grid + r.random(grid.shape)) / cells
    shifts = np.stack(np.meshgrid(*[np.array([-1, 0, 1])] * dims, indexing="ij"), -1).reshape(-1, dims)
    tree = cKDTree(np.concatenate([pts + sh for sh in shifts]))
    q = np.stack(np.meshgrid(*[(np.arange(n) + 0.5) / n] * dims, indexing="ij"), -1).reshape(-1, dims)
    dist, _ = tree.query(q, k=1)
    return (1 - np.clip(dist.reshape([n] * dims) * cells / 0.8, 0, 1)).astype(np.float32)


def norm01(a: np.ndarray) -> np.ndarray:
    lo, hi = np.percentile(a, 0.5), np.percentile(a, 99.5)
    return np.clip((a - lo) / max(hi - lo, 1e-6), 0, 1).astype(np.float32)


def cloud_noise(seed: int = 211) -> dict:
    """The fields the cloud density is built from, each a wrapping tile:
    where clouds stand (2D), their billows (3D, puffs of 1.1 km down to
    140 m) and the cauliflower of their surface (3D, 185 to 46 m)."""
    r = rng(seed)
    cover = fbm(1024, 1024, 20, 4, r, gain=0.5)
    shape = norm01(0.42 * worley(96, 3, r, 3) + 0.3 * worley(96, 6, r, 3) + 0.19 * worley(96, 12, r, 3)
                   + 0.09 * worley(96, 24, r, 3))
    detail = norm01(0.5 * worley(64, 4, r, 3) + 0.3 * worley(64, 8, r, 3) + 0.2 * worley(64, 16, r, 3))
    # The cover field's level under which a given share of the ground lies.
    levels = np.percentile(cover, np.arange(0, 100.5, 0.5)).astype(np.float32)
    return {"cover": cover.astype(np.float32), "shape": shape, "detail": detail, "levels": levels}


def tex(t: np.ndarray, u: np.ndarray, v: np.ndarray) -> np.ndarray:
    """Bilinear lookup in a wrapping tile, (u, v) in tiles."""
    n = t.shape[0]
    x = (u % 1.0) * n - 0.5
    y = (v % 1.0) * n - 0.5
    x0 = np.floor(x).astype(np.int32)
    y0 = np.floor(y).astype(np.int32)
    fx = (x - x0).astype(np.float32)
    fy = (y - y0).astype(np.float32)
    x0 %= n
    y0 %= n
    x1 = (x0 + 1) % n
    y1 = (y0 + 1) % n
    return (t[y0, x0] * (1 - fx) + t[y0, x1] * fx) * (1 - fy) + (t[y1, x0] * (1 - fx) + t[y1, x1] * fx) * fy


def tex3(t: np.ndarray, u: np.ndarray, v: np.ndarray, w: np.ndarray) -> np.ndarray:
    """Trilinear lookup in a wrapping cube, (u, v, w) in tiles."""
    n = t.shape[0]
    out = None
    c = [(q % 1.0) * n - 0.5 for q in (u, v, w)]
    i0 = [np.floor(q).astype(np.int32) for q in c]
    f = [(q - i).astype(np.float32) for q, i in zip(c, i0)]
    i0 = [i % n for i in i0]
    i1 = [(i + 1) % n for i in i0]
    for a, wa in ((i0[0], 1 - f[0]), (i1[0], f[0])):
        for b, wb in ((i0[1], 1 - f[1]), (i1[1], f[1])):
            for cc, wc in ((i0[2], 1 - f[2]), (i1[2], f[2])):
                term = t[a, b, cc] * (wa * wb * wc)
                out = term if out is None else out + term
    return out


def cloudiness(nz: dict, x: np.ndarray, z: np.ndarray) -> np.ndarray:
    """How much cloud stands over the ground point (x east, z south, km): 0
    clear to 1 a cumulus's core. Small clouds are scattered all round, more
    and larger ones stand from a few kilometres inland (north), fewer over
    the sea; none between the eye and the sun, which shines on the road
    the whole ride, and none overhead."""
    c = tex(nz["cover"], x / COVER_TILE_KM + COVER_OFFSET[0], z / COVER_TILE_KM + COVER_OFFSET[1])
    north = -z
    # The share of the ground with any cloud over it: 36 % inland, 26 %
    # overhead, 14 % out over the sea (about half of it thick enough to see).
    share = 0.26 + 0.10 * smoothstep(1.5, 10.0, north) - 0.12 * smoothstep(0.5, 8.0, -north)
    sun = bm.sun_vector()
    s2 = np.array([sun[0], sun[2]]) / math.hypot(sun[0], sun[2])
    reach = math.hypot(sun[0], sun[2]) / sun[1]
    along = np.clip(x * s2[0] + z * s2[1], CLOUD_BASE_KM * reach * 0.6, CLOUD_TOP_KM * reach * 1.1)
    off = np.hypot(x - along * s2[0], z - along * s2[1])
    share = share * smoothstep(1.2, 3.4, off)
    # None overhead either: a cumulus within a few kilometres would fill
    # the top of the frame with its dark base over a road it casts no
    # shade on. From 2.5 km out its base is seen from the side.
    share = share * smoothstep(2.3, 4.8, np.hypot(x, z))
    lv = nz["levels"]
    thr = np.interp(100 - share * 100, np.arange(0, 100.5, 0.5), lv).astype(np.float32)
    return smoothstep(thr, thr + 0.27, c)


def density(nz: dict, x: np.ndarray, y: np.ndarray, z: np.ndarray, detail: bool = True, m=None) -> np.ndarray:
    """Cloud density, 0-1, at points (km). A cumulus stands on a flat base
    and rises with its size; its body is a heap of billows, their surface
    eaten into cauliflower."""
    if m is None:
        m = cloudiness(nz, x, z)
    h = (y - CLOUD_BASE_KM) / (CLOUD_TOP_KM - CLOUD_BASE_KM)
    # A dome: the top comes down to the base at the cloud's rim.
    top = np.maximum(m, 1e-4) ** 0.75
    hr = h / top
    prof = smoothstep(0.0, 0.1, hr) * (1 - smoothstep(0.45, 1.0, hr))
    lf = tex3(nz["shape"], x / SHAPE_TILE_KM, y / SHAPE_TILE_KM, z / SHAPE_TILE_KM)
    d = np.sqrt(m) * prof * (0.42 + 0.86 * lf) - 0.33
    if detail:
        hf = tex3(nz["detail"], x / DETAIL_TILE_KM, y / DETAIL_TILE_KM, z / DETAIL_TILE_KM)
        # The base stays flat and solid; the rest is eroded at its surface.
        d = d - 0.46 * (1 - hf) * (1 - smoothstep(0.0, 0.4, d)) * smoothstep(0.02, 0.3, hr)
        # Denser and thinner in its billows all the way through, so a cloud
        # seen against the light is not one even grey.
        return (np.clip(d * 11.0, 0, 1) * (0.62 + 0.76 * hf)).astype(np.float32)
    return np.clip(d * 11.0, 0, 1).astype(np.float32)


def may_hold_cloud(nz: dict, x: np.ndarray, y: np.ndarray, z: np.ndarray) -> tuple:
    """Whether a point can have any density, cheaply, and its cloudiness."""
    m = cloudiness(nz, x, z)
    h = (y - CLOUD_BASE_KM) / (CLOUD_TOP_KM - CLOUD_BASE_KM)
    return (np.sqrt(m) * 1.28 > 0.33) & (h < np.maximum(m, 1e-4) ** 0.75), m


def hg(g: float, c: np.ndarray) -> np.ndarray:
    """Henyey-Greenstein phase function times 4 pi (1 when isotropic)."""
    return (1 - g * g) / np.power(1 + g * g - 2 * g * c, 1.5)


def march(d: np.ndarray, nz: dict, steps: int, jitter: np.ndarray, sun_gain: float = 1.0) -> tuple:
    """Marches rays from the eye along unit directions d (n, 3) through the
    cloud slab. Returns the clouds' radiance (n, 3), the transmittance left
    for the sky behind (n,) and the mean distance of the cloud seen, km."""
    sun = bm.sun_vector().astype(np.float32)
    n = d.shape[0]
    up = np.maximum(d[:, 1], 1e-4)
    t0 = (CLOUD_BASE_KM - EYE_KM) / up
    t1 = np.minimum((CLOUD_TOP_KM - EYE_KM) / up, 70.0)
    dt = np.maximum(t1 - t0, 0) / steps
    cosg = np.clip(d @ sun, -1, 1)
    # Two lobes: strong forward scattering (the silver lining towards the
    # sun) and a little back scattering.
    L = np.zeros((n, 3), np.float32)
    T = np.ones(n, np.float32)
    tsum = np.zeros(n, np.float32)
    wsum = np.zeros(n, np.float32)
    sun_col = np.array([1.0, 0.965, 0.91], np.float32) * 1.75 * sun_gain
    zen = clear_sky_hdr(np.array([[0.0, 1.0, 0.0]], np.float32))[0]
    sky_amb = (zen / float(zen @ LUMA)) * 0.34
    ground_amb = np.array([0.33, 0.345, 0.36], np.float32) * 0.95
    light_steps = (0.03, 0.08, 0.16, 0.3, 0.52, 0.85)
    for k in range(steps):
        t = t0 + (k + jitter) * dt
        live = (T > 0.004) & (dt > 0)
        if not live.any():
            break
        idx = np.nonzero(live)[0]
        px = d[idx, 0] * t[idx]
        py = EYE_KM + d[idx, 1] * t[idx]
        pz = d[idx, 2] * t[idx]
        # Skip where nothing can stand.
        hit, m = may_hold_cloud(nz, px, py, pz)
        if not hit.any():
            continue
        idx = idx[hit]
        px, py, pz = px[hit], py[hit], pz[hit]
        rho = density(nz, px, py, pz, m=m[hit])
        hit = rho > 1e-3
        if not hit.any():
            continue
        idx = idx[hit]
        px, py, pz, rho = px[hit], py[hit], pz[hit], rho[hit]
        # Depth of cloud between the point and the sun.
        tau = np.zeros(len(idx), np.float32)
        prev = 0.0
        for j, s in enumerate(light_steps):
            # The nearest steps with the cauliflower, so each billow shades
            # the next; the far ones with the cloud's body alone.
            tau += density(nz, px + sun[0] * s, py + sun[1] * s, pz + sun[2] * s, detail=j < 2) * (s - prev)
            prev = s
        tau *= EXTINCTION
        c = cosg[idx]
        # Octaves of scattering (Wrenninge 2013): each deeper, dimmer, more
        # isotropic.
        sunlit = np.zeros(len(idx), np.float32)
        a, b, g = 1.0, 1.0, 1.0
        for _ in range(3):
            phase = 0.75 * hg(0.42 * g, c) + 0.25 * hg(-0.2 * g, c)
            sunlit += a * np.exp(-b * tau) * phase
            a *= 0.45
            b *= 0.3
            g *= 0.5
        # Powder: a thin rim scatters less light back towards the sun's side.
        sunlit *= 1 - 0.55 * np.exp(-rho * 5.0) * np.clip(0.5 - 0.5 * c, 0, 1)
        hrel = np.clip((py - CLOUD_BASE_KM) / (CLOUD_TOP_KM - CLOUD_BASE_KM), 0, 1)
        # The sky lights the tops and sides, the ground the bases; both are
        # dimmed inside the cloud.
        open_ = np.exp(-rho * 1.6)
        amb = (sky_amb[None, :] * (0.35 + 0.65 * hrel)[:, None] + ground_amb[None, :] * (1 - hrel)[:, None] * 0.6) \
            * (0.45 + 0.55 * open_)[:, None]
        S = sun_col[None, :] * sunlit[:, None] + amb
        od = EXTINCTION * rho * dt[idx]
        seg = 1 - np.exp(-od)
        wgt = T[idx] * seg
        L[idx] += wgt[:, None] * S
        tsum[idx] += wgt * t[idx]
        wsum[idx] += wgt
        T[idx] *= 1 - seg
    return L, T, tsum / np.maximum(wsum, 1e-6)


def cloud_layer(d: np.ndarray, nz: dict, quality: float = 1.0, seed: int = 5, sun_gain: float = 1.0) -> tuple:
    """Clouds for directions d (..., 3): radiance, the sky's share behind
    them and their distance. Rays below 1.2 degrees see none (the slab
    there is over 50 km away, and in the haze)."""
    shape = d.shape[:-1]
    flat = d.reshape(-1, 3).astype(np.float32)
    n = flat.shape[0]
    L = np.zeros((n, 3), np.float32)
    T = np.ones(n, np.float32)
    dist = np.zeros(n, np.float32)
    idx = np.nonzero(flat[:, 1] > 0.021)[0]
    r = rng(seed)
    # Steeper rays cross the slab in a short path: grouped by elevation so
    # each group marches with steps of about the same length.
    order = idx[np.argsort(-flat[idx, 1])]
    chunk = 120_000
    for a in range(0, len(order), chunk):
        sel = order[a:a + chunk]
        path = (CLOUD_TOP_KM - CLOUD_BASE_KM) / float(flat[sel, 1].mean())
        steps = int(np.clip(path / 0.022, 64, 190) * quality)
        Lc, Tc, dc = march(flat[sel], nz, steps, r.random(len(sel)).astype(np.float32), sun_gain)
        L[sel], T[sel], dist[sel] = Lc, Tc, dc
    return L.reshape(*shape, 3), T.reshape(shape), dist.reshape(shape)


def cloud_layer_aa(d: np.ndarray, nz: dict, spread: float, samples: int = 4, quality: float = 1.0) -> tuple:
    """`cloud_layer` averaged over `samples` rays jittered within `spread`
    radians of each direction (a texel), which smooths the march's grain
    and the clouds' edges."""
    r = rng(17)
    acc = None
    for k in range(samples):
        j = (r.random(d.shape, dtype=np.float32) - 0.5) * spread
        dj = d + j
        dj /= np.linalg.norm(dj, axis=-1, keepdims=True)
        out = cloud_layer(dj, nz, quality, seed=5 + k)
        acc = out if acc is None else tuple(a + b for a, b in zip(acc, out))
    return tuple(a / samples for a in acc)


# ---------------------------------------------------------------- the sky

def sky_hdr(d: np.ndarray, nz: dict, fit: dict, sun: bool = True, quality: float = 1.0,
            aa: tuple | None = None) -> np.ndarray:
    """The background's linear radiance for unit directions d (..., 3)."""
    sunv = bm.sun_vector()
    up = d[..., 1]
    cosg = np.clip((d * sunv).sum(-1), -1, 1)
    sky = clear_sky_hdr(d)
    for power, gain in AUREOLE:
        sky = sky + (np.clip(cosg, 0, 1) ** power * gain)[..., None] * AUREOLE_COLOUR
    haze = horizon_haze_dir(d, fit)
    # The lowest degrees settle on the haze of their own direction.
    band = 1 - smoothstep(0.0, 0.075, up)
    sky = sky + (haze - sky) * (band * (0.7 + 0.3 * band))[..., None]
    Lc, Tc, dist = cloud_layer(d, nz, quality) if aa is None else cloud_layer_aa(d, nz, aa[0], aa[1], quality)
    # Far clouds stand in the haze: the air below 3 km over 30-60 km.
    air = (1 - np.exp(-dist / 34.0))[..., None]
    Lc = Lc * (1 - air) + haze * air * (1 - Tc)[..., None]
    sky = sky * Tc[..., None] + Lc
    if sun:
        disc = smoothstep(SUN_COS - 2.5e-6, SUN_COS + 2.5e-6, cosg) * Tc ** 3
        sky = sky + disc[..., None] * SUN_DISC_RADIANCE * np.array([1.0, 0.96, 0.9], np.float32)
    # Below the horizon: the fog of that direction, meeting the haze band
    # in a soft line over the first half degree.
    fog = haze * fog_ratio()
    sky = fog + (sky - fog) * smoothstep(-0.002, 0.009, up)[..., None]
    assert np.isfinite(sky).all(), "the sky has a texel that is not a number"
    return sky.astype(np.float32)


def sky_env(d: np.ndarray, nz: dict, fit: dict) -> np.ndarray:
    """The lighting environment's radiance: bake_materials' calibrated sky
    (its roll-off, no sun, a hemisphere of sunlit land and sea below) under
    the new clouds, dimmed as that bake dims them."""
    base = bm.sky_radiance(d, STYLE, clouds=False, ground=True, background=False, sun_disc=False)
    Lc, Tc, _ = cloud_layer(d, nz, quality=0.6)
    lum = (Lc @ LUMA)[..., None]
    Lc = (lum + (Lc - lum) * 0.45) * bm.ENV_CLOUD_GAIN
    above = (d[..., 1] > 0)[..., None]
    return np.where(above, base * Tc[..., None] + np.minimum(Lc, 1.6), base).astype(np.float32)


# ---------------------------------------------------------------- output

def pack_rgb9e5(rgb: np.ndarray) -> np.ndarray:
    """Linear RGB (..., 3) as shared-exponent uint32 (MTLPixelFormat
    .rgb9e5Float; the OpenGL EXT_texture_shared_exponent packing)."""
    N, B, EMAX = 9, 15, 31
    limit = (2 ** N - 1) / 2 ** N * 2.0 ** (EMAX - B)
    c = np.clip(rgb.astype(np.float64), 0, limit)
    m = np.maximum(c.max(-1), 1e-30)
    e = np.maximum(-B - 1, np.floor(np.log2(m))) + 1 + B
    s = 2.0 ** (e - B - N)
    top = np.floor(m / s + 0.5)
    e = np.where(top == 2 ** N, e + 1, e)
    s = 2.0 ** (e - B - N)
    q = np.floor(c / s[..., None] + 0.5).astype(np.uint32)
    return (q[..., 0] | (q[..., 1] << 9) | (q[..., 2] << 18) | (e.astype(np.uint32) << 27)).astype("<u4")


def save_hdr_cube(path: Path, faces: list) -> None:
    """`.hdrc`: "CJHC", u32 face size, u32 face count, u32 format (1 =
    rgb9e5), then raw deflate of the faces' uint32 texels, rows top first,
    faces in SceneKit's order (`WorldTextures.hdrCube`)."""
    n = faces[0].shape[0]
    raw = b"".join(pack_rgb9e5(f).tobytes() for f in faces)
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = c.compress(raw) + c.flush()
    path.write_bytes(b"CJHC" + struct.pack("<III", n, len(faces), 1) + body)
    print(f"{path.name}: {n} px x {len(faces)}, {len(body) / 1e6:.2f} MB")


def preview(path: Path, nz: dict, fit: dict, w: int = 1536, h: int = 576) -> None:
    """Equirectangular preview, 10 degrees below the horizon to the zenith,
    north at the left edge, through a simple camera curve."""
    az = (np.arange(w, dtype=np.float32) + 0.5) / w * 2 * math.pi
    el = np.radians(90 - (np.arange(h, dtype=np.float32) + 0.5) / h * 100)
    az, el = np.meshgrid(az, el)
    d = np.stack([np.sin(az) * np.cos(el), np.sin(el), -np.cos(az) * np.cos(el)], -1).astype(np.float32)
    sky = sky_hdr(d, nz, fit, quality=0.8, aa=(2 * math.pi / w, 3))
    lum = sky @ LUMA
    print(f"preview: cloud-free zenith {clear_sky_hdr(np.array([[0, 1, 0]], np.float32))[0].round(3)}, "
          f"p50 {np.percentile(lum, 50):.3f}, p99 {np.percentile(lum, 99):.3f}, max {lum.max():.1f}")
    # Reinhard on luminance with a white point of 6, about what the post
    # pass does.
    k = (1 + lum / 36.0) / (1 + lum)
    save_rgb(path, np.clip(linear_to_srgb(sky * k[..., None] * 1.25), 0, 1), 92)


def camera_curve(rgb: np.ndarray, contrast: float = 1.3, shadows: float = 1.1, saturation: float = 1.25) -> np.ndarray:
    """The app's camera response (`CoursePost`: AgX and its look), linear
    radiance to sRGB-encoded display values, for previews."""
    inset = np.array([[0.842479062253094, 0.0784335999999992, 0.0792237451477643],
                      [0.0423282422610123, 0.878468636469772, 0.0791661274605434],
                      [0.0423756549057051, 0.0784336, 0.879142973793104]], np.float32)
    outset = np.array([[1.19687900512017, -0.0980208811401368, -0.0990297440797205],
                       [-0.0528968517574562, 1.15190312990417, -0.0989611768448433],
                       [-0.0529716355144438, -0.0980434501171241, 1.15107367264116]], np.float32)
    v = np.maximum(rgb, 0) @ inset.T
    v = (np.clip(np.log2(np.maximum(v, 1e-10)), -12.47393, 4.026069) + 12.47393) / 16.5
    v2 = v * v
    v4 = v2 * v2
    v = 15.5 * v4 * v2 - 40.14 * v4 * v + 31.96 * v4 - 6.868 * v2 * v + 0.4298 * v2 + 0.1191 * v - 0.00232
    v = np.clip(v, 0, 1)
    a = shadows + (contrast - shadows) * smoothstep(0.3, 0.7, v)
    pw = v ** a
    v = pw / np.maximum(pw + (1 - v) ** a, 1e-6)
    lum = (v @ LUMA)[..., None]
    v = (lum + saturation * (v - lum)) @ outset.T
    return linear_to_srgb(np.clip(v, 0, 1) ** 2.2)


def view(path: Path, nz: dict, fit: dict, az_deg: float, el_deg: float, fov_deg: float = 62.0,
         w: int = 900, h: int = 620) -> None:
    """A camera's view of the sky towards a compass azimuth and elevation,
    through the app's camera response: how the clouds read in a frame."""
    az, el = math.radians(az_deg), math.radians(el_deg)
    f = np.array([math.sin(az) * math.cos(el), math.sin(el), -math.cos(az) * math.cos(el)], np.float32)
    r = np.cross(f, np.array([0, 1, 0], np.float32))
    r /= np.linalg.norm(r)
    u = np.cross(r, f)
    t = math.tan(math.radians(fov_deg) / 2)
    y, x = np.mgrid[0:h, 0:w].astype(np.float32)
    px = ((x + 0.5) / w * 2 - 1) * t * w / h
    py = (1 - (y + 0.5) / h * 2) * t
    d = f[None, None, :] + px[..., None] * r[None, None, :] + py[..., None] * u[None, None, :]
    d /= np.linalg.norm(d, axis=-1, keepdims=True)
    # A cube texel's spread, as the bake has it.
    sky = sky_hdr(d.astype(np.float32), nz, fit, aa=(2.0 / 1024, 4))
    save_rgb(path, camera_curve(sky), 92)


def plan(path: Path, nz: dict, half_km: float = 12.0, n: int = 360) -> None:
    """Sheet of plan views of the cloudiness round the viewer (north up, rings at 2.5, 5 and
    10 km, a line towards the sun) for a grid of cover offsets, to pick `COVER_OFFSET`."""
    from PIL import Image, ImageDraw
    ax = (np.arange(n, dtype=np.float32) + 0.5) / n * 2 * half_km - half_km
    x, z = np.meshgrid(ax, ax)
    sun = bm.sun_vector()
    cols, rows = 6, 4
    sheet = Image.new("RGB", (cols * n, rows * n))
    r = rng(99)
    for k in range(cols * rows):
        off = [round(float(r.random()), 3), round(float(r.random()), 3)]
        COVER_OFFSET[:] = off
        m = cloudiness(nz, x, z)
        img = Image.fromarray((np.clip(m, 0, 1) * 255).astype(np.uint8)).convert("RGB")
        dr = ImageDraw.Draw(img)
        c = n / 2
        for ring in (2.5, 5.0, 10.0):
            rr = ring / half_km * c
            dr.ellipse([c - rr, c - rr, c + rr, c + rr], outline=(255, 80, 80))
        dr.line([c, c, c + sun[0] * c, c + sun[2] * c], fill=(255, 220, 0))
        dr.text((4, 4), f"{off[0]:.3f},{off[1]:.3f}", fill=(0, 255, 0))
        sheet.paste(img, ((k % cols) * n, (k // cols) * n))
    sheet.save(path, quality=88)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--preview", default="", help="write an equirectangular preview here and exit")
    ap.add_argument("--plan", default="", help="write a sheet of cloud plans for candidate cover offsets and exit")
    ap.add_argument("--offset", default="", help="cover offset u,v to try (with --preview)")
    ap.add_argument("--view", default="", help="az,el[,fov] in degrees: with --preview, a camera's view instead")
    ap.add_argument("--size", type=int, default=1024, help="background face size")
    args = ap.parse_args()
    t = time.time()
    nz = cloud_noise()
    fit = fit_horizon()
    print("horizon: power", fit["power"], "base", fit["base"].round(4), "glow", fit["glow"].round(4))
    print(f"noise {time.time() - t:.1f} s", flush=True)
    if args.offset:
        COVER_OFFSET[:] = [float(v) for v in args.offset.split(",")]
    if args.plan:
        plan(Path(args.plan), nz)
        return 0
    if args.preview and args.view:
        for k, spec in enumerate(args.view.split(";")):
            v = [float(x) for x in spec.split(",")]
            out = Path(args.preview)
            view(out.with_name(f"{out.stem}_{k}{out.suffix}"), nz, fit, *v)
        print(f"{time.time() - t:.1f} s")
        return 0
    if args.preview:
        preview(Path(args.preview), nz, fit)
        print(f"{time.time() - t:.1f} s")
        return 0
    n = args.size
    names = ["px", "nx", "py", "ny", "pz", "nz"]
    flip = np.array([1, 1, -1 if STYLE.mirror_z else 1], np.float32)
    dither = rng(137)
    faces, envs = [], []
    for k in range(6):
        d = bm.cube_dirs(k, n) * flip
        f = sky_hdr(d, nz, fit, aa=(2.0 / n, 4))
        faces.append(f)
        save_rgb_dithered(OUT / f"cj_sky{STYLE.suffix}_{names[k]}.jpg",
                          np.clip(linear_to_srgb(np.minimum(f, bm.SKY_SCALE) / bm.SKY_SCALE), 0, 1), dither, 93)
        de = bm.cube_dirs(k, 96) * flip
        envs.append((sky_env(de, nz, fit), de[..., 1] > 0))
        print(f"face {names[k]} {time.time() - t:.1f} s", flush=True)
    save_hdr_cube(OUT / f"cj_sky{STYLE.suffix}.hdrc", faces)
    # The lighting environment keeps the ambient the lights were calibrated
    # with (ENV_IRRADIANCE), whatever the clouds: its sky is scaled to it.
    irr0 = bm.up_irradiance([e for e, _ in envs])
    gain = bm.ENV_IRRADIANCE / irr0
    print(f"lighting environment: up-facing irradiance {irr0:.3f} as baked, sky scaled by {gain:.3f}")
    scaled = []
    for k, (e, above) in enumerate(envs):
        e = np.clip(np.where(above[..., None], e * gain, e) / bm.SKY_ENV_SCALE, 0, 1)
        save_rgb(OUT / f"cj_skyenv{STYLE.suffix}_{names[k]}.jpg", linear_to_srgb(e), 90)
        scaled.append(e * bm.SKY_ENV_SCALE)
    envs = scaled
    # The sea's and the glass's sky: azimuth by u, 1 - sin(elevation) by v.
    w, h = 1024, 256
    az = (np.arange(w, dtype=np.float32) + 0.5) / w * 2 * math.pi
    s = 1 - (np.arange(h, dtype=np.float32) + 0.5) / h
    az, s = np.meshgrid(az, s)
    c = np.sqrt(1 - s * s)
    d = np.stack([np.sin(az) * c, s, -np.cos(az) * c], -1).astype(np.float32)
    sea = blur(np.minimum(sky_hdr(d, nz, fit, sun=False, quality=0.7), bm.SKY_SCALE), 1.5)
    save_rgb_dithered(OUT / "cj_sea_sky.jpg", np.clip(linear_to_srgb(sea / bm.SKY_SCALE), 0, 1), rng(139), 92)
    irr = bm.up_irradiance(envs)
    fog = fog_ratio()
    print(f"lighting environment: up-facing irradiance {irr:.3f} (calibrated {bm.ENV_IRRADIANCE})")
    record = {
        "horizonBase": [round(float(x), 4) for x in fit["base"] * fog],
        "horizonGlow": [round(float(x), 4) for x in fit["glow"] * fog],
        "horizonPower": fit["power"],
        "horizonLinear": [round(float(x), 4) for x in (horizon_ring()[1].mean(0) * fog)],
        "skyScale": bm.SKY_SCALE,
        "envIrradiance": round(irr, 4),
    }
    (Path(__file__).resolve().parent / f"cj_sky_horizon{STYLE.suffix}.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps(record))
    print(f"total {time.time() - t:.1f} s")
    return 0


if __name__ == "__main__":
    sys.exit(main())
