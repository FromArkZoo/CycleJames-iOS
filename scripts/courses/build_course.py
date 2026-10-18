# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "tifffile", "pyproj", "pillow", "matplotlib", "scipy"]
# ///
"""Bake a CycleJames climb course from open data (see scripts/courses/FORMAT.md).

    uv run --script scripts/courses/build_course.py koppenberg   (or oudekwaremont, paterberg)

Sources (all fetched once and cached under scripts/courses/.cache/<id>/):
  * OpenStreetMap via Overpass  -> route centreline, surface, names
  * Digitaal Vlaanderen DHM Vlaanderen II (WCS, DTM + DSM 1 m, Lambert 72/TAW)
  * Digitaal Vlaanderen orthophoto mosaic (WMS, summer flight)

Outputs go to CycleJames/Resources/Courses/<id>/ (shipped in the app), the
raw aerial photo, which only build_scenery.py and
textures/bake_course_maps.py read, to scripts/courses/pipeline/<id>/, and
debug renders to scripts/courses/debug/<id>/. Everything downloaded is
treated as data only.

Memory: everything is float32 and tiled; the far grid is built one 1 km
tile at a time. Peak RSS is printed at the end.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import math
import os
import re
import resource
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import date
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[2]
CACHE_ROOT = REPO / "scripts" / "courses" / ".cache"
DEBUG_ROOT = REPO / "scripts" / "courses" / "debug"
OUT_ROOT = REPO / "CycleJames" / "Resources" / "Courses"
# Outputs the app never reads: the folder above is a folder reference, so
# everything in it ships. See FORMAT.md, "Pipeline-only data".
PIPELINE_ROOT = REPO / "scripts" / "courses" / "pipeline"

USER_AGENT = "CycleJames-course-builder/1.0 (offline course baking; contact via repo owner)"

# ---------------------------------------------------------------------------
# Course configuration. Add more bergs here.
# ---------------------------------------------------------------------------
# ways: OSM way ids in race order; orientation is worked out from shared nodes.
# climb_start / climb_end: ("way_start"|"way_end", way_id) = first/last node of
#   that way in race direction.
# width_m: per-way carriageway width used when OSM has no width tag.
COURSES: dict[str, dict] = {
    "koppenberg": {
        "name": "Koppenberg",
        "region": "Melden, Oudenaarde · Flemish Ardennes",
        # Race order as in the Ronde van Vlaanderen 2025 roadbook (Flanders
        # Classics, women elite, version 10/03/2025): Berchemweg (N8) ->
        # Meldenstraat (2de afslag, left) -> Rotelenberg (right) ->
        # Steengat -> Koppenberg (x3) -> Rijksweg (N60).
        "ways": [
            121762002,  # Meldenstraat (from the N8 Berchemweg), asphalt
            25711648,   # Rotelenberg, asphalt
            175941336,  # Rotelenberg, sett
            86501824,   # Steengat, sett (foot of the climb)
            509660327,  # Steengat, sett
            370297724,  # Koppenberg, sett (the cobbled ramp)
            143078350,  # Koppenberg, asphalt (summit plateau); the trimmed route ends inside this way
            370301194,  # Koppenberg, asphalt: only extends the chain past exit_m (not on the shipped route);
                        # kept so the cached Overpass query (keyed on these ids) stays valid
        ],
        "climb_start": ("way_start", 86501824),  # Rotelenberg/Steengat junction
        "climb_end": ("way_end", 370297724),     # top of the cobbles (sett -> asphalt)
        "approach_m": 300.0,
        "exit_m": 200.0,
        "osm_bbox": (50.806, 3.558, 50.818, 3.592),  # S, W, N, E for side-road context
        # None of these ways has an OSM width tag and no published width was found.
        # Values come from the open data itself (see build_log.txt): paved-band width
        # across the 2024 summer / 2025 winter orthophotos where the road is open,
        # and the flat floor of the sunken lane in the 1 m DTM where it is not
        # (median 3.25 m, p10-p90 2.5-3.75 m at +0.25 m above the floor).
        "width_m": {
            121762002: 4.5,  # Meldenstraat: ~4 m asphalt + gutters (footpath on the left excluded)
            25711648: 4.5,   # Rotelenberg asphalt: ~4.5-5 m between houses
            175941336: 4.5,  # Rotelenberg sett: opens into a ~8 m paved junction area; carriageway kept at 4.5
            86501824: 3.5,   # Steengat sett: ~3.5-3.75 m paved band in both orthos
            509660327: 3.5,
            370297724: 3.5,  # Koppenberg sett: 3.25 m DTM floor in the sunken part, 3.5 m where open
            143078350: 3.0,  # Koppenberg asphalt summit lane: ~3 m paved band
            370301194: 3.0,
        },
        "default_width_m": 4.0,
        # Where the DTM rises inside the nominal carriageway (sunken-lane banks), narrow the
        # shipped widthM to the clear floor: half-width = distance from the centreline to the
        # first point where DTM > max(road elev, DTM at the centreline) + bank_tol_m, taken on
        # the nearer side (the app's ribbon is symmetric), then Gaussian-smoothed along s (sigma
        # 2 m). Never below min_width_m (the 1 m DTM blurs the bank toe by up to ~0.5 m per side,
        # so the real floor is if anything wider) and never above the nominal width. The elevation
        # profile is still sampled across the nominal width, so it does not depend on this.
        "bank_limit_width": True,
        "bank_tol_m": 0.15,
        "min_width_m": 2.5,
        # Only lanes this narrow are bank-limited: wider roads (the N36 at the Oude Kwaremont's
        # top) have ditches and verges, not sunken-lane banks, inside a nominal width.
        "bank_limit_max_nominal_m": 5.0,
        "surface_crr": {"asphalt": 0.0040, "cobbles": 0.0090},
        "near_margin_m": 250.0,
        "far_size_m": 5000.0,
        "far_cell_m": 10.0,
        "smooth_sigma_m": 6.0,
        "xy_smooth_sigma_m": 2.0,
        "low_percentile": 20.0,
        "despike_window_m": 7,       # Hampel half-window (stations) on the raw low-percentile profile
        "despike_min_m": 0.25,       # ... and minimum deviation treated as a spike
        # Shift the centreline into the sunken-lane floor only where the DTM shows
        # a clear U-trough (banks >= 1 m on both sides, floor <= 6 m wide).
        "refine_centreline": True,
        "refine_sigma_m": 8.0,
        "refine_max_m": 3.5,
        "validation_ortho": {  # leafless winter mosaic, debug renders only (not shipped)
            "service": "https://geo.api.vlaanderen.be/OMW/wms",
            "layer": "OMWRGB25VL",
            "m_per_px": 0.5,
        },
        "ortho": {
            "service": "https://geo.api.vlaanderen.be/OMZ/wms",
            "layer": "OMZRGB24VL",
            "vdc_layer": "OMZ24VL_vdc",
            "season": "summer",
            "year": 2024,
            "title": "Orthofotomozaïek, middenschalig, zomeropnamen, kleur, 2024, Vlaanderen",
            "m_per_px": 0.5,
        },
        "village": "Melden",
        "climb_start_name": "Koppenberg – foot of the Steengat",
        "summit_name": "Koppenberg – top of the cobbles",
        # Streets of the route in race order, for the OSM source note.
        "streets": "Meldenstraat, Rotelenberg, Steengat, Koppenberg",
        "roadbook": {
            "name": "Ronde van Vlaanderen 2025 roadmap (Flanders Classics)",
            "url": "https://oudenaarde.be/sites/default/files/2025-03/rvv-2025-roadmap-elite-vrouwen-fc.pdf",
            "retrieved": "2026-10-17",
            "notes": "Race direction and streets: Berchemweg (N8), Meldenstraat, Rotelenberg, Steengat, Koppenberg.",
        },
        # Data used by build_scenery.py for this course. The app shows attribution only from
        # course.json, so it is credited here. `cache_glob` dates the source by its cached download.
        "scenery_sources": [
            {"attribution": "Digitaal Vlaanderen – GRB Gebouw aan de grond (GBG), Modellicentie Gratis Hergebruik",
             "name": "GRB – Gebouw aan de grond (GRB:GBG), Digitaal Vlaanderen",
             "url": "https://geo.api.vlaanderen.be/GRB/wfs",
             "cache_glob": "wfs_GRB_GBG_*.json",
             "notes": "WFS 2.0.0 GetFeature, typeNames GRB:GBG, native Lambert 72 (EPSG:31370). Building "
                      "footprints in scenery.json (types, roof shape and height tags from OSM where matched). "
                      "Modellicentie Gratis Hergebruik."},
        ],
    },
}

# Pipeline tunables the other bergs share with the Koppenberg (see the comments above).
_SHARED = {k: COURSES["koppenberg"][k] for k in (
    "bank_limit_width", "bank_tol_m", "min_width_m", "bank_limit_max_nominal_m", "near_margin_m", "far_size_m", "far_cell_m",
    "smooth_sigma_m", "xy_smooth_sigma_m", "low_percentile", "despike_window_m", "despike_min_m",
    "refine_centreline", "refine_sigma_m", "refine_max_m", "validation_ortho", "ortho", "scenery_sources")}
_SURFACE_CRR = {"asphalt": 0.0040, "cobbles": 0.0090, "concrete": 0.0045}

COURSES["oudekwaremont"] = {
    **_SHARED,
    "name": "Oude Kwaremont",
    "region": "Kwaremont, Kluisbergen · Flemish Ardennes",
    # Race order from the Ronde van Vlaanderen 2025 roadmap (Flanders Classics, women elite,
    # version 10/03/2025): Brugzavel -> Broektestraat -> Kwaremontplein -> Schilderstraat ->
    # left onto Ronse Baan (N36) towards Lamontstraat and the Paterberg. The 2026 men's course
    # GPX (cyclingstage.com, from the 2026 road book) follows the same ways on the finale
    # passages; the first 2026 passage turned right on the N36 instead.
    "ways": [
        79620616,    # Broektestraat, asphalt, from the Brugzavel mini-roundabout (approach)
        1375368944,  # Broektestraat: starts at the right-left kink where the 2200 m climb begins
        1375368938,  # Broektestraat, asphalt
        31295044,    # Broektestraat, asphalt
        169091283,   # Broektestraat, asphalt
        660521414,   # Broektestraat, sett: the cobbles start, steepest part (holle weg)
        86501829,    # Broektestraat, sett
        1527496580,  # Broektestraat, sett
        1472108189,  # sett; OSM name Ommegangstraat, Broektestraat in the Wegenregister
        850884348,   # sett; Kwaremontplein (the square) in the Wegenregister
        25730689,    # sett; Kwaremontplein, then Schilderstraat
        1472108187,  # Schilderstraat, sett
        1472108188,  # Schilderstraat, sett: the cobbled false flat across open fields
        368750237,   # Schilderstraat, sett (Feelbosstraat junction)
        25730690,    # Schilderstraat, sett: upper hollow lane; the cobbles end at its last node
        1159118827,  # Schilderstraat, asphalt link to the N36: the race's 2200 m climb ends at its last node
        242724612,   # Ronse Baan (N36), asphalt (exit)
        313601768,   # Ronse Baan (N36), asphalt (exit; the trimmed route ends inside it)
    ],
    "climb_start": ("way_start", 1375368944),
    "climb_end": ("way_end", 1159118827),
    "approach_m": 300.0,
    "exit_m": 200.0,
    "osm_bbox": (50.762, 3.514, 50.795, 3.545),
    # No OSM width tags and no published widths. Medians of the surveyed carriageway edges in
    # GRB WGO ('rand van de rijbaan'), measured perpendicular to the OSM line every 5 m
    # (scripts/courses/.cache/oudekwaremont/research/), rounded to 0.25 m.
    "width_m": {
        79620616: 3.0, 1375368944: 3.5, 1375368938: 3.0, 31295044: 3.0, 169091283: 3.0,
        660521414: 3.25, 86501829: 3.25, 1527496580: 3.25, 1472108189: 3.25,
        850884348: 5.0,   # the square
        25730689: 5.25,   # Kwaremontplein through the village
        1472108187: 3.25, 1472108188: 3.5, 368750237: 3.75, 25730690: 3.25,
        1159118827: 3.75,
        # N36: two lanes and red cycle lanes, 9.9 m between the GRB carriageway edges.
        242724612: 9.75,
        313601768: 9.75,
    },
    "way_names": {1472108189: "Broektestraat", 850884348: "Kwaremontplein", 25730689: "Kwaremontplein"},
    # Way 25730689 turns from Kwaremontplein into Schilderstraat at the Kwaremontplein loop
    # junction (its middle node 4771542876), ~22 m before its end (Wegenregister).
    "name_breaks": {25730689: [(149.5, "Schilderstraat")]},
    # The DTM trough fit chases ditches and bank toes here; centre on the surveyed edges instead.
    "refine_centreline": False,
    "align_to_grb": True,
    "extra_sources": [
        {"name": "Wegenregister (Wegsegment), Digitaal Vlaanderen",
         "url": "https://geo.api.vlaanderen.be/Wegenregister/wfs",
         "retrieved": "2026-10-18",
         "notes": "Official street names for OSM ways 1472108189 (Broektestraat), 850884348 and the first "
                  "~150 m of 25730689 (Kwaremontplein), used for the junction landmarks. "
                  "Modellicentie Gratis Hergebruik."},
    ],
    "extra_attribution": ["Digitaal Vlaanderen – Wegenregister, Modellicentie Gratis Hergebruik"],
    "default_width_m": 3.25,
    "surface_crr": _SURFACE_CRR,
    "village": "Berchem",
    "climb_start_name": "Oude Kwaremont – start on the Broektestraat",
    "summit_name": "Oude Kwaremont – top at the N36",
    "streets": "Broektestraat, Kwaremontplein, Schilderstraat, Ronse Baan (N36)",
    "roadbook": {
        "name": "Ronde van Vlaanderen 2025 roadmap (Flanders Classics)",
        "url": "https://oudenaarde.be/sites/default/files/2025-03/rvv-2025-roadmap-elite-vrouwen-fc.pdf",
        "retrieved": "2026-10-18",
        "notes": "Race direction and streets: Brugzavel, Broektestraat, Kwaremontplein, Schilderstraat, Ronse Baan "
                 "(N36). Oude Kwaremont 2200 m, 4 % average, 11.6 % max, 1500 m of cobbles.",
    },
}

COURSES["paterberg"] = {
    **_SHARED,
    "name": "Paterberg",
    "region": "Kwaremont, Kluisbergen · Flemish Ardennes",
    # Race order from the Ronde van Vlaanderen 2025 roadmaps (Flanders Classics, men and women
    # elite, version 10/03/2025): Ronsebaan (N36) -> Lamontstraat -> Kalkhovenstraat ->
    # Middelloopstraat -> right onto Paterbergstraat -> left into Stooktestraat.
    "ways": [
        86501819,    # Middelloopstraat, asphalt: only orients the chain (before the route start)
        86501826,    # Middelloopstraat, asphalt (approach)
        369071618,   # Middelloopstraat, asphalt (approach, slight descent to the corner)
        31295027,    # Paterbergstraat, sett: the whole timed climb, junction to junction
        223598561,   # Stooktestraat, concrete (exit; the race turns left at the top)
        1472505832,  # Stooktestraat, concrete (exit; the trimmed route ends inside it)
    ],
    "climb_start": ("way_start", 31295027),  # Middelloopstraat corner, foot of the cobbles
    "climb_end": ("way_end", 31295027),      # Stooktestraat/Lamontstraat T-junction, top of the cobbles
    "approach_m": 300.0,
    "exit_m": 200.0,
    "osm_bbox": (50.774, 3.532, 50.792, 3.560),
    # GRB WGO carriageway edges every 10 m: Paterbergstraat median 3.53 m (p10-p90 3.47-3.62,
    # including the ~0.6 m concrete gutter on the left), Middelloopstraat 3.1 m, Stooktestraat 3.0 m.
    # Stooktestraat: the pale concrete band in the 2024 summer ortho is ~3.4 m, 3.0 m in GRB (2013).
    "width_m": {86501819: 3.0, 86501826: 3.0, 369071618: 3.25, 31295027: 3.5, 223598561: 3.25, 1472505832: 3.25},
    # The OSM line runs up to ~1 m off the cobbles (south at the foot's junction mouth, north
    # higher up); the DTM trough fit made the foot worse. Centre on the surveyed edges instead.
    "refine_centreline": False,
    "align_to_grb": True,
    "default_width_m": 3.25,
    "surface_crr": _SURFACE_CRR,
    "village": "Kwaremont",
    "climb_start_name": "Paterberg – foot of the cobbles",
    "summit_name": "Paterberg – top of the cobbles",
    "streets": "Middelloopstraat, Paterbergstraat, Stooktestraat",
    "roadbook": {
        "name": "Ronde van Vlaanderen 2025 roadmap (Flanders Classics)",
        "url": "https://oudenaarde.be/sites/default/files/2025-03/rvv-2025-roadmap-elite-mannen-fc_0.pdf",
        "retrieved": "2026-10-18",
        "notes": "Race direction and streets: Ronsebaan (N36), Lamontstraat, Kalkhovenstraat, Middelloopstraat, "
                 "Paterbergstraat, Stooktestraat. Paterberg 360 m, 12.9 % average, 20.3 % max, 360 m of cobbles.",
    },
}

DHMV_WCS = "https://geo.api.vlaanderen.be/DHMV/wcs"
DHMV_WMS = "https://geo.api.vlaanderen.be/DHMV/wms"
OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
]
COBBLE_SURFACES = {"sett", "cobblestone", "unhewn_cobblestone", "cobblestone:flattened", "paving_stones"}
CONCRETE_SURFACES = {"concrete", "concrete:plates", "concrete:lanes"}

# ---------------------------------------------------------------------------
# HTTP with cache + backoff
# ---------------------------------------------------------------------------


class FetchError(RuntimeError):
    pass


def _http(url: str, data: bytes | None = None, timeout: float = 180.0) -> tuple[int, dict, bytes]:
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
    """Return the cached body for `name`, fetching it (with retries) if absent."""
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


# ---------------------------------------------------------------------------
# OSM
# ---------------------------------------------------------------------------


def _overpass_ok(body: bytes, headers) -> bool:
    try:
        d = json.loads(body)
    except ValueError:
        return False
    return bool(d.get("elements")) and "error" not in str(d.get("remark", "")).lower()


def fetch_osm(cfg: dict, cache: Path, log) -> dict:
    s, w, n, e = cfg["osm_bbox"]
    ids = ",".join(str(i) for i in cfg["ways"])
    q = (f"[out:json][timeout:90];(way(id:{ids});way[\"highway\"]({s},{w},{n},{e}););out body geom;")
    key = hashlib.sha1(q.encode()).hexdigest()[:12]
    name = f"osm_{key}.json"
    body = None
    for ep in OVERPASS_ENDPOINTS:
        try:
            body = cached_fetch(cache, name, ep, data=urllib.parse.urlencode({"data": q}).encode(),
                                validate=_overpass_ok,
                                tries=4, log=log)
            break
        except FetchError as err:
            log(f"    overpass endpoint {ep} gave up: {err}")
    if body is None:
        raise FetchError("all Overpass endpoints failed")
    d = json.loads(body)
    d["_cache_file"] = name
    d["_query"] = q
    return d


@dataclass
class Chain:
    lat: np.ndarray
    lon: np.ndarray
    way_idx: np.ndarray        # index into cfg["ways"] for the segment starting at each vertex
    node_ids: list[int]
    ways: list[dict]
    way_first_vertex: list[int] = field(default_factory=list)
    way_last_vertex: list[int] = field(default_factory=list)


def build_chain(cfg: dict, osm: dict) -> Chain:
    by_id = {el["id"]: el for el in osm["elements"] if el["type"] == "way"}
    ways = []
    for wid in cfg["ways"]:
        if wid not in by_id:
            raise SystemExit(f"OSM way {wid} missing from Overpass result")
        ways.append(by_id[wid])
    oriented = []
    for k, w in enumerate(ways):
        nodes = list(w["nodes"])
        geom = [(p["lat"], p["lon"]) for p in w["geometry"]]
        if k == 0:
            nxt = ways[1]["nodes"]
            if nodes[-1] in (nxt[0], nxt[-1]):
                pass
            elif nodes[0] in (nxt[0], nxt[-1]):
                nodes, geom = nodes[::-1], geom[::-1]
            else:
                raise SystemExit(f"way {w['id']} does not touch way {ways[1]['id']}")
        else:
            prev_end = oriented[-1][0][-1]
            if nodes[0] == prev_end:
                pass
            elif nodes[-1] == prev_end:
                nodes, geom = nodes[::-1], geom[::-1]
            else:
                raise SystemExit(f"way {w['id']} is not connected to way {ways[k - 1]['id']}")
        oriented.append((nodes, geom))
    lat, lon, widx, nids, first, last = [], [], [], [], [], []
    for k, (nodes, geom) in enumerate(oriented):
        start = 0 if k == 0 else 1
        if k > 0:
            widx[-1] = k  # the joint vertex starts a segment of the new way
        first.append(len(lat) - (0 if k == 0 else 1))
        for j in range(start, len(nodes)):
            lat.append(geom[j][0]); lon.append(geom[j][1]); nids.append(nodes[j]); widx.append(k)
        last.append(len(lat) - 1)
    return Chain(np.array(lat), np.array(lon), np.array(widx), nids, ways, first, last)


# ---------------------------------------------------------------------------
# DHMV WCS (multipart/related: GML part + GeoTIFF part)
# ---------------------------------------------------------------------------


def parse_wcs_multipart(body: bytes):
    """Return (array float32 with NaN nodata, tiepoint x, tiepoint y, pixel size)."""
    import tifffile

    first = body.lstrip()[:200].split(b"\n", 1)[0].strip()
    if not first.startswith(b"--"):
        raise ValueError("not a multipart body")
    boundary = first[2:]
    end = body.rfind(b"--" + boundary + b"--")
    parts = body[:end if end > 0 else len(body)].split(b"--" + boundary)
    tif = None
    for p in parts:
        sep = p.find(b"\r\n\r\n")
        sep_len = 4
        if sep < 0:
            sep = p.find(b"\n\n"); sep_len = 2
        if sep < 0:
            continue
        hdr = p[:sep]
        if b"image/tiff" in hdr.lower():
            tif = p[sep + sep_len:]
            break
    if tif is None:
        raise ValueError("no image/tiff part")
    with tifffile.TiffFile(io.BytesIO(tif)) as tf:
        pg = tf.pages[0]
        a = pg.asarray().astype(np.float32, copy=False)
        tags = {t.name: t.value for t in pg.tags.values()}
    tp = tags["ModelTiepointTag"]
    sc = tags["ModelPixelScaleTag"]
    nod = float(tags.get("GDAL_NODATA", "-9999"))
    a = np.where(a <= nod + 1e-3, np.nan, a).astype(np.float32)
    a[a < -1000] = np.nan
    return a, float(tp[3]), float(tp[4]), (float(sc[0]), float(sc[1]))


def wcs_tile(cache: Path, cov: str, x0: int, x1: int, y0: int, y1: int, log) -> np.ndarray:
    """Native 1 m tile with NW corner (x0, y1); rows north->south."""
    url = (f"{DHMV_WCS}?service=WCS&version=2.0.1&request=GetCoverage&coverageId={cov}"
           f"&format=image/tiff&subset=x({x0},{x1})&subset=y({y0},{y1})")
    name = f"wcs_{cov}_x{x0}_{x1}_y{y0}_{y1}.bin"

    def ok(b, h):
        return b"image/tiff" in b[:20000]

    body = cached_fetch(cache, name, url, validate=ok, log=log)
    a, tx, ty, (sx, sy) = parse_wcs_multipart(body)
    if (abs(tx - x0) > 1e-6 or abs(ty - y1) > 1e-6 or abs(sx - 1) > 1e-9 or abs(sy - 1) > 1e-9
            or a.shape != (y1 - y0, x1 - x0)):
        raise RuntimeError(f"{name}: unexpected georeference tie=({tx},{ty}) scale=({sx},{sy}) shape={a.shape}")
    return a


def wcs_grid(cache: Path, cov: str, x0: int, x1: int, y0: int, y1: int, log, tile: int = 1000) -> np.ndarray:
    out = np.full((y1 - y0, x1 - x0), np.nan, dtype=np.float32)
    for ty0 in range(y0, y1, tile):
        ty1 = min(ty0 + tile, y1)
        for tx0 in range(x0, x1, tile):
            tx1 = min(tx0 + tile, x1)
            a = wcs_tile(cache, cov, tx0, tx1, ty0, ty1, log)
            out[(y1 - ty1):(y1 - ty0), (tx0 - x0):(tx1 - x0)] = a
            del a
    return out


def far_grid(cache: Path, x0: int, x1: int, y0: int, y1: int, cell: int, log, tile: int = 1000) -> np.ndarray:
    """Block-average the 1 m DTM to `cell` metres, one tile in memory at a time."""
    assert tile % cell == 0 and (x1 - x0) % cell == 0 and (y1 - y0) % cell == 0
    rows, cols = (y1 - y0) // cell, (x1 - x0) // cell
    out = np.full((rows, cols), np.nan, dtype=np.float32)
    n = 0
    for ty0 in range(y0, y1, tile):
        ty1 = min(ty0 + tile, y1)
        for tx0 in range(x0, x1, tile):
            tx1 = min(tx0 + tile, x1)
            n += 1
            log(f"    far tile {n}: x {tx0}-{tx1} y {ty0}-{ty1}")
            a = wcs_tile(cache, "DHMVII_DTM_1m", tx0, tx1, ty0, ty1, log)
            h, w = a.shape
            blk = a.reshape(h // cell, cell, w // cell, cell)
            valid = np.isfinite(blk).sum(axis=(1, 3))
            sums = np.nansum(blk, axis=(1, 3), dtype=np.float64)
            with np.errstate(invalid="ignore", divide="ignore"):
                m = np.where(valid >= (cell * cell) // 4, sums / np.maximum(valid, 1), np.nan).astype(np.float32)
            r0 = (y1 - ty1) // cell
            c0 = (tx0 - x0) // cell
            out[r0:r0 + m.shape[0], c0:c0 + m.shape[1]] = m
            del a, blk, m, sums, valid
    return out


def fill_nans(a: np.ndarray, max_iter: int = 200) -> tuple[np.ndarray, int]:
    """Fill NaN holes (e.g. under buildings) by nearest valid neighbour + light diffusion."""
    from scipy import ndimage

    mask = ~np.isfinite(a)
    n = int(mask.sum())
    if n == 0:
        return a, 0
    idx = ndimage.distance_transform_edt(mask, return_distances=False, return_indices=True)
    filled = a[tuple(idx)].astype(np.float32)
    # a few Jacobi iterations inside the holes to avoid terraces
    for _ in range(min(max_iter, 50)):
        sm = ndimage.uniform_filter(filled, size=3, mode="nearest")
        filled[mask] = sm[mask]
    del idx
    return filled, n


# ---------------------------------------------------------------------------
# Geometry helpers
# ---------------------------------------------------------------------------


def bilinear(grid: np.ndarray, origin_e: float, origin_n: float, cell: float, e, n):
    """Cell-centre bilinear sampling (same convention as HeightRaster.swift)."""
    e = np.asarray(e, dtype=np.float64)
    n = np.asarray(n, dtype=np.float64)
    fc = (e - origin_e) / cell - 0.5
    fr = (origin_n - n) / cell - 0.5
    rows, cols = grid.shape
    c0 = np.clip(np.floor(fc).astype(np.int64), 0, cols - 2)
    r0 = np.clip(np.floor(fr).astype(np.int64), 0, rows - 2)
    tx = np.clip(fc - c0, 0, 1)
    ty = np.clip(fr - r0, 0, 1)
    v00 = grid[r0, c0]; v10 = grid[r0, c0 + 1]; v01 = grid[r0 + 1, c0]; v11 = grid[r0 + 1, c0 + 1]
    top = v00 + (v10 - v00) * tx
    bot = v01 + (v11 - v01) * tx
    return top + (bot - top) * ty


def resample_polyline(x: np.ndarray, y: np.ndarray, step: float):
    d = np.hypot(np.diff(x), np.diff(y))
    s = np.concatenate([[0.0], np.cumsum(d)])
    ss = np.arange(0.0, s[-1] + 1e-9, step)
    return ss, np.interp(ss, s, x), np.interp(ss, s, y), s


def gaussian1d(v: np.ndarray, sigma_samples: float) -> np.ndarray:
    from scipy.ndimage import gaussian_filter1d
    return gaussian_filter1d(v.astype(np.float64), sigma_samples, mode="nearest")


def tangents(e: np.ndarray, n: np.ndarray, half: int = 2):
    """Unit tangent from points +-half stations away (matches the app's +-2 m)."""
    idx = np.arange(len(e))
    a = np.clip(idx - half, 0, len(e) - 1)
    b = np.clip(idx + half, 0, len(e) - 1)
    de = e[b] - e[a]; dn = n[b] - n[a]
    L = np.hypot(de, dn)
    return de / L, dn / L


def trough_analysis(grid, oE, oN, e, n, ne_, nn_, search_m=5.0, span_m=8.0, floor_tol=0.25, bank_m=6.0):
    """Per-station lateral DTM profile analysis.

    Returns arrays: floor centre offset (m, + = right), floor width (m), left/right bank
    height above the floor (max within bank_m outside the floor edges)."""
    wide = np.arange(-span_m, span_m + 1e-9, 0.25)
    k = len(e)
    mid = np.zeros(k); fw = np.zeros(k); lb = np.zeros(k); rb = np.zeros(k)
    inner = np.abs(wide) <= search_m
    for i in range(k):
        z = bilinear(grid, oE, oN, 1.0, e[i] + wide * ne_[i], n[i] + wide * nn_[i])
        zs = z.copy()
        zs[1:-1] = (z[:-2] + z[1:-1] + z[2:]) / 3.0
        j = int(np.argmin(np.where(inner, zs, np.inf)))
        thr = zs[j] + floor_tol
        a = j
        while a > 0 and zs[a - 1] <= thr:
            a -= 1
        b = j
        while b < len(wide) - 1 and zs[b + 1] <= thr:
            b += 1
        mid[i] = 0.5 * (wide[a] + wide[b]); fw[i] = wide[b] - wide[a]
        lm = (wide < wide[a]) & (wide >= wide[a] - bank_m)
        rm = (wide > wide[b]) & (wide <= wide[b] + bank_m)
        lb[i] = (zs[lm].max() - zs[j]) if lm.any() else 0.0
        rb[i] = (zs[rm].max() - zs[j]) if rm.any() else 0.0
    return mid, fw, lb, rb


def bank_clear_width(grid, oE, oN, e, n, ne_, nn_, elev, half_max, tol, step=0.05):
    """Per-station clear carriageway width before the DTM rises onto a bank.

    For each side, the distance from the centreline to the first lateral sample where
    DTM > max(elev, DTM at the centreline) + tol, searched out to half_max (else half_max).
    Returns (2 * min(left, right), left, right)."""
    k = len(e)
    dl = np.empty(k); dr = np.empty(k)
    for i in range(k):
        hm = float(half_max[i])
        off = np.arange(0.0, hm + 1e-9, step)
        zc = float(bilinear(grid, oE, oN, 1.0, e[i], n[i]))
        ref = max(float(elev[i]), zc) + tol
        for sign, outv in ((1.0, dr), (-1.0, dl)):
            z = bilinear(grid, oE, oN, 1.0, e[i] + sign * off * ne_[i], n[i] + sign * off * nn_[i])
            bad = np.flatnonzero(z > ref)
            outv[i] = off[bad[0]] if bad.size else hm
    return 2.0 * np.minimum(dl, dr), dl, dr


def cache_date(cache: Path, pattern: str) -> str | None:
    """Local date of the oldest cached file matching `pattern` (when the data was downloaded)."""
    files = [p for p in cache.glob(pattern) if p.is_file() and p.stat().st_size > 0]
    if not files:
        return None
    return date.fromtimestamp(min(p.stat().st_mtime for p in files)).isoformat()


def hampel(v: np.ndarray, half: int, min_dev: float, k: float = 3.0, grow: int = 2):
    """Replace isolated spikes (and `grow` stations either side) by the running median."""
    from scipy.ndimage import binary_dilation, median_filter
    med = median_filter(v, size=2 * half + 1, mode="nearest")
    dev = np.abs(v - med)
    mad = median_filter(dev, size=2 * half + 1, mode="nearest") * 1.4826
    bad = dev > np.maximum(k * mad, min_dev)
    if grow and bad.any():
        bad = binary_dilation(bad, iterations=grow)
    out = v.copy()
    out[bad] = med[bad]
    return out, bad


def sample_rgb(arr: np.ndarray, oE, oN, mpp, e, n):
    return np.stack([bilinear(arr[..., c].astype(np.float32), oE, oN, mpp, e, n) for c in range(3)], axis=-1)


def fetch_wms_mosaic(cache: Path, service: str, layer: str, gx0, gx1, gy0, gy1, mpp, log, tile_m=1000):
    from PIL import Image
    pw, ph = int(round((gx1 - gx0) / mpp)), int(round((gy1 - gy0) / mpp))
    img = Image.new("RGB", (pw, ph))
    for ty0 in range(gy0, gy1, tile_m):
        ty1 = min(ty0 + tile_m, gy1)
        for tx0 in range(gx0, gx1, tile_m):
            tx1 = min(tx0 + tile_m, gx1)
            tw, th = int(round((tx1 - tx0) / mpp)), int(round((ty1 - ty0) / mpp))
            q = urllib.parse.urlencode({
                "SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetMap", "LAYERS": layer,
                "STYLES": "", "CRS": "EPSG:31370", "BBOX": f"{tx0},{ty0},{tx1},{ty1}",
                "WIDTH": tw, "HEIGHT": th, "FORMAT": "image/png"})
            body = cached_fetch(cache, f"wms_{layer}_{tx0}_{tx1}_{ty0}_{ty1}_{mpp}.png", f"{service}?{q}",
                                validate=lambda b, h: b[:8] == b"\x89PNG\r\n\x1a\n", log=log)
            im = Image.open(io.BytesIO(body)).convert("RGB")
            if im.size != (tw, th):
                raise RuntimeError(f"{layer} tile size {im.size} != {(tw, th)}")
            img.paste(im, (int(round((tx0 - gx0) / mpp)), int(round((gy1 - ty1) / mpp))))
            im.close()
    return img


GRB_WFS = "https://geo.api.vlaanderen.be/GRB/wfs"


def fetch_grb_road_edges(cache: Path, x0: int, x1: int, y0: int, y1: int, log) -> np.ndarray:
    """GRB WGO 'rand van de rijbaan' lines (surveyed carriageway edges) in the box, as segments
    (x0, y0, x1, y1) in Lambert 72, fetched page by page and cached."""
    segs, start, page = [], 0, 5000
    while True:
        q = urllib.parse.urlencode({
            "SERVICE": "WFS", "VERSION": "2.0.0", "REQUEST": "GetFeature", "TYPENAMES": "GRB:WGO",
            "BBOX": f"{x0},{y0},{x1},{y1},urn:ogc:def:crs:EPSG::31370", "SRSNAME": "urn:ogc:def:crs:EPSG::31370",
            "OUTPUTFORMAT": "application/json", "COUNT": page, "STARTINDEX": start})
        body = cached_fetch(cache, f"wfs_GRB_WGO_{x0}_{x1}_{y0}_{y1}_{start}.json", f"{GRB_WFS}?{q}",
                            validate=lambda b, h: b.lstrip().startswith(b"{"), log=log, tries=4)
        d = json.loads(body)
        crs = str(d.get("crs", {}).get("properties", {}).get("name", ""))
        if crs and "31370" not in crs:
            raise SystemExit(f"GRB WFS answered in {crs}, expected EPSG:31370")
        feats = d.get("features", [])
        for f_ in feats:
            if not str(f_.get("properties", {}).get("LBLTYPE", "")).startswith("rand van de rijbaan"):
                continue
            g = f_.get("geometry") or {}
            lines = [g["coordinates"]] if g.get("type") == "LineString" else (
                g["coordinates"] if g.get("type") == "MultiLineString" else [])
            for ln in lines:
                a = np.asarray(ln, dtype=np.float64)[:, :2]
                segs.extend(np.hstack([a[:-1], a[1:]]))
        if len(feats) < page:
            break
        start += page
    log(f"[grb] {len(segs)} carriageway-edge segments (GRB WGO 'rand van de rijbaan') in the near grid box")
    return np.array(segs).reshape(-1, 4)


def grb_carriageway(segs, e, n, ne_, nn_, width_nom, reach=1.5):
    """Per station: the centre (m along the right-hand normal, + = right) and width of the surveyed
    carriageway, from the pair of adjacent GRB edge crossings along the normal (within the nominal
    half-width + `reach`) whose spacing best fits the nominal width and lies nearest the line.
    NaN where no such pair."""
    A = segs[:, :2]; D = segs[:, 2:] - A
    mids = A + D / 2; half = np.hypot(D[:, 0], D[:, 1]) / 2
    k = len(e); centre = np.full(k, np.nan); width = np.full(k, np.nan)
    for i in range(k):
        L = width_nom[i] / 2 + reach
        near = np.hypot(mids[:, 0] - e[i], mids[:, 1] - n[i]) < half + L + 0.5
        if near.sum() < 2:
            continue
        a, d = A[near], D[near]
        nx, ny = ne_[i], nn_[i]
        det = -nx * d[:, 1] + ny * d[:, 0]
        ok = np.abs(det) > 1e-9
        det = np.where(ok, det, 1.0)
        rx, ry = a[:, 0] - e[i], a[:, 1] - n[i]
        tt = (-rx * d[:, 1] + ry * d[:, 0]) / det      # along the normal
        uu = (nx * ry - ny * rx) / det                  # along the segment
        ts = np.sort(tt[ok & (uu >= 0) & (uu <= 1) & (np.abs(tt) <= L)])
        best = None
        for j in range(len(ts) - 1):
            g = ts[j + 1] - ts[j]
            if 0.6 * width_nom[i] <= g <= 1.6 * width_nom[i] + 0.5:
                c = 0.5 * (ts[j] + ts[j + 1])
                if best is None or abs(c) < abs(best[0]):
                    best = (c, g)
        if best:
            centre[i], width[i] = best
    return centre, width


# ---------------------------------------------------------------------------
# Encoding
# ---------------------------------------------------------------------------


def encode_u16(a: np.ndarray, base: float | None = None) -> tuple[bytes, float]:
    finite = np.isfinite(a)
    if base is None:
        base = math.floor(float(np.nanmin(a)) - 1.0) if finite.any() else 0.0
    raw = np.full(a.shape, 65535, dtype="<u2")
    v = np.round((a[finite].astype(np.float64) - base) * 100.0)
    if v.size and (v.min() < 0 or v.max() > 65534):
        raise ValueError(f"values out of u16 range for base {base}")
    raw[finite] = v.astype("<u2")
    return raw.tobytes(order="C"), float(base)


# ---------------------------------------------------------------------------
# Main build
# ---------------------------------------------------------------------------


def build(course_id: str) -> int:
    cfg = COURSES[course_id]
    cache = CACHE_ROOT / course_id
    dbg = DEBUG_ROOT / course_id
    out = OUT_ROOT / course_id
    pipe = PIPELINE_ROOT / course_id
    for p in (cache, dbg, out, pipe):
        p.mkdir(parents=True, exist_ok=True)
    log_lines: list[str] = []

    def log(msg: str):
        print(msg, flush=True)
        log_lines.append(msg)

    today = date.today().isoformat()
    from pyproj import Transformer

    to72 = Transformer.from_crs("EPSG:4326", "EPSG:31370", always_xy=True)
    to84 = Transformer.from_crs("EPSG:31370", "EPSG:4326", always_xy=True)

    # ---------------- route ----------------
    log("[osm] fetching route ways")
    osm = fetch_osm(cfg, cache, log)
    chain = build_chain(cfg, osm)
    X, Y = to72.transform(chain.lon, chain.lat)
    X = np.asarray(X); Y = np.asarray(Y)
    try:
        from pyproj.transformer import TransformerGroup
        tg = TransformerGroup("EPSG:4326", "EPSG:31370", always_xy=True)
        t0 = tg.transformers[0]
        log(f"[proj] EPSG:4326 -> EPSG:31370: {t0.description} (accuracy {t0.accuracy} m); "
            f"{len(tg.unavailable_operations)} grid-based operations unavailable offline")
    except Exception as e:
        log(f"[proj] EPSG:4326 -> EPSG:31370 ({e})")
    for k, w in enumerate(chain.ways):
        i0, i1 = chain.way_first_vertex[k], chain.way_last_vertex[k]
        L = float(np.hypot(np.diff(X[i0:i1 + 1]), np.diff(Y[i0:i1 + 1])).sum())
        t = w.get("tags", {})
        log(f"  way {w['id']:>10} {t.get('name', '?'):<12} {t.get('highway', ''):<12} surface={t.get('surface', '-'):<8} "
            f"width={t.get('width', '-')} len={L:6.1f} m")

    # dense raw polyline at 0.25 m, then light horizontal smoothing to round junction kinks
    seg = np.hypot(np.diff(X), np.diff(Y))
    s_vert = np.concatenate([[0.0], np.cumsum(seg)])
    dense_step = 0.25
    sd = np.arange(0.0, s_vert[-1] + 1e-9, dense_step)
    xd = np.interp(sd, s_vert, X); yd = np.interp(sd, s_vert, Y)
    seg_of = np.clip(np.searchsorted(s_vert, sd, side="right") - 1, 0, len(X) - 2)
    wd = chain.way_idx[seg_of]
    sig = cfg["xy_smooth_sigma_m"] / dense_step
    xs = gaussian1d(xd, sig); ys = gaussian1d(yd, sig)
    dev = np.hypot(xs - xd, ys - yd)
    log(f"[route] raw chain length {s_vert[-1]:.1f} m; xy smoothing sigma {cfg['xy_smooth_sigma_m']} m, "
        f"max lateral change {dev.max():.2f} m, median {np.median(dev):.3f} m")
    ss = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(xs), np.diff(ys)))])

    def key_vertex(spec):
        kind, wid = spec
        k = cfg["ways"].index(wid)
        return chain.way_first_vertex[k] if kind == "way_start" else chain.way_last_vertex[k]

    def s_of_point(px, py):
        j = int(np.argmin(np.hypot(xs - px, ys - py)))
        return float(ss[j])

    vs, ve = key_vertex(cfg["climb_start"]), key_vertex(cfg["climb_end"])
    s_cs = s_of_point(X[vs], Y[vs])
    s_ce = s_of_point(X[ve], Y[ve])
    r0 = s_cs - cfg["approach_m"]
    r1 = s_ce + cfg["exit_m"]
    if r0 < 0 or r1 > ss[-1]:
        raise SystemExit(f"approach/exit beyond chain: need [{r0:.1f}, {r1:.1f}] within [0, {ss[-1]:.1f}]")
    n_st = int(math.floor(r1 - r0 + 1e-9)) + 1
    s = np.arange(n_st, dtype=np.float64)  # exactly 1.0 m spacing
    Xr = np.interp(r0 + s, ss, xs); Yr = np.interp(r0 + s, ss, ys)
    widx = wd[np.clip(np.round((np.interp(r0 + s, ss, sd)) / dense_step).astype(int), 0, len(wd) - 1)]
    startS = s_cs - r0
    endS = s_ce - r0
    # s of every way boundary (junction vertex) on the trimmed route, for landmarks
    way_start_s = [s_of_point(X[chain.way_first_vertex[k]], Y[chain.way_first_vertex[k]]) - r0
                   for k in range(len(chain.ways))]
    log(f"[route] {n_st} stations, total {s[-1]:.0f} m; climb {startS:.1f} -> {endS:.1f} ({endS - startS:.1f} m)")

    # local origin: climb midpoint snapped to 10 m (centre of the far grid)
    mid_e = 0.5 * (np.interp(startS, s, Xr) + np.interp(endS, s, Xr))
    mid_n = 0.5 * (np.interp(startS, s, Yr) + np.interp(endS, s, Yr))
    oE = float(round(mid_e / 10.0) * 10.0)
    oN = float(round(mid_n / 10.0) * 10.0)
    olon, olat = to84.transform(oE, oN)
    e_loc = Xr - oE; n_loc = Yr - oN

    # per-station tags
    tagsk = [w.get("tags", {}) for w in chain.ways]
    # Street names, where the official road register (Wegenregister) differs from OSM's name tag.
    names = [cfg.get("way_names", {}).get(chain.ways[k]["id"], t.get("name", "")) for k, t in enumerate(tagsk)]

    def width_for(k):
        t = tagsk[k]
        if "width" in t:
            try:
                return float(str(t["width"]).replace("m", "").strip())
            except ValueError:
                pass
        return float(cfg["width_m"].get(chain.ways[k]["id"], cfg["default_width_m"]))

    def surface_name(k):
        v = tagsk[k].get("surface", "asphalt")
        return "cobbles" if v in COBBLE_SURFACES else "concrete" if v in CONCRETE_SURFACES else "asphalt"

    # "concrete" is listed only when the route has some, so older courses keep [asphalt, cobbles].
    surfaces = ["asphalt", "cobbles"]
    if any(surface_name(k) == "concrete" for k in range(len(tagsk))):
        surfaces.append("concrete")
    surf_k = [surfaces.index(surface_name(k)) for k in range(len(tagsk))]
    width = np.array([width_for(k) for k in widx])
    surf = np.array([surf_k[k] for k in widx], dtype=int)

    # ---------------- near grid ----------------
    margin = cfg["near_margin_m"]
    gx0 = int(math.floor((Xr.min() - margin) / 10.0) * 10)
    gx1 = int(math.ceil((Xr.max() + margin) / 10.0) * 10)
    gy0 = int(math.floor((Yr.min() - margin) / 10.0) * 10)
    gy1 = int(math.ceil((Yr.max() + margin) / 10.0) * 10)
    log(f"[near] Lambert72 x {gx0}..{gx1}, y {gy0}..{gy1} ({gx1 - gx0} x {gy1 - gy0} m)")
    dtm = wcs_grid(cache, "DHMVII_DTM_1m", gx0, gx1, gy0, gy1, log)
    dsm = wcs_grid(cache, "DHMVII_DSM_1m", gx0, gx1, gy0, gy1, log)
    n_dtm_nan = int((~np.isfinite(dtm)).sum()); n_dsm_nan = int((~np.isfinite(dsm)).sum())
    log(f"[near] DTM nodata {n_dtm_nan} cells ({100 * n_dtm_nan / dtm.size:.2f} %), DSM nodata {n_dsm_nan}")
    near_oE = gx0 - oE; near_oN = gy1 - oN
    dtm_raw_nan = ~np.isfinite(dtm)
    dtm_f, nfilled = fill_nans(dtm)
    dsm_f, _ = fill_nans(dsm)
    log(f"[near] filled {nfilled} DTM nodata cells by nearest-neighbour + diffusion")

    def samp(grid, e, n):
        return bilinear(grid, near_oE, near_oN, 1.0, e, n)

    # ---------------- centreline refinement (sunken lane) ----------------
    te, tn = tangents(e_loc, n_loc, half=2)
    ne_, nn_ = tn, -te  # right-hand normal (east, north)
    osm_e, osm_n = e_loc.copy(), n_loc.copy()
    mid0, fw0, lb0, rb0 = trough_analysis(dtm_f, near_oE, near_oN, e_loc, n_loc, ne_, nn_)
    bank0 = np.minimum(lb0, rb0)
    wgt = np.clip((bank0 - 0.5) / 0.5, 0, 1) * (fw0 <= 6.0)
    refine_off = np.zeros(n_st)
    sunken0 = wgt >= 1.0
    log(f"[trough] two-sided sunken lane (banks >= 1 m both sides): {int(sunken0.sum())} stations; "
        f"floor-centre offset from OSM there: median {np.median(mid0[sunken0]) if sunken0.any() else 0:+.2f} m, "
        f"max |{np.abs(mid0[sunken0]).max() if sunken0.any() else 0:.2f}| m; floor width (+0.25 m) median "
        f"{np.median(fw0[sunken0]) if sunken0.any() else 0:.2f} m (p10 {np.percentile(fw0[sunken0], 10) if sunken0.any() else 0:.2f}, "
        f"p90 {np.percentile(fw0[sunken0], 90) if sunken0.any() else 0:.2f})")
    if cfg.get("refine_centreline"):
        refine_off = gaussian1d(wgt * mid0, cfg["refine_sigma_m"])
        refine_off = np.clip(refine_off, -cfg["refine_max_m"], cfg["refine_max_m"])
        pe = e_loc + refine_off * ne_; pn = n_loc + refine_off * nn_
        cum = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(pe), np.diff(pn)))])
        n_new = int(math.floor(cum[-1] + 1e-9)) + 1
        s_new = np.arange(n_new, dtype=np.float64)
        old_at = np.interp(s_new, cum, s)            # old-station parameter of each new station
        e_loc = np.interp(s_new, cum, pe); n_loc = np.interp(s_new, cum, pn)
        nearest = np.clip(np.round(old_at).astype(int), 0, n_st - 1)
        widx = widx[nearest]
        refine_off = refine_off[nearest]
        osm_e = np.interp(old_at, s, osm_e); osm_n = np.interp(old_at, s, osm_n)
        startS = float(np.interp(startS, s, cum)); endS = float(np.interp(endS, s, cum))
        way_start_s = [float(np.interp(v, s, cum)) for v in way_start_s]
        s = s_new; n_st = n_new
        log(f"[trough] centreline shifted by up to {np.abs(refine_off).max():.2f} m "
            f"(Gaussian sigma {cfg['refine_sigma_m']} m, weight from bank height); "
            f"{int((np.abs(refine_off) > 0.5).sum())} stations moved > 0.5 m; route now {s[-1]:.0f} m, "
            f"climb {startS:.1f} -> {endS:.1f}")
        te, tn = tangents(e_loc, n_loc, half=2)
        ne_, nn_ = tn, -te

    # ---------------- centreline alignment to the surveyed carriageway (GRB WGO) ----------------
    grb_off = np.zeros(n_st)
    if cfg.get("align_to_grb"):
        segs = fetch_grb_road_edges(cache, gx0, gx1, gy0, gy1, log) - np.array([oE, oN, oE, oN])
        wn = np.array([width_for(k) for k in widx])
        centre, gw = grb_carriageway(segs, e_loc, n_loc, ne_, nn_, wn)
        ok_ = np.isfinite(centre)
        log(f"[grb] surveyed carriageway found at {int(ok_.sum())} of {n_st} stations; centre off the line: "
            f"median {np.median(centre[ok_]):+.2f} m, p10 {np.percentile(centre[ok_], 10):+.2f}, "
            f"p90 {np.percentile(centre[ok_], 90):+.2f} m")
        for k in sorted(set(int(v) for v in widx)):
            m_ = ok_ & (widx == k)
            if m_.sum() >= 5:
                log(f"[grb]   way {chain.ways[k]['id']:>10} {names[k]:<15}: measured width median "
                    f"{np.median(gw[m_]):.2f} m (p10 {np.percentile(gw[m_], 10):.2f}, p90 {np.percentile(gw[m_], 90):.2f}) "
                    f"vs configured {width_for(k):.2f}; centre {np.median(centre[m_]):+.2f} m")
        # Robust fill: despike, carry across short gaps, ease to no shift over long ones.
        if ok_.sum() >= 10:
            idx_ok = np.flatnonzero(ok_)
            filled = np.interp(s, s[idx_ok], centre[idx_ok])
            gap = np.abs(s[:, None] - s[idx_ok][None, :]).min(axis=1) if n_st * len(idx_ok) < 2e7 else \
                np.minimum(np.abs(s - s[idx_ok][np.clip(np.searchsorted(s[idx_ok], s), 0, len(idx_ok) - 1)]),
                           np.abs(s - s[idx_ok][np.clip(np.searchsorted(s[idx_ok], s) - 1, 0, len(idx_ok) - 1)]))
            filled = filled * np.clip(1 - (gap - 15.0) / 15.0, 0, 1)
            filled, _ = hampel(filled, 7, 0.3)
            grb_off = np.clip(gaussian1d(filled, cfg.get("grb_sigma_m", 4.0)), -1.5, 1.5)
            pe = e_loc + grb_off * ne_; pn = n_loc + grb_off * nn_
            cum = np.concatenate([[0.0], np.cumsum(np.hypot(np.diff(pe), np.diff(pn)))])
            n_new = int(math.floor(cum[-1] + 1e-9)) + 1
            s_new = np.arange(n_new, dtype=np.float64)
            old_at = np.interp(s_new, cum, s)
            e_loc = np.interp(s_new, cum, pe); n_loc = np.interp(s_new, cum, pn)
            nearest = np.clip(np.round(old_at).astype(int), 0, n_st - 1)
            widx = widx[nearest]; refine_off = refine_off[nearest]; grb_off = grb_off[nearest]
            osm_e = np.interp(old_at, s, osm_e); osm_n = np.interp(old_at, s, osm_n)
            startS = float(np.interp(startS, s, cum)); endS = float(np.interp(endS, s, cum))
            way_start_s = [float(np.interp(v, s, cum)) for v in way_start_s]
            s = s_new; n_st = n_new
            te, tn = tangents(e_loc, n_loc, half=2)
            ne_, nn_ = tn, -te
            after, _ = grb_carriageway(segs, e_loc, n_loc, ne_, nn_, np.array([width_for(k) for k in widx]))
            fa = np.isfinite(after)
            log(f"[grb] centreline moved by up to {np.abs(grb_off).max():.2f} m (sigma {cfg.get('grb_sigma_m', 4.0)} m); "
                f"{int((np.abs(grb_off) > 0.3).sum())} stations > 0.3 m; residual |centre| median "
                f"{np.median(np.abs(after[fa])):.2f} m, p90 {np.percentile(np.abs(after[fa]), 90):.2f} m; "
                f"route now {s[-1]:.0f} m, climb {startS:.1f} -> {endS:.1f}")
    width = np.array([width_for(k) for k in widx])
    surf = np.array([surf_k[k] for k in widx], dtype=int)
    floor_mid, floor_w, lb1, rb1 = trough_analysis(dtm_f, near_oE, near_oN, e_loc, n_loc, ne_, nn_)
    sunken1 = (np.minimum(lb1, rb1) >= 1.0) & (floor_w <= 6.0)
    if sunken1.any():
        log(f"[trough] after refinement, sunken stations {int(sunken1.sum())}: floor-centre residual median "
            f"{np.median(floor_mid[sunken1]):+.2f} m, |p90| {np.percentile(np.abs(floor_mid[sunken1]), 90):.2f} m")

    # ---------------- road profile ----------------
    naive = samp(dtm_f, e_loc, n_loc)
    naive_osm = samp(dtm_f, osm_e, osm_n)
    pct = cfg["low_percentile"]
    z_low = np.empty(n_st)
    for i in range(n_st):
        hw = width[i] / 2 + 1.0
        offs = np.arange(-hw, hw + 1e-9, 0.25)
        z = samp(dtm_f, e_loc[i] + offs * ne_[i], n_loc[i] + offs * nn_[i])
        z_low[i] = np.percentile(z, pct)
    z_raw = z_low.copy()
    z_low, spikes = hampel(z_raw, int(cfg["despike_window_m"]), cfg["despike_min_m"])
    if spikes.any():
        sp = s[spikes]
        log(f"[profile] despiked {int(spikes.sum())} stations (Hampel +-{cfg['despike_window_m']} m, "
            f">= {cfg['despike_min_m']} m) at s = {', '.join(f'{v:.0f}' for v in sp[:20])}; "
            f"max change {np.abs(z_raw - z_low).max():.2f} m")
    sigma = cfg["smooth_sigma_m"]
    elev = gaussian1d(z_low, sigma / 1.0)
    grade = np.gradient(elev, s) * 100.0
    climb_mask = (s >= startS) & (s <= endS)
    log(f"[profile] low-percentile p{pct:.0f} across +-(w/2+1) m; Gaussian sigma {sigma} m")
    log(f"[profile] p{pct:.0f} - DTM at refined centreline: median {np.median(z_low - naive):+.2f} m, "
        f"min {np.min(z_low - naive):+.2f}; p{pct:.0f} - DTM at OSM centreline: median "
        f"{np.median(z_low - naive_osm):+.2f}, min {np.min(z_low - naive_osm):+.2f} m")
    log(f"[profile] raw-vs-smoothed residual (climb): rms {np.sqrt(np.mean((z_low - elev)[climb_mask] ** 2)):.3f} m, "
        f"max {np.abs(z_low - elev)[climb_mask].max():.3f} m")

    def window_max(el, w):
        best, at = -1e9, 0.0
        for i in range(n_st):
            if s[i] < startS - 1e-9:
                continue
            if s[i] + w > endS + 1e-9:
                break
            g = (np.interp(s[i] + w, s, el) - el[i]) / w * 100.0
            if g > best:
                best, at = g, s[i] + w / 2
        return best, at

    def climb_stats(el):
        z0 = float(np.interp(startS, s, el)); z1 = float(np.interp(endS, s, el))
        out_ = {"gain": z1 - z0, "avg": (z1 - z0) / (endS - startS) * 100, "z0": z0, "z1": z1}
        for w in (10, 25, 50, 100):
            out_[f"max{w}"], out_[f"at{w}"] = window_max(el, w)
        return out_

    for sg in (3.0, 4.0, 6.0, 8.0, 10.0):
        st_ = climb_stats(gaussian1d(z_low, sg))
        log(f"[sens] sigma {sg:4.1f} m: gain {st_['gain']:.1f} avg {st_['avg']:.2f}% max10 {st_['max10']:.1f} "
            f"max25 {st_['max25']:.1f} max50 {st_['max50']:.1f} max100 {st_['max100']:.1f}")
    for p_ in (10.0, 50.0):
        zz = np.array([np.percentile(samp(dtm_f, e_loc[i] + np.arange(-width[i] / 2 - 1, width[i] / 2 + 1 + 1e-9, 0.25) * ne_[i],
                                          n_loc[i] + np.arange(-width[i] / 2 - 1, width[i] / 2 + 1 + 1e-9, 0.25) * nn_[i]), p_)
                       for i in range(n_st)])
        st_ = climb_stats(gaussian1d(hampel(zz, int(cfg["despike_window_m"]), cfg["despike_min_m"])[0], sigma))
        log(f"[sens] percentile p{p_:.0f} (sigma {sigma}): gain {st_['gain']:.1f} avg {st_['avg']:.2f}% "
            f"max10 {st_['max10']:.1f} max25 {st_['max25']:.1f} max50 {st_['max50']:.1f}")
    for lab, zz in (("DTM at refined centreline", naive), ("DTM at OSM centreline", naive_osm)):
        st_ = climb_stats(gaussian1d(zz, sigma))
        log(f"[sens] naive {lab} (sigma {sigma}): gain {st_['gain']:.1f} avg {st_['avg']:.2f}% "
            f"max10 {st_['max10']:.1f} max25 {st_['max25']:.1f} max50 {st_['max50']:.1f}")

    # ---------------- shipped carriageway width (bank-limited in the sunken lane) ----------------
    width_nom = width.copy()
    width_out = width_nom.copy()
    cw = np.full(n_st, np.nan)
    if cfg.get("bank_limit_width"):
        tol_b = cfg["bank_tol_m"]; wmin = cfg["min_width_m"]

        def clear_for(tol_):
            return bank_clear_width(dtm_f, near_oE, near_oN, e_loc, n_loc, ne_, nn_, elev, width_nom / 2, tol_)[0]

        cw, dl_b, dr_b = bank_clear_width(dtm_f, near_oE, near_oN, e_loc, n_loc, ne_, nn_, elev, width_nom / 2, tol_b)
        # smooth the bank deficit (not the width, so the nominal steps between ways stay sharp);
        # wide roads get none, before smoothing, so it doesn't spill onto the lanes next to them
        eligible = width_nom <= cfg.get("bank_limit_max_nominal_m", np.inf)
        deficit = gaussian1d(np.where(eligible, width_nom - np.minimum(width_nom, cw), 0.0), 2.0)
        width_out = np.where((deficit > 0.02) & eligible,
                             np.maximum(width_nom - deficit, np.minimum(wmin, width_nom)), width_nom)
        narrowed = width_out < width_nom - 0.01
        if narrowed.any():
            sn_ = s[narrowed]
            br_ = np.flatnonzero(np.diff(sn_) > 3)
            runs = [(float(a), float(b)) for a, b in zip(np.r_[sn_[0], sn_[br_ + 1]], np.r_[sn_[br_], sn_[-1]])]
            log(f"[width] bank-limited carriageway (DTM > max(elev, centre DTM) + {tol_b} m inside the nominal "
                f"width): {int(narrowed.sum())} stations narrowed, s ranges "
                + ", ".join(f"{a:.0f}-{b:.0f}" for a, b in runs)
                + f"; there clear width median {np.median(cw[narrowed]):.2f} m (p10 {np.percentile(cw[narrowed], 10):.2f}),"
                  f" shipped width median {np.median(width_out[narrowed]):.2f} m, min {width_out.min():.2f} m "
                  f"({int((width_out <= wmin + 1e-6).sum())} stations at the {wmin} m floor)")
            for t_ in (0.10, 0.20):
                cw_t = clear_for(t_)
                nt = cw_t < width_nom - 0.01
                log(f"[width] sensitivity tol {t_:.2f} m: {int(nt.sum())} stations below nominal, clear width median "
                    f"{np.median(cw_t[nt]) if nt.any() else 0:.2f} m there")
        else:
            log("[width] no station has a bank inside the nominal carriageway; widths unchanged")

    def ribbon_rise(wv):
        """Max DTM inside a +-w/2 ribbon above max(elev, centre DTM), per station."""
        out_ = np.empty(n_st)
        for i in range(n_st):
            offs = np.arange(-wv[i] / 2, wv[i] / 2 + 1e-9, 0.25)
            z = samp(dtm_f, e_loc[i] + offs * ne_[i], n_loc[i] + offs * nn_[i])
            out_[i] = z.max() - max(float(elev[i]), float(samp(dtm_f, e_loc[i], n_loc[i])))
        return out_

    rise_nom = ribbon_rise(width_nom); rise_out = ribbon_rise(width_out)
    log(f"[width] DTM inside the ribbon above the road level: nominal widths p95 {np.percentile(rise_nom, 95):.2f} / "
        f"max {rise_nom.max():.2f} m ({int((rise_nom > 0.3).sum())} stations > 0.3 m); shipped widths p95 "
        f"{np.percentile(rise_out, 95):.2f} / max {rise_out.max():.2f} m ({int((rise_out > 0.3).sum())} stations > 0.3 m)")

    st = climb_stats(elev)
    climb_len = endS - startS
    per100 = []
    a_ = startS
    while a_ < endS - 1e-6:
        b_ = min(a_ + 100.0, endS)
        ga = (np.interp(b_, s, elev) - np.interp(a_, s, elev)) / (b_ - a_) * 100
        per100.append({"fromS": round(a_, 1), "toS": round(b_, 1), "avgGradePct": round(float(ga), 1)})
        a_ = b_
    log(f"[climb] length {climb_len:.1f} m, gain {st['gain']:.1f} m ({st['z0']:.1f} -> {st['z1']:.1f}), "
        f"avg {st['avg']:.2f}%, max10 {st['max10']:.1f}% max25 {st['max25']:.1f}% max50 {st['max50']:.1f}%")
    zmax_i = int(np.argmax(elev))
    log(f"[climb] highest route point {elev[zmax_i]:.1f} m at s={s[zmax_i]:.0f}; "
        f"elev at route end {elev[-1]:.1f} m")

    # ---------------- landmarks ----------------
    landmarks = []
    landmarks.append({"s": 0.0, "kind": "village", "name": f"{cfg['village']} – {names[widx[0]]}"})
    # A street that changes its name part way along an OSM way (name_breaks: metres along it).
    end_name = list(names)
    for k in range(len(chain.ways)):
        for along, nm in cfg.get("name_breaks", {}).get(chain.ways[k]["id"], []):
            sb = way_start_s[k] + along
            if 0.0 < sb < s[-1]:
                landmarks.append({"s": round(sb, 1), "kind": "junction", "name": f"{end_name[k]} → {nm}"})
            end_name[k] = nm
    for k in range(1, len(chain.ways)):
        sj = way_start_s[k]
        if not (0.0 < sj < s[-1]):
            continue
        sj = round(sj, 1)
        if end_name[k - 1] != names[k]:
            landmarks.append({"s": sj, "kind": "junction", "name": f"{end_name[k - 1]} → {names[k]}"})
        if surf_k[k - 1] != surf_k[k]:
            a_, b_ = surfaces[surf_k[k - 1]], surfaces[surf_k[k]]
            landmarks.append({"s": sj, "kind": "note",
                              "name": "Cobbles begin" if b_ == "cobbles" else f"Cobbles end, {b_}" if a_ == "cobbles"
                              else f"{b_.capitalize()} begins"})
    landmarks.append({"s": round(startS, 1), "kind": "climbStart", "name": cfg["climb_start_name"]})
    landmarks.append({"s": round(st["at25"], 1), "kind": "steepest",
                      "name": f"Steepest 25 m ({st['max25']:.1f} %)"})
    landmarks.append({"s": round(endS, 1), "kind": "summit", "name": cfg["summit_name"]})
    # drop junction/note landmarks that coincide with climb start/summit (keep them, but avoid exact dupes)
    landmarks.sort(key=lambda d: (d["s"], d["kind"]))

    # ---------------- far grid ----------------
    half = cfg["far_size_m"] / 2
    fx0, fx1 = int(oE - half), int(oE + half)
    fy0, fy1 = int(oN - half), int(oN + half)
    cell = int(cfg["far_cell_m"])
    log(f"[far] DHMV II DTM 1 m block-averaged to {cell} m over x {fx0}..{fx1}, y {fy0}..{fy1}")
    far = far_grid(cache, fx0, fx1, fy0, fy1, cell, log)
    far_nan = int((~np.isfinite(far)).sum())
    far, _ = fill_nans(far)
    log(f"[far] {far.shape[1]} x {far.shape[0]} cells, nodata filled {far_nan}, range {np.nanmin(far):.1f}..{np.nanmax(far):.1f} m")

    # ---------------- canopy ----------------
    canopy = np.maximum(dsm - dtm, 0).astype(np.float32)  # NaN where either is NaN
    canopy[~np.isfinite(canopy)] = np.nan
    # where the DTM was a hole (buildings), compare against the filled ground
    hole = dtm_raw_nan & np.isfinite(dsm)
    canopy[hole] = np.maximum(dsm[hole] - dtm_f[hole], 0)
    log(f"[canopy] max {np.nanmax(canopy):.1f} m, cells > 2 m: {100 * np.mean(canopy > 2):.1f} %")

    # ---------------- ortho ----------------
    oc = cfg["ortho"]
    mpp = oc["m_per_px"]
    W, H = gx1 - gx0, gy1 - gy0
    pw, ph = int(round(W / mpp)), int(round(H / mpp))
    if max(pw, ph) > 8192:
        raise SystemExit("ortho too large")
    from PIL import Image

    ortho = fetch_wms_mosaic(cache, oc["service"], oc["layer"], gx0, gx1, gy0, gy1, mpp, log)
    winter = None
    vo = cfg.get("validation_ortho")
    if vo:
        try:
            winter = fetch_wms_mosaic(cache, vo["service"], vo["layer"], gx0, gx1, gy0, gy1, vo["m_per_px"], log)
        except Exception as e:
            log(f"[ortho] validation layer {vo['layer']} unavailable: {e}")
    # flight date from the vliegdagcontour layer at the climb midpoint
    vdc_info = ""
    try:
        bb = f"{oE - 50},{oN - 50},{oE + 50},{oN + 50}"
        q = urllib.parse.urlencode({
            "SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetFeatureInfo", "LAYERS": oc["vdc_layer"],
            "QUERY_LAYERS": oc["vdc_layer"], "STYLES": "", "CRS": "EPSG:31370", "BBOX": bb, "WIDTH": 101,
            "HEIGHT": 101, "I": 50, "J": 50, "INFO_FORMAT": "application/geo+json", "FORMAT": "image/png"})
        body = cached_fetch(cache, f"vdc_{oc['vdc_layer']}_{int(oE)}_{int(oN)}.json", f"{oc['service']}?{q}",
                            validate=lambda b, h: b.lstrip().startswith(b"{"), log=log, tries=3)
        feats = json.loads(body).get("features", [])
        if feats:
            props = feats[0].get("properties", {})
            vdc_info = "flight date " + ", ".join(f"{v}" for k, v in props.items()
                                                  if "datum" in k.lower() and v not in (None, "", "Null"))
    except Exception as e:  # informative only
        vdc_info = f"(flight date lookup failed: {e})"
    log(f"[ortho] {oc['layer']} {pw}x{ph} px at {mpp} m/px; flight info: {vdc_info}")
    dhm_info = ""
    try:
        bb = f"{oE - 50},{oN - 50},{oE + 50},{oN + 50}"
        q = urllib.parse.urlencode({
            "SERVICE": "WMS", "VERSION": "1.3.0", "REQUEST": "GetFeatureInfo", "LAYERS": "DHMVII_vdc",
            "QUERY_LAYERS": "DHMVII_vdc", "STYLES": "", "CRS": "EPSG:31370", "BBOX": bb, "WIDTH": 101,
            "HEIGHT": 101, "I": 50, "J": 50, "INFO_FORMAT": "application/geo+json", "FORMAT": "image/png"})
        body = cached_fetch(cache, f"vdc_DHMVII_{int(oE)}_{int(oN)}.json", f"{DHMV_WMS}?{q}",
                            validate=lambda b, h: b.lstrip().startswith(b"{"), log=log, tries=3)
        feats = json.loads(body).get("features", [])
        if feats:
            props = feats[0].get("properties", {})
            dhm_info = "LiDAR flight date at the climb " + ", ".join(
                f"{v}" for k, v in props.items() if "datum" in k.lower() and v not in (None, "", "Null"))
    except Exception as e:
        dhm_info = f"(survey date lookup failed: {e})"
    log(f"[dhmv] survey info at climb: {dhm_info}")

    # ---------------- write outputs ----------------
    route_way_ids = [chain.ways[k]["id"] for k in sorted(set(int(v) for v in widx))]
    log(f"[route] OSM ways on the shipped route: {route_way_ids}")
    near_bytes, near_base = encode_u16(dtm_f)
    far_bytes, far_base = encode_u16(far)
    can_bytes, can_base = encode_u16(canopy, base=0.0)
    (out / "terrain_near.u16").write_bytes(near_bytes)
    (out / "terrain_far.u16").write_bytes(far_bytes)
    (out / "canopy_near.u16").write_bytes(can_bytes)
    # The raw photo feeds the scenery and ground-map bakes only; the app
    # drapes the baked CourseTextures/<id>_ortho_ground.jpg.
    ortho.save(pipe / "ortho_near.jpg", "JPEG", quality=85, optimize=True)
    (out / "ortho_near.jpg").unlink(missing_ok=True)  # shipped by older builds

    def hdr(file, base, oe, on, cellm, grid):
        return {"file": file, "encoding": "u16le_cm", "baseM": base, "originEast": float(oe),
                "originNorth": float(on), "cellM": float(cellm), "cols": int(grid.shape[1]), "rows": int(grid.shape[0])}

    course = {
        "schemaVersion": 1,
        "id": course_id,
        "name": cfg["name"],
        "region": cfg["region"],
        "origin": {"lambert72": [oE, oN], "wgs84": [round(olat, 7), round(olon, 7)]},
        "attribution": [
            "© OpenStreetMap contributors (ODbL)",
            "Digitaal Vlaanderen – Digitaal Hoogtemodel Vlaanderen II (DTM/DSM 1 m), Modellicentie Gratis Hergebruik",
            f"Digitaal Vlaanderen – {oc['title']} ({oc['layer']}), Modellicentie Gratis Hergebruik",
        ] + [x["attribution"] for x in cfg.get("scenery_sources", [])]
          + (["Digitaal Vlaanderen – GRB Wegopdeling (WGO), Modellicentie Gratis Hergebruik"]
             if cfg.get("align_to_grb") else [])
          + list(cfg.get("extra_attribution", [])),
        "sources": [
            {"name": "OpenStreetMap (Overpass API)", "url": "https://www.openstreetmap.org/",
             "retrieved": cache_date(cache, osm["_cache_file"]) or today,
             "notes": "Ways " + ", ".join(str(w) for w in route_way_ids) + " joined in race order "
                      f"({cfg['streets']}) and trimmed to the route; projected "
                      "EPSG:4326->31370 with pyproj; "
                      f"OSM base {osm.get('osm3s', {}).get('timestamp_osm_base', '?')}. ODbL."},
            {"name": "DHM Vlaanderen II DTM 1 m (DHMVII_DTM_1m)", "url": DHMV_WCS,
             "retrieved": cache_date(cache, "wcs_DHMVII_DTM_1m_*.bin") or today,
             "notes": "WCS 2.0.1 GetCoverage in native Lambert 72 metres, TAW heights. Near grid 1 m; far grid "
                      f"block-averaged to {cell} m from 1 m tiles. {dhm_info}. Modellicentie Gratis Hergebruik "
                      "(CC-BY 4.0 compatible)."},
            {"name": "DHM Vlaanderen II DSM 1 m (DHMVII_DSM_1m)", "url": DHMV_WCS,
             "retrieved": cache_date(cache, "wcs_DHMVII_DSM_1m_*.bin") or today,
             "notes": "Canopy = max(DSM − DTM, 0) on the near grid. Modellicentie Gratis Hergebruik."},
            {"name": oc["title"], "url": oc["service"],
             "retrieved": cache_date(cache, f"wms_{oc['layer']}_*.png") or today,
             "notes": f"WMS layer {oc['layer']} ({oc['season']} {oc['year']}, 40 cm source) resampled by the "
                      f"server to {mpp} m/px. {vdc_info}. Modellicentie Gratis Hergebruik."},
        ] + [{"name": x["name"], "url": x["url"],
              "retrieved": cache_date(cache, x["cache_glob"]) or today, "notes": x["notes"]}
             for x in cfg.get("scenery_sources", [])] + ([
            {"name": "GRB – Wegopdeling (GRB:WGO), Digitaal Vlaanderen", "url": GRB_WFS,
             "retrieved": cache_date(cache, "wfs_GRB_WGO_*.json") or today,
             "notes": "WFS 2.0.0 GetFeature, typeNames GRB:WGO, 'rand van de rijbaan' (surveyed carriageway edge) "
                      "lines. The route centreline is moved onto the middle of the surveyed carriageway (Gaussian-"
                      "smoothed); per-way widths checked against them. Modellicentie Gratis Hergebruik."}]
            if cfg.get("align_to_grb") else []) + [dict(cfg["roadbook"])] + [
            dict(x) for x in cfg.get("extra_sources", [])
        ],
        "climb": {"startS": round(startS, 2), "endS": round(endS, 2)},
        "stats": {
            "totalLengthM": float(s[-1]),
            "climbLengthM": round(climb_len, 1),
            "climbGainM": round(st["gain"], 1),
            "climbAvgGradePct": round(st["avg"], 2),
            "climbMaxGradePct10m": round(st["max10"], 1),
            "climbMaxGradePct25m": round(st["max25"], 1),
            "climbMaxGradePct50m": round(st["max50"], 1),
            "startElevationM": round(st["z0"], 1),
            "summitElevationM": round(st["z1"], 1),
            "per100m": per100,
        },
        "route": {
            "spacingM": 1.0,
            "s": [float(v) for v in s],
            "east": [round(float(v), 2) for v in e_loc],
            "north": [round(float(v), 2) for v in n_loc],
            "elev": [round(float(v), 3) for v in elev],
            "gradePct": [round(float(v), 2) for v in grade],
            "widthM": [round(float(v), 2) for v in width_out],
            "surface": [int(v) for v in surf],
        },
        "surfaces": surfaces,
        "surfaceCrr": {k: v for k, v in cfg["surface_crr"].items() if k in surfaces},
        "landmarks": landmarks,
        "terrain": {
            "near": hdr("terrain_near.u16", near_base, near_oE, near_oN, 1.0, dtm_f),
            "far": hdr("terrain_far.u16", far_base, fx0 - oE, fy1 - oN, cell, far),
        },
        "canopy": hdr("canopy_near.u16", can_base, near_oE, near_oN, 1.0, canopy),
        # "file" is in PIPELINE_ROOT/<id>/, not in the shipped folder.
        "ortho": {"file": "ortho_near.jpg", "originEast": float(near_oE), "originNorth": float(near_oN),
                  "widthM": float(W), "heightM": float(H), "pixelsWide": pw, "pixelsHigh": ph,
                  "capturedSeason": oc["season"], "capturedYear": oc["year"]},
        "scenery": "scenery.json",
    }
    (out / "course.json").write_text(json.dumps(course, ensure_ascii=False, separators=(",", ":")) + "\n")

    # ---------------- debug renders ----------------
    render_debug(dbg, cfg, dict(s=s, e=e_loc, n=n_loc, ne=ne_, nn=nn_, width=width_out, width_nom=width_nom, clear_w=cw,
                                z_raw=z_raw, z_low=z_low,
                                spikes=spikes, naive=naive, naive_osm=naive_osm, elev=elev, grade=grade,
                                startS=startS, endS=endS, st=st, landmarks=landmarks, osm_e=osm_e, osm_n=osm_n,
                                refine_off=refine_off, floor_mid=floor_mid, floor_w=floor_w, sigma=sigma, surf=surf),
                 dtm_f, dsm_f, canopy, near_oE, near_oN, ortho, winter, mpp, (vo or {}).get("m_per_px", mpp),
                 far, course["terrain"]["far"])
    ortho.close()
    if winter is not None:
        winter.close()
    del dtm, dsm, dsm_f, canopy, far

    # ---------------- self-check ----------------
    ok = self_check(out, pipe, log, dtm_f, near_oE, near_oN)
    sizes = {p.name: p.stat().st_size for p in out.iterdir() if p.is_file()}
    total = sum(sizes.values())
    log(f"[out] {out}: " + ", ".join(f"{k} {v / 1e6:.2f} MB" for k, v in sorted(sizes.items()))
        + f"; total {total / 1e6:.2f} MB")
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    rss_mb = rss / 1e6 if sys.platform == "darwin" else rss / 1e3
    log(f"[mem] peak RSS {rss_mb:.0f} MB")
    (dbg / "build_log.txt").write_text("\n".join(log_lines) + "\n")
    diag = {"s": s.tolist(), "z_low": np.round(z_low, 3).tolist(), "naive": np.round(naive, 3).tolist(),
            "elev": np.round(elev, 3).tolist(), "floor_mid": np.round(floor_mid, 2).tolist(),
            "floor_w": np.round(floor_w, 2).tolist(), "refine_off": np.round(refine_off, 2).tolist(),
            "z_raw": np.round(z_raw, 3).tolist(), "naive_osm": np.round(naive_osm, 3).tolist()}
    (dbg / "profile_diagnostics.json").write_text(json.dumps(diag))
    return 0 if ok else 1


# ---------------------------------------------------------------------------
# Debug renders
# ---------------------------------------------------------------------------


def hillshade(z: np.ndarray, cell: float = 1.0, az: float = 315, alt: float = 45, zf: float = 2.0) -> np.ndarray:
    gy, gx = np.gradient(z.astype(np.float32), cell)
    slope = np.arctan(zf * np.hypot(gx, gy))
    aspect = np.arctan2(-gx, gy)
    azr, altr = np.radians(az), np.radians(alt)
    hs = np.sin(altr) * np.cos(slope) + np.cos(altr) * np.sin(slope) * np.cos(azr - aspect)
    return np.clip(hs, 0, 1).astype(np.float32)


def render_debug(dbg, cfg, R, dtm, dsm, canopy, oE, oN, ortho, winter, mpp, wmpp, far=None, far_hdr=None):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import LineCollection

    s, e, n, ne_, nn_ = R["s"], R["e"], R["n"], R["ne"], R["nn"]
    width, z_raw, z_low, elev, grade = R["width"], R["z_raw"], R["z_low"], R["elev"], R["grade"]
    startS, endS, st, sigma = R["startS"], R["endS"], R["st"], R["sigma"]
    pct = cfg["low_percentile"]

    # ---- profile ----
    fig, (a1, a2) = plt.subplots(2, 1, figsize=(13, 8.5), sharex=True, gridspec_kw={"height_ratios": [3, 2]})
    a1.plot(s, R["naive_osm"], color="#9a9a9a", lw=0.8, label="DTM at OSM centreline (naive)")
    a1.plot(s, z_raw, color="#e08a2c", lw=0.9, label=f"p{pct:.0f} across carriageway (raw)")
    if R["spikes"].any():
        a1.plot(s[R["spikes"]], z_raw[R["spikes"]], "x", color="#c0392b", ms=5, label="despiked (Hampel)")
    a1.plot(s, elev, color="#1f5fbf", lw=1.8, label=f"road elevation, Gaussian σ={sigma:g} m")
    for x, lab in ((startS, "climb start"), (endS, "summit")):
        for ax in (a1, a2):
            ax.axvline(x, color="k", ls="--", lw=0.8)
        a1.text(x + 4, float(np.min(elev)) + (0.1 if lab == "climb start" else 0.3) * float(np.ptp(elev)), lab,
                rotation=90, va="bottom", fontsize=8)
    a1.set_ylabel("elevation (m TAW)")
    a1.legend(loc="upper left", fontsize=8)
    a1.set_title(f"{cfg['name']}: climb {endS - startS:.0f} m, +{st['gain']:.1f} m ({st['z0']:.1f} → {st['z1']:.1f} m), "
                 f"avg {st['avg']:.1f} %, max 10/25/50 m = {st['max10']:.1f} / {st['max25']:.1f} / {st['max50']:.1f} %",
                 fontsize=11)
    a1.grid(alpha=0.3)
    ins = a1.inset_axes([0.62, 0.08, 0.36, 0.42])
    m = (s > st["at25"] - 60) & (s < st["at25"] + 60)
    ins.plot(s[m], R["naive_osm"][m], color="#9a9a9a", lw=0.8)
    ins.plot(s[m], z_raw[m], color="#e08a2c", lw=0.9)
    ins.plot(s[m], elev[m], color="#1f5fbf", lw=1.5)
    ins.set_title("steepest section, ±60 m", fontsize=7); ins.tick_params(labelsize=6); ins.grid(alpha=0.3)
    raw_g = np.gradient(z_low, s) * 100
    a2.plot(s, raw_g, color="#e08a2c", lw=0.5, alpha=0.6, label="raw gradient, 1 m (despiked p20)")
    a2.plot(s, grade, color="#1f5fbf", lw=1.6, label="gradePct (smoothed)")
    w25 = np.full_like(s, np.nan)
    for i in range(len(s) - 25):
        w25[i + 12] = (elev[i + 25] - elev[i]) / 25 * 100
    a2.plot(s, w25, color="#2a9d4b", lw=1.0, label="25 m window")
    cob = R["surf"] == 1
    a2.fill_between(s, -10, -8, where=cob, color="#7a5c3a", alpha=0.7, label="cobbles")
    a2.set_ylim(-10, 32)
    a2.set_xlabel("distance along route s (m)"); a2.set_ylabel("grade (%)")
    a2.legend(loc="upper left", fontsize=8, ncol=2); a2.grid(alpha=0.3)
    for k, lm in enumerate(R["landmarks"]):
        a2.annotate(lm["name"], (lm["s"], 31 - 7 * (k % 2)), rotation=90, fontsize=6, va="top", ha="right", color="#444")
    fig.tight_layout(); fig.savefig(dbg / "profile.png", dpi=110); plt.close(fig)

    # ---- map ----
    rows, cols = dtm.shape
    ext = [oE, oE + cols, oN - rows, oN]
    hs = hillshade(dtm)
    fig, (m1, m2) = plt.subplots(1, 2, figsize=(19, 6.6))
    m1.imshow(hs, cmap="gray", extent=ext, interpolation="bilinear")
    xs_ = oE + 0.5 + np.arange(0, cols, 4); ys_ = oN - 0.5 - np.arange(0, rows, 4)
    cs = m1.contour(xs_, ys_, dtm[::4, ::4], levels=np.arange(0, 200, 5), colors="#8a6d3b", linewidths=0.4, alpha=0.7)
    m1.clabel(cs, cs.levels[::2], fontsize=6, fmt="%d")
    pts = np.column_stack([e, n]).reshape(-1, 1, 2)
    segs = np.concatenate([pts[:-1], pts[1:]], axis=1)
    lc = LineCollection(segs, cmap="turbo", norm=plt.Normalize(-5, 25), linewidths=3)
    lc.set_array(grade[:-1]); m1.add_collection(lc)
    fig.colorbar(lc, ax=m1, fraction=0.03, pad=0.01, label="grade %")
    for ax in (m1, m2):
        for x, mk in ((startS, "o"), (endS, "s")):
            i = int(round(x)); ax.plot(e[i], n[i], mk, ms=8, mfc="none", mec="red", mew=2)
        ax.plot(e[0], n[0], ">", ms=8, color="lime", mec="k")
        ax.set_xlim(ext[0], ext[1]); ax.set_ylim(ext[2], ext[3]); ax.set_aspect("equal")
        ax.set_xlabel("east (local m)"); ax.set_ylabel("north (local m)")
    m1.set_title("near DTM 1 m hillshade, 5 m contours, route coloured by grade (○ start, □ summit, ▶ route start)", fontsize=9)
    ow, oh = ortho.size
    sm = ortho.resize((ow // 2, oh // 2))
    m2.imshow(np.asarray(sm), extent=ext)
    m2.plot(e, n, color="yellow", lw=1.2)
    m2.set_title(f"ortho {cfg['ortho']['layer']} ({cfg['ortho']['season']} {cfg['ortho']['year']}) + route", fontsize=9)
    fig.tight_layout(); fig.savefig(dbg / "map.png", dpi=95); plt.close(fig)
    sm.close()

    # ---- zoom on the climb ----
    pad = 40
    i0, i1 = max(int(startS) - 30, 0), min(int(endS) + 30, len(s) - 1)
    zx0, zx1 = e[i0:i1].min() - pad, e[i0:i1].max() + pad
    zy0, zy1 = n[i0:i1].min() - pad, n[i0:i1].max() + pad
    panels = [("hillshade: OSM centreline (red), refined (cyan)", "hs"), ("summer ortho", "sum")]
    if winter is not None:
        panels.append((f"winter ortho {cfg['validation_ortho']['layer']} (validation only)", "win"))
    fig, axs = plt.subplots(len(panels), 1, figsize=(15, 5.2 * len(panels)))
    for ax, (title, kind) in zip(np.atleast_1d(axs), panels):
        if kind == "hs":
            c0 = int(zx0 - oE); c1 = int(zx1 - oE); r0 = int(oN - zy1); r1 = int(oN - zy0)
            ax.imshow(hs[r0:r1, c0:c1], cmap="gray", extent=[oE + c0, oE + c1, oN - r1, oN - r0])
            ax.plot(R["osm_e"], R["osm_n"], color="red", lw=0.9)
            ax.plot(e, n, color="cyan", lw=0.9)
        else:
            img, ppm = (ortho, mpp) if kind == "sum" else (winter, wmpp)
            crop = img.crop((int((zx0 - oE) / ppm), int((oN - zy1) / ppm), int((zx1 - oE) / ppm), int((oN - zy0) / ppm)))
            ax.imshow(np.asarray(crop), extent=[zx0, zx1, zy0, zy1])
            crop.close()
            ax.plot(e, n, color="yellow", lw=0.6, alpha=0.8)
        for k in range(int(startS // 50) * 50 + 50, int(endS), 50):
            ax.annotate(f"{k - startS:.0f}" if False else f"s{k}", (e[k], n[k]), fontsize=7, color="w",
                        xytext=(3, 6), textcoords="offset points")
            ax.plot(e[k], n[k], "+", color="w", ms=6)
        ax.set_xlim(zx0, zx1); ax.set_ylim(zy0, zy1); ax.set_aspect("equal"); ax.set_title(title, fontsize=9)
    fig.tight_layout(); fig.savefig(dbg / "map_climb_zoom.png", dpi=90); plt.close(fig)

    # ---- straightened corridor (s along x, lateral offset along y) ----
    off = np.arange(-15, 15.001, 0.25)
    EE = e[None, :] + off[:, None] * ne_[None, :]
    NN = n[None, :] + off[:, None] * nn_[None, :]
    rel = bilinear(dtm, oE, oN, 1.0, EE, NN) - elev[None, :]
    canp = bilinear(np.nan_to_num(canopy, nan=0.0), oE, oN, 1.0, EE, NN)
    summ = sample_rgb(np.asarray(ortho), oE, oN, mpp, EE, NN)
    wint = sample_rgb(np.asarray(winter), oE, oN, wmpp, EE, NN) if winter is not None else None
    nseg = 3
    L = len(s)
    bounds = np.linspace(0, L, nseg + 1).astype(int)
    strips = [("DTM − road elevation (m)", "rel"), ("canopy DSM−DTM (m)", "can"), ("summer ortho", "sum")]
    if wint is not None:
        strips.append(("winter ortho", "win"))
    fig, axs = plt.subplots(len(strips) * nseg, 1, figsize=(16, 1.25 * len(strips) * nseg + 1))
    k = 0
    osm_off = -R["refine_off"]
    for sg in range(nseg):
        a, b = bounds[sg], bounds[sg + 1]
        ex = [s[a], s[b - 1], off[0], off[-1]]
        for title, kind in strips:
            ax = axs[k]; k += 1
            if kind == "rel":
                im = ax.imshow(rel[::-1, a:b], extent=ex, aspect="auto", cmap="RdBu_r", vmin=-3, vmax=3)
            elif kind == "can":
                im = ax.imshow(canp[::-1, a:b], extent=ex, aspect="auto", cmap="Greens", vmin=0, vmax=15)
            elif kind == "sum":
                ax.imshow(np.clip(summ[::-1, a:b], 0, 255).astype(np.uint8), extent=ex, aspect="auto")
            else:
                ax.imshow(np.clip(wint[::-1, a:b], 0, 255).astype(np.uint8), extent=ex, aspect="auto")
            hw = width[a:b] / 2
            ax.plot(s[a:b], hw, color="yellow", lw=0.6); ax.plot(s[a:b], -hw, color="yellow", lw=0.6)
            hwn = np.where(R["width_nom"][a:b] > width[a:b] + 0.01, R["width_nom"][a:b] / 2, np.nan)
            ax.plot(s[a:b], hwn, color="orange", lw=0.5, ls=":"); ax.plot(s[a:b], -hwn, color="orange", lw=0.5, ls=":")
            ax.plot(s[a:b], osm_off[a:b], color="red", lw=0.6, ls="--")
            for x in (startS, endS):
                if s[a] <= x <= s[b - 1]:
                    ax.axvline(x, color="magenta", lw=1)
            ax.set_ylabel(title, fontsize=6, rotation=0, ha="right", va="center")
            ax.tick_params(labelsize=6)
            ax.set_ylim(-15, 15)
    axs[-1].set_xlabel("s (m) — left = right-hand side of travel is +offset (top of each strip); yellow = carriageway edges, "
                       "orange dotted = nominal width where bank-limited, red dashed = original OSM centreline, magenta = climb start/summit", fontsize=7)
    fig.tight_layout(h_pad=0.2); fig.savefig(dbg / "corridor.png", dpi=90); plt.close(fig)
    del EE, NN, rel, canp, summ, wint

    # ---- far grid ----
    if far is not None:
        fh = far_hdr
        fext = [fh["originEast"], fh["originEast"] + fh["cols"] * fh["cellM"],
                fh["originNorth"] - fh["rows"] * fh["cellM"], fh["originNorth"]]
        fig, ax = plt.subplots(figsize=(8, 7.5))
        ax.imshow(hillshade(far, fh["cellM"], zf=3.0), cmap="gray", extent=fext)
        im = ax.imshow(far, cmap="terrain", extent=fext, alpha=0.45, vmin=0, vmax=max(110.0, float(np.nanmax(far))))
        fig.colorbar(im, ax=ax, fraction=0.04, label="m TAW")
        ax.add_patch(plt.Rectangle((ext[0], ext[2]), ext[1] - ext[0], ext[3] - ext[2], fill=False, ec="red", lw=1))
        ax.plot(e, n, color="k", lw=1.5)
        ax.set_title(f"far grid {fh['cols']}x{fh['rows']} @ {fh['cellM']:g} m (red = near grid)", fontsize=9)
        fig.tight_layout(); fig.savefig(dbg / "map_far.png", dpi=90); plt.close(fig)

    # ---- sunken-lane width: +-5 m sections at the narrowest places, and widths along s ----
    if "width_nom" in R and np.any(R["width_nom"] > width + 0.01):
        nar = np.flatnonzero(R["width_nom"] > width + 0.01)
        pick = nar[np.linspace(0, len(nar) - 1, 9).round().astype(int)]
        fig = plt.figure(figsize=(16, 12))
        gs = fig.add_gridspec(4, 3, height_ratios=[1, 1, 1, 0.9])
        offw = np.arange(-5, 5.001, 0.05)
        for k_, i in enumerate(pick):
            ax = fig.add_subplot(gs[k_ // 3, k_ % 3])
            zt = bilinear(dtm, oE, oN, 1.0, e[i] + offw * ne_[i], n[i] + offw * nn_[i])
            zc = float(bilinear(dtm, oE, oN, 1.0, e[i], n[i]))
            ax.plot(offw, zt, color="#6b4f2a", lw=1.6, label="DTM 1 m (bilinear)")
            ax.axhline(elev[i], color="#1f5fbf", lw=1.1, label="road elevation")
            ax.axhline(max(elev[i], zc) + cfg["bank_tol_m"], color="#1f5fbf", lw=0.7, ls=":",
                       label=f"road level + {cfg['bank_tol_m']} m (bank test)")
            ax.axvspan(-width[i] / 2, width[i] / 2, color="#1f5fbf", alpha=0.15, label=f"shipped {width[i]:.2f} m")
            for sg_ in (-1, 1):
                ax.axvline(sg_ * R["width_nom"][i] / 2, color="orange", lw=1, ls="--",
                           label=f"nominal {R['width_nom'][i]:.2f} m" if sg_ < 0 else None)
            zr = zt[np.abs(offw) <= 4]
            ax.set_ylim(elev[i] - 0.4, min(np.nanmax(zr), elev[i] + 3.0) + 0.2)
            ax.set_title(f"s={s[i]:.0f} m: clear {R['clear_w'][i]:.2f} m, shipped {width[i]:.2f} m", fontsize=9)
            ax.set_xlabel("lateral offset, + = right (m)", fontsize=8); ax.grid(alpha=0.3); ax.tick_params(labelsize=7)
            if k_ == 0:
                ax.legend(fontsize=6, loc="upper center")
        ax = fig.add_subplot(gs[3, :])
        ax.plot(s, R["width_nom"], color="orange", lw=1, ls="--", label="nominal (per OSM way)")
        ax.plot(s, np.minimum(R["clear_w"], R["width_nom"]), color="#888", lw=0.6,
                label=f"clear floor width (2 × nearer side, DTM ≤ road + {cfg['bank_tol_m']} m)")
        ax.plot(s, width, color="#1f5fbf", lw=1.5, label="shipped widthM (σ 2 m, floor %.1f m)" % cfg["min_width_m"])
        for x in (startS, endS):
            ax.axvline(x, color="magenta", lw=0.8)
        ax.set_ylim(1.5, 5); ax.set_xlabel("s (m)"); ax.set_ylabel("width (m)"); ax.grid(alpha=0.3)
        ax.legend(fontsize=7, loc="upper right", ncol=3)
        fig.tight_layout(); fig.savefig(dbg / "lane_width.png", dpi=90); plt.close(fig)

    # ---- cross sections ----
    L_ = endS - startS
    at = [("climb start +15 m", startS + 15), (f"steepest 25 m centre", st["at25"]),
          ("summit −15 m", endS - 15)] + [(f"climb +{f * L_:.0f} m", startS + f * L_) for f in (0.2, 0.45, 0.8)]
    fig, axs = plt.subplots(2, 3, figsize=(16, 8.5))
    offx = np.arange(-25, 25.01, 0.25)
    for ax, (lab, x) in zip(axs.ravel(), at):
        i = int(round(x))
        zt = bilinear(dtm, oE, oN, 1.0, e[i] + offx * ne_[i], n[i] + offx * nn_[i])
        zs = bilinear(dsm, oE, oN, 1.0, e[i] + offx * ne_[i], n[i] + offx * nn_[i])
        ax.fill_between(offx, zt, zs, color="#4c9a4c", alpha=0.25, label="DSM above DTM (trees, hedges)")
        ax.plot(offx, zt, color="#6b4f2a", lw=1.6, label="DTM 1 m")
        hw = width[i] / 2
        ax.axvspan(-hw, hw, color="#1f5fbf", alpha=0.12, label=f"carriageway {width[i]:.2f} m (route)")
        if R["width_nom"][i] > width[i] + 0.01:
            for sg_ in (-1, 1):
                ax.axvline(sg_ * R["width_nom"][i] / 2, color="orange", lw=0.9, ls=":",
                           label=f"nominal {R['width_nom'][i]:.2f} m (narrowed: bank)" if sg_ < 0 else None)
        ax.axvline(0, color="#1f5fbf", lw=0.8)
        ax.axvline(osm_off[i], color="red", lw=0.9, ls="--", label="OSM centreline")
        ax.axhline(z_raw[i], color="#e08a2c", lw=1, ls="--", label=f"p{pct:.0f} sample")
        ax.axhline(elev[i], color="#1f5fbf", lw=1.1, label="smoothed road elevation")
        zr = zt[np.abs(offx) < 12]
        ax.set_ylim(np.nanmin(zr) - 1.0, np.nanmax(zr) + 3)
        ax.set_title(f"{lab}: s={s[i]:.0f} m, grade {grade[i]:.1f} %, OSM offset {osm_off[i]:+.1f} m", fontsize=9)
        ax.set_xlabel("lateral offset, + = right of travel (m)"); ax.set_ylabel("m TAW"); ax.grid(alpha=0.3)
    axs[0, 0].legend(fontsize=7, loc="upper left")
    fig.tight_layout(); fig.savefig(dbg / "cross_sections.png", dpi=100); plt.close(fig)


# ---------------------------------------------------------------------------
# Independent self-check (reads only what was written to disk)
# ---------------------------------------------------------------------------

# Mirror of CourseData.swift: field -> (type, optional)
SWIFT_SCHEMA = {
    "CourseFile": {"schemaVersion": ("int", False), "id": ("str", False), "name": ("str", False),
                   "region": ("str", False), "origin": ("Origin", False), "attribution": ("[str]", False),
                   "sources": ("[Source]", True), "climb": ("ClimbRange", False), "stats": ("Stats", False),
                   "route": ("RouteArrays", False), "surfaces": ("[str]", False),
                   "surfaceCrr": ("{num}", False), "landmarks": ("[Landmark]", False),
                   "terrain": ("TerrainSet", False), "canopy": ("RasterHeader", True),
                   "ortho": ("OrthoHeader", True), "scenery": ("str", True)},
    "Origin": {"lambert72": ("[num]", False), "wgs84": ("[num]", False)},
    "Source": {"name": ("str", False), "url": ("str", True), "retrieved": ("str", True), "notes": ("str", True)},
    "ClimbRange": {"startS": ("num", False), "endS": ("num", False)},
    "Stats": {"totalLengthM": ("num", False), "climbLengthM": ("num", False), "climbGainM": ("num", False),
              "climbAvgGradePct": ("num", False), "climbMaxGradePct10m": ("num", True),
              "climbMaxGradePct25m": ("num", True), "climbMaxGradePct50m": ("num", True),
              "startElevationM": ("num", True), "summitElevationM": ("num", True), "per100m": ("[Per100]", True)},
    "Per100": {"fromS": ("num", False), "toS": ("num", False), "avgGradePct": ("num", False)},
    "RouteArrays": {"spacingM": ("num", False), "s": ("[num]", False), "east": ("[num]", False),
                    "north": ("[num]", False), "elev": ("[num]", False), "gradePct": ("[num]", False),
                    "widthM": ("[num]", False), "surface": ("[int]", False)},
    "Landmark": {"s": ("num", False), "kind": ("str", False), "name": ("str", False)},
    "TerrainSet": {"near": ("RasterHeader", False), "far": ("RasterHeader", True)},
    "RasterHeader": {"file": ("str", False), "encoding": ("str", False), "baseM": ("num", False),
                     "originEast": ("num", False), "originNorth": ("num", False), "cellM": ("num", False),
                     "cols": ("int", False), "rows": ("int", False)},
    "OrthoHeader": {"file": ("str", False), "originEast": ("num", False), "originNorth": ("num", False),
                    "widthM": ("num", False), "heightM": ("num", False), "pixelsWide": ("int", False),
                    "pixelsHigh": ("int", False), "capturedSeason": ("str", True), "capturedYear": ("int", True)},
}


def _check_type(v, t, path, errs):
    if t.startswith("["):
        if not isinstance(v, list):
            errs.append(f"{path}: expected array"); return
        for k, x in enumerate(v):
            _check_type(x, t[1:-1], f"{path}[{k}]", errs)
        return
    if t.startswith("{"):
        if not isinstance(v, dict):
            errs.append(f"{path}: expected object"); return
        for k, x in v.items():
            _check_type(x, t[1:-1], f"{path}.{k}", errs)
        return
    if t == "str":
        if not isinstance(v, str): errs.append(f"{path}: expected string")
    elif t == "int":
        if not (isinstance(v, int) and not isinstance(v, bool)): errs.append(f"{path}: expected Int, got {v!r}")
    elif t == "num":
        if not (isinstance(v, (int, float)) and not isinstance(v, bool)) or (isinstance(v, float) and not math.isfinite(v)):
            errs.append(f"{path}: expected finite number")
    elif t in SWIFT_SCHEMA:
        if not isinstance(v, dict):
            errs.append(f"{path}: expected {t} object"); return
        for f_, (ft, opt) in SWIFT_SCHEMA[t].items():
            if f_ not in v or v[f_] is None:
                if not opt:
                    errs.append(f"{path}.{f_}: missing non-optional field")
                continue
            _check_type(v[f_], ft, f"{path}.{f_}", errs)
    else:
        errs.append(f"{path}: unknown type {t}")


def self_check(out: Path, pipe: Path, log, dtm_mem: np.ndarray, near_oE: float, near_oN: float) -> bool:
    from PIL import Image

    errs: list[str] = []
    warn: list[str] = []
    raw = (out / "course.json").read_bytes()
    c = json.loads(raw)
    _check_type(c, "CourseFile", "course", errs)
    r = c["route"]
    n = len(r["s"])
    for k in ("east", "north", "elev", "gradePct", "widthM", "surface"):
        if len(r[k]) != n:
            errs.append(f"route.{k} length {len(r[k])} != {n}")
    sarr = np.array(r["s"])
    if not np.all(np.diff(sarr) > 0):
        errs.append("route.s not strictly increasing")
    if abs(sarr[0]) > 1e-9 or not np.allclose(np.diff(sarr), r["spacingM"]):
        errs.append("route.s does not start at 0 with spacingM steps")
    if max(r["surface"]) >= len(c["surfaces"]) or min(r["surface"]) < 0:
        errs.append("surface index out of range")
    for sname in c["surfaces"]:
        if sname not in c["surfaceCrr"]:
            errs.append(f"surfaceCrr missing {sname}")
    cl = c["climb"]
    if not (0 <= cl["startS"] < cl["endS"] <= sarr[-1]):
        errs.append("climb range outside route")
    if abs(c["stats"]["totalLengthM"] - sarr[-1]) > 1e-6:
        errs.append("stats.totalLengthM != last s")
    if (out / c["ortho"]["file"]).exists():
        errs.append(f"{c['ortho']['file']} is in the shipped course folder (pipeline-only)")

    def load(h):
        b = (out / h["file"]).read_bytes()
        if len(b) != h["cols"] * h["rows"] * 2:
            errs.append(f"{h['file']}: {len(b)} bytes, expected {h['cols'] * h['rows'] * 2}")
            return None
        if h["encoding"] != "u16le_cm":
            errs.append(f"{h['file']}: encoding {h['encoding']}")
        a = np.frombuffer(b, dtype="<u2").reshape(h["rows"], h["cols"])
        v = np.where(a == 65535, np.nan, h["baseM"] + a.astype(np.float32) / 100.0).astype(np.float32)
        return v

    near_h = c["terrain"]["near"]; far_h = c["terrain"]["far"]; can_h = c["canopy"]
    near = load(near_h); far = load(far_h); can = load(can_h)
    for nm, a in (("near", near), ("far", far), ("canopy", can)):
        if a is not None:
            log(f"[check] {nm}: {a.shape[1]}x{a.shape[0]}, nodata {int(np.isnan(a).sum())}, "
                f"range {np.nanmin(a):.2f}..{np.nanmax(a):.2f}")
    if near is not None:
        # Swift-like sampler, written independently of bilinear()
        def swift_sample(h, a, e, nn):
            fc = (e - h["originEast"]) / h["cellM"] - 0.5
            fr = (h["originNorth"] - nn) / h["cellM"] - 0.5
            c0 = int(math.floor(fc)); r0 = int(math.floor(fr))
            tx = fc - c0; ty = fr - r0
            def v(rr, cc):
                return float(a[min(max(rr, 0), h["rows"] - 1), min(max(cc, 0), h["cols"] - 1)])
            top = v(r0, c0) + (v(r0, c0 + 1) - v(r0, c0)) * tx
            bot = v(r0 + 1, c0) + (v(r0 + 1, c0 + 1) - v(r0 + 1, c0)) * tx
            return top + (bot - top) * ty
        E = np.array(r["east"]); N = np.array(r["north"]); Z = np.array(r["elev"])
        inside = ((E >= near_h["originEast"] + 50) & (E <= near_h["originEast"] + near_h["cols"] - 50) &
                  (N <= near_h["originNorth"] - 50) & (N >= near_h["originNorth"] - near_h["rows"] + 50))
        if not inside.all():
            errs.append(f"{int((~inside).sum())} route stations within 50 m of / outside the near-grid edge")
        dz = np.array([Z[i] - swift_sample(near_h, near, E[i], N[i]) for i in range(n)])
        log(f"[check] route elev − DTM(centreline, decoded): median {np.median(dz):+.2f} m, "
            f"p5 {np.percentile(dz, 5):+.2f}, p95 {np.percentile(dz, 95):+.2f}, max |{np.abs(dz).max():.2f}| m")
        if np.abs(dz).max() > 3.0:
            warn.append(f"route elevation departs from centreline DTM by up to {np.abs(dz).max():.2f} m")
        # terrain inside the shipped carriageway ribbon vs the road level (banks poking through the edges)
        W_ = np.array(r["widthM"])
        ke_ = np.arange(n); a_ = np.clip(ke_ - 2, 0, n - 1); b_ = np.clip(ke_ + 2, 0, n - 1)
        te_ = E[b_] - E[a_]; tn_ = N[b_] - N[a_]; L_ = np.hypot(te_, tn_); te_ /= L_; tn_ /= L_
        rise = np.empty(n)
        for i in range(n):
            zc = swift_sample(near_h, near, E[i], N[i])
            ref = max(Z[i], zc)
            rise[i] = max(swift_sample(near_h, near, E[i] + o * tn_[i], N[i] - o * te_[i])
                          for o in np.arange(-W_[i] / 2, W_[i] / 2 + 1e-9, 0.25)) - ref
        log(f"[check] DTM inside the carriageway above max(elev, centre DTM): p95 {np.percentile(rise, 95):.2f} m, "
            f"max {rise.max():.2f} m, {int((rise > 0.3).sum())} stations > 0.3 m")
        if (rise > 0.3).sum() > 10:
            warn.append(f"{int((rise > 0.3).sum())} stations have terrain > 0.3 m above the road inside the carriageway")
        # decoded raster equals in-memory DTM within quantisation
        q = np.nanmax(np.abs(near - dtm_mem))
        if q > 0.0051:
            errs.append(f"near raster round-trip error {q:.4f} m")
        if near_h["originEast"] != near_oE or near_h["originNorth"] != near_oN:
            errs.append("near header origin mismatch")
        # far vs near consistency (block-average the near grid where they overlap)
        fe0 = far_h["originEast"]; fn0 = far_h["originNorth"]; fc_ = far_h["cellM"]
        c0 = (near_h["originEast"] - fe0) / fc_; r0 = (fn0 - near_h["originNorth"]) / fc_
        if abs(c0 - round(c0)) < 1e-6 and abs(r0 - round(r0)) < 1e-6 and far is not None:
            k = int(fc_)
            rr = near_h["rows"] // k; cc = near_h["cols"] // k
            blk = near[:rr * k, :cc * k].reshape(rr, k, cc, k).mean(axis=(1, 3))
            sub = far[int(r0):int(r0) + rr, int(c0):int(c0) + cc]
            d = blk - sub
            log(f"[check] far vs block-averaged near: median {np.nanmedian(d):+.3f} m, max |{np.nanmax(np.abs(d)):.2f}| m")
            if np.nanmax(np.abs(d)) > 0.5:
                warn.append("far grid differs from near grid by > 0.5 m somewhere")
            # seam: bilinear far grid vs near grid along the near-grid border (resolution-inherent, for the app)
            rr_, cc_ = near.shape
            border = [(0, c_) for c_ in range(cc_)] + [(rr_ - 1, c_) for c_ in range(cc_)] + \
                     [(r__, 0) for r__ in range(rr_)] + [(r__, cc_ - 1) for r__ in range(rr_)]
            bd = np.array([swift_sample(far_h, far, near_h["originEast"] + c_ + 0.5, near_h["originNorth"] - r__ - 0.5)
                           - float(near[r__, c_]) for r__, c_ in border])
            log(f"[check] seam: far (bilinear) − near along the near-grid border: p99 |{np.percentile(np.abs(bd), 99):.2f}| m, "
                f"max |{np.abs(bd).max():.2f}| m (10 m vs 1 m resolution; the app should skirt or blend the seam)")
        else:
            warn.append("near grid not aligned with far grid cells")
        if can is not None and can.shape != near.shape:
            errs.append("canopy grid shape != near grid")
        if (can_h["originEast"], can_h["originNorth"], can_h["cellM"]) != (near_h["originEast"], near_h["originNorth"], near_h["cellM"]):
            errs.append("canopy header != near header")
    o = c["ortho"]
    with Image.open(pipe / o["file"]) as im:
        if im.format != "JPEG":
            errs.append("ortho is not JPEG")
        if im.size != (o["pixelsWide"], o["pixelsHigh"]):
            errs.append(f"ortho pixel size {im.size} != header")
        if (o["originEast"], o["originNorth"]) != (near_h["originEast"], near_h["originNorth"]) or \
                abs(o["widthM"] - near_h["cols"] * near_h["cellM"]) > 1e-6 or abs(o["heightM"] - near_h["rows"] * near_h["cellM"]) > 1e-6:
            errs.append("ortho footprint != near grid footprint")
        # georeference: correlate ortho luminance edges with canopy-height edges at 1 m
        if can is not None:
            g = np.asarray(im.convert("L").resize((near_h["cols"], near_h["rows"]), Image.BILINEAR), dtype=np.float32)
            shift, peak = edge_shift(g, np.nan_to_num(can, nan=0.0))
            log(f"[check] ortho vs canopy edge alignment: best shift (east {shift[0]:+.0f} m, north {shift[1]:+.0f} m), "
                f"peak score {peak:.3f}")
            if max(abs(shift[0]), abs(shift[1])) > 3:
                warn.append(f"ortho may be offset from the terrain by {shift} m")
            del g
    if c.get("scenery") and not (out / c["scenery"]).exists():
        warn.append(f"{c['scenery']} not present yet (written by another step; app treats it as optional)")
    for e_ in errs:
        log(f"[check] ERROR {e_}")
    for w_ in warn:
        log(f"[check] warning: {w_}")
    log(f"[check] {'PASS' if not errs else 'FAIL'} ({len(errs)} errors, {len(warn)} warnings)")
    return not errs


def edge_shift(img: np.ndarray, ref: np.ndarray, maxs: int = 8):
    """Integer shift (east, north) maximising normalised correlation of gradient magnitudes."""
    def gm(a):
        gy, gx = np.gradient(a.astype(np.float32))
        m = np.hypot(gx, gy)
        m = np.clip(m, 0, np.percentile(m, 99))
        return (m - m.mean()) / (m.std() + 1e-6)
    A = gm(img); B = gm(ref)
    best, at = -1.0, (0, 0)
    h, w = A.shape
    core = (slice(maxs, h - maxs), slice(maxs, w - maxs))
    Bc = B[core]
    for dy in range(-maxs, maxs + 1):
        for dx in range(-maxs, maxs + 1):
            As = A[maxs + dy:h - maxs + dy, maxs + dx:w - maxs + dx]
            sc = float(np.mean(As * Bc))
            if sc > best:
                best, at = sc, (dx, dy)
    # A sampled at (row+dy, col+dx) matches B at (row, col): ortho content sits dx east, -dy north of terrain
    return (at[0], -at[1]), best


SWIFT_PROBE = r"""
import Foundation
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
do {
    let course = try JSONDecoder().decode(CourseFile.self, from: Data(contentsOf: dir.appendingPathComponent("course.json")))
    let route = try CourseRoute(course.route, surfaceNames: course.surfaces)
    let near = try HeightRaster.load(from: dir.appendingPathComponent(course.terrain.near.file), header: course.terrain.near)
    if let f = course.terrain.far { _ = try HeightRaster.load(from: dir.appendingPathComponent(f.file), header: f) }
    if let c = course.canopy { _ = try HeightRaster.load(from: dir.appendingPathComponent(c.file), header: c) }
    var maxd: Float = 0
    var s = 0.0
    while s <= route.length {
        let p = route.planar(at: s)
        maxd = max(maxd, abs(Float(route.elevation(at: s)) - near.sample(east: p.x, north: p.y)))
        s += 1
    }
    print("swift decode OK: \(route.count) stations, \(route.length) m; max |route elev - near.sample| = \(maxd) m")
} catch {
    print("swift decode FAILED: \(error)")
    exit(1)
}
"""


def swift_check(course_id: str) -> int:
    """Compile the app's own decoder (CourseData/HeightRaster/CourseRoute.swift) with swiftc and decode."""
    import subprocess
    import tempfile
    model = REPO / "CycleJames" / "Courses" / "Model"
    with tempfile.TemporaryDirectory() as td:
        main_swift = Path(td) / "main.swift"
        main_swift.write_text(SWIFT_PROBE)
        exe = Path(td) / "probe"
        cmd = ["swiftc", "-Onone", "-o", str(exe), str(model / "CourseData.swift"), str(model / "HeightRaster.swift"),
               str(model / "CourseRoute.swift"), str(main_swift)]
        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr[-2000:])
            return 1
        r = subprocess.run([str(exe), str(OUT_ROOT / course_id)], capture_output=True, text=True)
        print(r.stdout.strip() or r.stderr.strip())
        return r.returncode


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("course", choices=sorted(COURSES))
    ap.add_argument("--swift-check", action="store_true",
                    help="after building, compile the app's Swift decoder with swiftc and decode the output")
    args = ap.parse_args(argv)
    rc = build(args.course)
    if rc == 0 and args.swift_check:
        rc = swift_check(args.course)
    return rc


if __name__ == "__main__":
    sys.exit(main())
