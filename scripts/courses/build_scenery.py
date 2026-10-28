# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pyproj", "pillow", "matplotlib", "scipy"]
# ///
"""Bake scenery.json for a CycleJames course (see scripts/courses/FORMAT.md).

    uv run --script scripts/courses/build_scenery.py koppenberg [--swift-check]   (or oudekwaremont, paterberg, muur)

Reads the already-baked course folder (course.json, terrain_near.u16,
canopy_near.u16) and the raw aerial photo build_course.py keeps out of the
app in scripts/courses/pipeline/<id>/ortho_near.jpg, and adds scenery.json
to the course folder, covering the near grid:

  * OpenStreetMap (Overpass, cached): building tags, landuse/natural/leisure
    polygons, side roads, barriers, waterways and ponds.
  * GRB "gebouw aan de grond" (Digitaal Vlaanderen WFS, native Lambert 72,
    cached): building footprints. OSM's buildings here are a partial import
    of GRB, so GRB supplies the geometry and OSM the tags (matched by
    source:geometry:ref=Gbg/<OIDN> or by overlap).
  * canopy_near.u16 (DHM Vlaanderen II DSM - DTM, 1 m, leaf-off 25/1/2015):
    building heights and roof shapes, individual trees (pit-free canopy
    model, variable-window local maxima, watershed crowns) and shrubs
    (0.6-3 m vegetation on a 1.5 m lattice).
  * ortho_near.jpg (summer 2024) to confirm that canopy-model vegetation is
    still vegetation and to tell bushes from posts/animals.

No conifer/deciduous signal is used: the only other mosaic ("winter" 2025)
was flown on 29/4/2025, in leaf, and OSM has no needle-leaved woodland here,
so every tree is "deciduous".

Raw downloads live only in scripts/courses/.cache/<id>/ and are parsed as data.
Debug renders go to scripts/courses/debug/<id>/.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import resource
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import date
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
CACHE_ROOT = REPO / "scripts" / "courses" / ".cache"
DEBUG_ROOT = REPO / "scripts" / "courses" / "debug"
OUT_ROOT = REPO / "CycleJames" / "Resources" / "Courses"
PIPELINE_ROOT = REPO / "scripts" / "courses" / "pipeline"  # not shipped; see FORMAT.md

USER_AGENT = "CycleJames-course-builder/1.0 (offline course baking; contact via repo owner)"
OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]

# Per-course scenery settings. Route way ids come from build_course.py's config
# (repeated here so this script stays standalone).
COURSES: dict[str, dict] = {
    "koppenberg": {
        "route_ways": [121762002, 25711648, 175941336, 86501824, 509660327,
                       370297724, 143078350, 370301194],
        # Overpass bbox (S, W, N, E); must contain the near grid (checked at run time).
        "osm_bbox": (50.8076, 3.5640, 50.8170, 3.5866),
        # Only consulted for its flight date (is a leaf-off evergreen test possible?).
        "winter_ortho": {"service": "https://geo.api.vlaanderen.be/OMW/wms", "vdc_layer": "OMWRGB25VL_vdc"},
    },
    "oudekwaremont": {
        # Candelabra-pollarded limes every ~8 m on the left of upper Kwaremontplein (photo survey;
        # freshly pollarded, so too small for the leaf-off LiDAR crowns).
        "tree_rows": [(1492.0, 1596.0, -1, 0.9, 8.0, 5.5, 1.8)],
        "route_ways": [79620616, 1375368944, 1375368938, 31295044, 169091283, 660521414, 86501829,
                       1527496580, 1472108189, 850884348, 25730689, 1472108187, 1472108188, 368750237,
                       25730690, 1159118827, 242724612, 313601768],
        "osm_bbox": (50.7638, 3.5181, 50.7931, 3.5391),
        "winter_ortho": {"service": "https://geo.api.vlaanderen.be/OMW/wms", "vdc_layer": "OMWRGB25VL_vdc"},
    },
    "paterberg": {
        "route_ways": [86501819, 86501826, 369071618, 31295027, 223598561, 1472505832],
        "osm_bbox": (50.7762, 3.5377, 50.7876, 3.5552),
        "winter_ortho": {"service": "https://geo.api.vlaanderen.be/OMW/wms", "vdc_layer": "OMWRGB25VL_vdc"},
    },
    "muur": {
        "route_ways": [117050598, 140834449, 226829598, 121791848, 51812708, 51812713, 1049733123, 229368632,
                       31295090, 31295211, 86502351, 1116471189, 501773779, 147154162, 439546912, 86502349,
                       127709175, 147154153, 365912740, 571820915, 571820916, 572035233, 1453533351, 410355879,
                       117772267, 86502347, 365912388, 229161973, 86502330],
        "osm_bbox": (50.7685, 3.8715, 50.7767, 3.8956),
        "winter_ortho": {"service": "https://geo.api.vlaanderen.be/OMW/wms", "vdc_layer": "OMWRGB25VL_vdc"},
    },
}

# ---------------------------------------------------------------------------
# Tunables (all derived from the data / general practice, not from the course)
# ---------------------------------------------------------------------------
TREE_MIN_H = 3.0          # m, minimum tree-top height
CHM_SMOOTH_SIGMA = 0.7    # m, light Gaussian on the canopy model before peak search
PIT_FILL_R = 2.0          # m, grey-closing radius for the pit-free canopy model (leaf-off LiDAR)
CROWN_MIN_H = 2.0         # m, canopy below this is not crown
CROWN_REL_H = 0.35        # crown cells must be >= this fraction of the tree-top height
SHRUB_MIN_H, SHRUB_MAX_H = 0.6, 3.0
SHRUB_SPACING = 1.5       # m lattice
SHRUB_MIN_CELLS = 4       # smaller low-vegetation blobs need confirmation in the ortho
ROUTE_CLEAR_M = 0.5       # keep trunks/shrubs this far outside the route carriageway
SIDE_ROAD_CLEAR_M = 0.4   # shrub centres at least this far outside a side-road carriageway
TRUNK_SETBACK_M = 1.5     # trunks moved off the ride go at least this far from its carriageway if the crown allows
BUILDING_DILATE_M = 1.0   # building mask grows by this for tree/shrub exclusion

# OSM tag -> scenery enums
LANDUSE_MAP = {
    ("landuse", "farmland"): "farmland",
    ("landuse", "meadow"): "meadow",
    ("landuse", "grass"): "grass",
    ("landuse", "village_green"): "grass",
    ("landuse", "forest"): "forest",
    ("natural", "wood"): "forest",
    ("landuse", "orchard"): "orchard",
    ("natural", "scrub"): "scrub",
    ("natural", "heath"): "scrub",
    ("landuse", "residential"): "residential",
    ("landuse", "farmyard"): "residential",
    ("natural", "grassland"): "grass",
    ("leisure", "park"): "grass",
    ("leisure", "garden"): "grass",
    ("leisure", "pitch"): "grass",
}
COBBLES = {"sett", "cobblestone", "unhewn_cobblestone", "cobblestone:flattened", "paving_stones"}
ASPHALT = {"asphalt", "concrete", "concrete:plates", "concrete:lanes", "paved", "chipseal", "metal", "wood"}
GRAVEL = {"gravel", "fine_gravel", "compacted", "pebblestone", "grass_paver"}
UNPAVED = {"unpaved", "dirt", "ground", "earth", "grass", "mud", "sand", "soil"}
# Default carriageway widths when OSM has no width tag (typical Flemish rural values).
HIGHWAY_WIDTH = {
    "motorway": 7.5, "trunk": 7.0, "primary": 7.0, "secondary": 6.5, "tertiary": 5.5,
    "unclassified": 4.0, "residential": 4.5, "living_street": 4.0, "service": 3.0,
    "track": 2.5, "cycleway": 2.0, "footway": 1.5, "path": 1.2, "bridleway": 1.5, "steps": 1.5,
    "pedestrian": 3.0,
}
SKIP_HIGHWAYS = {"proposed", "construction", "abandoned", "razed", "platform", "bus_stop", "elevator"}
FENCE_MAP = {"fence": "fence", "guard_rail": "fence", "handrail": "fence", "chain": "fence",
             "wall": "wall", "retaining_wall": "wall", "city_wall": "wall",
             "hedge": "hedge", "hedge_bank": "hedge"}
STREAMS = {"stream", "river", "ditch", "drain", "canal", "brook"}


# ---------------------------------------------------------------------------
# HTTP with cache + backoff (same policy as build_course.py)
# ---------------------------------------------------------------------------


class FetchError(RuntimeError):
    pass


def _http(url: str, data: bytes | None = None, timeout: float = 180.0):
    req = urllib.request.Request(url, data=data, headers={"User-Agent": USER_AGENT})
    if data is not None:
        req.add_header("Content-Type", "application/x-www-form-urlencoded")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, dict(r.headers), r.read()
    except urllib.error.HTTPError as e:
        return e.code, dict(e.headers or {}), e.read() if e.fp else b""


def cached_fetch(cache: Path, name: str, url: str, data: bytes | None = None,
                 validate=None, tries: int = 6, log=print) -> bytes:
    path = cache / name
    if path.exists() and path.stat().st_size > 0:
        return path.read_bytes()
    delay = 5.0
    last = ""
    for attempt in range(tries):
        try:
            code, headers, body = _http(url, data)
        except Exception as e:  # network error / timeout
            code, headers, body = -1, {}, str(e).encode()
        if code == 200 and (validate is None or validate(body, headers)):
            tmp = path.with_suffix(path.suffix + ".part")
            tmp.write_bytes(body)
            tmp.replace(path)
            return body
        last = f"HTTP {code}: {body[:200]!r}"
        if code in (400, 403, 404) and attempt >= 1:
            break
        log(f"    fetch {name} failed ({last[:120]}), retry in {delay:.0f}s")
        time.sleep(delay)
        delay = min(delay * 2, 90)
    raise FetchError(f"could not fetch {name}: {last}")


def _overpass_ok(body: bytes, headers) -> bool:
    try:
        d = json.loads(body)
    except ValueError:
        return False
    return bool(d.get("elements")) and "error" not in str(d.get("remark", "")).lower()


def fetch_scenery_osm(cache: Path, bbox, log) -> dict:
    s, w, n, e = bbox
    b = f"({s:.5f},{w:.5f},{n:.5f},{e:.5f})"
    q = ("[out:json][timeout:120];("
         f"way[\"building\"]{b};relation[\"building\"]{b};"
         f"way[\"landuse\"]{b};relation[\"landuse\"]{b};"
         f"way[\"natural\"]{b};relation[\"natural\"]{b};"
         f"way[\"leisure\"]{b};relation[\"leisure\"]{b};"
         f"way[\"highway\"]{b};way[\"barrier\"]{b};"
         f"way[\"waterway\"]{b};way[\"water\"]{b};relation[\"water\"]{b};"
         f"node[\"natural\"=\"tree\"]{b};"
         ");out body geom;")
    key = hashlib.sha1(q.encode()).hexdigest()[:12]
    name = f"osm_scenery_{key}.json"
    body = None
    for ep in OVERPASS_ENDPOINTS:
        try:
            body = cached_fetch(cache, name, ep, data=urllib.parse.urlencode({"data": q}).encode(),
                                validate=_overpass_ok, tries=4, log=log)
            break
        except FetchError as err:
            log(f"    overpass endpoint {ep} gave up: {err}")
    if body is None:
        raise FetchError("all Overpass endpoints failed")
    d = json.loads(body)
    d["_cache_file"] = name
    d["_query"] = q
    return d


def fetch_winter_date(cache: Path, wcfg: dict, oE72: float, oN72: float, log) -> str:
    """Flight date of the winter mosaic at the course origin (vliegdagcontour layer)."""
    bb = f"{oE72 - 50},{oN72 - 50},{oE72 + 50},{oN72 + 50}"
    q = urllib.parse.urlencode({
        "SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetFeatureInfo", "LAYERS": wcfg["vdc_layer"],
        "QUERY_LAYERS": wcfg["vdc_layer"], "STYLES": "", "CRS": "EPSG:31370", "BBOX": bb, "WIDTH": 101,
        "HEIGHT": 101, "I": 50, "J": 50, "INFO_FORMAT": "application/geo+json", "FORMAT": "image/png"})
    try:
        body = cached_fetch(cache, f"vdc_{wcfg['vdc_layer']}_{int(oE72)}_{int(oN72)}.json",
                            f"{wcfg['service']}?{q}", validate=lambda b, h: b.lstrip().startswith(b"{"),
                            log=log, tries=3)
        feats = json.loads(body).get("features", [])
        if feats:
            props = feats[0].get("properties", {})
            return ", ".join(str(v) for k, v in props.items() if "datum" in k.lower() and v not in (None, "", "Null"))
    except Exception as e:  # informative only
        log(f"    winter flight date lookup failed: {e}")
    return ""


GRB_WFS = "https://geo.api.vlaanderen.be/GRB/wfs"


def fetch_grb_buildings(cache: Path, x0: int, x1: int, y0: int, y1: int, log) -> list:
    """GRB GBG (gebouw aan de grond) footprints intersecting the box, as (properties, exterior ring in L72)."""
    q = urllib.parse.urlencode({
        "SERVICE": "WFS", "VERSION": "2.0.0", "REQUEST": "GetFeature", "TYPENAMES": "GRB:GBG",
        "BBOX": f"{x0},{y0},{x1},{y1},urn:ogc:def:crs:EPSG::31370", "SRSNAME": "urn:ogc:def:crs:EPSG::31370",
        "OUTPUTFORMAT": "application/json"})
    body = cached_fetch(cache, f"wfs_GRB_GBG_{x0}_{x1}_{y0}_{y1}.json", f"{GRB_WFS}?{q}",
                        validate=lambda b, h: b.lstrip().startswith(b"{"), log=log, tries=4)
    d = json.loads(body)
    crs = str(d.get("crs", {}).get("properties", {}).get("name", ""))
    if crs and "31370" not in crs:
        raise SystemExit(f"GRB WFS answered in {crs}, expected EPSG:31370")
    outv = []
    for f_ in d.get("features", []):
        geom = f_.get("geometry") or {}
        polys = [geom["coordinates"]] if geom.get("type") == "Polygon" else (
            geom["coordinates"] if geom.get("type") == "MultiPolygon" else [])
        for poly in polys:
            ext = np.array(poly[0], dtype=np.float64)[:, :2]
            if len(ext) >= 4:
                outv.append((f_.get("properties", {}), ext))
    log(f"[grb] {len(outv)} GRB GBG footprints ({len(d.get('features', []))} features) in the near grid box")
    return outv


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------


def signed_area(ring: np.ndarray) -> float:
    x, y = ring[:, 0], ring[:, 1]
    return 0.5 * float(np.dot(x, np.roll(y, -1)) - np.dot(np.roll(x, -1), y))


def clean_ring(pts: np.ndarray, nd: int = 1) -> np.ndarray | None:
    """Round, drop the closing point and consecutive duplicates, wind CCW. None if degenerate."""
    p = np.round(np.asarray(pts, dtype=np.float64), nd)
    if len(p) and np.allclose(p[0], p[-1]):
        p = p[:-1]
    if len(p) < 3:
        return None
    keep = np.ones(len(p), bool)
    keep[1:] = np.any(np.diff(p, axis=0) != 0, axis=1)
    p = p[keep]
    if len(p) >= 2 and np.allclose(p[0], p[-1]):
        p = p[:-1]
    # drop collinear spikes (zero-area back-and-forth vertices)
    changed = True
    while changed and len(p) >= 3:
        changed = False
        a, b, c = np.roll(p, 1, axis=0), p, np.roll(p, -1, axis=0)
        cross = (b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (b[:, 1] - a[:, 1]) * (c[:, 0] - a[:, 0])
        bad = np.abs(cross) < 1e-9
        if bad.any() and len(p) - bad.sum() >= 3:
            p = p[~bad]
            changed = True
        elif bad.any():
            return None
    if len(p) < 3:
        return None
    A = signed_area(p)
    if abs(A) < 0.5:
        return None
    if A < 0:
        p = p[::-1]
    return p


def clip_polygon_rect(pts: np.ndarray, x0, y0, x1, y1) -> np.ndarray:
    """Sutherland-Hodgman clip of a (not closed) ring against an axis-aligned rectangle."""
    def clip(poly, inside, inter):
        out = []
        n = len(poly)
        for i in range(n):
            cur, prev = poly[i], poly[i - 1]
            ci, pi = inside(cur), inside(prev)
            if ci:
                if not pi:
                    out.append(inter(prev, cur))
                out.append(cur)
            elif pi:
                out.append(inter(prev, cur))
        return out

    def ix(p, q, x):
        t = (x - p[0]) / (q[0] - p[0])
        return (x, p[1] + t * (q[1] - p[1]))

    def iy(p, q, y):
        t = (y - p[1]) / (q[1] - p[1])
        return (p[0] + t * (q[0] - p[0]), y)

    poly = [tuple(map(float, p)) for p in pts]
    for inside, inter in (
        (lambda p: p[0] >= x0, lambda p, q: ix(p, q, x0)),
        (lambda p: p[0] <= x1, lambda p, q: ix(p, q, x1)),
        (lambda p: p[1] >= y0, lambda p, q: iy(p, q, y0)),
        (lambda p: p[1] <= y1, lambda p, q: iy(p, q, y1)),
    ):
        if not poly:
            break
        poly = clip(poly, inside, inter)
    return np.array(poly, dtype=np.float64).reshape(-1, 2)


def clip_polyline_rect(pts: np.ndarray, x0, y0, x1, y1) -> list[np.ndarray]:
    """Liang-Barsky per segment; returns the pieces of the polyline inside the rectangle."""
    pieces: list[list] = []
    cur: list = []
    for i in range(len(pts) - 1):
        (ax, ay), (bx, by) = pts[i], pts[i + 1]
        dx, dy = bx - ax, by - ay
        t0, t1 = 0.0, 1.0
        ok = True
        for p, q in ((-dx, ax - x0), (dx, x1 - ax), (-dy, ay - y0), (dy, y1 - ay)):
            if p == 0:
                if q < 0:
                    ok = False
                    break
            else:
                t = q / p
                if p < 0:
                    t0 = max(t0, t)
                else:
                    t1 = min(t1, t)
        if not ok or t0 > t1:
            if cur:
                pieces.append(cur)
                cur = []
            continue
        a = (ax + t0 * dx, ay + t0 * dy)
        b = (ax + t1 * dx, ay + t1 * dy)
        if not cur:
            cur = [a, b]
        elif t0 > 0:  # re-entered: start a new piece
            pieces.append(cur)
            cur = [a, b]
        else:
            cur.append(b)
        if t1 < 1:
            pieces.append(cur)
            cur = []
    if cur:
        pieces.append(cur)
    return [np.array(p) for p in pieces if len(p) >= 2]


def clean_line(pts: np.ndarray, nd: int = 1) -> np.ndarray | None:
    p = np.round(np.asarray(pts, dtype=np.float64), nd)
    if len(p) < 2:
        return None
    keep = np.ones(len(p), bool)
    keep[1:] = np.any(np.diff(p, axis=0) != 0, axis=1)
    p = p[keep]
    if len(p) < 2 or float(np.hypot(*np.diff(p, axis=0).T).sum()) < 1.0:
        return None
    return p


def densify(pts: np.ndarray, step: float) -> tuple[np.ndarray, np.ndarray]:
    """Points every <= step along the polyline, and their distance along it."""
    seg = np.hypot(*np.diff(pts, axis=0).T)
    s = np.concatenate([[0.0], np.cumsum(seg)])
    n = max(2, int(math.ceil(s[-1] / step)) + 1)
    sd = np.linspace(0.0, s[-1], n)
    return np.stack([np.interp(sd, s, pts[:, 0]), np.interp(sd, s, pts[:, 1])], axis=1), sd


def assemble_rings(member_geoms: list[np.ndarray], tol: float = 0.05) -> list[np.ndarray]:
    """Join open member ways end-to-end into closed rings (multipolygon outers)."""
    segs = [g for g in member_geoms if len(g) >= 2]
    rings = []
    while segs:
        cur = segs.pop(0)
        changed = True
        while not np.allclose(cur[0], cur[-1], atol=tol) and changed:
            changed = False
            for k, g in enumerate(segs):
                if np.allclose(cur[-1], g[0], atol=tol):
                    cur = np.vstack([cur, g[1:]])
                elif np.allclose(cur[-1], g[-1], atol=tol):
                    cur = np.vstack([cur, g[::-1][1:]])
                elif np.allclose(cur[0], g[-1], atol=tol):
                    cur = np.vstack([g[:-1], cur])
                elif np.allclose(cur[0], g[0], atol=tol):
                    cur = np.vstack([g[::-1][:-1], cur])
                else:
                    continue
                segs.pop(k)
                changed = True
                break
        if np.allclose(cur[0], cur[-1], atol=tol):
            rings.append(cur)
    return rings


def cells_in_polygon(ring: np.ndarray, oE: float, oN: float, cell: float, rows: int, cols: int,
                     shrink: float = 0.0):
    """(r, c) index arrays of raster cells whose centre lies inside the ring (optionally shrunk)."""
    from matplotlib.path import Path as MPath
    e0, n0 = ring.min(axis=0)
    e1, n1 = ring.max(axis=0)
    c0 = max(0, int(math.floor((e0 - oE) / cell)))
    c1 = min(cols - 1, int(math.floor((e1 - oE) / cell)))
    r0 = max(0, int(math.floor((oN - n1) / cell)))
    r1 = min(rows - 1, int(math.floor((oN - n0) / cell)))
    if c1 < c0 or r1 < r0:
        return np.zeros(0, int), np.zeros(0, int)
    rr, cc = np.mgrid[r0:r1 + 1, c0:c1 + 1]
    ce = oE + (cc + 0.5) * cell
    cn = oN - (rr + 0.5) * cell
    pts = np.stack([ce.ravel(), cn.ravel()], axis=1)
    path = MPath(np.vstack([ring, ring[:1]]), closed=True)
    inside = path.contains_points(pts)
    if shrink:
        inside &= _dist_to_ring(pts, ring) >= shrink
    return rr.ravel()[inside], cc.ravel()[inside]


def _dist_to_ring(pts: np.ndarray, ring: np.ndarray) -> np.ndarray:
    a = ring
    b = np.roll(ring, -1, axis=0)
    d = np.full(len(pts), np.inf)
    for (ax, ay), (bx, by) in zip(a, b):
        dx, dy = bx - ax, by - ay
        L2 = dx * dx + dy * dy
        if L2 == 0:
            continue
        t = np.clip(((pts[:, 0] - ax) * dx + (pts[:, 1] - ay) * dy) / L2, 0, 1)
        d = np.minimum(d, np.hypot(pts[:, 0] - (ax + t * dx), pts[:, 1] - (ay + t * dy)))
    return d


def disk(radius: float) -> np.ndarray:
    r = int(math.ceil(radius))
    y, x = np.mgrid[-r:r + 1, -r:r + 1]
    return (x * x + y * y) <= radius * radius + 1e-9


def load_u16(path: Path, hdr: dict) -> np.ndarray:
    raw = np.fromfile(path, dtype="<u2")
    if raw.size != hdr["rows"] * hdr["cols"]:
        raise SystemExit(f"{path.name}: {raw.size} values, header says {hdr['rows']}x{hdr['cols']}")
    a = (raw.astype(np.float32) / 100.0 + np.float32(hdr["baseM"])).reshape(hdr["rows"], hdr["cols"])
    a[raw.reshape(a.shape) == 65535] = np.nan
    return a


def peak_rss_mb() -> float:
    r = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return r / (1024 * 1024) if sys.platform == "darwin" else r / 1024


# ---------------------------------------------------------------------------
# OSM parsing
# ---------------------------------------------------------------------------


def osm_features(osm: dict, to_local):
    """Yield (kind, tags, element, list-of-local-arrays, is_area) for every element."""
    for el in osm["elements"]:
        t = el.get("tags", {})
        if el["type"] == "way" and "geometry" in el:
            g = to_local(el["geometry"])
            closed = len(el["nodes"]) >= 4 and el["nodes"][0] == el["nodes"][-1]
            yield t, el, [g], closed
        elif el["type"] == "relation" and t.get("type") == "multipolygon":
            outers = [to_local(m["geometry"]) for m in el.get("members", [])
                      if m.get("type") == "way" and m.get("role") in ("outer", "") and m.get("geometry")]
            yield t, el, assemble_rings(outers), True


def building_kind(t: dict) -> str:
    b = t.get("building", "yes")
    if b in ("house", "detached", "semidetached_house", "terrace", "residential", "bungalow", "apartments",
             "dormitory"):
        return "house"
    if b == "farm":
        return "farm"
    if b in ("farm_auxiliary", "barn", "stable", "cowshed", "sty", "greenhouse"):
        return "barn"
    if b in ("church", "cathedral") or t.get("amenity") == "place_of_worship" and b != "chapel":
        return "church"
    if b in ("chapel", "shrine"):
        return "chapel"
    if b == "yes" and "addr:housenumber" in t:
        return "house"  # GRB-imported main building with an address
    return "other"


ROOF_TAG_MAP = {"gabled": "gabled", "saltbox": "gabled", "gambrel": "gabled", "hipped": "hipped",
                "half-hipped": "hipped", "side_hipped": "hipped", "pyramidal": "hipped", "mansard": "hipped",
                "flat": "flat"}
DEFAULT_HEIGHT = {"house": 8.0, "farm": 8.0, "barn": 7.0, "church": 15.0, "chapel": 5.0, "other": 3.5}
# Above this a LiDAR "roof" height is taken to be a tree over the footprint, not the building.
HEIGHT_CAP = {"house": 16.0, "farm": 16.0, "barn": 15.0, "church": 45.0, "chapel": 12.0}


def _centroid(ring: np.ndarray) -> np.ndarray:
    r = ring[:-1] if np.allclose(ring[0], ring[-1]) else ring
    x, y = r[:, 0], r[:, 1]
    x1, y1 = np.roll(x, -1), np.roll(y, -1)
    cr = x * y1 - x1 * y
    A = cr.sum() / 2
    if abs(A) < 1e-9:
        return r.mean(axis=0)
    return np.array([((x + x1) * cr).sum() / (6 * A), ((y + y1) * cr).sum() / (6 * A)])


def _num(v) -> float | None:
    try:
        return float(str(v).split(";")[0].replace("m", "").replace(",", ".").strip())
    except (TypeError, ValueError):
        return None


def road_surface(t: dict) -> str:
    s = t.get("surface", "")
    if s in COBBLES:
        return "cobbles"
    if s in ASPHALT:
        return "asphalt"
    if s in GRAVEL:
        return "gravel"
    if s in UNPAVED:
        return "unpaved"
    hw = t.get("highway", "")
    if hw == "track":
        return {"grade1": "asphalt", "grade2": "gravel"}.get(t.get("tracktype", ""), "unpaved")
    if hw in ("path", "footway", "bridleway", "steps"):
        return "unpaved"
    return "asphalt"


def roof_from_dsm(z: np.ndarray, e: np.ndarray, n: np.ndarray, ring: np.ndarray):
    """Classify a roof from relative heights z at cell centres (e, n) inside the eroded footprint.

    Least-squares fits of a flat roof, a gabled roof with the ridge along either footprint axis,
    and a hipped roof (four equal-slope planes). Pitched shapes are only assigned to near-
    rectangular footprints, where one such model can describe the whole roof; multi-wing
    buildings stay "unknown". Returns (shape, rms_by_model)."""
    if z.size < 25:
        return "unknown", {}
    P = np.stack([e - e.mean(), n - n.mean()], axis=1)
    w, V = np.linalg.eigh(np.cov(P.T))
    u = P @ V[:, 1]   # long axis
    v = P @ V[:, 0]   # short axis
    # footprint extent along the same axes (from the ring, not the eroded cells)
    R = ring - np.array([e.mean(), n.mean()])
    ru, rv = R @ V[:, 1], R @ V[:, 0]
    Lr, Wr = ru.max() - ru.min(), rv.max() - rv.min()
    rect = abs(signed_area(ring)) / max(Lr * Wr, 1e-6)
    L = u.max() - u.min()
    W = v.max() - v.min()
    u0 = 0.5 * (ru.max() + ru.min())
    v0 = 0.5 * (rv.max() + rv.min())
    du, dv = np.abs(u - u0), np.abs(v - v0)

    def trimmed_rms(res):  # ignore the worst 10 % (chimneys, dormers, overhanging branches)
        r2 = np.sort(res * res)
        return float(np.sqrt(np.mean(r2[: max(1, int(0.9 * r2.size))])))

    rms = {"flat": trimmed_rms(z - np.median(z)), "rect": float(rect)}
    # ridge position searched across the footprint (row houses: ridge over the front volume)
    feats = {"hipped": [np.maximum(dv, du - 0.5 * max(L - W, 0.0))]}
    feats["gabled"] = [np.abs(v - (v0 + o)) for o in np.arange(-0.3, 0.31, 0.1) * Wr]       # ridge along the long axis
    feats["gabled_cross"] = [np.abs(u - (u0 + o)) for o in np.arange(-0.3, 0.31, 0.1) * Lr]  # ridge along the short axis
    slopes = {}
    for k, fl in feats.items():
        best = (np.inf, 0.0)
        for f in fl:
            A = np.stack([np.ones_like(f), f], axis=1)
            coef, *_ = np.linalg.lstsq(A, z, rcond=None)
            r_ = trimmed_rms(A @ coef - z)
            if r_ < best[0]:
                best = (r_, -float(coef[1]))
        rms[k], slopes[k] = best
    spread = float(np.percentile(z, 90) - np.percentile(z, 10))
    if rms["flat"] < 0.35 and spread < 1.0:
        return "flat", rms
    if rect < 0.85 or W < 4.0 or L < 6.0:
        return "unknown", rms  # multi-wing or too small for a single-roof fit
    gk = "gabled" if rms["gabled"] <= rms["gabled_cross"] else "gabled_cross"
    g, h = rms[gk], rms["hipped"]
    if min(g, h) > 0.6 * rms["flat"]:
        return "unknown", rms  # neither pitched model explains the roof well
    if h < 0.85 * g and slopes["hipped"] > 0.15:
        return "hipped", rms
    if g < 0.85 * h and slopes[gk] > 0.15:
        return "gabled", rms
    return "unknown", rms


def exg(rgb: np.ndarray) -> np.ndarray:
    """Chromatic excess-green index (2g - r - b), robust to illumination."""
    s = rgb.sum(axis=-1) + 1e-3
    return (2 * rgb[..., 1] - rgb[..., 0] - rgb[..., 2]) / s


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

VEG_EXG_SUMMER = 0.0   # chromatic excess green above this = vegetation in the 2024 summer ortho


def build(course_id: str, render: bool = True) -> int:
    from pyproj import Transformer
    from scipy import ndimage as ndi
    from scipy.spatial import cKDTree
    from PIL import Image

    cfg = COURSES[course_id]
    cache = CACHE_ROOT / course_id
    dbg = DEBUG_ROOT / course_id
    out = OUT_ROOT / course_id
    pipe = PIPELINE_ROOT / course_id
    for p in (cache, dbg):
        p.mkdir(parents=True, exist_ok=True)
    log_lines: list[str] = []

    def log(msg: str):
        print(msg, flush=True)
        log_lines.append(msg)

    course = json.loads((out / "course.json").read_text())
    oE72, oN72 = course["origin"]["lambert72"]
    nh, ch, oh = course["terrain"]["near"], course["canopy"], course["ortho"]
    for k in ("originEast", "originNorth", "cellM", "cols", "rows"):
        if nh[k] != ch[k]:
            raise SystemExit(f"canopy grid differs from terrain.near ({k})")
    cell = float(nh["cellM"])
    rows, cols = int(nh["rows"]), int(nh["cols"])
    gE0, gN1 = float(nh["originEast"]), float(nh["originNorth"])
    gE1, gN0 = gE0 + cols * cell, gN1 - rows * cell
    log(f"[grid] near grid local E {gE0:.0f}..{gE1:.0f}, N {gN0:.0f}..{gN1:.0f} ({cols}x{rows} @ {cell} m); "
        f"origin L72 ({oE72:.0f}, {oN72:.0f})")
    dtm = load_u16(out / nh["file"], nh)
    chm = load_u16(out / ch["file"], ch)
    if np.isnan(dtm).any():
        raise SystemExit("terrain_near has nodata cells")
    h = np.nan_to_num(chm, nan=0.0).astype(np.float32)
    del chm

    # summer ortho at 1 m (mean of the 0.5 m pixels) -> vegetation index
    with Image.open(pipe / oh["file"]) as im:
        ortho = np.asarray(im.convert("RGB"), dtype=np.uint8).copy()
    f = int(round(cell / (oh["widthM"] / oh["pixelsWide"])))
    if (oh["originEast"], oh["originNorth"]) != (gE0, gN1) or ortho.shape[:2] != (rows * f, cols * f):
        raise SystemExit("ortho does not cover the near grid exactly")
    ortho_cell = ortho.reshape(rows, f, cols, f, 3).astype(np.float32).mean(axis=(1, 3))
    veg = exg(ortho_cell)
    bright = ortho_cell.mean(axis=-1)
    del ortho_cell

    # cell-centre coordinates
    ce = (gE0 + (np.arange(cols, dtype=np.float32) + 0.5) * cell)
    cn = (gN1 - (np.arange(rows, dtype=np.float32) + 0.5) * cell)

    def cell_of(e, n):
        c = np.clip(np.floor((np.asarray(e) - gE0) / cell).astype(int), 0, cols - 1)
        r = np.clip(np.floor((gN1 - np.asarray(n)) / cell).astype(int), 0, rows - 1)
        return r, c

    # ---------------- route (from course.json) ----------------
    R = course["route"]
    re_, rn_ = np.array(R["east"]), np.array(R["north"])
    rhw = 0.5 * np.array(R["widthM"])
    rpts = np.stack([re_, rn_], axis=1)
    rdense, rsd = densify(rpts, 0.2)
    rs = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(rpts, axis=0).T))])
    rdense_hw = np.interp(rsd, rs, rhw)
    rtree = cKDTree(rdense)
    route_len = rsd[-1]

    def route_dist(p):
        d, i = rtree.query(p, k=1)
        return d, rdense_hw[i], rsd[i]

    # ---------------- OSM ----------------
    to72 = Transformer.from_crs("EPSG:4326", "EPSG:31370", always_xy=True)
    to84 = Transformer.from_crs("EPSG:31370", "EPSG:4326", always_xy=True)
    cx = np.array([gE0, gE1, gE0, gE1]) + oE72
    cy = np.array([gN0, gN0, gN1, gN1]) + oN72
    lon, lat = to84.transform(cx, cy)
    bbox = cfg["osm_bbox"]
    if not (bbox[0] < min(lat) and bbox[1] < min(lon) and bbox[2] > max(lat) and bbox[3] > max(lon)):
        raise SystemExit(f"osm_bbox {bbox} does not contain the near grid "
                         f"({min(lat):.5f},{min(lon):.5f},{max(lat):.5f},{max(lon):.5f})")
    log(f"[osm] Overpass bbox S,W,N,E = {bbox[0]:.5f},{bbox[1]:.5f},{bbox[2]:.5f},{bbox[3]:.5f}")
    osm = fetch_scenery_osm(cache, bbox, log)
    log(f"[osm] {len(osm['elements'])} elements ({osm['_cache_file']}, base "
        f"{osm.get('osm3s', {}).get('timestamp_osm_base', '?')})")

    def to_local(geom):
        lo = np.array([p["lon"] for p in geom])
        la = np.array([p["lat"] for p in geom])
        X, Y = to72.transform(lo, la)
        return np.stack([np.asarray(X) - oE72, np.asarray(Y) - oN72], axis=1)

    rect = (gE0, gN0, gE1, gN1)
    route_way_ids = set(cfg["route_ways"])
    buildings_raw, landuse, roads_raw, fences, water = [], [], [], [], []
    skipped = {"landuse_kind": {}, "tunnel_streams": 0}
    for t, el, geoms, is_area in osm_features(osm, to_local):
        if "building" in t and is_area and t.get("building") not in ("no",):
            for g in geoms:
                buildings_raw.append((t, el["id"], g))
            continue
        lk = None
        for key in ("landuse", "natural", "leisure"):
            if key in t:
                lk = LANDUSE_MAP.get((key, t[key]))
                if lk is None and (key, t[key]) == ("landuse", "cemetery"):
                    lk = "grass"
                if lk:
                    break
        if lk and is_area:
            for g in geoms:
                c = clip_polygon_rect(g[:-1] if np.allclose(g[0], g[-1]) else g, *rect)
                ring = clean_ring(c) if len(c) >= 3 else None
                if ring is not None:
                    landuse.append({"kind": lk, "ring": ring, "osm": el["id"]})
            continue
        if is_area and (t.get("natural") == "water" or "water" in t and t.get("natural") in (None, "water")):
            for g in geoms:
                c = clip_polygon_rect(g[:-1] if np.allclose(g[0], g[-1]) else g, *rect)
                ring = clean_ring(c) if len(c) >= 3 else None
                if ring is not None:
                    water.append({"kind": "pond", "points": ring, "closed": True, "osm": el["id"]})
            continue
        if any(k in t for k in ("landuse", "natural", "leisure")) and not ("highway" in t or "barrier" in t
                                                                        or "waterway" in t):
            kk = next(f"{k}={t[k]}" for k in ("landuse", "natural", "leisure") if k in t)
            skipped["landuse_kind"][kk] = skipped["landuse_kind"].get(kk, 0) + 1
        if "highway" in t and el["type"] == "way" and t["highway"] not in SKIP_HIGHWAYS:
            roads_raw.append((t, el["id"], geoms[0]))
        elif "barrier" in t and t["barrier"] in FENCE_MAP and el["type"] == "way":
            for piece in clip_polyline_rect(geoms[0], *rect):
                p = clean_line(piece)
                if p is not None:
                    fences.append({"kind": FENCE_MAP[t["barrier"]], "points": p, "osm": el["id"]})
        elif "waterway" in t and t["waterway"] in STREAMS and el["type"] == "way":
            if t.get("tunnel") in ("culvert", "yes", "building_passage") or t.get("covered") == "yes":
                skipped["tunnel_streams"] += 1
                continue
            for piece in clip_polyline_rect(geoms[0], *rect):
                p = clean_line(piece)
                if p is not None:
                    water.append({"kind": "stream", "points": p, "closed": False, "osm": el["id"],
                                  "name": t.get("name")})
    log(f"[osm] raw: {len(buildings_raw)} building rings, {len(landuse)} landuse rings (clipped), "
        f"{len(roads_raw)} highway ways, {len(fences)} barrier lines, {len(water)} water features; "
        f"skipped area kinds {skipped['landuse_kind']}, {skipped['tunnel_streams']} culverted stream ways")

    # ---------------- side roads ----------------
    roads = []
    for t, wid, g in roads_raw:
        dense, sd = densify(g, 0.5)
        d, hw, s_on = route_dist(dense)
        if wid in route_way_ids:
            # the part of a route way that the ride covers; keep what lies beyond the trimmed route
            # (the ride's centreline was moved up to 3.5 m into the sunken-lane floor by build_course.py)
            covered = (d < 3.6) & (s_on > 0.3) & (s_on < route_len - 0.3)
        else:
            covered = d < np.maximum(hw - 0.25, 0.5)
        if covered.all():
            continue
        seg = np.hypot(*np.diff(g, axis=0).T)
        sv = np.concatenate([[0.0], np.cumsum(seg)])
        # runs of uncovered dense samples
        idx = np.flatnonzero(~covered)
        breaks = np.flatnonzero(np.diff(idx) > 1)
        starts = np.concatenate([[idx[0]], idx[breaks + 1]])
        ends = np.concatenate([idx[breaks], [idx[-1]]])
        for a, b in zip(starts, ends):
            sa, sb = sd[a], sd[b]
            if sb - sa < 2.0:
                continue
            inner = [g[k] for k in range(len(g)) if sa + 1e-6 < sv[k] < sb - 1e-6]
            pts = np.array([dense[a]] + inner + [dense[b]])
            for piece in clip_polyline_rect(pts, *rect):
                p = clean_line(piece)
                if p is None:
                    continue
                wv = _num(t.get("width")) or _num(t.get("est_width"))
                roads.append({
                    "name": t.get("name"), "widthM": round(wv if wv else HIGHWAY_WIDTH.get(t["highway"], 3.0), 1),
                    "surface": road_surface(t), "points": p, "osm": wid, "highway": t["highway"],
                })
    log(f"[roads] {len(roads)} side-road pieces from {len(roads_raw)} highway ways "
        f"(route ways trimmed to the parts beyond the ride)")

    # ---------------- buildings ----------------
    # Footprints: GRB "gebouw aan de grond" (Digitaal Vlaanderen, native Lambert 72) is the
    # authoritative and complete set; OSM buildings in Flanders are imports of it
    # (source:geometry:ref=Gbg/<OIDN>) and are used for their tags. OSM-only footprints that
    # do not overlap a GRB building are kept as well.
    grb = fetch_grb_buildings(cache, int(oE72 + gE0), int(oE72 + gE1), int(oN72 + gN0), int(oN72 + gN1), log)
    osm_by_oidn, osm_other = {}, []
    for t, wid, g in buildings_raw:
        ref = str(t.get("source:geometry:ref", ""))
        if ref.startswith("Gbg/") and ref[4:].isdigit():
            osm_by_oidn.setdefault(int(ref[4:]), (t, wid, g))
        else:
            osm_other.append((t, wid, g))
    cands = []
    offs = []
    for props, ring72 in grb:
        ring = ring72 - np.array([oE72, oN72])
        oidn = int(props.get("OIDN", -1))
        t, wid = {}, None
        if oidn in osm_by_oidn:
            t, wid, g = osm_by_oidn.pop(oidn)
            a_osm, a_grb = abs(signed_area(g)), abs(signed_area(ring))
            if a_grb > 20 and abs(a_osm - a_grb) < 0.03 * a_grb:  # same geometry version
                offs.append(_centroid(g) - _centroid(ring))
        cands.append(("grb", t, oidn, wid, ring, props))
    stale = list(osm_by_oidn.values())  # OSM copies of GRB objects no longer current
    # OSM footprints without a (current) GRB reference: if one covers a GRB footprint, it is the same
    # building drawn by hand or from an older GRB version -> give its tags to the GRB footprint.
    glab = np.zeros((rows, cols), np.int32)
    for k, c_ in enumerate(cands):
        rg = clean_ring(c_[4], nd=2)
        if rg is not None:
            rr, cc = cells_in_polygon(rg, gE0, gN1, cell, rows, cols)
            glab[rr, cc] = k + 1
    gcells = np.bincount(glab.ravel(), minlength=len(cands) + 1)
    n_tagged = n_part = 0
    for t, wid, g in osm_other + stale:
        rg = clean_ring(g, nd=2)
        if rg is None:
            continue
        rr, cc = cells_in_polygon(rg, gE0, gN1, cell, rows, cols)
        hit = glab[rr, cc]
        if rr.size and (hit > 0).mean() > 0.3:
            k = int(np.bincount(hit[hit > 0]).argmax()) - 1
            # Only one covering at least 40 % of that GRB footprint is the same building: a small
            # one inside a big GRB block is a part of it (Geraardsbergen's Oud-Hospitaal chapel
            # in the 7500 m2 hospital block would otherwise make the whole block a church).
            if rr.size < 0.4 * gcells[k + 1]:
                n_part += 1
            elif not cands[k][1]:
                cands[k] = (cands[k][0], t, cands[k][2], wid, cands[k][4], cands[k][5])
                n_tagged += 1
            continue  # duplicate of a GRB footprint
        cands.append(("osm", t, None, wid, g, {}))
    del glab
    log(f"[buildings] {n_tagged} GRB footprints took tags from an overlapping OSM building without a Gbg ref; "
        f"{n_part} smaller OSM buildings inside a GRB block left it untagged")
    if offs:
        offs = np.array(offs)
        log(f"[buildings] OSM (projected with pyproj) minus GRB (native L72) centroid offset over {len(offs)} "
            f"matched footprints: median dE {np.median(offs[:, 0]):+.2f} m, dN {np.median(offs[:, 1]):+.2f} m, "
            f"median |d| {np.median(np.hypot(offs[:, 0], offs[:, 1])):.2f} m")
    dsm = dtm + h
    bmask = np.zeros((rows, cols), bool)
    buildings = []
    n_out = n_straddle = n_dup = 0
    order = sorted(range(len(cands)), key=lambda k: cands[k][0] != "grb")  # GRB first
    for k in order:
        src0, t, oidn, wid, g, props = cands[k]
        ring = clean_ring(g, nd=2)
        if ring is None:
            continue
        inside_v = ((ring[:, 0] > gE0 + 1) & (ring[:, 0] < gE1 - 1) & (ring[:, 1] > gN0 + 1) & (ring[:, 1] < gN1 - 1))
        if not inside_v.any():
            n_out += 1
            continue
        if not inside_v.all():
            n_straddle += 1
            continue
        rr, cc = cells_in_polygon(ring, gE0, gN1, cell, rows, cols)
        if rr.size == 0:
            r1, c1 = cell_of(*ring.mean(axis=0))
            rr, cc = np.array([r1]), np.array([c1])
        if src0 == "osm" and bmask[rr, cc].mean() > 0.3:
            n_dup += 1
            continue
        bmask[rr, cc] = True
        ri, ci = cells_in_polygon(ring, gE0, gN1, cell, rows, cols, shrink=0.7)
        if ri.size < 4:
            ri, ci = rr, cc
        area = float(signed_area(ring))
        ground = float(dtm[rr, cc].min())
        p90c = float(np.percentile(h[ri, ci], 90))
        p50c = float(np.percentile(h[ri, ci], 50))
        measured = float(np.percentile(dsm[ri, ci], 90)) - ground
        green = float(np.mean(veg[ri, ci] > 0.05))
        if t.get("building"):
            kind = building_kind(t)
        elif props.get("LBLTYPE") == "hoofdgebouw":
            kind = "house" if area <= 300 else "other"
        else:
            kind = "other"
        cap = HEIGHT_CAP[kind] if kind != "other" else (7.0 if area < 60 else 10.0 if area < 300 else 15.0)
        # Tiny footprints under a tree pick up its crown height from the LiDAR whatever the ortho
        # shows, and would stand as 8-27 m towers. A real cottage this small (the Paterberg's
        # summit cottage, 22 m2) measures about 5 m.
        small_cap = 6.5 if area < 25 else 8.0 if area < 60 else None
        if p90c < 2.0:
            why = "not in the 2015 LiDAR"
        elif small_cap and kind in ("house", "other") and not t.get("height") and measured > small_cap:
            why = f"LiDAR {measured:.1f} m > {small_cap} m plausible for {area:.0f} m2"
            if area < 25:
                kind = "other"   # a 'hoofdgebouw' this small under a crown is a shed, not a house
        elif measured > cap and green >= 0.25:   # a visible roof (little green) keeps its LiDAR height
            why = f"LiDAR {measured:.1f} m > {cap:.0f} m plausible for {kind}"
        elif green >= 0.5 and p90c - p50c > 2.5:
            why = "roof under tree canopy"
        else:
            why = ""
        buildings.append({
            "ring": ring, "kind": kind, "groundElevM": round(ground, 2), "measured": measured, "why": why,
            "src": src0, "oidn": oidn, "osm": wid, "p90c": p90c, "p50c": p50c, "green": green, "area": area,
            "btag": t.get("building") or props.get("LBLTYPE"), "roof_tag": ROOF_TAG_MAP.get(t.get("roof:shape", "")),
            "tag_h": _num(t.get("height")), "levels": _num(t.get("building:levels")),
            "cells": (ri, ci),
        })
    # fallback heights: OSM height / levels, else the median LiDAR height of reliable buildings of that kind
    by_kind = {}
    for b in buildings:
        if not b["why"]:
            by_kind.setdefault(b["kind"], []).append(b["measured"])
    kind_median = {k: float(np.median(v)) for k, v in by_kind.items() if len(v) >= 5}
    n_fallback = 0
    reasons = {}
    for b in buildings:
        if not b["why"]:
            hm, b["hsrc"] = b["measured"], "lidar"
        else:
            n_fallback += 1
            key = b["why"].split(" ")[0] if not b["why"].startswith("LiDAR") else "LiDAR too high"
            reasons[key] = reasons.get(key, 0) + 1
            if b["tag_h"]:
                hm, b["hsrc"] = b["tag_h"], "osm height"
            elif b["levels"]:
                hm, b["hsrc"] = b["levels"] * 3 + 2, "osm levels"
            elif b["kind"] in kind_median:
                hm, b["hsrc"] = kind_median[b["kind"]], f"median LiDAR {b['kind']}"
            else:
                hm, b["hsrc"] = DEFAULT_HEIGHT[b["kind"]], "default"
        b["heightM"] = round(max(hm, 2.0), 1)
        ri, ci = b.pop("cells")
        if b["roof_tag"]:
            b["roofShape"], b["rms"] = b["roof_tag"], {}
        elif b["hsrc"] == "lidar":
            b["roofShape"], b["rms"] = roof_from_dsm(h[ri, ci].astype(np.float64), ce[ci].astype(np.float64),
                                                     cn[ri].astype(np.float64), b["ring"])
        else:
            b["roofShape"], b["rms"] = "unknown", {}
    kinds = {}
    for b in buildings:
        kinds[b["kind"]] = kinds.get(b["kind"], 0) + 1
    log(f"[buildings] {len(buildings)} kept ({sum(b['src'] == 'grb' for b in buildings)} GRB, "
        f"{sum(b['src'] == 'osm' for b in buildings)} OSM-only); {n_out} outside the grid, {n_straddle} straddling "
        f"its edge (dropped), {n_dup} OSM duplicates of GRB; kinds {kinds}")
    log(f"[buildings] {n_fallback} heights not from LiDAR {reasons}; kind medians "
        + ", ".join(f"{k} {v:.1f} m" for k, v in sorted(kind_median.items())))
    roof_counts = {}
    for b in buildings:
        roof_counts[b["roofShape"]] = roof_counts.get(b["roofShape"], 0) + 1
    log(f"[buildings] roof shapes {roof_counts}")
    (dbg / "scenery_buildings.json").write_text(json.dumps([
        {k: (round(v, 2) if isinstance(v, float) else v) for k, v in b_.items() if k not in ("ring",)}
        | {"rms": {k: round(v, 2) for k, v in b_["rms"].items()},
           "centroid": [round(float(x), 1) for x in _centroid(b_["ring"])]}
        for b_ in buildings], indent=1))
    del dsm

    # ---------------- exclusion masks ----------------
    bmask_d = ndi.binary_dilation(bmask, structure=disk(BUILDING_DILATE_M / cell))
    E, N = np.meshgrid(ce, cn)
    cpts = np.stack([E.ravel(), N.ravel()], axis=1)
    del E, N
    d, i = rtree.query(cpts, k=1, distance_upper_bound=12.0)
    ok = np.isfinite(d)
    route_clear = np.full(cpts.shape[0], np.inf, np.float32)   # distance outside the carriageway edge
    route_clear[ok] = d[ok] - rdense_hw[i[ok]]
    route_clear = route_clear.reshape(rows, cols)
    on_route = route_clear < ROUTE_CLEAR_M
    side_pts, side_hw = [], []
    for rd in roads:
        dp, _ = densify(rd["points"], 0.25)
        side_pts.append(dp)
        side_hw.append(np.full(len(dp), 0.5 * rd["widthM"]))
    on_side = np.zeros((rows, cols), bool)
    if side_pts:
        sp = np.vstack(side_pts)
        shw = np.concatenate(side_hw)
        stree = cKDTree(sp)
        d2, i2 = stree.query(cpts, k=1, distance_upper_bound=float(shw.max()) + 1.0)
        ok2 = np.isfinite(d2)
        tmp = np.zeros(cpts.shape[0], bool)
        tmp[ok2] = d2[ok2] < shw[i2[ok2]]
        on_side = tmp.reshape(rows, cols)
    del cpts, d, i
    road_mask = on_route | on_side
    log(f"[masks] buildings {bmask.sum()} cells (+{BUILDING_DILATE_M} m: {bmask_d.sum()}), route carriageway "
        f"+{ROUTE_CLEAR_M} m {on_route.sum()} cells, side roads {on_side.sum()} cells")
    for lab, m in (("buildings", bmask), ("open ground (chm<0.3)", h < 0.3), ("chm>=8", h >= 8)):
        if m.any():
            log(f"    summer ExG on {lab}: p10/p50/p90 = "
                + "/".join(f"{v:.3f}" for v in np.percentile(veg[m], [10, 50, 90])))

    # ---------------- trees ----------------
    wdate = fetch_winter_date(cache, cfg["winter_ortho"], oE72, oN72, log)
    log(f"[trees] newest 'winter' mosaic flown {wdate or '?'} at the course: in leaf in late April, so it cannot "
        f"separate evergreens; no other conifer signal -> all trees 'deciduous'")
    # The LiDAR was flown leaf-off (25/1/2015): deciduous crowns are full of pits where pulses went
    # through the bare branches. A grey closing (r = 2 m) gives a pit-free canopy model (it fills
    # holes narrower than ~3 m but keeps crown outlines), then a light Gaussian.
    hf = ndi.grey_closing(h, footprint=disk(PIT_FILL_R / cell), mode="nearest").astype(np.float32)
    hs = ndi.gaussian_filter(hf, CHM_SMOOTH_SIGMA / cell).astype(np.float32)
    # Variable window: Popescu & Wynne (2004) crown width for deciduous trees, CW = 3.09632 + 0.00895 h^2
    cw = 3.09632 + 0.00895 * hs * hs
    rad = np.clip(0.5 * cw, 1.5, 6.0)
    radii = [1.5, 2.0, 2.5, 3.0, 3.5, 4.0, 5.0, 6.0]
    cand = hs >= TREE_MIN_H
    peak = np.zeros((rows, cols), bool)
    prev = 0.0
    for rb in radii:
        sel = cand & (rad > prev) & (rad <= rb + 1e-6)
        prev = rb
        if not sel.any():
            continue
        mf = ndi.maximum_filter(hs, footprint=disk(rb / cell), mode="nearest")
        peak |= sel & (hs >= mf)
    del cw, rad, cand
    lab, npk = ndi.label(peak, structure=np.ones((3, 3)))
    pos = ndi.maximum_position(hs, lab, index=np.arange(1, npk + 1))
    pr = np.array([p[0] for p in pos], int)
    pc = np.array([p[1] for p in pos], int)
    del lab, peak
    log(f"[trees] {npk} raw tree tops (smoothed CHM >= {TREE_MIN_H} m, variable window)")
    # crowns by marker-controlled watershed on the inverted smoothed CHM
    markers = np.zeros((rows, cols), np.int32)
    markers[pr, pc] = np.arange(1, npk + 1, dtype=np.int32)
    markers[hs < CROWN_MIN_H] = -1
    inv = np.clip((float(hs.max()) - hs) * 20.0, 0, 65535).astype(np.uint16)
    seg = ndi.watershed_ift(inv, markers)
    del inv, markers
    top_h = ndi.maximum_filter(h, size=3, mode="nearest")[pr, pc].astype(np.float64)
    top_hs = hs[pr, pc].astype(np.float64)
    thr = np.maximum(CROWN_MIN_H, CROWN_REL_H * top_hs)
    seg_valid = seg > 0
    lbl = np.where(seg_valid, seg, 0)
    in_crown = seg_valid & (hs >= thr[np.clip(lbl - 1, 0, npk - 1)])
    area = np.bincount(lbl[in_crown], minlength=npk + 1)[1:].astype(np.float64) * cell * cell
    green_cnt = np.bincount(lbl[in_crown & (veg > VEG_EXG_SUMMER)], minlength=npk + 1)[1:]
    green_frac = green_cnt / np.maximum(area / (cell * cell), 1)
    # compactness: a crown, not a wire/pole: >= 5 of the 3x3 pit-free cells reach half the top height
    hp = np.pad(hf, 1, mode="edge")
    cnt3 = np.zeros(npk, int)
    for dr in (-1, 0, 1):
        for dc in (-1, 0, 1):
            cnt3 += hp[pr + 1 + dr, pc + 1 + dc] >= 0.5 * top_hs
    crown_r = np.sqrt(area / math.pi)
    keep = np.ones(npk, bool)
    why = {}

    def drop(mask, reason):
        nonlocal keep
        m = keep & mask
        why[reason] = int(m.sum())
        keep &= ~mask

    drop(cnt3 < 5, "not crown-like (wire/pole/edge)")
    drop(area < 3.0, "crown < 3 m2")
    nonveg_open = int((keep & (green_frac < 0.25) & ~bmask_d[pr, pc]).sum())
    drop(green_frac < 0.25, "crown not vegetation in the 2024 ortho")
    log(f"[trees] {nonveg_open} of the non-vegetation tops are away from buildings "
        f"(trees felled since 2015, or unmapped structures)")
    # Tops over a building or a road: a roof ridge, or a crown reaching over the roof / carriageway.
    # If the top's own crown has enough green cells clear of buildings and roads, the trunk goes to
    # the nearest of them (the crown keeps the area clear of buildings); otherwise it is dropped.
    tr_e = ce[pc].astype(np.float64)
    tr_n = cn[pr].astype(np.float64)
    moved = {"road": 0, "building": 0}
    blocked = road_mask | bmask_d
    on_bl = keep & blocked[pr, pc]
    if on_bl.any():
        free = in_crown & ~blocked & (veg > VEG_EXG_SUMMER)
        objs = ndi.find_objects(np.where(free, lbl, 0), max_label=npk)
        for k in np.flatnonzero(on_bl):
            cause = "building" if bmask_d[pr[k], pc[k]] else "road"
            sl = objs[k]
            if sl is None:
                keep[k] = False
                why[f"on {cause}, crown not clear of it"] = why.get(f"on {cause}, crown not clear of it", 0) + 1
                continue
            sub = (lbl[sl] == k + 1) & free[sl]
            rr_, cc_ = np.nonzero(sub)
            rr_ += sl[0].start
            cc_ += sl[1].start
            free_area = rr_.size * cell * cell
            if cause == "building" and (free_area < 8.0 or free_area < 0.3 * area[k]):
                keep[k] = False   # essentially a roof (or a tree mostly over the roof)
                why["on building, crown not clear of it"] = why.get("on building, crown not clear of it", 0) + 1
                continue
            dd = np.hypot(rr_ - pr[k], cc_ - pc[k]) * cell
            # prefer a spot >= TRUNK_SETBACK_M from the ride's carriageway (bank, not the gutter)
            pref = route_clear[rr_, cc_] >= TRUNK_SETBACK_M
            reach = max(crown_r[k], 2.0)
            if (pref & (dd <= reach)).any():
                dd = np.where(pref, dd, np.inf)
            j = int(np.argmin(dd))
            if dd[j] > reach:
                keep[k] = False
                why[f"on {cause}, crown not clear of it"] = why.get(f"on {cause}, crown not clear of it", 0) + 1
                continue
            tr_e[k], tr_n[k] = float(ce[cc_[j]]), float(cn[rr_[j]])
            if cause == "building":
                crown_r[k] = math.sqrt(free_area / math.pi)
            moved[cause] += 1
    log(f"[trees] dropped: {why}; trunks moved to the nearest clear cell of their own crown: {moved} "
        f"(>= {TRUNK_SETBACK_M} m from the ride where possible)")
    trees = []
    kidx = np.flatnonzero(keep)
    for k in kidx:
        r_ = float(np.clip(crown_r[k], 0.8, 10.0))
        trees.append({"e": round(float(tr_e[k]), 1), "n": round(float(tr_n[k]), 1),
                      "heightM": round(float(max(top_h[k], top_hs[k])), 1),
                      "crownRadiusM": round(r_, 1), "kind": "deciduous"})
    # Hand-placed rows the LiDAR misses (young or freshly pollarded trees), from the photo survey:
    # (from s, to s, side -1 left / +1 right, metres beyond the carriageway edge, spacing, height, crown).
    route_hw_at = lambda sv: float(np.interp(sv, rsd, rdense_hw))
    for s0, s1, side, beyond, step, hgt, rad in cfg.get("tree_rows", []):
        n_added = 0
        for sv in np.arange(s0, s1 + 1e-9, step):
            i = int(np.clip(np.searchsorted(rsd, sv), 1, len(rsd) - 2))
            d_ = rdense[i + 1] - rdense[i - 1]
            d_ = d_ / max(np.hypot(*d_), 1e-9)
            right = np.array([d_[1], -d_[0]])
            pt = rdense[i] + right * side * (route_hw_at(sv) + beyond)
            trees.append({"e": round(float(pt[0]), 1), "n": round(float(pt[1]), 1), "heightM": float(hgt),
                          "crownRadiusM": float(rad), "kind": "deciduous"})
            n_added += 1
        log(f"[trees] tree row s {s0:.0f}-{s1:.0f} side {side:+d}: {n_added} trees added (config tree_rows)")
    th = np.array([t["heightM"] for t in trees])
    tcr = np.array([t["crownRadiusM"] for t in trees])
    log(f"[trees] {len(trees)} trees; height p10/p50/p90 {np.percentile(th, 10):.1f}/{np.percentile(th, 50):.1f}/"
        f"{np.percentile(th, 90):.1f} m, crown radius p10/p50/p90 {np.percentile(tcr, 10):.1f}/"
        f"{np.percentile(tcr, 50):.1f}/{np.percentile(tcr, 90):.1f} m")

    # ---------------- shrubs ----------------
    # On the pit-free model, so gaps inside leaf-off tree crowns do not become shrubs.
    crown_cells = seg_valid & (hf >= CROWN_MIN_H)
    shrub_ok = ((hf >= SHRUB_MIN_H) & (hf < SHRUB_MAX_H) & (veg > VEG_EXG_SUMMER) & ~bmask_d & ~road_mask
                & ~crown_cells)
    # Tiny blobs (1-3 cells) of low "vegetation" on green ground are mostly fence posts, grazing
    # animals or bales in the January LiDAR; keep them only where the 2024 ortho shows a darker
    # crown than the surrounding ground (young orchard trees, solitary bushes).
    slab, nsl = ndi.label(shrub_ok, structure=np.ones((3, 3)))
    ssize = np.bincount(slab.ravel(), minlength=nsl + 1)
    small = (ssize[slab] < SHRUB_MIN_CELLS) & shrub_ok
    darker = bright < 0.85 * ndi.uniform_filter(bright, size=9, mode="nearest")
    n_small = int(ndi.label(small, structure=np.ones((3, 3)))[1])
    shrub_ok &= ~small | darker
    n_small_kept = int(ndi.label(small & darker, structure=np.ones((3, 3)))[1])
    del slab, ssize, small, darker
    log(f"[shrubs] {n_small} blobs smaller than {SHRUB_MIN_CELLS} cells; {n_small_kept} kept (darker crown in the "
        f"2024 ortho), the rest dropped as posts/animals/bales")
    se = np.arange(gE0 + 0.5 * SHRUB_SPACING, gE1, SHRUB_SPACING)
    sn = np.arange(gN1 - 0.5 * SHRUB_SPACING, gN0, -SHRUB_SPACING)
    SE, SN = np.meshgrid(se, sn)
    sr, sc = cell_of(SE.ravel(), SN.ravel())
    sel = shrub_ok[sr, sc]
    sr, sc = sr[sel], sc[sel]
    spt_e, spt_n = SE.ravel()[sel], SN.ravel()[sel]
    del SE, SN
    # Clearances are measured from the position as written (rounded to 0.1 m) to the carriageway
    # edges of the ride and of every side road, on polylines densified to 0.05 m (<= 0.025 m error).
    spt_e = np.round(spt_e, 1); spt_n = np.round(spt_n, 1)
    spts = np.stack([spt_e, spt_n], axis=1)
    rfine, rfine_s = densify(rpts, 0.05)
    rfine_hw = np.interp(rfine_s, rs, rhw)
    dq, iq = cKDTree(rfine).query(spts, k=1)
    sclear = dq - rfine_hw[iq]           # clearance from the ride's carriageway edge
    side_clear = np.full(len(spts), np.inf)
    for rd in roads:  # per road, so a wide road is not hidden behind a nearer narrow one
        dp, _ = densify(rd["points"], 0.05)
        hw_ = 0.5 * rd["widthM"]
        dq2, _ = cKDTree(dp).query(spts, k=1, distance_upper_bound=hw_ + 3.0)
        side_clear = np.minimum(side_clear, dq2 - hw_)   # inf where farther than the bound
        del dp, dq2
    shrubs = []
    n_route_drop = n_side_drop = n_side_clip = 0
    for k in range(len(sr)):
        hh = float(hf[sr[k], sc[k]])
        rad_ = float(np.clip(0.45 + 0.2 * hh, 0.6, 1.0))
        clear = float(sclear[k]); sclr = float(side_clear[k])
        if clear < ROUTE_CLEAR_M + 0.03:
            n_route_drop += 1
            continue
        if sclr < SIDE_ROAD_CLEAR_M + 0.03:
            n_side_drop += 1
            continue
        lim_ = min(clear, sclr) - 0.03          # never reach over any carriageway edge
        if lim_ < rad_:
            n_side_clip += sclr < clear
            rad_ = lim_
        rad_ = math.floor(rad_ * 10.0 + 1e-9) / 10.0   # round down so the written disc stays clear
        shrubs.append({"e": float(spt_e[k]), "n": float(spt_n[k]),
                       "heightM": round(hh, 1), "radiusM": round(rad_, 1)})
    log(f"[shrubs] {len(shrubs)} shrubs on a {SHRUB_SPACING} m lattice from {int(shrub_ok.sum())} cells of "
        f"{SHRUB_MIN_H}-{SHRUB_MAX_H} m green vegetation ({n_route_drop} lattice points too close to the ride, "
        f"{n_side_drop} centred within {SIDE_ROAD_CLEAR_M} m of a side-road carriageway dropped, {n_side_clip} radii "
        f"clipped to a side-road edge)")

    # ---------------- write ----------------
    def pts(a):
        return [[round(float(x), 1), round(float(y), 1)] for x, y in a]

    scen = {
        "schemaVersion": 1,
        "buildings": [{"ring": pts(b["ring"]), "heightM": b["heightM"], "roofShape": b["roofShape"],
                       "kind": b["kind"], "groundElevM": b["groundElevM"]} for b in buildings],
        "trees": trees,
        "shrubs": shrubs,
        "landuse": [{"kind": l["kind"], "ring": pts(l["ring"])} for l in landuse],
        "roads": [{**({"name": r["name"]} if r["name"] else {}), "widthM": r["widthM"], "surface": r["surface"],
                   "points": pts(r["points"])} for r in roads],
        "fences": [{"kind": f_["kind"], "points": pts(f_["points"])} for f_ in fences],
        "water": [{"kind": w["kind"], "points": pts(w["points"]), "closed": w["closed"]} for w in water],
    }
    # re-clean rings after rounding to 0.1 m (rounding can create duplicates)
    for key, fld in (("buildings", "ring"), ("landuse", "ring")):
        kept = []
        for item in scen[key]:
            rg = clean_ring(np.array(item[fld]))
            if rg is not None:
                item[fld] = pts(rg)
                kept.append(item)
        scen[key] = kept
    for item in scen["water"]:
        if item["closed"]:
            rg = clean_ring(np.array(item["points"]))
            item["points"] = pts(rg) if rg is not None else item["points"]
    body = json.dumps(scen, separators=(",", ":"), ensure_ascii=False)
    (out / "scenery.json").write_text(body)
    log(f"[write] scenery.json {len(body) / 1e6:.2f} MB: " + ", ".join(f"{k} {len(v)}" for k, v in scen.items()
                                                                      if isinstance(v, list)))

    ctx = dict(course=course, gE0=gE0, gE1=gE1, gN0=gN0, gN1=gN1, cell=cell, ortho=ortho, h=hf, hs=hs,
               route=rpts, rhw=rhw, buildings=buildings, landuse=landuse, roads=roads, fences=fences,
               water=water, trees=trees, shrubs=shrubs, oh=oh)
    ok = self_check(out, ctx, log)
    if render:
        render_debug(dbg, ctx, log)
    log(f"[done] peak RSS {peak_rss_mb():.0f} MB")
    (dbg / "scenery_log.txt").write_text("\n".join(log_lines) + "\n")
    return 0 if ok else 1


# ---------------------------------------------------------------------------
# Self-check: decode as SceneryFile would (Python mirror of CourseData.swift)
# ---------------------------------------------------------------------------

SCENERY_SCHEMA = {  # field -> (type, optional)
    "SceneryFile": {"schemaVersion": ("int", False), "buildings": ("[Building]", True), "trees": ("[Tree]", True),
                    "shrubs": ("[Shrub]", True), "landuse": ("[Landuse]", True), "roads": ("[Road]", True),
                    "fences": ("[Fence]", True), "water": ("[Water]", True)},
    "Building": {"ring": ("[[num]]", False), "heightM": ("num", False), "roofShape": ("str", True),
                 "kind": ("str", True), "groundElevM": ("num", True)},
    "Tree": {"e": ("num", False), "n": ("num", False), "heightM": ("num", False), "crownRadiusM": ("num", False),
             "kind": ("str", True)},
    "Shrub": {"e": ("num", False), "n": ("num", False), "heightM": ("num", False), "radiusM": ("num", False)},
    "Landuse": {"kind": ("str", False), "ring": ("[[num]]", False)},
    "Road": {"name": ("str", True), "widthM": ("num", True), "surface": ("str", True), "points": ("[[num]]", False)},
    "Fence": {"kind": ("str", False), "points": ("[[num]]", False)},
    "Water": {"kind": ("str", False), "points": ("[[num]]", False), "closed": ("bool", True)},
}
ENUMS = {
    ("Building", "roofShape"): {"gabled", "hipped", "flat", "unknown"},
    ("Building", "kind"): {"house", "farm", "barn", "church", "chapel", "other"},
    ("Tree", "kind"): {"deciduous", "conifer"},
    ("Landuse", "kind"): {"farmland", "meadow", "forest", "residential", "orchard", "scrub", "grass"},
    ("Road", "surface"): {"asphalt", "cobbles", "gravel", "unpaved"},
    ("Fence", "kind"): {"fence", "wall", "hedge"},
    ("Water", "kind"): {"stream", "pond"},
}


def _check(v, t, path, errs, limit=40):
    if len(errs) > limit:
        return
    if t.startswith("["):
        if not isinstance(v, list):
            errs.append(f"{path}: expected array")
            return
        for k, x in enumerate(v):
            _check(x, t[1:-1], f"{path}[{k}]", errs)
        return
    if t == "str":
        if not isinstance(v, str):
            errs.append(f"{path}: expected string")
    elif t == "bool":
        if not isinstance(v, bool):
            errs.append(f"{path}: expected Bool")
    elif t == "int":
        if not (isinstance(v, int) and not isinstance(v, bool)):
            errs.append(f"{path}: expected Int")
    elif t == "num":
        if not (isinstance(v, (int, float)) and not isinstance(v, bool)) or not math.isfinite(v):
            errs.append(f"{path}: expected finite number")
    elif t in SCENERY_SCHEMA:
        if not isinstance(v, dict):
            errs.append(f"{path}: expected {t}")
            return
        for f_, (ft, opt) in SCENERY_SCHEMA[t].items():
            if f_ not in v or v[f_] is None:
                if not opt:
                    errs.append(f"{path}.{f_}: missing non-optional field")
                continue
            _check(v[f_], ft, f"{path}.{f_}", errs)
            if (t, f_) in ENUMS and v[f_] not in ENUMS[(t, f_)]:
                errs.append(f"{path}.{f_}: {v[f_]!r} not in {sorted(ENUMS[(t, f_)])}")
    else:
        errs.append(f"{path}: unknown type {t}")


def self_check(out: Path, ctx: dict, log) -> bool:
    from scipy.spatial import cKDTree
    errs: list[str] = []
    warns: list[str] = []
    raw = (out / "scenery.json").read_bytes()
    d = json.loads(raw)
    _check(d, "SceneryFile", "scenery", errs)
    if d.get("schemaVersion") != 1:
        errs.append("schemaVersion != 1")
    if len(raw) > 4_000_000:
        errs.append(f"scenery.json is {len(raw) / 1e6:.2f} MB (> 4 MB)")
    gE0, gE1, gN0, gN1 = ctx["gE0"], ctx["gE1"], ctx["gN0"], ctx["gN1"]

    def inside(p):
        return gE0 - 1e-6 <= p[0] <= gE1 + 1e-6 and gN0 - 1e-6 <= p[1] <= gN1 + 1e-6

    for key, fld in (("buildings", "ring"), ("landuse", "ring")):
        for k, item in enumerate(d.get(key, [])):
            rg = np.array(item[fld], float)
            if len(rg) < 3:
                errs.append(f"{key}[{k}]: ring has {len(rg)} points")
                continue
            if np.allclose(rg[0], rg[-1]):
                errs.append(f"{key}[{k}]: ring repeats its first point")
            if signed_area(rg) <= 0:
                errs.append(f"{key}[{k}]: ring not counter-clockwise")
            if not all(inside(p) for p in rg):
                errs.append(f"{key}[{k}]: ring leaves the near grid")
    for k, item in enumerate(d.get("water", [])):
        rg = np.array(item["points"], float)
        if item.get("closed"):
            if np.allclose(rg[0], rg[-1]) or signed_area(rg) <= 0:
                errs.append(f"water[{k}]: closed ring must be CCW without a repeated point")
    for key in ("roads", "fences", "water"):
        for k, item in enumerate(d.get(key, [])):
            if len(item["points"]) < 2:
                errs.append(f"{key}[{k}]: fewer than 2 points")
            if not all(inside(p) for p in item["points"]):
                errs.append(f"{key}[{k}]: leaves the near grid")
    # vegetation must stay off the ride
    rp = ctx["route"]
    dense, sd = densify(rp, 0.1)
    rs = np.concatenate([[0.0], np.cumsum(np.hypot(*np.diff(rp, axis=0).T))])
    dhw = np.interp(sd, rs, ctx["rhw"])
    tr = cKDTree(dense)
    for key, rkey in (("trees", None), ("shrubs", "radiusM")):
        items = d.get(key, [])
        if not items:
            warns.append(f"no {key}")
            continue
        P = np.array([[t["e"], t["n"]] for t in items])
        dd, ii = tr.query(P)
        clear = dd - dhw[ii]
        bad = clear < ROUTE_CLEAR_M - 0.08  # 0.1 m coordinate rounding
        if bad.any():
            errs.append(f"{int(bad.sum())} {key} within carriageway + {ROUTE_CLEAR_M} m of the route "
                        f"(min clearance {clear.min():.2f} m)")
        if rkey:
            rr = np.array([t[rkey] for t in items])
            over = clear - rr < -0.08
            if over.any():
                errs.append(f"{int(over.sum())} shrubs overlap the carriageway")
        s_on = sd[ii]
        cl = ctx["course"]["climb"]
        on_climb = (s_on > cl["startS"]) & (s_on < cl["endS"])
        log(f"[check] {key}: min clearance from the carriageway edge {clear.min():.2f} m; "
            f"{int((clear < 3).sum())} within 3 m of the edge; along the climb {int((on_climb & (clear < 5)).sum())} "
            f"within 5 m and {int((on_climb & (clear < 15)).sum())} within 15 m of the edge")
        if not all(inside(p) for p in P):
            errs.append(f"{key} outside the near grid")
    # vegetation vs side-road carriageways (exact point-to-segment distance, as written to disk)
    def side_edge_clear(P):
        best = np.full(len(P), np.inf)
        for rd in d.get("roads", []):
            p = np.array(rd["points"], float); hw = 0.5 * (rd.get("widthM") or 3.0)
            a, b = p[:-1], p[1:]
            ab = b - a; L2 = np.maximum((ab * ab).sum(1), 1e-12)
            for j in range(len(a)):
                tt = np.clip(((P[:, 0] - a[j, 0]) * ab[j, 0] + (P[:, 1] - a[j, 1]) * ab[j, 1]) / L2[j], 0, 1)
                dd_ = np.hypot(P[:, 0] - (a[j, 0] + ab[j, 0] * tt), P[:, 1] - (a[j, 1] + ab[j, 1] * tt)) - hw
                np.minimum(best, dd_, out=best)
        return best
    if d.get("roads"):
        if d.get("shrubs"):
            P = np.array([[t["e"], t["n"]] for t in d["shrubs"]]); rr = np.array([t["radiusM"] for t in d["shrubs"]])
            sc_ = side_edge_clear(P)
            n_c, n_o = int((sc_ < 0).sum()), int((sc_ - rr < -0.005).sum())
            log(f"[check] shrubs vs side-road carriageways: {n_c} centres on one, {n_o} discs overlapping one "
                f"(min centre clearance {sc_.min():.2f} m, min disc clearance {(sc_ - rr).min():.2f} m)")
            if n_c or n_o:
                errs.append(f"{n_c} shrub centres on / {n_o} shrub discs over a side-road carriageway")
        if d.get("trees"):
            P = np.array([[t["e"], t["n"]] for t in d["trees"]])
            tc_ = side_edge_clear(P)
            log(f"[check] tree trunks on side-road carriageways: {int((tc_ < 0).sum())} "
                f"(min clearance {tc_.min():.2f} m)")
            if (tc_ < 0).any():
                warns.append(f"{int((tc_ < 0).sum())} tree trunks on a side-road carriageway")
    # buildings must not stand on the ride's carriageway
    from matplotlib.path import Path as MPath
    intr = []
    for b_ in d.get("buildings", []):
        rg = np.array(b_["ring"], float)
        dp, _ = densify(np.vstack([rg, rg[:1]]), 0.25)
        dd, ii = tr.query(dp)
        inside_pts = MPath(np.vstack([rg, rg[:1]])).contains_points(dense[::5])
        m = float((dhw[ii] - dd).max())
        if m > 0 or inside_pts.any():
            intr.append(max(m, 0.0) if not inside_pts.any() else 99.0)
    if intr:
        warns.append(f"{len(intr)} building footprints reach into the ride's carriageway "
                     f"(max {max(intr):.2f} m{' / centreline inside a footprint' if max(intr) >= 99 else ''})")
    else:
        log("[check] no building footprint reaches the ride's carriageway")
    for m in warns:
        log(f"[check] WARN {m}")
    for m in errs[:40]:
        log(f"[check] ERROR {m}")
    log(f"[check] {'PASSED' if not errs else 'FAILED'} ({len(errs)} errors, {len(warns)} warnings)")
    return not errs


# ---------------------------------------------------------------------------
# Debug render
# ---------------------------------------------------------------------------

LANDUSE_COLORS = {"farmland": "#e8c547", "meadow": "#7fdc5a", "grass": "#b6f28a", "forest": "#1f7a1f",
                  "orchard": "#d36bd3", "scrub": "#9a7b3c", "residential": "#ff7f50"}


def render_debug(dbg: Path, ctx: dict, log):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import EllipseCollection, LineCollection, PolyCollection

    gE0, gE1, gN0, gN1 = ctx["gE0"], ctx["gE1"], ctx["gN0"], ctx["gN1"]
    ortho = ctx["ortho"]
    route = ctx["route"]
    course = ctx["course"]

    def overlay(ax, lw=1.0, tree_alpha=0.9, shrub_ms=1.0, show_landuse=True, edges=False):
        if show_landuse:
            for l in ctx["landuse"]:
                rg = np.vstack([l["ring"], l["ring"][:1]])
                ax.plot(rg[:, 0], rg[:, 1], color=LANDUSE_COLORS[l["kind"]], lw=0.8 * lw, ls="--", alpha=0.9)
        for w in ctx["water"]:
            p = np.asarray(w["points"])
            if w["closed"]:
                p = np.vstack([p, p[:1]])
            ax.plot(p[:, 0], p[:, 1], color="#00b7ff", lw=1.4 * lw)
        segs = [np.asarray(r["points"]) for r in ctx["roads"]]
        cols_ = [{"asphalt": "#ffffff", "cobbles": "#ff9a3c", "gravel": "#d9c38c", "unpaved": "#c08a5a"}[r["surface"]]
                 for r in ctx["roads"]]
        ax.add_collection(LineCollection(segs, colors=cols_, linewidths=1.2 * lw, alpha=0.95))
        for f_ in ctx["fences"]:
            p = np.asarray(f_["points"])
            ax.plot(p[:, 0], p[:, 1], color="#ff00ff", lw=1.2 * lw)
        polys = [np.asarray(b["ring"]) for b in ctx["buildings"]]
        ax.add_collection(PolyCollection(polys, facecolors="none", edgecolors="#ff2020", linewidths=1.0 * lw))
        sh = ctx["shrubs"]
        if sh:
            P = np.array([[s["e"], s["n"]] for s in sh])
            r = np.array([s["radiusM"] for s in sh])
            ax.add_collection(EllipseCollection(2 * r, 2 * r, np.zeros(len(r)), units="xy", offsets=P,
                                                offset_transform=ax.transData, facecolors="#c6ff00",
                                                edgecolors="none", alpha=0.55))
        tr = ctx["trees"]
        if tr:
            P = np.array([[t["e"], t["n"]] for t in tr])
            r = np.array([t["crownRadiusM"] for t in tr])
            hh = np.array([t["heightM"] for t in tr])
            ax.add_collection(EllipseCollection(2 * r, 2 * r, np.zeros(len(r)), units="xy", offsets=P,
                                                offset_transform=ax.transData, facecolors="none",
                                                edgecolors=plt.cm.cool(np.clip(hh / 35.0, 0, 1)),
                                                linewidths=0.7 * lw, alpha=tree_alpha))
            ax.plot(P[:, 0], P[:, 1], ".", color="#00ffff", ms=1.2 * lw)
        ax.plot(route[:, 0], route[:, 1], color="#ffff00", lw=1.6 * lw)
        if edges:  # carriageway edges and the +ROUTE_CLEAR_M keep-out line
            tx, ty = np.gradient(route[:, 0]), np.gradient(route[:, 1])
            L = np.hypot(tx, ty)
            nx, ny = -ty / L, tx / L
            for off, ls in ((0.0, "-"), (ROUTE_CLEAR_M, ":")):
                for sgn in (-1, 1):
                    ax.plot(route[:, 0] + sgn * nx * (ctx["rhw"] + off), route[:, 1] + sgn * ny * (ctx["rhw"] + off),
                            color="#ffff00", lw=0.7, ls=ls)
            if ctx["trees"]:
                P = np.array([[t["e"], t["n"]] for t in ctx["trees"]])
                ax.plot(P[:, 0], P[:, 1], "^", color="#00ffff", ms=5, mec="k", mew=0.4)

    # --- full view
    fig, ax = plt.subplots(figsize=(22, 14), dpi=110)
    ax.imshow(ortho[::2, ::2], extent=(gE0, gE1, gN0, gN1), interpolation="bilinear")
    overlay(ax, lw=0.7, shrub_ms=0.6)
    ax.set_xlim(gE0, gE1)
    ax.set_ylim(gN0, gN1)
    ax.set_aspect("equal")
    ax.set_title(f"scenery over ortho {course['ortho'].get('capturedSeason')} {course['ortho'].get('capturedYear')}: "
                 f"{len(ctx['buildings'])} buildings (red), {len(ctx['trees'])} trees (circles = crown, colour = height), "
                 f"{len(ctx['shrubs'])} shrubs (lime), side roads (white/orange), water (blue), landuse (dashed), route (yellow)",
                 fontsize=10)
    ax.set_xlabel("east (local m)")
    ax.set_ylabel("north (local m)")
    fig.tight_layout()
    fig.savefig(dbg / "scenery.png")
    plt.close(fig)

    # --- zooms
    s = np.array(course["route"]["s"])
    steep = next((l["s"] for l in course["landmarks"] if l["kind"] == "steepest"), 0.5 * (s[0] + s[-1]))
    se_, sn_ = float(np.interp(steep, s, route[:, 0])), float(np.interp(steep, s, route[:, 1]))
    zooms = [("steep", se_, sn_, 90, 60), ("village", float(route[60, 0]), float(route[60, 1]), 90, 60),
             ("summit", float(np.interp(course["climb"]["endS"], s, route[:, 0])),
              float(np.interp(course["climb"]["endS"], s, route[:, 1])), 90, 60),
             ("forest", 330.0, 160.0, 90, 60), ("orchard", -640.0, 190.0, 90, 60),
             ("steep_tight", se_, sn_, 30, 20)]
    oE0, oN1 = ctx["oh"]["originEast"], ctx["oh"]["originNorth"]
    mpp = ctx["oh"]["widthM"] / ctx["oh"]["pixelsWide"]
    for name, ze, zn, hx, hy in zooms:
        x0, x1, y0, y1 = ze - hx, ze + hx, zn - hy, zn + hy
        c0 = max(0, int((x0 - oE0) / mpp)); c1 = min(ortho.shape[1], int((x1 - oE0) / mpp))
        r0 = max(0, int((oN1 - y1) / mpp)); r1 = min(ortho.shape[0], int((oN1 - y0) / mpp))
        crop = ortho[r0:r1, c0:c1]
        ext = (oE0 + c0 * mpp, oE0 + c1 * mpp, oN1 - r1 * mpp, oN1 - r0 * mpp)
        hc0 = max(0, int((x0 - gE0) / ctx["cell"])); hc1 = int((x1 - gE0) / ctx["cell"])
        hr0 = max(0, int((gN1 - y1) / ctx["cell"])); hr1 = int((gN1 - y0) / ctx["cell"])
        hcrop = ctx["h"][hr0:hr1, hc0:hc1]
        hext = (gE0 + hc0 * ctx["cell"], gE0 + hc1 * ctx["cell"], gN1 - hr1 * ctx["cell"], gN1 - hr0 * ctx["cell"])
        fig, axs = plt.subplots(1, 3, figsize=(30, 7.6), dpi=100)
        axs[0].imshow(crop, extent=ext, interpolation="nearest")
        axs[0].set_title(f"{name}: ortho {course['ortho'].get('capturedYear')} only", fontsize=10)
        axs[1].imshow(crop, extent=ext, interpolation="nearest")
        tight = hx <= 40
        overlay(axs[1], lw=1.4, shrub_ms=2.0, show_landuse=not tight, edges=tight)
        axs[1].set_title(f"{name}: scenery over ortho", fontsize=10)
        im = axs[2].imshow(hcrop, extent=hext, cmap="viridis", vmin=0, vmax=30, interpolation="nearest")
        overlay(axs[2], lw=1.4, shrub_ms=2.0, show_landuse=False, edges=tight)
        axs[2].set_title(f"{name}: pit-free canopy height (DSM-DTM, LiDAR 25/1/2015) + scenery", fontsize=10)
        fig.colorbar(im, ax=axs[2], fraction=0.03, label="m")
        for a in axs:
            a.set_xlim(x0, x1)
            a.set_ylim(y0, y1)
            a.set_aspect("equal")
        fig.tight_layout()
        fig.savefig(dbg / f"scenery_zoom_{name}.png")
        plt.close(fig)
    log(f"[debug] wrote scenery.png and scenery_zoom_{{" + ",".join(z[0] for z in zooms) + f"}}.png to {dbg}")


# ---------------------------------------------------------------------------
# Swift decode check (the app's own CourseData.swift, plain swiftc, no Xcode)
# ---------------------------------------------------------------------------

SWIFT_PROBE = r"""
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let course = try JSONDecoder().decode(CourseFile.self, from: Data(contentsOf: dir.appendingPathComponent("course.json")))
    guard let name = course.scenery else { print("course.json names no scenery file"); exit(1) }
    let s = try JSONDecoder().decode(SceneryFile.self, from: Data(contentsOf: dir.appendingPathComponent(name)))
    print("swift decode OK: schema \(s.schemaVersion), buildings \(s.buildings?.count ?? -1), trees \(s.trees?.count ?? -1), " +
          "shrubs \(s.shrubs?.count ?? -1), landuse \(s.landuse?.count ?? -1), roads \(s.roads?.count ?? -1), " +
          "fences \(s.fences?.count ?? -1), water \(s.water?.count ?? -1)")
} catch {
    print("swift decode FAILED: \(error)")
    exit(1)
}
"""


def swift_check(course_id: str) -> int:
    import subprocess
    import tempfile
    model = REPO / "CycleJames" / "Courses" / "Model"
    with tempfile.TemporaryDirectory() as td:
        main_swift = Path(td) / "main.swift"
        main_swift.write_text(SWIFT_PROBE)
        exe = Path(td) / "probe"
        r = subprocess.run(["swiftc", "-Onone", "-o", str(exe), str(model / "CourseData.swift"), str(main_swift)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr[-2000:])
            return 1
        r = subprocess.run([str(exe), str(OUT_ROOT / course_id)], capture_output=True, text=True)
        print(r.stdout.strip() or r.stderr.strip())
        return r.returncode


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("course", choices=sorted(COURSES))
    ap.add_argument("--no-render", action="store_true", help="skip the debug PNGs")
    ap.add_argument("--swift-check", action="store_true",
                    help="after building, compile the app's CourseData.swift with swiftc and decode scenery.json")
    args = ap.parse_args(argv)
    rc = build(args.course, render=not args.no_render)
    if rc == 0 and args.swift_check:
        rc = swift_check(args.course)
    return rc


if __name__ == "__main__":
    sys.exit(main())
