# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow", "scipy"]
# ///
"""Repetition check for road-surface shots (WorldDebugShots "plan" views:
straight down, the road running up the image).

    uv run --script scripts/courses/debug/sett_repeat.py shot.png [...] [--px-per-m 182] [--max-r 0.25]
    uv run --script scripts/courses/debug/sett_repeat.py w_*_plan30_*.png --px-per-m 36.4 --min-lag 1.5 --road-frac 0.15
    uv run --script scripts/courses/debug/sett_repeat.py w_1000_strip800_*.png --px-per-m 40 --road-frac 0.38 --max-lag-frac 0.85

Autocorrelation of the luminance over the road (the central 60 % of the
width), normalised by the overlap. A tiled texture correlates near 1 at its
tile length; procedural setts only show their short course-scale lobe.
Reports the strongest correlation at lags beyond --min-lag (0.35 m, two or
three courses) along the road (up the image) and any lag across it, and
exits 1 if any shot exceeds --max-r. On the 30 m plans a course is a few
pixels, so their rhythm reaches further: look beyond about 1.5 m there,
and only at the road (a 3-4 m lane is about 15-20 % of the width). The
"strip<metres>" views unroll hundreds of metres of road at 40 px/m: look
at lags up to most of their length (--max-lag-frac) for a long-period
repeat; keep --road-frac at about 0.38 there, as a wider band takes in the
pale kerb (a false repeat on the Paterberg).

By default the image is first made fair to the setts: a high-pass with
local contrast normalisation (0.25 m), so a hard shadow edge along the road
doesn't correlate at every lag, and each row's mean removed, so the courses'
own rhythm (rows of nearly equal depth, as on any real sett road) doesn't
either. A texture repeat survives both: run it on a plan tiled from the old
1.08 m texture and it still scores about 1. --raw skips both.
"""
from __future__ import annotations

import argparse
import sys

import numpy as np
from PIL import Image


def acf(im: np.ndarray) -> np.ndarray:
    """Normalised autocorrelation for lags (0..h-1 along, -(w-1)..w-1 across)."""
    im = im - im.mean()
    h, w = im.shape
    f = np.fft.rfft2(im, s=(2 * h, 2 * w))
    full = np.fft.irfft2(f * np.conj(f), s=(2 * h, 2 * w))
    ac = np.concatenate([full[:h, w + 1:], full[:h, :w]], 1)        # across lags -(w-1)..w-1
    lu = np.arange(-(w - 1), w)
    ac = ac / np.outer(h - np.arange(h), w - np.abs(lu))
    return ac / ac[0, w - 1]


def fair(im: np.ndarray, px_per_m: float) -> np.ndarray:
    """High-pass, local contrast normalised, row means removed."""
    from scipy.ndimage import gaussian_filter
    sig = 0.25 * px_per_m
    hp = im - gaussian_filter(im, sig)
    hp /= np.sqrt(gaussian_filter(hp * hp, sig)) + 1e-3
    return hp - hp.mean(axis=1, keepdims=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("shots", nargs="+")
    ap.add_argument("--px-per-m", type=float, default=182.0, help="plan view from 6 m, 62 deg vfov, 1311 px tall")
    ap.add_argument("--max-r", type=float, default=0.25)
    ap.add_argument("--road-frac", type=float, default=0.6, help="central share of the width that is road")
    ap.add_argument("--raw", action="store_true", help="no high-pass, no row-mean removal")
    ap.add_argument("--min-lag", type=float, default=0.35, help="shortest lag along the road, m")
    ap.add_argument("--max-lag-frac", type=float, default=0.6, help="longest lag along the road, share of the shot")
    a = ap.parse_args()
    worst = 0.0
    for path in a.shots:
        im = np.asarray(Image.open(path).convert("L"), np.float32)
        h, w = im.shape
        m = int(w * (1 - a.road_frac) / 2)
        road = im[:, m:w - m]
        ac = acf(road if a.raw else fair(road, a.px_per_m))
        hh, ww = road.shape
        ls = np.arange(hh)[:, None] / a.px_per_m
        lu = np.arange(-(ww - 1), ww)[None, :] / a.px_per_m
        # Lags at least --min-lag along the road, any across: shorter ones
        # only see the courses' own rhythm.
        sel = (ls > a.min_lag) & (ls < a.max_lag_frac * ls.max()) & (np.abs(lu) < 0.6 * np.abs(lu).max())
        k = int(np.argmax(np.where(sel, ac, -9)))
        i, j = np.unravel_index(k, ac.shape)
        r = float(ac[i, j])
        worst = max(worst, r)
        print(f"{path}: strongest repeat r={r:.3f} at {ls[i, 0]:.2f} m along, {lu[0, j]:+.2f} m across"
              f"{'  REPEATS' if r > a.max_r else ''}")
    return 1 if worst > a.max_r else 0


if __name__ == "__main__":
    sys.exit(main())
