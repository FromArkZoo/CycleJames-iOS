# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pillow"]
# ///
"""Checks a Simulator shot of a climb against targets measured on photos of
the three climbs (Commons, sunlit and overcast; see the art-direction notes
in CycleJames/Courses/Scene/World/SettStyle.swift).

    uv run --script scripts/courses/debug/photo_match.py SHOT.png --road x0 y0 x1 y1 [--sky x0 y0 x1 y1] [--shade]

Boxes are fractions of the frame (x0 y0 x1 y1). On the road box: the
luminance spread (p95 / p5; photos of sunlit setts reach 3 or more, the
domes' shadows in the joints, about 1.8 in shade) and the warmth (mean
R - B, sRGB 0-255; photos +2 to +27, so +3..+18). On the sky box: its
luminance and G/B. The photos came from other cameras and exposures, so
these are directions, not exact values. Exits 1 if a target is missed.
"""
from __future__ import annotations

import argparse
import sys

import numpy as np
from PIL import Image

LUMA = np.array([0.299, 0.587, 0.114])


def box(im: np.ndarray, b: list[float]) -> np.ndarray:
    h, w, _ = im.shape
    x0, y0, x1, y1 = b
    return im[int(y0 * h):int(y1 * h), int(x0 * w):int(x1 * w)].reshape(-1, 3)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("shot")
    ap.add_argument("--road", nargs=4, type=float, required=True)
    ap.add_argument("--sky", nargs=4, type=float)
    ap.add_argument("--shade", action="store_true", help="the road box is in shade")
    a = ap.parse_args()
    im = np.asarray(Image.open(a.shot).convert("RGB")).astype(np.float64)
    r = box(im, a.road)
    lum = r @ LUMA
    p5, p95 = np.percentile(lum, [5, 95])
    warm = r[:, 0].mean() - r[:, 2].mean()
    need = 1.8 if a.shade else 3.0
    ratio = p95 / max(p5, 1)
    ok = ratio >= need and 3 <= warm <= 18
    print(f"{a.shot}: road p5/p95 {p5:.0f}/{p95:.0f} ratio {ratio:.2f} (target >= {need})  "
          f"R-B {warm:+.1f} (target +3..+18)")
    if a.sky:
        s = box(im, a.sky)
        sl = (s @ LUMA).mean()
        gb = s[:, 1].mean() / max(s[:, 2].mean(), 1)
        print(f"  sky luma {sl:.0f} (target 165..190)  G/B {gb:.2f} (target >= 0.78)")
        ok = ok and 165 <= sl <= 190 and gb >= 0.78
    print("  ok" if ok else "  MISSES")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
