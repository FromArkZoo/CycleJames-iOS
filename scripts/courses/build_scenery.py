# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "pyproj", "pillow", "matplotlib", "scipy"]
# ///
"""Bake scenery.json for a CycleJames course (see scripts/courses/FORMAT.md).

    uv run --script scripts/courses/build_scenery.py koppenberg [--swift-check] [--out-root DIR]
    (or oudekwaremont, paterberg, muur, molenberg, taaienberg, poggio)

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

The Poggio (EPSG:7791, Liguria) takes its footprints from Regione Liguria's
CTR 1:5000 2007/2013 3D (WFS M1237, cached) instead of GRB: buildings
(L3165, Z = eaves), greenhouses, sheds and cisterns (L3166), retaining walls
and agricultural terraces (L3175) and dividing walls and fences (L3169),
each wall with its surveyed crest. Its canopy is the 2008-2010 LiDAR (DSM
First - DTM), checked against the summer 2022 ortho; trees get a species
where the crown, the landuse or the CTR's woods say which (see
med_tree_kinds). See COURSES["poggio"].

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
    "molenberg": {
        "route_ways": [229057047, 562510988, 370262557, 370262562, 489939403, 440285202, 503851708],
        "osm_bbox": (50.8535, 3.6886, 50.8657, 3.7154),
        "winter_ortho": {"service": "https://geo.api.vlaanderen.be/OMW/wms", "vdc_layer": "OMWRGB25VL_vdc"},
    },
    "taaienberg": {
        "route_ways": [1446400782, 1447012705, 965272548, 1447012704, 34006550, 1492020940, 798758556, 34006549,
                       186384384, 121508810],
        "osm_bbox": (50.7895, 3.6142, 50.8010, 3.6489),
        "winter_ortho": {"service": "https://geo.api.vlaanderen.be/OMW/wms", "vdc_layer": "OMWRGB25VL_vdc"},
    },
    # The Poggio di Sanremo: a hillside of villas, greenhouses and dry-stone terraces above the sea. Every
    # setting here is opt-in, so the Flemish scenery files stay as they are.
    "poggio": {
        "route_ways": [280009642, 525886322, 502869479, 502869477, 502869476, 502869478, 28209618],
        "osm_bbox": (43.8142, 7.8100, 43.8313, 7.8365),
        # Footprints, walls and structures from the Liguria CTR 3D (build_course.py fetched the same box).
        "buildings": "ctr",
        "ctr": {
            "url": "https://geoservizi.regione.liguria.it/geoserver/M1237/wfs",
            "box": (404000, 4851500, 406500, 4854000),   # EPSG:7791 E0, N0, E1, N1 (contains the near grid)
            "buildings": "M1237:L3165",      # Edificato: footprint, Z = eaves (gronda)
            "structures": "M1237:L3166",     # Manufatto edilizio: Serra, Baracca, Cisterna, Vasca ...
            "walls": "M1237:L3175",          # Muro di sostegno / Terrazzamento agricolo: crest (Coronamento) lines
            "dividers": "M1237:L3169",       # Elemento divisorio: Muro in muratura, Muro a secco, Recinzione
            "trees": "M1237:L3203",          # Albero isolato (points; used to check the LiDAR tops)
            "crops": "M1237:L3200",          # Colture agricole: Uliveti
            "woods": "M1237:L3196",          # Bosco: Conifere / Pini
        },
        # OSM tags this hillside uses that Flanders maps elsewhere or not at all.
        "landuse_extra": {("landuse", "greenhouse_horticulture"): "greenhouse", ("landuse", "orchard"): "olive",
                          ("landuse", "farmland"): "terraces", ("leisure", "garden"): "garden",
                          ("landuse", "allotments"): "terraces", ("landuse", "plant_nursery"): "greenhouse"},
        # Evergreen crowns flown in leaf (2008-2010): a light pit fill, and a crown-width allometry for
        # Mediterranean trees (olives and pines are wider for their height than a beech of the same height).
        "pit_fill_r": 1.0,
        "crown_allometry": "mediterranean",
        "shrub_far": 80.0,
        "tree_species": "riviera",
        # CTR footprints by the road that are gone, checked by eye against the summer 2022 ortho and the
        # April 2024 ride (the CTR is 2007/2013): a point inside each (local metres, a strip's own point where
        # split_by_fall cuts one). Greenhouses now dry scrub terraces, bare earth or a track: the start ramp's
        # right (route s 345-480, 5 strips), the bank before hairpin 2 on the left (route 1290-1360, one
        # polygon in 7 strips), the ridge's right at route 2495-2525 (2 strips). The flat-roofed "house" at
        # route 2703-2707 right is a yard with a car and a tree in 2022, the forecourt behind a rubble pier
        # in the 2024 frame f76 (look s 2400).
        "ctr_gone": [(752.3, -603.1), (750.5, -598.1), (750.1, -591.4), (756.7, -584.4), (757.1, -578.4),
                     (757.5, -572.4), (749.8, -570.0), (359.2, -421.0), (346.1, -480.4), (353.6, -466.8),
                     (366.1, -465.6), (383.2, -515.3), (684.6, -294.8), (683.7, -288.8), (514.8, -198.6)],
        # Footprints stop this far outside the ride's carriageway: the CTR's footprints overlap its own
        # road area (which gives the route its width) by up to 0.5 m, and a wall on the edge line stands
        # in the gutter.
        "footprint_clear_m": 0.35,
        # Debug zooms at route s: hairpin 1, the sanctuary park, the glasshouses on the road wall (look.md
        # 2560-2600 m), the summit loop.
        "debug_zooms_s": [("hairpin1", 660.0), ("santuario", 2279.0), ("greenhouses", 2865.0), ("summit_loop", 4160.0)],
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


def fetch_wfs(cache: Path, url: str, typename: str, crs: str, box, log, page: int = 1000) -> list:
    """Every feature of a WFS 2.0.0 layer in a box (E0, N0, E1, N1 in `crs`), GeoJSON reprojected by the server
    into `crs` (Regione Liguria's own transformation, which fits the 2022 ortho), paged. Cached under the same
    names as build_course.py's wfs_geojson, so the two scripts share the pages."""
    from pyproj import CRS
    x0, y0, x1, y1 = box
    north_first = CRS.from_user_input(crs).axis_info[0].direction.lower() == "north"
    bb = f"{y0},{x0},{y1},{x1}" if north_first else f"{x0},{y0},{x1},{y1}"
    feats, start = [], 0
    while True:
        q = urllib.parse.urlencode({
            "service": "WFS", "version": "2.0.0", "request": "GetFeature", "typeNames": typename,
            "outputFormat": "application/json", "srsName": crs, "bbox": f"{bb},{crs}", "count": page,
            "startIndex": start})
        body = cached_fetch(cache, f"wfs_{typename.replace(':', '_')}_{x0}_{x1}_{y0}_{y1}_{start}.json", f"{url}?{q}",
                            validate=lambda b, h: b.lstrip().startswith(b"{"), log=log, tries=4)
        d = json.loads(body)
        got = str(d.get("crs", {}).get("properties", {}).get("name", ""))
        if got and not got.endswith(crs.split(":")[1]):
            raise SystemExit(f"{typename} answered in {got}, expected {crs}")
        f_ = d.get("features", [])
        feats.extend(f_)
        if len(f_) < page:
            break
        start += page
    return feats


def geom_parts(g: dict, polygons: bool) -> list[np.ndarray]:
    """A GeoJSON geometry's exterior rings (polygons=True) or lines, as (n, 2 or 3) arrays."""
    t, c = (g or {}).get("type"), (g or {}).get("coordinates")
    if polygons:
        if t == "Polygon":
            return [np.asarray(c[0], np.float64)]
        if t == "MultiPolygon":
            return [np.asarray(p[0], np.float64) for p in c]
        return []
    if t == "LineString":
        return [np.asarray(c, np.float64)]
    if t == "MultiLineString":
        return [np.asarray(x, np.float64) for x in c]
    return []


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
# Liguria CTR (the Poggio): buildings, greenhouses, walls
# ---------------------------------------------------------------------------

# Manufatto edilizio (L3166) kinds that stand on the hillside. Rudere (ruins), Pensilina/tettoia (open
# canopies), Spartitraffico, tombs and Rampa are left to the ground photo.
CTR_STRUCTURES = {"Serra": "greenhouse", "Cisterna": "cistern", "Vasca generica": "cistern",
                  "Vasca/piscina scoperta": "pool", "Baracca": "shed",
                  "Cabina trasformazione energia": "cabin"}
CTR_WALLS = {"Muri di sostegno": "retaining", "Muri d'ala": "retaining", "Terrazzamento agricolo": "terrace",
             "Muro in muratura": "masonry", "Muro a secco": "masonry", "Recinzione generica": "fence"}
# Marseille-tile hipped roofs on the Riviera rise at about 20-25 degrees (BuildingBuilder+Riviera.swift
# draws 20-25); the CTR's eaves plus this rise over the footprint's half width is the ridge.
RIVIERA_PITCH_DEG = 22.0
# The roof colour in the summer 2022 ortho: Marseille tiles are terracotta (#c4876a, chromatic red - blue
# ~0.13), roof terraces white or grey (#e8e2d8, ~0.04); greenhouse glass whitewashed grey-green from the air
# (#7b8d85-#8d9e97), plastic film white (#e8edea). Thresholds from the distributions in scenery_log.txt.
ROOF_WARM_TILES = 0.07      # chromatic (r - b) / (r + g + b) above this: a tiled roof (houses p50 0.076 here)
ROOF_COOL_FLAT = 0.045      # below this: a terrace (or a sheet) roof (the houses' cool mode is 0.02-0.04)
FILM_BRIGHT = 0.70          # mean sRGB brightness above this, and little colour: plastic film, not glass
FILM_SAT = 0.10


def _half_short(ring: np.ndarray) -> float:
    """Half the footprint's width across its long axis."""
    P = ring - ring.mean(axis=0)
    _, V = np.linalg.eigh(np.cov(P.T))
    v = P @ V[:, 0]
    return 0.5 * float(v.max() - v.min())


def split_by_fall(ring: np.ndarray, ce: np.ndarray, cn: np.ndarray, g: np.ndarray, rise: float) -> list:
    """The footprint cut into strips across the ground's fall, `rise` metres of it each (a plane fitted to the
    ground g at cell centres (ce, cn)). Strips under 15 m2 are dropped."""
    A = np.stack([np.ones_like(ce), ce - ce.mean(), cn - cn.mean()], axis=1)
    coef, *_ = np.linalg.lstsq(A, g.astype(np.float64), rcond=None)
    k = math.hypot(coef[1], coef[2])
    if k < 0.02:
        return [ring]
    u = np.array([coef[1], coef[2]]) / k
    t = ring @ u
    edges = np.arange(t.min(), t.max(), rise / k)[1:]
    if not len(edges):
        return [ring]

    def clip(poly, t0, keep_above):
        out = []
        for i in range(len(poly)):
            a, b = poly[i - 1], poly[i]
            ta, tb = a @ u - t0, b @ u - t0
            ina, inb = (ta >= 0) == keep_above, (tb >= 0) == keep_above
            if inb:
                if not ina:
                    out.append(a + (b - a) * (ta / (ta - tb)))
                out.append(b)
            elif ina:
                out.append(a + (b - a) * (ta / (ta - tb)))
        return np.array(out).reshape(-1, 2)

    pieces = []
    for lo, hi in zip(np.concatenate([[t.min() - 1], edges]), np.concatenate([edges, [t.max() + 1]])):
        p = clip(clip(ring, lo, True), hi, False)
        p = clean_ring(p, nd=2) if len(p) >= 3 else None
        if p is not None and abs(signed_area(p)) >= 15.0:
            pieces.append(p)
    return pieces or [ring]


def _simple_ring(p: np.ndarray) -> bool:
    """True if no two non-adjacent edges of the closed ring cross."""
    n = len(p)
    a, b = p, np.roll(p, -1, axis=0)
    for i in range(n):
        for j in range(i + 2, n):
            if i == 0 and j == n - 1:
                continue
            d1 = (b[i, 0] - a[i, 0]) * (a[j, 1] - a[i, 1]) - (b[i, 1] - a[i, 1]) * (a[j, 0] - a[i, 0])
            d2 = (b[i, 0] - a[i, 0]) * (b[j, 1] - a[i, 1]) - (b[i, 1] - a[i, 1]) * (b[j, 0] - a[i, 0])
            d3 = (b[j, 0] - a[j, 0]) * (a[i, 1] - a[j, 1]) - (b[j, 1] - a[j, 1]) * (a[i, 0] - a[j, 0])
            d4 = (b[j, 0] - a[j, 0]) * (b[i, 1] - a[j, 1]) - (b[j, 1] - a[j, 1]) * (b[i, 0] - a[j, 0])
            if d1 * d2 < 0 and d3 * d4 < 0:
                return False
    return True


def clear_of_carriageway(ring: np.ndarray, rtree, rdense: np.ndarray, rdense_hw: np.ndarray,
                         margin: float) -> tuple[np.ndarray, str]:
    """The footprint pulled back to `margin` metres outside the ride's carriageway (the route's half width).
    The outline is walked every 0.25 m and each point inside the band is moved out along the line from its
    nearest route point, three passes so a point pushed off one leg of a hairpin or the summit loop is checked
    against the other; the moved run follows the carriageway's curve and the untouched walls keep their
    corners (Douglas-Peucker at 5 cm). Returns (ring, "clear" | "clipped" | "kept"): "clear" if it already
    is; a footprint this would fold (the route through it, or two legs closer than it is deep) is "kept" as
    it is."""
    closed = np.vstack([ring, ring[:1]])
    d0, i0 = rtree.query(closed)
    if float((d0 - rdense_hw[i0]).min()) >= margin - 0.05:
        dp, _ = densify(closed, 0.25)
        d1, i1 = rtree.query(dp)
        if float((d1 - rdense_hw[i1]).min()) >= margin - 0.05:
            return ring, "clear"
    pts = []
    for a, b in zip(closed[:-1], closed[1:]):
        n = max(1, int(math.ceil(math.hypot(*(b - a)) / 0.25)))
        pts += [a + (b - a) * t for t in np.arange(n) / n]
    pts = np.array(pts)
    for _ in range(3):
        d, i = rtree.query(pts)
        short = d - rdense_hw[i] < margin
        if not short.any():
            break
        if float(d[short].min()) < 0.05:
            return ring, "kept"
        v = pts[short] - rdense[i[short]]
        pts[short] = rdense[i[short]] + v * ((rdense_hw[i[short]] + margin) / d[short])[:, None]
    # A corner pushed out past its neighbours can leave a fold of a few centimetres: a coarser
    # simplification takes it out, as long as the outline stays clear.
    for tol in (0.05, 0.15, 0.3):
        p = clean_ring(simplify_line(np.vstack([pts, pts[:1]]), tol)[:-1], nd=2)
        if p is None or not _simple_ring(p) or signed_area(p) < 0.5 * signed_area(ring):
            continue
        dp, _ = densify(np.vstack([p, p[:1]]), 0.25)
        d, i = rtree.query(dp)
        if float((d - rdense_hw[i]).min()) >= margin - 0.05:
            return p, "clipped"
    return ring, "kept"


def _circle_fit(ring: np.ndarray):
    """Least-squares circle through the vertices: (centre, radius, rms of the radial misfit)."""
    x, y = ring[:, 0], ring[:, 1]
    A = np.stack([x, y, np.ones_like(x)], axis=1)
    sol, *_ = np.linalg.lstsq(A, x * x + y * y, rcond=None)
    c = 0.5 * sol[:2]
    r = math.sqrt(max(sol[2] + c @ c, 0.0))
    return c, r, float(np.sqrt(np.mean((np.hypot(x - c[0], y - c[1]) - r) ** 2)))


def ctr_buildings(ctr: dict, osm_rings: list, oE: float, oN: float, grid: tuple, dtm: np.ndarray, h: np.ndarray,
                  photo: dict, log, gone: list | None = None):
    """Riviera footprints from the CTR, with heights and roofs from the LiDAR and the 2022 ortho.

    Edificato (L3165) polygons hold the eaves elevation (Z, constant per polygon; data.md 3.8): eavesM = Z -
    groundElevM, where groundElevM is the lowest ground in the footprint, as everywhere. heightM is what
    BuildingBuilder draws to (the ridge, or a flat roof's parapet): the LiDAR's p90 roof height (DSM First -
    ground, 2008-2010) when it agrees with the CTR's eaves (between eaves - 1 m and eaves + ridge rise + 2 m:
    a tree over the roof or a building built or raised since then fails it), else the eaves plus the rise of a
    22 degree hipped roof (or 0.4 m of parapet on a flat one). Roofs: a LiDAR plane fit (roof_from_dsm), with
    the ortho's roof colour as the judge (terracotta tiles are never flat, a white or grey roof with no
    pitched fit is a terrace), hipped otherwise. Greenhouses (Serra) are "sawtooth" glass or "tunnel" film by
    the photo's brightness; ones that are vegetation in 2022 are dropped, and so is any footprint (or strip)
    holding one of the `gone` points (checked by eye). OSM tags (churches) come by overlap, and OSM footprints
    the CTR lacks are added with LiDAR heights."""
    from matplotlib.path import Path as MPath
    gone = np.array(gone or [], np.float64).reshape(-1, 2)
    gone_hit = np.zeros(len(gone), int)
    gE0, gN1, cell, rows, cols = grid
    gE1, gN0 = gE0 + cols * cell, gN1 - rows * cell
    veg, bright, warm, sat = photo["veg"], photo["bright"], photo["warm"], photo["sat"]
    dsm = dtm + h
    # OSM footprints by cell, for their tags
    olab = np.zeros((rows, cols), np.int32)
    osm = []
    for t, wid, g in osm_rings:
        rg = clean_ring(g, nd=2)
        if rg is None:
            continue
        rr, cc = cells_in_polygon(rg, gE0, gN1, cell, rows, cols)
        osm.append({"tags": t, "osm": wid, "ring": rg, "n": rr.size, "used": False})
        olab[rr, cc] = len(osm)
    cands = []
    for f_ in ctr["buildings"]:
        for r3 in geom_parts(f_.get("geometry"), polygons=True):
            cands.append(("L3165", f_.get("properties") or {}, r3))
    n_struct = {}
    for f_ in ctr["structures"]:
        d_ = (f_.get("properties") or {}).get("definizione")
        n_struct[d_] = n_struct.get(d_, 0) + 1
        if d_ in CTR_STRUCTURES:
            for r3 in geom_parts(f_.get("geometry"), polygons=True):
                cands.append(("L3166", f_.get("properties") or {}, r3))
    log(f"[ctr] {len(ctr['buildings'])} Edificato polygons; Manufatto by kind {n_struct}")
    bmask = np.zeros((rows, cols), bool)
    tanp = math.tan(math.radians(RIVIERA_PITCH_DEG))
    buildings = []
    stats = {"outside": 0, "straddle": 0, "overlap": 0, "pool": 0, "greenhouse gone by 2022": 0,
             "gone by 2022 (checked)": 0}
    dropped = []
    hsrc_n, gh_photo = {}, []

    def lidar_cells(ring):
        rr, cc = cells_in_polygon(ring, gE0, gN1, cell, rows, cols)
        if rr.size == 0:
            r1 = int(np.clip(math.floor((gN1 - ring[:, 1].mean()) / cell), 0, rows - 1))
            c1 = int(np.clip(math.floor((ring[:, 0].mean() - gE0) / cell), 0, cols - 1))
            rr, cc = np.array([r1]), np.array([c1])
        ri, ci = cells_in_polygon(ring, gE0, gN1, cell, rows, cols, shrink=0.7)
        if ri.size < 4:
            ri, ci = rr, cc
        return rr, cc, ri, ci

    for layer, props, r3 in cands:
        ring = clean_ring(r3[:, :2] - np.array([oE, oN]), nd=2)
        if ring is None:
            continue
        inside_v = ((ring[:, 0] > gE0 + 1) & (ring[:, 0] < gE1 - 1) & (ring[:, 1] > gN0 + 1) & (ring[:, 1] < gN1 - 1))
        if not inside_v.any():
            stats["outside"] += 1
            continue
        if not inside_v.all():
            stats["straddle"] += 1
            continue
        rr, cc, ri, ci = lidar_cells(ring)
        if bmask[rr, cc].mean() > (0.5 if layer == "L3166" else 0.3):
            stats["overlap"] += 1
            continue
        area = float(signed_area(ring))
        ground = float(dtm[rr, cc].min())
        z = float(np.median(r3[:, 2])) if r3.shape[1] > 2 else float("nan")
        eaves = z - ground
        p90c = float(np.percentile(h[ri, ci], 90))
        p50c = float(np.percentile(h[ri, ci], 50))
        measured = float(np.percentile(dsm[ri, ci], 90)) - ground
        green = float(np.mean(veg[ri, ci] > 0.05))
        w_roof = float(np.median(warm[ri, ci]))
        b_roof = float(np.median(bright[ri, ci]))
        s_roof = float(np.median(sat[ri, ci]))
        tags = {}
        hit = olab[rr, cc]
        if rr.size and (hit > 0).mean() > 0.3:
            k = int(np.bincount(hit[hit > 0]).argmax()) - 1
            tags = osm[k]["tags"]
            osm[k]["used"] = True
        b = {"ring": ring, "groundElevM": round(ground, 2), "src": layer, "osm": None, "area": area,
             "measured": measured, "p90c": p90c, "green": green, "warm": w_roof, "bright": b_roof, "sat": s_roof,
             "ctr": props.get("def_tipo_edil") or props.get("definizione"), "btag": tags.get("building")}
        ctr_eaves_ok = math.isfinite(eaves) and 1.8 <= eaves <= 45.0
        if layer == "L3166":
            what = CTR_STRUCTURES[props.get("definizione")]
            if what == "pool":
                c_, r_, rms_ = _circle_fit(ring)
                if not (r_ > 2.0 and rms_ < 0.4 and len(ring) >= 8):
                    stats["pool"] += 1   # a swimming pool: the ground photo has it
                    continue
                what = "cistern"
            if what == "greenhouse":
                glassy = float(np.mean((sat[ri, ci] < 0.16) & (bright[ri, ci] > 0.40)))
                gh_photo.append((b_roof, s_roof, glassy, green))
                b["glassy"] = glassy
                # Gone by 2022: little glass- or film-like roof (grey, white or grey-green), and either
                # vegetation or warm, earthy ground (terraces) instead (glass and film: warmth 0.0-0.06 here).
                if glassy < 0.25 and (green > 0.6 or w_roof > 0.06):
                    stats["greenhouse gone by 2022"] += 1
                    dropped.append(b | {"why": "greenhouse gone by 2022"})
                    continue
                b["kind"] = "greenhouse"
                b["roofShape"] = "tunnel" if b_roof > FILM_BRIGHT and s_roof < FILM_SAT else "sawtooth"
                if p90c >= 1.8 and 2.5 <= measured <= 7.0:
                    hm, b["hsrc"] = measured, "lidar"
                elif 1.8 <= eaves <= 6.0:
                    hm, b["hsrc"] = eaves + 0.8, "ctr eaves"   # Venlo spans rise ~0.8 m over the gutter
                else:
                    hm, b["hsrc"] = 4.0, "default"
                b["heightM"] = round(float(np.clip(hm, 3.0, 6.0)), 1)
                if 1.8 <= eaves <= 6.0:
                    b["eavesM"] = round(eaves, 1)
                g_ = dtm[rr, cc]
                if float(np.percentile(g_, 95) - np.percentile(g_, 5)) > 2.5:
                    # One CTR polygon over several terraces (up to 10 m of fall across 1900 m2 here): the
                    # houses step down the slope, so it is cut into strips across the fall, 2 m of it each,
                    # each with its own floor (its lowest ground) and its ridge >= 2.6 m over its highest.
                    b["pieces"] = []
                    for piece in split_by_fall(ring, gE0 + (cc + 0.5) * cell, gN1 - (rr + 0.5) * cell, g_, 2.0):
                        pr_, pc_, pri, pci = lidar_cells(piece)
                        fl, gmx = float(dtm[pr_, pc_].min()), float(dtm[pr_, pc_].max())
                        mp = float(np.percentile(dsm[pri, pci], 90)) - fl
                        hp = mp if (float(np.percentile(h[pri, pci], 90)) >= 1.8 and 2.5 <= mp <= 7.0) else 4.0
                        b["pieces"].append(b | {"ring": piece, "groundElevM": round(fl, 2), "area": float(signed_area(piece)),
                                                "heightM": round(float(min(max(hp, gmx - fl + 2.6), 7.0)), 1),
                                                "hsrc": "lidar (strip)" if hp == mp else "default (strip)"})
                        b["pieces"][-1].pop("eavesM", None)
                    stats["greenhouses cut across their fall"] = stats.get("greenhouses cut across their fall", 0) + 1
            elif what == "cistern":
                b["kind"], b["roofShape"] = "cistern", "flat"
                if p90c >= 0.5 and 0.5 <= measured <= 9.0:
                    hm, b["hsrc"] = measured, "lidar"
                elif math.isfinite(eaves) and 0.5 <= eaves <= 9.0:
                    hm, b["hsrc"] = eaves, "ctr eaves"
                else:
                    hm, b["hsrc"] = 1.8, "default"
                b["heightM"] = round(float(hm), 1)
            else:   # shed (Baracca) or transformer cabin
                b["kind"] = "barn" if what == "shed" else "other"
                if p90c >= 1.5 and 1.8 <= measured <= 6.0 and green < 0.5:
                    hm, b["hsrc"] = measured, "lidar"
                elif math.isfinite(eaves) and 1.8 <= eaves <= 5.0:
                    hm, b["hsrc"] = eaves + 0.3, "ctr eaves"
                else:
                    hm, b["hsrc"] = 2.6 if what == "shed" else 3.2, "default"
                b["heightM"] = round(float(np.clip(hm, 2.2, 6.0)), 1)
                b["roofShape"] = "flat" if w_roof < ROOF_COOL_FLAT else "unknown"
        else:
            tipo, uso = props.get("def_tipo_edil", ""), props.get("def_cat_uso", "")
            if (uso == "Luogo di culto" or tipo in ("Battistero", "Campanile")
                    or tags.get("building") in ("church", "chapel") or tags.get("amenity") == "place_of_worship"):
                kind = "church" if area >= 120 else "chapel"
            elif tipo == "Capannone" or uso.startswith("Industriale"):
                kind = "barn"
            elif tipo == "Faro":
                kind = "other"
            else:
                kind = "house"
            b["kind"] = kind
            half = _half_short(ring)
            rise = tanp * half
            lidar_ok = p90c >= 2.0 and not (green >= 0.5 and p90c - p50c > 2.5)
            if lidar_ok and ctr_eaves_ok and kind not in ("church", "chapel"):
                lidar_ok = eaves - 1.0 <= measured <= eaves + rise + 2.0
            if lidar_ok:
                hm, b["hsrc"] = measured, "lidar"
                shape, _ = roof_from_dsm(h[ri, ci].astype(np.float64), (gE0 + (ci + 0.5) * cell).astype(np.float64),
                                         (gN1 - (ri + 0.5) * cell).astype(np.float64), ring)
            elif ctr_eaves_ok:
                shape = "flat" if w_roof < ROOF_COOL_FLAT else "unknown"
                hm, b["hsrc"] = eaves + (0.4 if shape == "flat" else rise), "ctr eaves"
            else:
                shape = "unknown"
                hm, b["hsrc"] = (7.5 if kind == "house" else 6.0), "default"
            # The photo's roof colour has the last word on a roof's shape.
            if shape == "flat" and w_roof > ROOF_WARM_TILES:
                shape = "hipped"     # tiles: a low-pitched roof the 1 m LiDAR reads as a plane
            elif shape == "unknown" and w_roof < ROOF_COOL_FLAT and kind != "church":
                shape = "flat"       # a white or grey roof terrace
            if kind in ("church", "chapel"):
                shape = "gabled"
                if ctr_eaves_ok:
                    hm = max(hm, eaves + rise)
            elif shape == "unknown" and kind != "barn":
                shape = "hipped"     # the Riviera's default: Marseille tiles on four slopes
            b["roofShape"] = shape
            b["heightM"] = round(max(float(hm), 2.4), 1)
            if ctr_eaves_ok:
                b["eavesM"] = round(eaves, 1)
                if kind == "house":
                    b["levels"] = int(max(1, round((eaves - 0.3) / 3.0)))
        pieces = b.pop("pieces", None) or [b]
        kept = []
        for p_ in pieces:
            hit = MPath(np.vstack([p_["ring"], p_["ring"][:1]])).contains_points(gone) if len(gone) else []
            if np.any(hit):
                gone_hit += np.asarray(hit, int)
                stats["gone by 2022 (checked)"] += 1
                dropped.append(p_ | {"why": "gone by 2022 (checked)"})
            else:
                kept.append(p_)
        if len(kept) == len(pieces):
            bmask[rr, cc] = True
        for b_ in kept:
            if len(kept) < len(pieces):
                pr_, pc_ = cells_in_polygon(b_["ring"], gE0, gN1, cell, rows, cols)
                bmask[pr_, pc_] = True
            b_.pop("pieces", None)
            hsrc_n[b_["hsrc"]] = hsrc_n.get(b_["hsrc"], 0) + 1
            buildings.append(b_)
    # OSM footprints the CTR does not have (built since, or missed), with LiDAR heights where there are some.
    n_osm = 0
    for o in osm:
        if o["used"]:
            continue
        ring = o["ring"]
        if not ((ring[:, 0] > gE0 + 1) & (ring[:, 0] < gE1 - 1) & (ring[:, 1] > gN0 + 1)
                & (ring[:, 1] < gN1 - 1)).all():
            continue
        rr, cc, ri, ci = lidar_cells(ring)
        if bmask[rr, cc].mean() > 0.3:
            continue
        ground = float(dtm[rr, cc].min())
        measured = float(np.percentile(dsm[ri, ci], 90)) - ground
        p90c = float(np.percentile(h[ri, ci], 90))
        kind = building_kind(o["tags"])
        if kind == "other" and o["tags"].get("building") in ("yes", "house", "residential", "apartments"):
            kind = "house"
        w_roof = float(np.median(warm[ri, ci]))
        if p90c >= 2.0 and 2.4 <= measured <= 25.0:
            hm, hsrc = measured, "lidar"
        else:
            hm, hsrc = (7.5 if kind == "house" else DEFAULT_HEIGHT.get(kind, 4.0)), "default"
        b = {"ring": ring, "groundElevM": round(ground, 2), "src": "osm", "osm": o["osm"], "area": float(signed_area(ring)),
             "measured": measured, "p90c": p90c, "green": float(np.mean(veg[ri, ci] > 0.05)), "warm": w_roof,
             "bright": float(np.median(bright[ri, ci])), "sat": float(np.median(sat[ri, ci])), "ctr": None,
             "btag": o["tags"].get("building"), "kind": kind, "hsrc": hsrc, "heightM": round(max(hm, 2.4), 1),
             "roofShape": "flat" if w_roof < ROOF_COOL_FLAT else "hipped"}
        bmask[rr, cc] = True
        hsrc_n[hsrc] = hsrc_n.get(hsrc, 0) + 1
        buildings.append(b)
        n_osm += 1
    kinds, roofs = {}, {}
    for b in buildings:
        kinds[b["kind"]] = kinds.get(b["kind"], 0) + 1
        roofs[b["roofShape"]] = roofs.get(b["roofShape"], 0) + 1
    log(f"[buildings] {len(buildings)} kept ({len(buildings) - n_osm} CTR, {n_osm} OSM-only); dropped {stats}; "
        f"kinds {kinds}")
    if len(gone) and not (gone_hit == 1).all():
        raise SystemExit(f"ctr_gone points {np.flatnonzero(gone_hit != 1).tolist()} matched "
                         f"{gone_hit[gone_hit != 1].tolist()} footprints (want exactly one each)")
    log(f"[buildings] heights from {hsrc_n}; roofs {roofs}")
    hs_ = [b for b in buildings if b["src"] == "L3165" and b["hsrc"] == "lidar" and "eavesM" in b]
    if hs_:
        dd = np.array([b["heightM"] - b["eavesM"] for b in hs_])
        log(f"[buildings] LiDAR p90 roof minus CTR eaves (houses where both agree): p10/p50/p90 "
            f"{np.percentile(dd, 10):.1f}/{np.percentile(dd, 50):.1f}/{np.percentile(dd, 90):.1f} m (n {len(hs_)})")
    if gh_photo:
        a_ = np.array(gh_photo)
        log(f"[buildings] greenhouse roofs in the 2022 ortho: brightness p10/p50/p90 "
            + "/".join(f"{v:.2f}" for v in np.percentile(a_[:, 0], [10, 50, 90])) + ", colour "
            + "/".join(f"{v:.3f}" for v in np.percentile(a_[:, 1], [10, 50, 90])) + ", glassy share "
            + "/".join(f"{v:.2f}" for v in np.percentile(a_[:, 2], [10, 50, 90])))
    for kk in ("house", "barn"):
        ww = [b["warm"] for b in buildings if b["kind"] == kk]
        if ww:
            log(f"[buildings] roof colour (r - b) / sum on {kk}: p10/p50/p90 "
                + "/".join(f"{v:.3f}" for v in np.percentile(ww, [10, 50, 90])))
    photo["dropped_buildings"] = dropped   # for the debug render
    return buildings, bmask


def ctr_walls(ctr: dict, oE: float, oN: float, grid: tuple, dtm: np.ndarray, h: np.ndarray, route: dict,
              log) -> list[dict]:
    """The CTR's walls, each a crest polyline (east, north, crest elevation) and a typical height.

    Muri di sostegno and Muri d'ala are "retaining", Terrazzamento agricolo "terrace" (L3175, the crest
    "Coronamento" lines only); Muro in muratura and Muro a secco "masonry", Recinzione generica "fence" (L3169).
    A masonry wall within 2.5 m of the ride's carriageway edge whose crest stands 0.3-1.4 m over the road, with
    the ground falling away behind it, is a "parapet".

    Retaining walls and terraces: the crest is the survey's Z (0.6 m precision; against the LiDAR ground it sits
    a median 0.1 m below the upper side 1.5 m back), put back 0.15 m over the higher side where it is below the
    lower side or more than 2.5 m over the higher one. heightM is the median of the crest over the lower side,
    1.0 m (terraces) or 1.5 m (retaining walls) out on the 1 m DTM.
    Dividing walls and fences: the CTR's Z is their foot (a median 0.07 m below the LiDAR ground on the line), so
    the crest comes from the LiDAR's first returns: the highest DSM within 0.5 m of the line, between 0.4 and
    2.5 m over the ground beside it (1.0 m for a wall, 1.5 m for a fence where the DSM shows nothing)."""
    gE0, gN1, cell, rows, cols = grid
    gE1, gN0 = gE0 + cols * cell, gN1 - rows * cell

    def ground(e, n):
        fc = np.clip((np.asarray(e) - gE0) / cell - 0.5, 0, cols - 1.001)
        fr = np.clip((gN1 - np.asarray(n)) / cell - 0.5, 0, rows - 1.001)
        c0, r0 = np.floor(fc).astype(int), np.floor(fr).astype(int)
        tx, ty = fc - c0, fr - r0
        top = dtm[r0, c0] * (1 - tx) + dtm[r0, c0 + 1] * tx
        bot = dtm[r0 + 1, c0] * (1 - tx) + dtm[r0 + 1, c0 + 1] * tx
        return top * (1 - ty) + bot * ty

    walls = []
    n_by, n_fix, n_short, n_par = {}, 0, 0, 0
    sources = [(f_, CTR_WALLS.get((f_.get("properties") or {}).get("def_tipo"))) for f_ in ctr["walls"]
               if (f_.get("properties") or {}).get("def_zona") == "Coronamento"]
    sources += [(f_, CTR_WALLS.get((f_.get("properties") or {}).get("definizione"))) for f_ in ctr["dividers"]]
    for f_, kind in sources:
        if kind is None:
            continue
        for l3 in geom_parts(f_.get("geometry"), polygons=False):
            if l3.shape[1] < 3 or len(l3) < 2:
                continue
            p = l3 - np.array([oE, oN, 0.0])
            ok = (p[:, 0] > gE0 + 2) & (p[:, 0] < gE1 - 2) & (p[:, 1] > gN0 + 2) & (p[:, 1] < gN1 - 2)
            # runs of vertices inside the grid
            pieces, cur = [], []
            for k in range(len(p)):
                if ok[k]:
                    if not cur or np.hypot(*(p[k, :2] - cur[-1][:2])) >= 0.25:
                        cur.append(p[k])
                else:
                    if len(cur) >= 2:
                        pieces.append(np.array(cur))
                    cur = []
            if len(cur) >= 2:
                pieces.append(np.array(cur))
            for q in pieces:
                if float(np.hypot(*np.diff(q[:, :2], axis=0).T).sum()) < 2.0:
                    n_short += 1
                    continue
                # vertex normals in plan
                d_ = np.gradient(q[:, :2], axis=0)
                d_ /= np.maximum(np.hypot(d_[:, 0], d_[:, 1]), 1e-9)[:, None]
                nrm = np.stack([d_[:, 1], -d_[:, 0]], axis=1)
                free = kind in ("masonry", "fence")
                off = 0.6 if free else (1.0 if kind == "terrace" else 1.5)   # fasce are often < 2 m deep
                gA = ground(q[:, 0] + off * nrm[:, 0], q[:, 1] + off * nrm[:, 1])
                gB = ground(q[:, 0] - off * nrm[:, 0], q[:, 1] - off * nrm[:, 1])
                hi, lo = np.maximum(gA, gB), np.minimum(gA, gB)
                z = q[:, 2].copy()
                if free:
                    top = np.full(len(q), -np.inf)
                    for o_ in (-0.5, 0.0, 0.5):
                        r_ = np.clip(np.floor((gN1 - (q[:, 1] + o_ * nrm[:, 1])) / cell).astype(int), 0, rows - 1)
                        c_ = np.clip(np.floor((q[:, 0] + o_ * nrm[:, 0] - gE0) / cell).astype(int), 0, cols - 1)
                        top = np.maximum(top, dtm[r_, c_] + h[r_, c_])
                    seen = top - hi
                    dflt = 1.0 if kind == "masonry" else 1.5
                    z = hi + np.where(seen >= 0.4, np.minimum(seen, 2.5), dflt)
                    n_fix += int((seen < 0.4).sum())
                else:
                    bad = (z < lo - 0.3) | (z > hi + 2.5)
                    if bad.any():
                        n_fix += int(bad.sum())
                        z[bad] = hi[bad] + 0.15
                hgt = z - (hi if free else lo)
                lo_, hi_ = {"retaining": (0.4, 9.0), "terrace": (0.4, 6.0), "masonry": (0.5, 4.0),
                            "fence": (0.8, 3.0)}[kind]
                hm = float(np.clip(np.median(hgt), lo_, hi_))
                k_ = kind
                if kind == "masonry":
                    mid = q[len(q) // 2, :2]
                    dd, ii = route["tree"].query(mid)
                    beyond = dd - route["hw"][ii]
                    if -0.3 <= beyond <= 2.5:
                        road = float(np.interp(route["s"][ii], route["rs"], route["elev"]))
                        rp = route["pts"][ii]
                        away = (mid - rp) / max(np.hypot(*(mid - rp)), 1e-6)
                        behind = float(ground(mid[0] + 1.5 * away[0], mid[1] + 1.5 * away[1]))
                        if 0.3 <= float(np.median(z)) - road <= 1.4 and behind < road - 0.5:
                            k_ = "parapet"
                            n_par += 1
                walls.append({"kind": k_, "points": np.column_stack([q[:, :2], z]), "heightM": round(hm, 1)})
                n_by[k_] = n_by.get(k_, 0) + 1
    if walls:
        L = {}
        for w in walls:
            L[w["kind"]] = L.get(w["kind"], 0.0) + float(np.hypot(*np.diff(w["points"][:, :2], axis=0).T).sum())
        hh = {k: np.median([w["heightM"] for w in walls if w["kind"] == k]) for k in n_by}
        log(f"[walls] {len(walls)} CTR walls {n_by} ({', '.join(f'{k} {v / 1000:.1f} km' for k, v in L.items())}); "
            f"median height " + ", ".join(f"{k} {v:.1f} m" for k, v in hh.items())
            + f"; {n_fix} crest points put back on the LiDAR ground (or with no wall in the DSM), {n_short} pieces "
              f"< 2 m dropped, "
              f"{n_par} masonry walls at the road edge taken as parapets")
    return walls


def simplify_line(p: np.ndarray, tol: float) -> np.ndarray:
    """Douglas-Peucker."""
    if len(p) < 3:
        return p
    keep = np.zeros(len(p), bool)
    keep[0] = keep[-1] = True
    stack = [(0, len(p) - 1)]
    while stack:
        a, b = stack.pop()
        if b - a < 2:
            continue
        ab = p[b] - p[a]
        L = math.hypot(*ab)
        seg = p[a + 1:b] - p[a]
        d = np.abs(seg[:, 0] * ab[1] - seg[:, 1] * ab[0]) / L if L > 1e-9 else np.hypot(seg[:, 0], seg[:, 1])
        k = int(np.argmax(d))
        if d[k] > tol:
            keep[a + 1 + k] = True
            stack += [(a, a + 1 + k), (a + 1 + k, b)]
    return p[keep]


def mask_rings(mask: np.ndarray, gE0: float, gN1: float, cell: float, min_area: float, tol: float = 1.5) -> list:
    """Outer outlines of a cell mask as CCW rings in local metres (holes dropped), smoothed and simplified."""
    import contourpy
    from scipy import ndimage as ndi
    rows, cols = mask.shape
    z = ndi.gaussian_filter(np.pad(mask.astype(np.float32), 2), 1.2)
    x = gE0 + (np.arange(-2, cols + 2) + 0.5) * cell
    y = gN1 - (np.arange(-2, rows + 2) + 0.5) * cell
    cg = contourpy.contour_generator(x, y, z, fill_type="OuterOffset")
    polys, offs = cg.filled(0.5, 10.0)
    out = []
    for pts, off in zip(polys, offs):
        outer = pts[off[0]:off[1]]
        if len(outer) < 4:
            continue
        rg = clip_polygon_rect(simplify_line(np.vstack([outer, outer[:1]]), tol)[:-1], gE0, gN1 - rows * cell,
                               gE0 + cols * cell, gN1)
        rg = clean_ring(rg) if len(rg) >= 3 else None
        if rg is not None and abs(signed_area(rg)) >= min_area:
            out.append(rg)
    return out


def med_tree_kinds(h_top, crown_r, flat, dark, lu_at, woods_at) -> list:
    """Species for the Riviera's trees from what the data can tell (else None: the app picks by its planting
    zones, the landuse and the crown's shape).

      cypress       a narrow, dark column: >= 6 m tall, crown radius <= 1.8 m, height >= 4 x the radius,
                    <= 0.85 of the open ground's brightness;
      pine          in the CTR's pine woods (Bosco, Conifere/Pini), or >= 12 m with a crown clearly darker
                    than the ground round it (Aleppo and maritime pines) away from gardens;
      umbrellaPine  >= 9 m, a crown radius >= 0.36 x the height, flat-topped (>= 30 % of the crown within
                    15 % of the top) and dark: the stone pines of the sanctuary park and the ridge;
      olive         <= 10 m in an olive grove (CTR Uliveti, OSM orchard), or <= 7 m with a crown >= 1.2 m
                    and not dark (silver-green) on the terraces and among the greenhouses.
    Palms are not guessed here: a Phoenix's crown from the 1 m LiDAR looks like any other round crown."""
    kinds = []
    for k in range(len(h_top)):
        hh, rr, lu = float(h_top[k]), float(crown_r[k]), lu_at[k]
        if hh >= 6.0 and rr <= 1.8 and hh >= 4.0 * rr and dark[k] <= 0.85:
            kinds.append("cypress")
        elif woods_at[k]:
            kinds.append("pine")
        elif hh >= 9.0 and rr >= 0.36 * hh and flat[k] >= 0.30 and dark[k] <= 0.85:
            kinds.append("umbrellaPine")
        elif lu == "olive" and hh <= 10.0:
            kinds.append("olive")
        elif lu in ("terraces", "greenhouse") and hh <= 7.0 and rr >= 1.2 and dark[k] > 0.8:
            kinds.append("olive")
        elif hh >= 12.0 and dark[k] <= 0.8 and lu not in ("residential", "garden"):
            kinds.append("pine")
        else:
            kinds.append(None)
    return kinds


# ---------------------------------------------------------------------------
# Build
# ---------------------------------------------------------------------------

VEG_EXG_SUMMER = 0.0   # chromatic excess green above this = vegetation in the 2024 summer ortho


def build(course_id: str, render: bool = True, out_root: Path | None = None) -> int:
    from pyproj import Transformer
    from scipy import ndimage as ndi
    from scipy.spatial import cKDTree
    from PIL import Image, ImageDraw

    cfg = COURSES[course_id]
    cache = CACHE_ROOT / course_id
    # --out-root: read the course folder as usual, write scenery.json and the debug files elsewhere.
    src = OUT_ROOT / course_id
    dbg = (out_root / "debug" / course_id) if out_root else DEBUG_ROOT / course_id
    out = (out_root / "Courses" / course_id) if out_root else src
    pipe = PIPELINE_ROOT / course_id
    for p in (cache, dbg, out):
        p.mkdir(parents=True, exist_ok=True)
    log_lines: list[str] = []

    def log(msg: str):
        print(msg, flush=True)
        log_lines.append(msg)

    course = json.loads((src / "course.json").read_text())
    # The course's projected CRS: Lambert 72 in Flanders (origin.lambert72), else origin.crs / origin.projected.
    crs = course["origin"].get("crs", "EPSG:31370")
    oE72, oN72 = course["origin"].get("projected") or course["origin"]["lambert72"]
    ctr_mode = cfg.get("buildings") == "ctr"
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
    dtm = load_u16(src / nh["file"], nh)
    chm = load_u16(src / ch["file"], ch)
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
    if ctr_mode:
        # Roof colour on the Riviera: chromatic warmth (r - b) / (r + g + b) tells terracotta tiles from roof
        # terraces, and brightness (0-1) and colourfulness (max - min) / max tell plastic film from glass.
        s_ = ortho_cell.sum(axis=-1) + 1e-3
        photo = {"veg": veg, "bright": bright / 255.0,
                 "warm": (ortho_cell[..., 0] - ortho_cell[..., 2]) / s_,
                 "sat": (ortho_cell.max(axis=-1) - ortho_cell.min(axis=-1)) / np.maximum(ortho_cell.max(axis=-1), 1.0)}
        del s_
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
    to72 = Transformer.from_crs("EPSG:4326", crs, always_xy=True)
    to84 = Transformer.from_crs(crs, "EPSG:4326", always_xy=True)
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
    landuse_map = LANDUSE_MAP | cfg.get("landuse_extra", {})
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
                lk = landuse_map.get((key, t[key]))
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
    off_grade = {"tunnel": 0, "deck": 0}
    for t, wid, g in roads_raw:
        if ctr_mode and wid not in route_way_ids:
            # The app drapes side roads on the terrain, so a way that is not at grade cannot be drawn. Under
            # the Poggio the Aurelia Bis (SS1bis) runs in tunnel right beneath the summit loop (OSM tunnel=yes,
            # layer=-1), and the coast cycleway uses the old railway tunnels: drop ways in a tunnel, under
            # cover or below ground. Bridges go where the deck stands off the ground: always for viaducts,
            # and for other bridges where the LiDAR DSM First stands >= 2.5 m over the DTM along the median
            # metre of the way (the SS1bis junction ramps east of the town, 4.5-9 m up; a culvert bridge on
            # a lane reads ~0).
            if (t.get("tunnel") in ("yes", "building_passage", "culvert") or t.get("covered") == "yes"
                    or (_num(t.get("layer")) or 0.0) < 0):
                off_grade["tunnel"] += 1
                continue
            if t.get("bridge") not in (None, "no"):
                bd, _ = densify(g, 1.0)
                br, bc = cell_of(bd[:, 0], bd[:, 1])
                inside = (bd[:, 0] >= gE0) & (bd[:, 0] < gE1) & (bd[:, 1] >= gN0) & (bd[:, 1] < gN1)
                if t["bridge"] == "viaduct" or (inside.any() and np.median(h[br[inside], bc[inside]]) >= 2.5):
                    off_grade["deck"] += 1
                    continue
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
        f"(route ways trimmed to the parts beyond the ride)"
        + (f"; dropped {off_grade['tunnel']} ways in tunnel/below ground and {off_grade['deck']} raised "
           f"bridge decks" if ctr_mode else ""))

    # ---------------- buildings ----------------
    if ctr_mode:
        # Footprints from the Liguria CTR 3D (Edificato with its eaves, Manufatto: greenhouses, sheds,
        # cisterns), heights from the LiDAR checked against the eaves, OSM for its tags (ctr_buildings).
        ctr = {k: fetch_wfs(cache, cfg["ctr"]["url"], cfg["ctr"][k], crs, cfg["ctr"]["box"], log)
               for k in ("buildings", "structures", "walls", "dividers", "trees", "crops", "woods")}
        log("[ctr] " + ", ".join(f"{cfg['ctr'][k]} {len(v)}" for k, v in ctr.items()) + " features in the box")
        buildings, bmask = ctr_buildings(ctr, buildings_raw, oE72, oN72, (gE0, gN1, cell, rows, cols), dtm, h,
                                         photo, log, cfg.get("ctr_gone"))
        if cfg.get("footprint_clear_m"):
            # Nothing stands on the ride's carriageway or in its gutter (both legs of a hairpin and of the
            # summit loop count: the whole route is in rtree).
            n_st = {"clear": 0, "clipped": 0, "kept": 0}
            for b_ in buildings:
                b_["ring"], st_ = clear_of_carriageway(b_["ring"], rtree, rdense, rdense_hw, cfg["footprint_clear_m"])
                n_st[st_] += 1
                if st_ == "kept":
                    log(f"[buildings] WARN {b_['kind']} at {_centroid(b_['ring']).round(1).tolist()} could not be "
                        f"pulled {cfg['footprint_clear_m']} m clear of the carriageway")
            log(f"[buildings] pulled {n_st['clipped']} footprints back to {cfg['footprint_clear_m']} m outside the "
                f"ride's carriageway ({n_st['kept']} could not be)")
        (dbg / "scenery_buildings.json").write_text(json.dumps([
            {k: (round(v, 2) if isinstance(v, float) else v) for k, v in b_.items() if k != "ring"}
            | {"centroid": [round(float(x), 1) for x in _centroid(b_["ring"])]} for b_ in buildings], indent=1))
    else:
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

    # ---------------- walls and the Riviera's landuse (CTR) ----------------
    walls = []
    if ctr_mode:
        walls = ctr_walls(ctr, oE72, oN72, (gE0, gN1, cell, rows, cols), dtm, h,
                          {"tree": rtree, "hw": rdense_hw, "s": rsd, "rs": rs, "elev": np.array(R["elev"]),
                           "pts": rdense}, log)
        sea = dtm < course.get("sea", {}).get("levelM", 0.0) - 0.5
        n0 = len(landuse)
        # The CTR's olive groves (Colture agricole: Uliveti) and pine woods (Bosco: Conifere, Pini).
        woods_rings = []
        for key, kind_, want in (("crops", "olive", ("definizione", "Uliveti")), ("woods", "forest", None)):
            for f_ in ctr[key]:
                pr = f_.get("properties") or {}
                if want and pr.get(want[0]) != want[1]:
                    continue
                for r3 in geom_parts(f_.get("geometry"), polygons=True):
                    c = clip_polygon_rect(r3[:-1, :2] - np.array([oE72, oN72]), *rect)
                    ring = clean_ring(c) if len(c) >= 3 else None
                    if ring is not None:
                        landuse.append({"kind": kind_, "ring": ring, "osm": None})
                        if key == "woods" and pr.get("def_essenze") == "Pini":
                            woods_rings.append(ring)
        # Gardens round the villas: within 12 m of a house, closed over 8 m gaps (OSM maps two residential
        # areas here; the plants and the ground maps need the gardens).
        houses = np.zeros((rows, cols), bool)
        for b in buildings:
            if b["kind"] in ("house", "church", "chapel") and b["area"] >= 30:
                rr_, cc_ = cells_in_polygon(b["ring"], gE0, gN1, cell, rows, cols)
                houses[rr_, cc_] = True
        gard = ndi.binary_closing(ndi.binary_dilation(houses, structure=disk(12.0 / cell)), structure=disk(8.0 / cell))
        gard &= ~sea
        for ring in mask_rings(gard, gE0, gN1, cell, min_area=600.0):
            landuse.append({"kind": "residential", "ring": ring, "osm": None})
        # Terraced slopes (fasce): within 6 m of the CTR's agricultural terrace walls, closed over 10 m.
        terr = np.zeros((rows, cols), bool)
        for w in walls:
            if w["kind"] == "terrace":
                dp, _ = densify(w["points"][:, :2], 0.5)
                r_, c_ = cell_of(dp[:, 0], dp[:, 1])
                terr[r_, c_] = True
        terr = ndi.binary_closing(ndi.binary_dilation(terr, structure=disk(6.0 / cell)), structure=disk(10.0 / cell))
        terr &= ~sea
        for ring in mask_rings(terr, gE0, gN1, cell, min_area=1500.0):
            landuse.append({"kind": "terraces", "ring": ring, "osm": None})
        del houses, gard, terr
        # The app takes the first polygon that holds a point: the specific kinds first, the derived gardens
        # and terraces last.
        rank = {"greenhouse": 0, "olive": 1, "forest": 2, "scrub": 3, "garden": 4, "grass": 5, "farmland": 6,
                "orchard": 6, "meadow": 6}
        landuse.sort(key=lambda l_: (rank.get(l_["kind"], 7), l_["osm"] is None and l_["kind"] == "terraces"))
        lk_n = {}
        for l_ in landuse:
            lk_n[l_["kind"]] = lk_n.get(l_["kind"], 0) + 1
        log(f"[landuse] {len(landuse) - n0} CTR / derived rings added (olive groves, pine woods, gardens within 12 m "
            f"of a house, terraced slopes within 6 m of a terrace wall); landuse now {lk_n}")

    # ---------------- trees ----------------
    if cfg.get("winter_ortho"):
        wdate = fetch_winter_date(cache, cfg["winter_ortho"], oE72, oN72, log)
        log(f"[trees] newest 'winter' mosaic flown {wdate or '?'} at the course: in leaf in late April, so it cannot "
            f"separate evergreens; no other conifer signal -> all trees 'deciduous'")
    # The LiDAR was flown leaf-off (25/1/2015): deciduous crowns are full of pits where pulses went
    # through the bare branches. A grey closing (r = 2 m) gives a pit-free canopy model (it fills
    # holes narrower than ~3 m but keeps crown outlines), then a light Gaussian. (The Poggio's evergreen
    # crowns, flown in leaf, need only a light fill: r 1 m keeps a row of cypresses apart.)
    hf = ndi.grey_closing(h, footprint=disk(cfg.get("pit_fill_r", PIT_FILL_R) / cell),
                          mode="nearest").astype(np.float32)
    hs = ndi.gaussian_filter(hf, CHM_SMOOTH_SIGMA / cell).astype(np.float32)
    if cfg.get("crown_allometry") == "mediterranean":
        # Olives, holm oaks and pines spread wider for their height than a beech: CW = 2.0 + 0.35 h
        # (an olive 5 m tall ~3.8 m across, a stone pine 15 m ~7 m), within the same radius bins.
        cw = 2.0 + 0.35 * hs
    else:
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
    if ctr_mode:
        # The 2008-2010 LiDAR still holds greenhouses and sheds pulled down since, and the CTR misses a few:
        # a top 2.5-6.5 m high whose crown is over 30 m2 and mostly within 0.4 m of the top is a roof, not a tree.
        ncell = np.maximum(area / (cell * cell), 1)
        top_lab = top_hs[np.clip(lbl - 1, 0, npk - 1)]
        level = np.bincount(lbl[in_crown & (hs >= top_lab - 0.4)], minlength=npk + 1)[1:] / ncell
        flat15 = np.bincount(lbl[in_crown & (hs >= 0.85 * top_lab)], minlength=npk + 1)[1:] / ncell
        # Crown brightness against the open ground round it (bare or grassy, no building, not the sea: 31 m,
        # or 101 m inside a wood): in this photo green does not tell a crown from the dry ground (ExG on
        # open ground p50 0.07, on crowns 0.04), shade does. Kept crowns 0.6-1.0 (p50 0.82), open ground
        # 0.76-1.22 (p10-p90).
        open_g = ((h < 0.5) & ~bmask & (dtm > course.get("sea", {}).get("levelM", 0.0) - 0.5)).astype(np.float32)
        ref_b = ndi.uniform_filter(bright, size=101, mode="nearest")
        for size, min_share in ((101, 0.05), (31, 0.1)):
            den = ndi.uniform_filter(open_g, size=size, mode="nearest")
            num = ndi.uniform_filter(bright * open_g, size=size, mode="nearest")
            ref_b = np.where(den > min_share, num / np.maximum(den, 1e-3), ref_b)
        del open_g, den, num
        dark = (np.bincount(lbl[in_crown], weights=bright[in_crown], minlength=npk + 1)[1:] / ncell
                / np.maximum(np.bincount(lbl[in_crown], weights=ref_b[in_crown], minlength=npk + 1)[1:] / ncell, 1.0))
        del top_lab
        drop((area > 30.0) & (top_hs < 6.5) & (level > 0.6), "flat roof-like top (greenhouse/shed in the 2008-10 LiDAR)")
        # ExG does not separate crowns from the ground in this photo; a crown felled since 2008-2010 is no
        # darker than the ground round it.
        log(f"[trees] crown brightness / open ground round it: p10/p50/p90 "
            + "/".join(f"{v:.2f}" for v in np.percentile(dark[keep], [10, 50, 90])))
        drop(dark > 0.95, "crown no darker than the open ground round it in the 2022 ortho (felled since the LiDAR)")
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
    if cfg.get("tree_species") == "riviera" and trees:
        # Species where the data can tell (med_tree_kinds); the rest are left to the app ("kind" omitted).
        lu_img = Image.new("I", (cols, rows), 0)
        dr_ = ImageDraw.Draw(lu_img)
        lu_kinds = sorted({l_["kind"] for l_ in landuse})
        for l_ in reversed(landuse):    # the first polygon holding a point wins, as in the app
            dr_.polygon([((x - gE0) / cell, (gN1 - y) / cell) for x, y in l_["ring"]], fill=lu_kinds.index(l_["kind"]) + 1)
        lu_r = np.asarray(lu_img, np.int32)
        wd_img = Image.new("L", (cols, rows), 0)
        dw_ = ImageDraw.Draw(wd_img)
        for ring in woods_rings:
            dw_.polygon([((x - gE0) / cell, (gN1 - y) / cell) for x, y in ring], fill=1)
        wd_r = np.asarray(wd_img) > 0
        tr_, tc_ = cell_of([t["e"] for t in trees], [t["n"] for t in trees])
        lu_at = [lu_kinds[v - 1] if v > 0 else None for v in lu_r[tr_, tc_]]
        kinds_ = med_tree_kinds([t["heightM"] for t in trees], [t["crownRadiusM"] for t in trees], flat15[kidx],
                                dark[kidx], lu_at, wd_r[tr_, tc_])
        for t, k_ in zip(trees, kinds_):
            if k_:
                t["kind"] = k_
            else:
                del t["kind"]
        del lu_img, lu_r, wd_img, wd_r
        cnt = {}
        for k_ in kinds_:
            cnt[k_ or "(app picks)"] = cnt.get(k_ or "(app picks)", 0) + 1
        # The CTR's surveyed single trees (2007/2013) against the LiDAR's crowns.
        ctr_t = np.array([c[:2] for f_ in ctr["trees"] for c in [((f_.get("geometry") or {}).get("coordinates") or [])]
                          if len(c) >= 2], np.float64).reshape(-1, 2) - np.array([oE72, oN72])
        ins = (ctr_t[:, 0] > gE0) & (ctr_t[:, 0] < gE1) & (ctr_t[:, 1] > gN0) & (ctr_t[:, 1] < gN1)
        if ins.any():
            dct, _ = cKDTree(np.array([[t["e"], t["n"]] for t in trees])).query(ctr_t[ins])
            log(f"[trees] species {cnt}; CTR single trees in the grid: {int(ins.sum())}, "
                f"{int((dct < 3.0).sum())} within 3 m of a LiDAR tree kept here")
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
    if ctr_mode:
        # The Poggio's photo is green-tinted all over (ExG on open ground p50 0.07, on crowns 0.04), so a
        # shrub is low canopy clearly darker than the open ground round it (< 0.88 of it, as for the crowns
        # above; low canopy runs 0.67-1.25, kept shrubs 0.59-0.89). Not along the walls (the
        # LiDAR ground rounds their steps off, which leaves 0.6-3 m "canopy" at every crest), and not in flat
        # slabs (greenhouses and sheds standing in 2008-2010, gone since: > 25 cells within a 0.3 m spread).
        wall_m = np.zeros((rows, cols), bool)
        for w in walls:
            if w["kind"] != "fence":
                dp, _ = densify(w["points"][:, :2], 0.5)
                wall_m[cell_of(dp[:, 0], dp[:, 1])] = True
        wall_m = ndi.binary_dilation(wall_m, structure=disk(0.8 / cell))
        vegd = bright < 0.88 * ref_b
        shrub_ok = ((hf >= SHRUB_MIN_H) & (hf < SHRUB_MAX_H) & vegd & ~bmask_d & ~road_mask & ~crown_cells
                    & ~wall_m)
        slab, nsl = ndi.label((hf >= SHRUB_MIN_H) & (hf < SHRUB_MAX_H) & ~crown_cells, structure=np.ones((3, 3)))
        idx = np.arange(1, nsl + 1)
        n_ = ndi.sum(np.ones_like(hf), slab, idx)
        sd_ = np.sqrt(np.maximum(ndi.mean(hf * hf, slab, idx) - ndi.mean(hf, slab, idx) ** 2, 0))
        flat_lab = np.concatenate([[False], (n_ > 25) & (sd_ < 0.3)])
        n_slab = int(flat_lab.sum())
        shrub_ok &= ~flat_lab[slab]
        del wall_m, vegd, slab, idx, n_, sd_, flat_lab, ref_b
        log(f"[shrubs] Riviera: vegetation = darker than the ground round it; {n_slab} flat slabs (old greenhouses, "
            f"sheds) and the cells within 0.8 m of a wall left out")
    else:
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
    far_lat = None
    if cfg.get("shrub_far"):
        # Beyond `far_m` from the ride only every other lattice point in each direction (twice the spacing),
        # the shrubs grown to cover the same ground: what keeps a 3.5 km2 grid's scenery.json under 4 MB.
        far_m = cfg["shrub_far"]
        dfar, _ = rtree.query(np.stack([SE.ravel(), SN.ravel()], axis=1), k=1, distance_upper_bound=far_m)
        ii, jj = np.meshgrid(np.arange(len(sn)), np.arange(len(se)), indexing="ij")
        coarse = ((ii % 2 == 0) & (jj % 2 == 0)).ravel()
        far_lat = ~np.isfinite(dfar)
        n_thin = int((sel & far_lat & ~coarse).sum())
        sel &= ~far_lat | coarse
        far_lat = far_lat[sel]
        del dfar, ii, jj, coarse
        log(f"[shrubs] beyond {far_m:.0f} m from the ride on a {2 * SHRUB_SPACING} m lattice ({n_thin} points thinned)")
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
        if far_lat is not None and far_lat[k]:
            rad_ = float(np.clip(0.7 + 0.3 * hh, 0.9, 1.6))
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
                       "kind": b["kind"], "groundElevM": b["groundElevM"]}
                      | ({k: b[k] for k in ("eavesM", "levels") if b.get(k) is not None} if ctr_mode else {})
                      for b in buildings],
        "trees": trees,
        "shrubs": shrubs,
        "landuse": [{"kind": l["kind"], "ring": pts(l["ring"])} for l in landuse],
        "roads": [{**({"name": r["name"]} if r["name"] else {}), "widthM": r["widthM"], "surface": r["surface"],
                   "points": pts(r["points"])} for r in roads],
        "fences": [{"kind": f_["kind"], "points": pts(f_["points"])} for f_ in fences],
        "water": [{"kind": w["kind"], "points": pts(w["points"]), "closed": w["closed"]} for w in water],
    }
    if walls:
        scen["walls"] = [{"kind": w["kind"], "points": [[round(float(x), 1), round(float(y), 1), round(float(z), 1)]
                                                        for x, y, z in w["points"]], "heightM": w["heightM"]}
                         for w in walls]
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
               water=water, trees=trees, shrubs=shrubs, oh=oh, walls=walls, zooms_s=cfg.get("debug_zooms_s"))
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
                    "fences": ("[Fence]", True), "water": ("[Water]", True), "walls": ("[Wall]", True)},
    "Building": {"ring": ("[[num]]", False), "heightM": ("num", False), "roofShape": ("str", True),
                 "kind": ("str", True), "groundElevM": ("num", True), "eavesM": ("num", True), "levels": ("int", True)},
    "Tree": {"e": ("num", False), "n": ("num", False), "heightM": ("num", False), "crownRadiusM": ("num", False),
             "kind": ("str", True)},
    "Shrub": {"e": ("num", False), "n": ("num", False), "heightM": ("num", False), "radiusM": ("num", False)},
    "Landuse": {"kind": ("str", False), "ring": ("[[num]]", False)},
    "Road": {"name": ("str", True), "widthM": ("num", True), "surface": ("str", True), "points": ("[[num]]", False)},
    "Fence": {"kind": ("str", False), "points": ("[[num]]", False)},
    "Water": {"kind": ("str", False), "points": ("[[num]]", False), "closed": ("bool", True)},
    "Wall": {"kind": ("str", False), "points": ("[[num]]", False), "heightM": ("num", True)},
}
ENUMS = {
    ("Building", "roofShape"): {"gabled", "hipped", "flat", "unknown", "sawtooth", "tunnel"},
    ("Building", "kind"): {"house", "farm", "barn", "church", "chapel", "other", "greenhouse", "cistern"},
    ("Tree", "kind"): {"deciduous", "conifer", "pine", "umbrellaPine", "cypress", "palm", "fanPalm", "olive",
                       "araucaria"},
    ("Landuse", "kind"): {"farmland", "meadow", "forest", "residential", "orchard", "scrub", "grass",
                          "greenhouse", "olive", "terraces", "garden"},
    ("Road", "surface"): {"asphalt", "cobbles", "gravel", "unpaved"},
    ("Fence", "kind"): {"fence", "wall", "hedge"},
    ("Water", "kind"): {"stream", "pond"},
    ("Wall", "kind"): {"retaining", "terrace", "masonry", "parapet", "fence"},
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
    for key in ("roads", "fences", "water", "walls"):
        for k, item in enumerate(d.get(key, [])):
            if len(item["points"]) < 2:
                errs.append(f"{key}[{k}]: fewer than 2 points")
            if not all(inside(p) for p in item["points"]):
                errs.append(f"{key}[{k}]: leaves the near grid")
            if key == "walls" and any(len(p) != 3 for p in item["points"]):
                errs.append(f"walls[{k}]: points must be [east, north, crest elevation]")
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
    intr, gaps = [], []
    for b_ in d.get("buildings", []):
        rg = np.array(b_["ring"], float)
        dp, _ = densify(np.vstack([rg, rg[:1]]), 0.25)
        dd, ii = tr.query(dp)
        inside_pts = MPath(np.vstack([rg, rg[:1]])).contains_points(dense[::5])
        m = float((dhw[ii] - dd).max())
        gaps.append(-m)
        if m > 0 or inside_pts.any():
            intr.append(max(m, 0.0) if not inside_pts.any() else 99.0)
    if intr:
        warns.append(f"{len(intr)} building footprints reach into the ride's carriageway "
                     f"(max {max(intr):.2f} m{' / centreline inside a footprint' if max(intr) >= 99 else ''})")
    else:
        log("[check] no building footprint reaches the ride's carriageway")
    if gaps:
        gaps = np.array(gaps)
        log(f"[check] buildings: min clearance from the carriageway edge {gaps.min():.2f} m; "
            f"{int((gaps < 0.3).sum())} within 0.3 m, {int((gaps < 1.0).sum())} within 1 m")
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
                  "orchard": "#d36bd3", "scrub": "#9a7b3c", "residential": "#ff7f50", "greenhouse": "#e0f4ff",
                  "olive": "#b5c27a", "terraces": "#d8a050", "garden": "#59e0a0"}
WALL_COLORS = {"retaining": "#ff9a00", "terrace": "#ffd27a", "masonry": "#ff4fd8", "parapet": "#ffffff",
               "fence": "#9fd0ff"}


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
        for w in ctx.get("walls") or []:
            p = np.asarray(w["points"])
            ax.plot(p[:, 0], p[:, 1], color=WALL_COLORS[w["kind"]], lw=0.9 * lw)
        polys = [np.asarray(b["ring"]) for b in ctx["buildings"]]
        ecol = [{"greenhouse": "#00e5ff", "cistern": "#0040ff"}.get(b["kind"], "#ff2020") for b in ctx["buildings"]]
        ax.add_collection(PolyCollection(polys, facecolors="none", edgecolors=ecol, linewidths=1.0 * lw))
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
    if ctx.get("zooms_s"):   # per-course zooms at route s instead of the Koppenberg's forest and orchard
        zooms = [z for z in zooms if z[0] not in ("forest", "orchard")] + [
            (nm, float(np.interp(sv, s, route[:, 0])), float(np.interp(sv, s, route[:, 1])), 90, 60)
            for nm, sv in ctx["zooms_s"]]
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
          "fences \(s.fences?.count ?? -1), water \(s.water?.count ?? -1), walls \(s.walls?.count ?? -1)")
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
    ap.add_argument("--out-root", type=Path, default=None,
                    help="write scenery.json to DIR/Courses/<id>/ and the debug files to DIR/debug/<id>/ "
                         "(byte-identity checks); the course folder is read as usual")
    args = ap.parse_args(argv)
    rc = build(args.course, render=not args.no_render, out_root=args.out_root)
    if rc == 0 and args.swift_check and args.out_root is None:
        rc = swift_check(args.course)
    return rc


if __name__ == "__main__":
    sys.exit(main())
