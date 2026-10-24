"""Small procedural-texture toolkit shared by the CycleJames texture bakers.

Everything tiles: noise lattices wrap, Voronoi features wrap, and normal
maps are taken with wrap-around differences. Arrays are float32 in [0, 1]
unless noted; images are (rows, cols[, channels]) with row 0 at the top.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image


def rng(seed: int) -> np.random.Generator:
    return np.random.default_rng(seed)


def value_noise(h: int, w: int, py: int, px: int, r: np.random.Generator) -> np.ndarray:
    """Periodic value noise with py x px lattice cells over an h x w tile."""
    lat = r.random((py, px)).astype(np.float32)
    y = np.arange(h, dtype=np.float32) * py / h
    x = np.arange(w, dtype=np.float32) * px / w
    y0 = np.floor(y).astype(int); x0 = np.floor(x).astype(int)
    fy = y - y0; fx = x - x0
    fy = fy * fy * (3 - 2 * fy); fx = fx * fx * (3 - 2 * fx)
    y1 = (y0 + 1) % py; x1 = (x0 + 1) % px; y0 %= py; x0 %= px
    a = lat[y0][:, x0]; b = lat[y0][:, x1]; c = lat[y1][:, x0]; d = lat[y1][:, x1]
    fx = fx[None, :]; fy = fy[:, None]
    return (a * (1 - fx) + b * fx) * (1 - fy) + (c * (1 - fx) + d * fx) * fy


def fbm(h: int, w: int, period: int, octaves: int, r: np.random.Generator,
        gain: float = 0.5, aspect: float = 1.0) -> np.ndarray:
    """Fractal sum of value noise, normalised to [0, 1]. `aspect` stretches
    the lattice (px = period * aspect)."""
    out = np.zeros((h, w), np.float32)
    amp, total = 1.0, 0.0
    p = period
    for _ in range(octaves):
        px = max(1, int(round(p * aspect)))
        out += amp * value_noise(h, w, p, px, r)
        total += amp
        amp *= gain
        p *= 2
        if p > min(h, w):
            break
    out /= total
    lo, hi = np.percentile(out, 0.5), np.percentile(out, 99.5)
    return np.clip((out - lo) / max(hi - lo, 1e-6), 0, 1)


def voronoi(h: int, w: int, n: int, r: np.random.Generator, points: np.ndarray | None = None):
    """Periodic Voronoi over an h x w tile with n random sites.
    Returns (f1, f2, id): distances (pixels) to the nearest and second
    nearest site, and the nearest site's index."""
    if points is None:
        points = r.random((n, 2)) * np.array([h, w])
    ys = np.arange(h, dtype=np.float32)[:, None]
    xs = np.arange(w, dtype=np.float32)[None, :]
    f1 = np.full((h, w), np.inf, np.float32)
    f2 = np.full((h, w), np.inf, np.float32)
    ids = np.zeros((h, w), np.int32)
    for k, (py, px) in enumerate(points):
        dy = np.abs(ys - py); dy = np.minimum(dy, h - dy)
        dx = np.abs(xs - px); dx = np.minimum(dx, w - dx)
        d = np.sqrt(dy * dy + dx * dx)
        closer = d < f1
        f2 = np.where(closer, f1, np.minimum(f2, d))
        ids = np.where(closer, k, ids)
        f1 = np.where(closer, d, f1)
    return f1, f2, ids


def blur(a: np.ndarray, radius: float) -> np.ndarray:
    """Wrap-around Gaussian blur."""
    from scipy.ndimage import gaussian_filter
    if a.ndim == 3:
        return np.stack([gaussian_filter(a[..., c], radius, mode="wrap") for c in range(a.shape[2])], -1)
    return gaussian_filter(a, radius, mode="wrap")


def normal_xy(height: np.ndarray, strength: float) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Tangent-space normal from a height field (units: pixels of height per
    pixel, times `strength`). +x is +u (columns), +y is +v (rows, down the
    image). Returns (nx, ny, nz) in [-1, 1]."""
    dx = (np.roll(height, -1, 1) - np.roll(height, 1, 1)) * 0.5 * strength
    dy = (np.roll(height, -1, 0) - np.roll(height, 1, 0)) * 0.5 * strength
    nx, ny, nz = -dx, -dy, np.ones_like(dx)
    l = np.sqrt(nx * nx + ny * ny + nz * nz)
    return nx / l, ny / l, nz / l


def to_u8(a: np.ndarray) -> np.ndarray:
    return (np.clip(a, 0, 1) * 255 + 0.5).astype(np.uint8)


def save_rgb(path: Path, rgb: np.ndarray, quality: int = 90) -> None:
    Image.fromarray(to_u8(rgb), "RGB").save(path, quality=quality, optimize=True, subsampling=0)


def save_rgb_dithered(path: Path, rgb: np.ndarray, r: np.random.Generator, quality: int = 95) -> None:
    """As `save_rgb`, with +-0.5 LSB triangular dither before quantising, so
    a smooth gradient (the sky) breaks into fine noise instead of bands."""
    n = (r.random(rgb.shape, dtype=np.float32) - r.random(rgb.shape, dtype=np.float32)) * 0.5
    u8 = np.clip(np.clip(rgb, 0, 1) * 255 + 0.5 + n, 0, 255).astype(np.uint8)
    Image.fromarray(u8, "RGB").save(path, quality=quality, optimize=True, subsampling=0)


def save_rgba(path: Path, rgba: np.ndarray) -> None:
    Image.fromarray(to_u8(rgba), "RGBA").save(path, optimize=True)


def save_raw(path: Path, rgba: np.ndarray) -> None:
    """Data texture as `.rgbz`: little-endian u32 width, u32 height, then
    raw-deflate (RFC 1951) RGBA8 rows, top row first. Used instead of PNG
    for anything whose alpha is data: Xcode re-encodes bundled PNGs with
    premultiplied alpha, which would scale R, G and B by A."""
    import struct
    import zlib
    h, w = rgba.shape[:2]
    raw = to_u8(rgba).tobytes()
    c = zlib.compressobj(9, zlib.DEFLATED, -15)
    body = c.compress(raw) + c.flush()
    path = path.with_suffix(".rgbz")
    path.write_bytes(struct.pack("<II", w, h) + body)


def save_gray(path: Path, g: np.ndarray) -> None:
    Image.fromarray(to_u8(g), "L").save(path, optimize=True)


def srgb_to_linear(c: np.ndarray) -> np.ndarray:
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c: np.ndarray) -> np.ndarray:
    c = np.clip(c, 0, None)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(c, 1 / 2.4) - 0.055)


def lerp(a, b, t):
    return a + (b - a) * t


def smoothstep(a, b, x):
    t = np.clip((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)


def stamp(canvas: np.ndarray, alpha: np.ndarray, sprite_rgb: np.ndarray, sprite_a: np.ndarray, y: int, x: int,
          wrap: bool = False) -> None:
    """Alpha-composites a sprite (rgb, a) onto canvas/alpha at top-left (y, x)."""
    sh, sw = sprite_a.shape
    H, W = alpha.shape
    if wrap:
        ys = (np.arange(sh) + y) % H
        xs = (np.arange(sw) + x) % W
        a = sprite_a[..., None]
        canvas[np.ix_(ys, xs)] = canvas[np.ix_(ys, xs)] * (1 - a) + sprite_rgb * a
        alpha[np.ix_(ys, xs)] = np.maximum(alpha[np.ix_(ys, xs)], sprite_a)
        return
    y0, x0 = max(y, 0), max(x, 0)
    y1, x1 = min(y + sh, H), min(x + sw, W)
    if y1 <= y0 or x1 <= x0:
        return
    sa = sprite_a[y0 - y:y1 - y, x0 - x:x1 - x]
    sr = sprite_rgb[y0 - y:y1 - y, x0 - x:x1 - x]
    a = sa[..., None]
    canvas[y0:y1, x0:x1] = canvas[y0:y1, x0:x1] * (1 - a) + sr * a
    alpha[y0:y1, x0:x1] = np.maximum(alpha[y0:y1, x0:x1], sa)
