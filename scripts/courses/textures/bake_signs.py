# /// script
# requires-python = ">=3.10"
# dependencies = ["pillow"]
# ///
"""Bake the road-sign atlas for the 3D climbs.

    uv run --script scripts/courses/textures/bake_signs.py

cj_signs.png (1024 x 1536, sRGB, opaque) and cj_signs_map.json go to
CycleJames/Resources/CourseTextures/. Every plate the climbs carry
(CourseArt.signs: Belgian road signs, street plates, the climbs' own boards,
cycle-node plates, traffic mirrors), drawn flat at 256 px per metre and
shelf-packed; the map gives each key its shape (rect, tri, triDown, disc),
its size in metres and its uv rect (u0, v0, u1, v1, v down). BuildingBuilder
cuts each face to its shape, so the atlas needs no alpha: each cell's corners
carry the plate's rim colour, which keeps the mips from bleeding a dark edge.
A few plain cells (paint.*) colour props: the chapel doors, the kiosk's
plinth, the pipeline marker, the Oudenberg chapel's gilt statue, its stone
dressings, white statue, timber door, window glass and niche; grate.* are
the cast-iron gully grates; kiosk.*
are the Paterberg summit kiosk's doors, end panels and roof, weathered, at
half the density and packed after everything else, so they move no plate.

Drawn procedurally at twice the size and filtered down. Text is set in DIN
Alternate Bold and DIN Condensed Bold from the system's fonts (only pixels
ship). No logos and no people's names; the node plates' design is generic
(the exact Flemish design is unchecked).
"""
from __future__ import annotations

import json
import math
import random
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageEnhance, ImageFont

ROOT = Path(__file__).resolve().parents[3]
OUT = ROOT / "CycleJames/Resources/CourseTextures"

SIZE = 1024
HEIGHT = 1536               # the plates outgrew a square 1024 with the Molenberg's and Taaienberg's
SS = 2                      # supersampling
PPM = 256 * SS              # pixels per metre while drawing
PAD = 10 * SS               # between cells
FONT = "/System/Library/Fonts/Supplemental/DIN Alternate Bold.ttf"
FONT_C = "/System/Library/Fonts/Supplemental/DIN Condensed Bold.ttf"

RED, WHITE, BLACK = (196, 30, 38), (238, 238, 232), (22, 22, 24)
BROWN, YELLOW, BLUE = (104, 58, 36), (246, 200, 18), (22, 70, 146)
GREEN = (0, 120, 70)


def font(path: str, px: float) -> ImageFont.FreeTypeFont:
    return ImageFont.truetype(path, max(int(px), 4))


def text(d: ImageDraw.ImageDraw, box, s: str, size_px: float, fill, path: str = FONT, fit: float = 0.92) -> None:
    """`s` centred in `box`, shrunk to fit its width."""
    x0, y0, x1, y1 = box
    f = font(path, size_px)
    w = d.textlength(s, font=f)
    if w > (x1 - x0) * fit:
        f = font(path, size_px * (x1 - x0) * fit / w)
    d.text(((x0 + x1) / 2, (y0 + y1) / 2), s, font=f, fill=fill, anchor="mm")


def inset(box, k):
    x0, y0, x1, y1 = box
    return (x0 + k, y0 + k, x1 - k, y1 - k)


def bicycle(d, cx, cy, w, fill, width):
    """A plain bicycle pictogram `w` wide, centred on (cx, cy)."""
    r = w * 0.2
    lw, rw = (cx - w * 0.3, cy + w * 0.1), (cx + w * 0.3, cy + w * 0.1)
    for c in (lw, rw):
        d.ellipse([c[0] - r, c[1] - r, c[0] + r, c[1] + r], outline=fill, width=width)
    crank = (cx - w * 0.02, cy + w * 0.1)
    seat = (cx - w * 0.12, cy - w * 0.2)
    head = (cx + w * 0.2, cy - w * 0.22)
    d.line([lw, crank, (cx + w * 0.22, cy - w * 0.12), lw], fill=fill, width=width)
    d.line([crank, seat], fill=fill, width=width)
    d.line([(cx + w * 0.22, cy - w * 0.12), rw], fill=fill, width=width)
    d.line([(cx + w * 0.22, cy - w * 0.12), head], fill=fill, width=width)
    d.line([(seat[0] - w * 0.07, seat[1]), (seat[0] + w * 0.07, seat[1])], fill=fill, width=width)


def arrow(d, cx, cy, length, fill, left=True, width=None):
    s = -1 if left else 1
    width = width or max(2, int(length * 0.16))
    tip = (cx + s * length / 2, cy)
    d.line([(cx - s * length / 2, cy), (tip[0] - s * length * 0.15, cy)], fill=fill, width=width)
    h = length * 0.32
    d.polygon([tip, (tip[0] - s * h, cy - h * 0.8), (tip[0] - s * h, cy + h * 0.8)], fill=fill)


# Painters: each gets the drawing and its cell box (x0, y0, x1, y1).

def street_plate(name, header=None):
    def draw(d, box):
        d.rectangle(box, fill=WHITE)
        h = box[3] - box[1]
        b = max(3, int(h * 0.07))
        d.rectangle(inset(box, b * 0.6), outline=BLACK, width=b)
        x0, y0, x1, y1 = inset(box, b * 2)
        if header:
            text(d, (x0, y0, x1, y0 + (y1 - y0) * 0.3), header, (y1 - y0) * 0.22, BLACK, FONT_C)
            text(d, (x0, y0 + (y1 - y0) * 0.3, x1, y1), name, (y1 - y0) * 0.62, BLACK)
        else:
            text(d, (x0, y0, x1, y1), name, (y1 - y0) * 0.78, BLACK)
    return draw


def town_plate(name, header, ink, rim, sub=None):
    """A municipality's street plate: white, rounded, a coloured border,
    the village (and municipality) small above the street's name (Zwalm:
    blue; Maarkedal: green with white letters, `ink` WHITE on `rim`)."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        h = y1 - y0
        field = rim if ink == WHITE else WHITE
        d.rectangle(box, fill=rim)
        d.rounded_rectangle(inset(box, h * 0.04), radius=h * 0.16, fill=field)
        d.rounded_rectangle(inset(box, h * 0.09), radius=h * 0.12, outline=ink if ink == WHITE else rim,
                            width=max(2, int(h * 0.05)))
        x0, y0, x1, y1 = inset(box, h * 0.16)
        top = (y1 - y0) * 0.32
        text(d, (x0, y0, x1, y0 + top), header + (f"  {sub}" if sub else ""), top * 0.75, ink, FONT_C)
        text(d, (x0, y0 + top, x1, y1), name, (y1 - y0 - top) * 0.78, ink)
    return draw


def village_board(town, municipality):
    """A village's own name board (not an F1): yellow, a red border, black
    letters (Sint-Denijs-Boekel, at the Molenberg's mill square)."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        h = y1 - y0
        d.rectangle(box, fill=RED)
        d.rectangle(inset(box, h * 0.07), fill=YELLOW)
        text(d, (x0 + h * 0.15, y0 + h * 0.14, x1 - h * 0.15, y0 + h * 0.62), town, h * 0.36, BLACK)
        text(d, (x0 + h * 0.15, y0 + h * 0.6, x1 - h * 0.15, y1 - h * 0.14), municipality, h * 0.2, BLACK)
    return draw


def tourist_arrow(name, left=True):
    def draw(d, box):
        x0, y0, x1, y1 = box
        h = y1 - y0
        d.rectangle(box, fill=BROWN)
        d.rectangle(inset(box, h * 0.06), outline=WHITE, width=max(2, int(h * 0.04)))
        ax = x0 + h * 0.6 if left else x1 - h * 0.6
        arrow(d, ax, (y0 + y1) / 2, h * 0.7, YELLOW, left=left, width=int(h * 0.16))
        tb = (x0 + h * 1.05, y0, x1 - h * 0.15, y1) if left else (x0 + h * 0.15, y0, x1 - h * 1.05, y1)
        text(d, tb, name, h * 0.56, WHITE)
    return draw


def place_name(town, municipality):                  # F1
    def draw(d, box):
        x0, y0, x1, y1 = box
        h = y1 - y0
        d.rectangle(box, fill=WHITE)
        d.rectangle(inset(box, h * 0.06), outline=BLACK, width=int(h * 0.05))
        text(d, (x0 + h * 0.18, y0 + h * 0.12, x1 - h * 0.18, y0 + h * 0.6), town, h * 0.32, BLACK)
        text(d, (x0 + h * 0.18, y0 + h * 0.58, x1 - h * 0.18, y1 - h * 0.14), municipality, h * 0.16, BLACK)
    return draw


def triangle(inner=None, down=False):                 # A series; B1 upside down
    def draw(d, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        d.rectangle(box, fill=RED)
        if down:
            outer = [(x0, y0), (x1, y0), ((x0 + x1) / 2, y1)]
        else:
            outer = [(x0, y1), (x1, y1), ((x0 + x1) / 2, y0)]
        d.polygon(outer, fill=RED)
        k = w * 0.12
        if down:
            inner_pts = [(x0 + k * 1.75, y0 + k), (x1 - k * 1.75, y0 + k), ((x0 + x1) / 2, y1 - k * 2.0)]
        else:
            inner_pts = [(x0 + k * 1.75, y1 - k), (x1 - k * 1.75, y1 - k), ((x0 + x1) / 2, y0 + k * 2.0)]
        d.polygon(inner_pts, fill=WHITE)
        if inner:
            inner(d, box)
    return draw


def steep(pct):                                       # A5: steep descent
    def draw(d, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        d.polygon([(x0 + w * 0.3, y0 + h * 0.8), (x0 + w * 0.7, y0 + h * 0.8), (x0 + w * 0.3, y0 + h * 0.56)], fill=BLACK)
        text(d, (x0 + w * 0.42, y0 + h * 0.5, x0 + w * 0.72, y0 + h * 0.66), pct, h * 0.15, BLACK)
    return draw


def uneven(d, box):                                   # A7a: uneven road, two humps
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    base = y0 + h * 0.78
    pts = [(x0 + w * 0.26, base)]
    for k in range(41):
        f = k / 40
        hump = max(0.0, math.sin(f * 2 * math.pi)) ** 1.2 if f < 0.5 else max(0.0, -math.sin(f * 2 * math.pi)) ** 1.2
        pts.append((x0 + w * (0.26 + 0.48 * f), base - h * 0.17 * hump))
    pts.append((x0 + w * 0.74, base))
    d.polygon(pts + [(x0 + w * 0.74, base + h * 0.035), (x0 + w * 0.26, base + h * 0.035)], fill=BLACK)


def children(d, box):                                 # A23: two children
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    for cx, sc in ((x0 + w * 0.44, 1.0), (x0 + w * 0.58, 0.85)):
        top = y0 + h * 0.42 + (1 - sc) * h * 0.1
        r = h * 0.045 * sc
        d.ellipse([cx - r, top - r, cx + r, top + r], fill=BLACK)
        d.polygon([(cx - r * 1.2, top + r * 1.3), (cx + r * 1.2, top + r * 1.3),
                   (cx + r * 1.5, top + h * 0.2 * sc), (cx - r * 1.5, top + h * 0.2 * sc)], fill=BLACK)
        d.line([(cx - r * 0.6, top + h * 0.2 * sc), (cx - r * 1.4, y0 + h * 0.8)], fill=BLACK, width=int(r * 0.9))
        d.line([(cx + r * 0.6, top + h * 0.2 * sc), (cx + r * 1.4, y0 + h * 0.8)], fill=BLACK, width=int(r * 0.9))


def disc(rim=RED, field=WHITE, inner=None):           # C series
    def draw(d, box):
        x0, y0, x1, y1 = box
        d.rectangle(box, fill=rim)
        d.ellipse(box, fill=rim)
        k = (x1 - x0) * 0.105
        d.ellipse(inset(box, k), fill=field)
        if inner:
            inner(d, box)
    return draw


def no_entry(d, box):                                 # C1
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    d.rectangle(box, fill=RED)
    d.ellipse(box, fill=RED)
    d.rectangle([x0 + w * 0.18, y0 + h * 0.41, x1 - w * 0.18, y1 - h * 0.41], fill=WHITE)


def no_parking(d, box):                               # E3
    x0, y0, x1, y1 = box
    w = x1 - x0
    disc(RED, BLUE)(d, box)
    c = ((x0 + x1) / 2, (y0 + y1) / 2)
    r = w * 0.4
    a = math.radians(45)
    d.line([(c[0] - r * math.cos(a), c[1] - r * math.sin(a)), (c[0] + r * math.cos(a), c[1] + r * math.sin(a))],
           fill=RED, width=int(w * 0.1))


def zone30(d, box):                                   # F4a
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    d.rectangle(box, fill=WHITE)
    d.rectangle(inset(box, w * 0.04), outline=BLACK, width=int(w * 0.025))
    text(d, (x0, y0 + h * 0.06, x1, y0 + h * 0.28), "ZONE", h * 0.17, BLACK)
    dbox = (x0 + w * 0.14, y0 + h * 0.32, x1 - w * 0.14, y0 + h * 0.32 + (w * 0.72))
    d.ellipse(dbox, fill=RED)
    d.ellipse(inset(dbox, (dbox[2] - dbox[0]) * 0.11), fill=WHITE)
    text(d, dbox, "30", (dbox[3] - dbox[1]) * 0.5, BLACK)


def mirror(d, box):
    """A convex traffic mirror: red and white rim, the sky and the road in it."""
    x0, y0, x1, y1 = box
    w = x1 - x0
    d.rectangle(box, fill=RED)
    for k in range(16):
        a0, a1 = k * 22.5, k * 22.5 + 22.5
        d.pieslice(box, a0, a1, fill=RED if k % 2 == 0 else WHITE)
    # The glass, row by row inside its circle: sky over the road.
    g = inset(box, w * 0.1)
    gw = g[2] - g[0]
    cx = (g[0] + g[2]) / 2
    for i in range(int(gw)):
        t = (i + 0.5) / gw
        half = math.sqrt(max(0.0, 0.25 - (t - 0.5) ** 2)) * gw
        sky = (150 + 50 * t, 178 + 30 * t, 205 + 15 * t)
        ground = (96 - 20 * t, 104 - 18 * t, 90 - 20 * t)
        c = sky if t < 0.55 else ground
        d.line([(cx - half, g[1] + i), (cx + half, g[1] + i)], fill=tuple(int(v) for v in c))
    # A highlight across the glass.
    d.arc(inset(box, w * 0.2), 200, 250, fill=(235, 240, 245), width=int(w * 0.04))


def node(number):
    """A cycle-node plate (generic): white, green border, the number."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        d.rectangle(box, fill=WHITE)
        d.rectangle(inset(box, w * 0.04), outline=GREEN, width=int(w * 0.06))
        bicycle(d, x0 + w * 0.5, y0 + h * 0.27, w * 0.42, GREEN, max(2, int(w * 0.035)))
        text(d, (x0, y0 + h * 0.42, x1, y1 - h * 0.08), str(number), h * 0.5, BLACK)
    return draw


def cycle_route(left=True):
    def draw(d, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        d.rectangle(box, fill=WHITE)
        d.rectangle(inset(box, h * 0.05), outline=GREEN, width=int(h * 0.06))
        bicycle(d, x0 + w * 0.32, y0 + h * 0.5, h * 0.62, GREEN, max(2, int(h * 0.06)))
        arrow(d, x0 + w * 0.72, y0 + h * 0.5, w * 0.38, BLACK, left=left)
    return draw


def sub_plate(label, blue=False, pictogram=False):
    def draw(d, box):
        x0, y0, x1, y1 = box
        h = y1 - y0
        bg, fg = (BLUE, WHITE) if blue else (WHITE, BLACK)
        d.rectangle(box, fill=bg)
        d.rectangle(inset(box, h * 0.06), outline=fg, width=max(2, int(h * 0.06)))
        if pictogram:
            bicycle(d, (x0 + x1) / 2, (y0 + y1) / 2, h * 0.75, fg, max(2, int(h * 0.07)))
        else:
            text(d, inset(box, h * 0.12), label, h * 0.55, fg, FONT_C)
    return draw


def climb_board(d, box):
    """The Paterberg's yellow board: name, length, maximum and mean."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    d.rectangle(box, fill=YELLOW)
    d.rectangle(inset(box, h * 0.03), outline=BLACK, width=int(h * 0.02))
    text(d, (x0, y0 + h * 0.04, x1, y0 + h * 0.3), "PATERBERG", h * 0.22, BLACK)
    d.line([(x0 + w * 0.04, y0 + h * 0.31), (x1 - w * 0.04, y0 + h * 0.31)], fill=BLACK, width=int(h * 0.015))
    text(d, (x0 + w * 0.02, y0 + h * 0.36, x0 + w * 0.42, y1 - h * 0.1), "400m", h * 0.3, BLACK)
    for k, (pct, label) in enumerate([("20%", "MAX."), ("13%", "GEMIDDELD")]):
        tx0 = x0 + w * (0.47 + 0.26 * k)
        tb = (tx0, y0 + h * 0.37, tx0 + w * 0.2, y0 + h * 0.37 + w * 0.2 * 0.85)
        tri = [(tb[0], tb[3]), (tb[2], tb[3]), ((tb[0] + tb[2]) / 2, tb[1])]
        d.polygon(tri, fill=RED)
        kk = (tb[2] - tb[0]) * 0.12
        d.polygon([(tb[0] + kk * 1.75, tb[3] - kk), (tb[2] - kk * 1.75, tb[3] - kk), ((tb[0] + tb[2]) / 2, tb[1] + kk * 2)],
                  fill=WHITE)
        text(d, (tb[0], tb[1] + (tb[3] - tb[1]) * 0.45, tb[2], tb[3] - kk * 1.2), pct, (tb[3] - tb[1]) * 0.28, BLACK)
        text(d, (tb[0] - w * 0.02, tb[3] + h * 0.02, tb[2] + w * 0.02, y1 - h * 0.05), label, h * 0.1, BLACK, FONT_C)


def paint(rgb):
    def draw(d, box):
        d.rectangle(box, fill=rgb)
    return draw


def grate_round(d, box):
    """A round cast-iron gully grate, slots across, in a frame."""
    x0, y0, x1, y1 = box
    w = x1 - x0
    d.rectangle(box, fill=(48, 46, 44))
    d.ellipse(box, fill=(58, 55, 52))
    g = inset(box, w * 0.1)
    d.ellipse(g, fill=(44, 42, 40))
    n = 7
    for k in range(n):
        y = g[1] + (g[3] - g[1]) * (k + 0.75) / (n + 0.5)
        half = math.sqrt(max(0.0, 0.25 - ((y - (g[1] + g[3]) / 2) / (g[3] - g[1])) ** 2)) * (g[2] - g[0]) * 0.86
        cx = (g[0] + g[2]) / 2
        d.rectangle([cx - half, y - w * 0.025, cx + half, y + w * 0.025], fill=(10, 10, 10))
    d.ellipse(inset(box, w * 0.02), outline=(80, 72, 62), width=int(w * 0.025))


def grate_rect(d, box):
    """A rectangular gutter grate: bars along its length in a frame."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    d.rectangle(box, fill=(60, 56, 52))
    g = inset(box, h * 0.1)
    d.rectangle(g, fill=(46, 43, 40))
    n = 9
    for k in range(n):
        x = g[0] + (g[2] - g[0]) * (k + 0.5) / n
        d.rectangle([x - w * 0.018, g[1] + h * 0.05, x + w * 0.018, g[3] - h * 0.05], fill=(10, 10, 10))


# The Paterberg's summit kiosk: a dark-green steel electricity cabinet,
# repainted now and then, on a concrete plinth. Its faces are drawn into an
# image of their own (`face`) so they can be weathered pixel by pixel, from
# seeded value noise: the bake gives the same bytes every run.
KIOSK = (34, 66, 47)
KIOSK_GAP = (12, 22, 16)
KIOSK_LIT = (60, 94, 72)
SOIL = (78, 66, 50)
RUST = (98, 62, 38)


def value_noise(rng: random.Random, size, cells) -> Image.Image:
    """Smooth noise, 'L', 0-255: seeded values on a cells[0] x cells[1] grid, bicubic up to size."""
    small = Image.new("L", cells)
    small.putdata([rng.randrange(256) for _ in range(cells[0] * cells[1])])
    return small.resize(size, Image.BICUBIC)


def ramp(size, stops) -> Image.Image:
    """'L' mask down the image: linear between (y fraction, 0-1) stops."""
    w, h = size
    rows = []
    for y in range(h):
        t = (y + 0.5) / h
        v = stops[0][1] if t < stops[0][0] else stops[-1][1]
        for (t0, v0), (t1, v1) in zip(stops, stops[1:]):
            if t0 <= t <= t1:
                v = v0 + (v1 - v0) * (t - t0) / max(t1 - t0, 1e-6)
                break
        rows.append(int(max(0.0, min(1.0, v)) * 255))
    col = Image.new("L", (1, h))
    col.putdata(rows)
    return col.resize((w, h), Image.NEAREST)


def scaled(mask: Image.Image, k: float) -> Image.Image:
    return mask.point(lambda v: int(v * k))


def tinted(img: Image.Image, rgb, mask: Image.Image) -> Image.Image:
    return Image.composite(Image.new("RGB", img.size, rgb), img, mask)


def louvre(d, k, x0, y0, x1, y1, slats):
    """Pressed louvres: dark slots under lit lips, in a dark frame (metres, `k` px per metre)."""
    pitch = (y1 - y0) / slats
    for i in range(slats):
        y = y0 + i * pitch
        d.rectangle([x0 * k, (y + pitch * 0.12) * k, x1 * k, (y + pitch * 0.66) * k], fill=KIOSK_GAP)
        d.rectangle([x0 * k, (y + pitch * 0.66) * k, x1 * k, (y + pitch * 0.9) * k], fill=KIOSK_LIT)
    d.rectangle([x0 * k, y0 * k, x1 * k, y1 * k], outline=KIOSK_GAP, width=max(1, int(0.006 * k)))


def seam(d, k, x0, y0, x1, y1):
    """A door or panel gap (metres): dark, its lower or right lip catching the light."""
    g, lip = 0.009 * k, 0.005 * k
    if x1 - x0 > y1 - y0:
        d.rectangle([x0 * k, y0 * k - g / 2, x1 * k, y0 * k + g / 2], fill=KIOSK_GAP)
        d.rectangle([x0 * k, y0 * k + g / 2, x1 * k, y0 * k + g / 2 + lip], fill=KIOSK_LIT)
    else:
        d.rectangle([x0 * k - g / 2, y0 * k, x0 * k + g / 2, y1 * k], fill=KIOSK_GAP)
        d.rectangle([x0 * k + g / 2, y0 * k, x0 * k + g / 2 + lip, y1 * k], fill=KIOSK_LIT)


def weathered(img: Image.Image, rng: random.Random, k: float, grime_from: float, streaks: float) -> Image.Image:
    """Uneven paint, sun-faded at the top, rain-streaked down from the
    eaves, splashed with soil up from the bottom, chipped low down. The
    fractions are of the face's height."""
    w, h = img.size
    mottle = value_noise(rng, img.size, (max(2, int(w / k / 0.12)), max(2, int(h / k / 0.12))))
    bright, dark = ImageEnhance.Brightness(img).enhance(1.07), ImageEnhance.Brightness(img).enhance(0.93)
    img = Image.composite(bright, dark, mottle)
    img = tinted(img, (66, 88, 74), ramp(img.size, [(0, 0.16), (0.4, 0)]))
    rain = value_noise(rng, img.size, (max(2, int(w / k / 0.025)), 3)).point(lambda v: min(255, max(0, v - 120) * 2))
    rain = ImageChops.multiply(rain, ramp(img.size, [(0, streaks), (0.65, 0)]))
    img = Image.composite(ImageEnhance.Brightness(img).enhance(0.8), img, rain)
    splash = value_noise(rng, img.size, (max(2, int(w / k / 0.03)), max(2, int(h / k / 0.04))))
    splash = ImageChops.multiply(splash.point(lambda v: min(255, v * 2)), ramp(img.size, [(grime_from, 0), (1, 0.85)]))
    img = Image.composite(ImageEnhance.Brightness(img).enhance(0.7), img, scaled(splash, 0.8))
    img = tinted(img, SOIL, scaled(splash, 0.55))
    d = ImageDraw.Draw(img)
    for _ in range(int(w * h / k / k * 14)):
        # Off the face's outermost pixels, which the atlas bleeds into its padding.
        x, y = rng.uniform(3, w - 3), min(h * (1 - rng.random() ** 3), h - 3)
        r = rng.uniform(0.6, 1.3) * k / 256
        d.ellipse([x - r, y - r, x + r, y + r], fill=RUST if rng.random() < 0.4 else (70, 88, 76))
    return img


def warning(d, k, cx, cy, side):
    """The yellow high-voltage triangle with its black lightning flash (metres)."""
    s, h = side * k, side * k * 0.87
    x, y = cx * k, cy * k
    d.polygon([(x - s / 2, y + h / 2), (x + s / 2, y + h / 2), (x, y - h / 2)], fill=BLACK)
    i = s * 0.07
    d.polygon([(x - s / 2 + i * 1.7, y + h / 2 - i), (x + s / 2 - i * 1.7, y + h / 2 - i), (x, y - h / 2 + i * 2)],
              fill=YELLOW)
    b = s * 0.07
    d.polygon([(x + b * 0.3, y - h * 0.16), (x - b * 1.1, y + h * 0.12), (x + b * 0.1, y + h * 0.1),
               (x - b * 0.4, y + h * 0.36), (x + b * 1.1, y + h * 0.04), (x - b * 0.1, y + h * 0.06)], fill=BLACK)


def kiosk_front(d, box):
    """Double doors (1.0 x 1.44 m), seen from the road: louvres low on
    both, the lock on the right, the warning triangle and the cabinet's
    number plate at eye height, a darker kick plate."""
    w, h = box[2] - box[0], box[3] - box[1]
    k = w / 1.0
    img = Image.new("RGB", (w, h), KIOSK)
    f = ImageDraw.Draw(img)
    f.rectangle([0, 1.34 * k, w, h], fill=(27, 52, 38))
    for x in (0.035, 0.5, 0.965):
        seam(f, k, x, 0.035, x, 1.34)
    for y in (0.035, 1.34):
        seam(f, k, 0.035, y, 0.965, y)
    for cx in (0.2675, 0.7325):
        louvre(f, k, cx - 0.14, 1.02, cx + 0.14, 1.26, 6)
    f.rectangle([0.535 * k, 0.6 * k, 0.553 * k, 0.78 * k], fill=(30, 33, 31))
    f.rectangle([0.535 * k, 0.6 * k, 0.539 * k, 0.78 * k], fill=(86, 92, 88))
    f.ellipse([0.533 * k, 0.545 * k, 0.555 * k, 0.567 * k], fill=(132, 130, 122))
    warning(f, k, 0.2675, 0.34, 0.12)
    f.rectangle([0.67 * k, 0.31 * k, 0.8 * k, 0.37 * k], fill=(210, 204, 186), outline=(40, 40, 38), width=2)
    for y in (0.326, 0.35):
        f.rectangle([0.685 * k, y * k, 0.785 * k, (y + 0.008) * k], fill=(54, 54, 52))
    img = weathered(img, random.Random(642), k, grime_from=0.72, streaks=0.9)
    # Rust run down from the louvres' lower corners.
    f = ImageDraw.Draw(img)
    for x in (0.13, 0.405, 0.595, 0.87):
        f.line([(x * k, 1.26 * k), (x * k, 1.31 * k)], fill=(70, 56, 38), width=max(1, int(0.004 * k)))
    return img


def kiosk_end(d, box):
    """An end panel (0.6 x 1.44 m): the main vent high up, a small one
    low down."""
    w, h = box[2] - box[0], box[3] - box[1]
    k = w / 0.6
    img = Image.new("RGB", (w, h), KIOSK)
    f = ImageDraw.Draw(img)
    f.rectangle([0, 1.34 * k, w, h], fill=(27, 52, 38))
    for x in (0.035, 0.565):
        seam(f, k, x, 0.035, x, 1.34)
    for y in (0.035, 1.34):
        seam(f, k, 0.035, y, 0.565, y)
    louvre(f, k, 0.12, 0.12, 0.48, 0.4, 7)
    louvre(f, k, 0.18, 1.1, 0.42, 1.26, 4)
    return weathered(img, random.Random(643), k, grime_from=0.7, streaks=1.0)


def kiosk_roof(d, box):
    """One face of the pyramid roof, eaves along the bottom (1.12 x
    0.45 m, mapped onto each triangle): more faded and streaked than the
    walls, a lit drip edge."""
    w, h = box[2] - box[0], box[3] - box[1]
    k = w / 1.12
    img = Image.new("RGB", (w, h), (30, 58, 42))
    img = tinted(img, (74, 92, 80), ramp(img.size, [(0, 0.35), (1, 0.12)]))
    img = weathered(img, random.Random(644), k, grime_from=0.9, streaks=1.0)
    ImageDraw.Draw(img).rectangle([0, h - 0.02 * k, w, h], fill=KIOSK_LIT)
    return img


# key, shape, width m, height m, painter. Shapes: rect, tri, triDown, disc.
SIGNS = [
    ("board.paterberg", "rect", 1.40, 0.62, climb_board),
    ("f4a.zone30", "rect", 0.60, 0.90, zone30),
    ("f1.kwaremont", "rect", 1.10, 0.60, place_name("Kwaremont", "Kluisbergen")),
    ("a.steep20", "tri", 0.90, 0.78, triangle(steep("20%"))),
    ("a23.children", "tri", 0.90, 0.78, triangle(children)),
    ("a7.uneven", "tri", 0.90, 0.78, triangle(uneven)),
    ("b1.giveway", "triDown", 0.90, 0.78, triangle(down=True)),
    ("c3", "disc", 0.70, 0.70, disc()),
    ("c1.noentry", "disc", 0.70, 0.70, no_entry),
    ("c21.3_5t", "disc", 0.70, 0.70, disc(inner=lambda d, b: text(d, b, "3,5t", (b[3] - b[1]) * 0.3, BLACK))),
    ("e3.noparking", "disc", 0.60, 0.60, no_parking),
    ("mirror", "disc", 0.60, 0.60, mirror),
    ("node.24", "rect", 0.32, 0.32, node(24)),
    ("node.65", "rect", 0.32, 0.32, node(65)),
    ("node.69", "rect", 0.32, 0.32, node(69)),
    ("node.19", "rect", 0.32, 0.32, node(19)),
    ("node.76", "rect", 0.32, 0.32, node(76)),
    ("node.32", "rect", 0.32, 0.32, node(32)),
    ("street.steengat", "rect", 0.80, 0.26, street_plate("STEENGAT", "Stad Oudenaarde")),
    ("tourist.koppenberg.left", "rect", 1.10, 0.25, tourist_arrow("KOPPENBERG", left=True)),
    ("cycle.route.left", "rect", 0.30, 0.20, cycle_route(left=True)),
    ("cycle.route.right", "rect", 0.30, 0.20, cycle_route(left=False)),
    ("street.paterbergstraat", "rect", 0.95, 0.20, street_plate("PATERBERGSTRAAT")),
    ("plate.landbouw", "rect", 0.70, 0.16, sub_plate("uitgezonderd landbouwvoertuigen", blue=True)),
    ("plate.m11", "rect", 0.45, 0.16, sub_plate("", pictogram=True)),
    ("plate.100m", "rect", 0.45, 0.16, sub_plate("100 m")),
    ("plate.aangelanden", "rect", 0.70, 0.16, sub_plate("uitgezonderd aangelanden", blue=True)),
    ("plate.wegdek", "rect", 0.90, 0.18, sub_plate("WEGDEK IN SLECHTE STAAT", blue=True)),
    ("street.molenberg", "rect", 0.80, 0.30, town_plate("MOLENBERG", "SINT-DENIJS-BOEKEL", BLUE, BLUE, "zwalm")),
    ("street.wijlegem", "rect", 0.80, 0.30, town_plate("WIJLEGEM", "SINT-DENIJS-BOEKEL", BLUE, BLUE, "zwalm")),
    ("street.boitsbank", "rect", 0.80, 0.22, town_plate("Boitsbank", "MAARKEDAL", WHITE, GREEN)),
    ("street.taaienberg", "rect", 0.80, 0.22, town_plate("Taaienberg", "MAARKEDAL", WHITE, GREEN)),
    ("place.stdenijsboekel", "rect", 1.10, 0.55, village_board("St-Denijs-Boekel", "Zwalm")),
    ("grate.round", "disc", 0.45, 0.45, grate_round),
    ("grate.rect", "rect", 0.50, 0.30, grate_rect),
    ("paint.blue", "rect", 0.06, 0.06, paint((44, 78, 140))),
    ("paint.green", "rect", 0.06, 0.06, paint((30, 64, 44))),
    ("paint.yellow", "rect", 0.06, 0.06, paint((232, 186, 22))),
    ("paint.cabinet", "rect", 0.06, 0.06, paint((118, 124, 116))),
    ("paint.plinth", "rect", 0.06, 0.06, paint((46, 46, 43))),
    ("paint.gold", "rect", 0.06, 0.06, paint((201, 158, 62))),
    ("paint.stone", "rect", 0.06, 0.06, paint((214, 205, 186))),
    ("paint.marble", "rect", 0.06, 0.06, paint((232, 229, 220))),
    ("paint.door", "rect", 0.06, 0.06, paint((92, 56, 34))),
    ("paint.glass", "rect", 0.06, 0.06, paint((30, 34, 40))),
    ("paint.niche", "rect", 0.06, 0.06, paint((96, 62, 48))),
    ("paint.darkgrey", "rect", 0.06, 0.06, paint((64, 68, 72))),
]

# The kiosk's faces (`BuildingBuilder.buildFurniture`), at PROP_SCALE of the
# plates' density: seen from the road, never read. Packed after the plates,
# so they never move a plate. A prop painter returns its face as an image.
PROP_SCALE = 0.5
PROPS = [
    ("kiosk.front", "rect", 1.00, 1.44, kiosk_front),
    ("kiosk.end", "rect", 0.60, 1.44, kiosk_end),
    ("kiosk.roof", "rect", 1.12, 0.45, kiosk_roof),
]


# The Poggio di Sanremo's plates (Codice della Strada, as photographed on the
# SP55 and at the summit, scripts/courses research look.md sections 5-6):
# Italian warning triangles (red rim, white field, as the Belgian ones),
# the old black hairpin plates with a white chevron, an orange-rimmed convex
# mirror, blue extra-urban direction arrows, the white place board of the
# frazione, blue square crossing signs, a bus-stop plate, the phone box's
# disc and the 2026 sculpture's inscriptions. Text in the same DIN faces
# (the Italian "alfabeto normale" is close; macOS doesn't ship it).
IT_HEIGHT = 1536
IT_BLUE = (26, 88, 162)          # the SP55 arrows in the 2008 Commons photo, sunlit #2570be, painted a touch darker
IT_ORANGE = (222, 86, 42)        # traffic-mirror rims
NAVY = (36, 40, 98)              # the sculpture's lettering
FONT_SCRIPT = "/System/Library/Fonts/Supplemental/Brush Script.ttf"


def curve_picto(left: bool):
    """Pericolo curva: a thick black road line up the middle, bending
    hard to one side near the top."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        s = -1 if left else 1
        cx = (x0 + x1) / 2 - s * w * 0.05
        lw = int(w * 0.075)
        pts = [(cx, y0 + h * 0.84), (cx, y0 + h * 0.62)]
        for k in range(1, 13):
            t = k / 12
            ang = t * math.pi * 0.5
            pts.append((cx + s * w * 0.12 * (1 - math.cos(ang)), y0 + h * 0.62 - h * 0.12 * math.sin(ang)))
        pts.append((pts[-1][0] + s * w * 0.08, pts[-1][1]))
        d.line(pts, fill=BLACK, width=lw, joint="curve")
    return draw


def double_curve_picto(left_first: bool):
    """Doppia curva: an S, first to one side then the other."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        s = -1 if left_first else 1
        cx = (x0 + x1) / 2
        lw = int(w * 0.07)
        pts = []
        for k in range(25):
            t = k / 24
            pts.append((cx + s * w * 0.09 * math.sin(t * 2 * math.pi), y0 + h * 0.82 - h * 0.42 * t))
        d.line(pts, fill=BLACK, width=lw, joint="curve")
    return draw


def danger_picto(d, box):
    """Altri pericoli: a black exclamation mark."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    cx = (x0 + x1) / 2
    d.polygon([(cx - w * 0.035, y0 + h * 0.4), (cx + w * 0.035, y0 + h * 0.4), (cx + w * 0.02, y0 + h * 0.68),
               (cx - w * 0.02, y0 + h * 0.68)], fill=BLACK)
    r = w * 0.035
    d.ellipse([cx - r, y0 + h * 0.74 - r, cx + r, y0 + h * 0.74 + r], fill=BLACK)


def walker(d, cx, cy, h, fill):
    """A plain walking figure `h` tall, centred on (cx, cy)."""
    r = h * 0.09
    d.ellipse([cx - r, cy - h * 0.5, cx + r, cy - h * 0.5 + 2 * r], fill=fill)
    lw = max(2, int(h * 0.1))
    hip, neck = (cx, cy + h * 0.08), (cx + h * 0.02, cy - h * 0.26)
    d.line([neck, hip], fill=fill, width=int(lw * 1.3))
    d.line([hip, (cx - h * 0.16, cy + h * 0.5)], fill=fill, width=lw)
    d.line([hip, (cx + h * 0.06, cy + h * 0.28), (cx + h * 0.2, cy + h * 0.5)], fill=fill, width=lw, joint="curve")
    d.line([(cx + h * 0.02, cy - h * 0.2), (cx - h * 0.17, cy + h * 0.02)], fill=fill, width=int(lw * 0.8))
    d.line([(cx + h * 0.02, cy - h * 0.2), (cx + h * 0.18, cy - h * 0.02)], fill=fill, width=int(lw * 0.8))


def crossing_square(d, box):
    """Attraversamento pedonale: blue square, a white triangle with a
    black figure on a zebra."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    d.rectangle(box, fill=IT_BLUE)
    d.rectangle(inset(box, w * 0.03), outline=WHITE, width=max(2, int(w * 0.02)))
    tri = [(x0 + w * 0.12, y1 - h * 0.14), (x1 - w * 0.12, y1 - h * 0.14), ((x0 + x1) / 2, y0 + h * 0.1)]
    d.polygon(tri, fill=WHITE)
    for k in range(5):
        xa = x0 + w * (0.3 + 0.085 * k)
        d.rectangle([xa, y1 - h * 0.24, xa + w * 0.05, y1 - h * 0.19], fill=BLACK)
    walker(d, (x0 + x1) / 2, y0 + h * 0.5, h * 0.36, BLACK)


def chevron(left: bool):
    """The old black hairpin plates on the outside walls, one white
    chevron pointing round the bend (PEZ 2007 hairpin photo)."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        d.rectangle(box, fill=(18, 18, 20))
        s = -1 if left else 1
        cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
        tip = (cx + s * w * 0.26, cy)
        arm = w * 0.36
        lw = int(w * 0.17)
        d.line([(tip[0] - s * arm, cy - arm), tip, (tip[0] - s * arm, cy + arm)], fill=WHITE, width=lw, joint="curve")
        d.rectangle(inset(box, w * 0.02), outline=(70, 70, 72), width=max(1, int(w * 0.012)))
    return draw


def mirror_it(d, box):
    """A convex traffic mirror with a plain orange-red rim."""
    x0, y0, x1, y1 = box
    w = x1 - x0
    d.rectangle(box, fill=IT_ORANGE)
    d.ellipse(box, fill=IT_ORANGE)
    g = inset(box, w * 0.09)
    gw = g[2] - g[0]
    cx = (g[0] + g[2]) / 2
    for i in range(int(gw)):
        t = (i + 0.5) / gw
        half = math.sqrt(max(0.0, 0.25 - (t - 0.5) ** 2)) * gw
        sky = (146 + 58 * t, 178 + 34 * t, 214 + 12 * t)
        ground = (110 - 24 * t, 104 - 20 * t, 92 - 22 * t)
        c = sky if t < 0.52 else ground
        d.line([(cx - half, g[1] + i), (cx + half, g[1] + i)], fill=tuple(int(v) for v in c))
    d.arc(inset(box, w * 0.2), 200, 250, fill=(240, 244, 248), width=int(w * 0.04))


def direction(name: str, km: str = "", sp: str = "", right: bool = True, ground=IT_BLUE):
    """A blue (extra-urban) direction arrow: white rim round the arrow
    outline, the road's number boxed, the place, its distance."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        w, h = x1 - x0, y1 - y0
        d.rectangle(box, fill=ground)
        tipw = h * 0.5
        k = h * 0.06
        if right:
            pts = [(x0 + k, y0 + k), (x1 - tipw, y0 + k), (x1 - k * 1.2, (y0 + y1) / 2), (x1 - tipw, y1 - k), (x0 + k, y1 - k)]
        else:
            pts = [(x1 - k, y0 + k), (x0 + tipw, y0 + k), (x0 + k * 1.2, (y0 + y1) / 2), (x0 + tipw, y1 - k), (x1 - k, y1 - k)]
        d.line(pts + [pts[0]], fill=WHITE, width=max(2, int(h * 0.045)), joint="curve")
        a, b = (x0 + h * 0.2, x1 - tipw) if right else (x0 + tipw, x1 - h * 0.2)
        if sp:
            sw = h * 1.05
            sb = (a, y0 + h * 0.28, a + sw, y1 - h * 0.28)
            d.rounded_rectangle(sb, radius=h * 0.06, outline=WHITE, width=max(2, int(h * 0.04)))
            text(d, inset(sb, h * 0.04), sp, h * 0.3, WHITE)
            a += sw + h * 0.15
        if km:
            kw = d.textlength(km, font=font(FONT, h * 0.46)) + h * 0.05
            text(d, (b - kw, y0, b, y1), km, h * 0.46, WHITE, fit=1.0)
            b -= kw + h * 0.25
        text(d, (a, y0, b, y1), name, h * 0.5, WHITE)
    return draw


def place_board(name: str, sub: str):
    """The frazione's board: white, a black rim, the name and its comune."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        h = y1 - y0
        d.rectangle(box, fill=(236, 238, 232))
        d.rounded_rectangle(inset(box, h * 0.05), radius=h * 0.06, outline=BLACK, width=max(2, int(h * 0.035)))
        text(d, (x0 + h * 0.2, y0 + h * 0.1, x1 - h * 0.2, y0 + h * 0.66), name, h * 0.42, BLACK, fit=0.84)
        text(d, (x0 + h * 0.2, y0 + h * 0.62, x1 - h * 0.2, y1 - h * 0.12), sub, h * 0.16, BLACK, FONT_C)
    return draw


def bus_stop(d, box):
    """A bus-stop plate: blue, FERMATA over a white bus (no operator's logo)."""
    x0, y0, x1, y1 = box
    w, h = x1 - x0, y1 - y0
    d.rectangle(box, fill=IT_BLUE)
    d.rectangle(inset(box, w * 0.04), outline=WHITE, width=max(2, int(w * 0.03)))
    text(d, (x0, y0 + h * 0.06, x1, y0 + h * 0.3), "FERMATA", h * 0.14, WHITE, FONT_C)
    bx = (x0 + w * 0.18, y0 + h * 0.38, x1 - w * 0.18, y0 + h * 0.72)
    d.rounded_rectangle(bx, radius=w * 0.05, fill=WHITE)
    for k in range(3):
        xa = bx[0] + (bx[2] - bx[0]) * (0.08 + 0.3 * k)
        d.rectangle([xa, bx[1] + h * 0.04, xa + (bx[2] - bx[0]) * 0.22, bx[1] + h * 0.14], fill=IT_BLUE)
    for xf in (0.25, 0.75):
        cx = bx[0] + (bx[2] - bx[0]) * xf
        r = w * 0.07
        d.ellipse([cx - r, bx[3] - r, cx + r, bx[3] + r], fill=(30, 30, 34))
    text(d, (x0, y0 + h * 0.78, x1, y1 - h * 0.06), "BUS", h * 0.12, WHITE)


def phone_disc(d, box):
    """The phone box's mast sign: a white disc, a red handset."""
    x0, y0, x1, y1 = box
    w = x1 - x0
    d.rectangle(box, fill=(232, 232, 228))
    d.ellipse(box, fill=(232, 232, 228), outline=(180, 176, 170), width=max(1, int(w * 0.02)))
    cx, cy = (x0 + x1) / 2, (y0 + y1) / 2
    lw = int(w * 0.12)
    d.line([(cx - w * 0.24, cy - w * 0.14), (cx + w * 0.24, cy + w * 0.14)], fill=(200, 34, 36), width=lw)
    for sx in (-1, 1):
        ex, ey = cx + sx * w * 0.24, cy + sx * w * 0.14
        d.ellipse([ex - w * 0.1, ey - w * 0.1, ex + w * 0.1, ey + w * 0.1], fill=(200, 34, 36))


def inscription(lines, size=0.32):
    """Navy script on the white plinth (the 2026 sculpture)."""
    def draw(d, box):
        x0, y0, x1, y1 = box
        h = y1 - y0
        d.rectangle(box, fill=(238, 236, 228))
        n = len(lines)
        for k, line in enumerate(lines):
            band = (x0 + h * 0.08, y0 + h * k / n, x1 - h * 0.08, y0 + h * (k + 1) / n)
            text(d, band, line, h * size * 1.6 / n, NAVY, FONT_SCRIPT, fit=0.94)
    return draw


def telecom_panel(d, box):
    """The phone box's red lower panel, faded a little."""
    x0, y0, x1, y1 = box
    d.rectangle(box, fill=(158, 34, 30))
    d.rectangle(inset(box, (x1 - x0) * 0.06), fill=(176, 40, 34))


# key, shape, width m, height m, painter. "arrowR"/"arrowL": a direction
# arrow, cut to a point half its height long (`BuildingBuilder.outline`).
IT_SIGNS = [
    ("it.dir.sp55.baiardo", "arrowR", 1.60, 0.40, direction("BAIARDO", "22.5", "SP55")),
    ("it.dir.sp55.ceriana", "arrowR", 1.60, 0.40, direction("CERIANA", "", "SP55")),
    ("it.dir.sp55.poggio", "arrowR", 1.60, 0.40, direction("POGGIO", "4", "SP55")),
    ("it.place.poggio", "rect", 1.25, 0.62, place_board("POGGIO", "(comune di SAN REMO)")),
    ("it.dir.ventimiglia", "arrowR", 0.95, 0.20, direction("VENTIMIGLIA", "22")),
    ("it.dir.sanremo", "arrowR", 0.95, 0.20, direction("SAN REMO")),
    ("it.dir.imperia", "arrowL", 0.95, 0.20, direction("IMPERIA", right=False)),
    ("it.dir.armataggia", "arrowL", 0.95, 0.20, direction("ARMA DI TAGGIA", right=False)),
    ("it.tri.curve.left", "tri", 0.90, 0.78, triangle(curve_picto(True))),
    ("it.tri.curve.right", "tri", 0.90, 0.78, triangle(curve_picto(False))),
    ("it.tri.doublecurve.left", "tri", 0.90, 0.78, triangle(double_curve_picto(True))),
    ("it.tri.doublecurve.right", "tri", 0.90, 0.78, triangle(double_curve_picto(False))),
    ("it.tri.danger", "tri", 0.90, 0.78, triangle(danger_picto)),
    ("it.crossing", "rect", 0.60, 0.60, crossing_square),
    ("it.chevron.left", "rect", 0.60, 0.60, chevron(True)),
    ("it.chevron.right", "rect", 0.60, 0.60, chevron(False)),
    ("it.mirror", "disc", 0.60, 0.60, mirror_it),
    ("it.c.3_5t", "disc", 0.60, 0.60, disc(inner=lambda d, b: text(d, b, "3,5t", (b[3] - b[1]) * 0.3, BLACK))),
    ("it.c.50", "disc", 0.60, 0.60, disc(inner=lambda d, b: text(d, b, "50", (b[3] - b[1]) * 0.42, BLACK))),
    ("it.bus.stop", "rect", 0.40, 0.60, bus_stop),
    ("it.phone", "disc", 0.42, 0.42, phone_disc),
    ("it.telecom.panel", "rect", 0.40, 0.50, telecom_panel),
    ("it.inscription.classicissima", "rect", 1.60, 0.62, inscription(["La Classicissima", "di Primavera"])),
    ("it.inscription.sanremo", "rect", 1.60, 0.62, inscription(["SanremoWomen", "MilanoSanremo"])),
    ("grate.round", "disc", 0.45, 0.45, grate_round),
    ("grate.rect", "rect", 0.50, 0.30, grate_rect),
    # The Flemish paints, so the props that take them keep their colours.
    ("paint.blue", "rect", 0.06, 0.06, paint((44, 78, 140))),
    ("paint.green", "rect", 0.06, 0.06, paint((30, 64, 44))),
    ("paint.yellow", "rect", 0.06, 0.06, paint((232, 186, 22))),
    ("paint.cabinet", "rect", 0.06, 0.06, paint((118, 124, 116))),
    ("paint.plinth", "rect", 0.06, 0.06, paint((46, 46, 43))),
    ("paint.gold", "rect", 0.06, 0.06, paint((201, 158, 62))),
    ("paint.stone", "rect", 0.06, 0.06, paint((214, 205, 186))),
    ("paint.marble", "rect", 0.06, 0.06, paint((227, 220, 200))),     # the piazza's white marble edging, #e3dcc8
    ("paint.door", "rect", 0.06, 0.06, paint((92, 56, 34))),
    ("paint.glass", "rect", 0.06, 0.06, paint((30, 34, 40))),
    ("paint.niche", "rect", 0.06, 0.06, paint((96, 62, 48))),
    ("paint.darkgrey", "rect", 0.06, 0.06, paint((64, 68, 72))),
    # The Riviera's: jersey blocks, the growers' vans, wheelie bins, the
    # sculpture's corten and white plinth, the phone box, the planter's brick.
    ("paint.white", "rect", 0.06, 0.06, paint((232, 231, 226))),
    ("paint.red", "rect", 0.06, 0.06, paint((188, 36, 34))),
    ("paint.corten", "rect", 0.06, 0.06, paint((122, 74, 50))),       # #7a4a32
    ("paint.render", "rect", 0.06, 0.06, paint((238, 234, 224))),
    ("paint.silver", "rect", 0.06, 0.06, paint((178, 172, 166))),     # the phone box's frame, #b2a49e weathered
    ("paint.tyre", "rect", 0.06, 0.06, paint((24, 24, 26))),
    ("paint.bin.green", "rect", 0.06, 0.06, paint((46, 108, 60))),
    ("paint.bin.brown", "rect", 0.06, 0.06, paint((98, 64, 40))),
    ("paint.bin.blue", "rect", 0.06, 0.06, paint((34, 74, 150))),
    ("paint.brick", "rect", 0.06, 0.06, paint((168, 92, 66))),
    ("paint.timber", "rect", 0.06, 0.06, paint((70, 52, 38))),        # the piazza's dark benches
    ("paint.orange", "rect", 0.06, 0.06, paint(IT_ORANGE)),
]
IT_PROPS: list = []


def bake(signs=None, props=None, name: str = "cj_signs", height: int = HEIGHT, out_dir: Path = OUT) -> None:
    """Packs `signs` (shelves by height) then `props` into `<name>.png` and
    `<name>_map.json` in `out_dir`: the Flemish atlas by default."""
    signs = SIGNS if signs is None else signs
    props = PROPS if props is None else props
    big, tall = SIZE * SS, height * SS
    atlas = Image.new("RGB", (big, tall), (128, 128, 128))
    d = ImageDraw.Draw(atlas)
    order = [(*c, 1.0) for c in sorted(signs, key=lambda c: -c[3])]        # shelves by height
    order += [(*c, PROP_SCALE) for c in props]
    x = y = row_h = 0
    cells = {}
    for key, shape, w_m, h_m, painter, scale in order:
        w, h = int(w_m * PPM * scale), int(h_m * PPM * scale)
        if x + w + 2 * PAD > big:
            x, y, row_h = 0, y + row_h, 0
        box = (x + PAD, y + PAD, x + PAD + w, y + PAD + h)
        if box[3] + PAD > tall:
            raise SystemExit(f"atlas full at {key}")
        face = painter(d, box)
        if face is not None:
            atlas.paste(face, box[:2])
        # The cell's padding takes its edge colours, so mips don't bleed grey.
        cells[key] = dict(key=key, shape=shape, w=w_m, h=h_m,
                          uv=[round(box[0] / big, 6), round(box[1] / tall, 6),
                              round(box[2] / big, 6), round(box[3] / tall, 6)])
        x += w + 2 * PAD
        row_h = max(row_h, h + 2 * PAD)
    # Bleed every cell's border into its padding.
    px = atlas.load()
    for c in cells.values():
        u0, v0, u1, v1 = (int(round(t * n)) for t, n in zip(c["uv"], (big, tall, big, tall)))
        for yy in range(v0 - PAD + 2, v1 + PAD - 2):
            for xx in range(u0 - PAD + 2, u1 + PAD - 2):
                if u0 <= xx < u1 and v0 <= yy < v1:
                    continue
                px[xx, yy] = px[min(max(xx, u0), u1 - 1), min(max(yy, v0), v1 - 1)]
    out = atlas.resize((SIZE, height), Image.LANCZOS)
    out_dir.mkdir(parents=True, exist_ok=True)
    out.save(out_dir / f"{name}.png", optimize=True)
    keys = [k for k, *_ in signs + props]
    (out_dir / f"{name}_map.json").write_text(json.dumps([cells[k] for k in keys], indent=1) + "\n")
    used = (y + row_h) / tall
    print(f"{name}.png: {len(cells)} cells, {used * 100:.0f} % of the height used")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--it", action="store_true", help="bake the Italian atlas (cj_signs_it) instead of the Flemish one")
    ap.add_argument("--out", type=Path, default=OUT, help="output folder (default: the app's CourseTextures)")
    a = ap.parse_args()
    if a.it:
        bake(IT_SIGNS, IT_PROPS, "cj_signs_it", IT_HEIGHT, a.out)
    else:
        bake(out_dir=a.out)
