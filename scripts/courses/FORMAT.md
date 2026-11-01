# Course data format (v1)

Baked course data for the 3D climb simulator. One folder per course under
`CycleJames/Resources/Courses/<course-id>/`, produced by the pipeline in
`scripts/courses/` from open data. The app only reads these files; it never
calls a map or elevation service at runtime. That folder is copied into the
app as a folder reference, so everything in it ships: inputs only the
pipeline needs live in `scripts/courses/pipeline/<course-id>/` instead (see
[Pipeline-only data](#pipeline-only-data)).

## Frames and units

- **Horizontal CRS:** one projected CRS per course, in metres: Belgian
  Lambert 72 (EPSG:31370) for the Flemish bergs, RDN2008 / UTM zone 32N with
  east, north axes (EPSG:7791) for the Poggio. `course.json → origin` names it
  (`origin.crs`; Lambert 72 when absent). Every file stores *local*
  coordinates: `east = E − origin E`, `north = N − origin N`, where the origin
  is `origin.lambert72` or `origin.projected`.
- **Vertical:** metres above the course's own datum: TAW/DNG (the native datum
  of DHM Vlaanderen) for the Flemish bergs, the Italian orthometric datum
  (Genova 1942 tide gauge) for the Poggio, where mean sea level is 0 m.
- **App mapping (SceneKit, right-handed, y up):** `x = east`, `y = elevation`,
  `z = −north`.
- **Raster layout:** row-major, row 0 is the **north** edge, column 0 the **west**
  edge. `originEast/originNorth` of a raster is the **north-west corner** of
  cell (0,0) in local coordinates. Cell (r,c) centre =
  `(originEast + (c + 0.5)·cellM, originNorth − (r + 0.5)·cellM)`.
- **Raster encoding `u16le_cm`:** little-endian `UInt16`,
  `value_m = baseM + raw / 100` (655.34 m of range above `baseM`);
  `raw == 65535` means no data. **`u16le_dm`** is the same with
  `raw / 10` (6553.4 m), for `terrain.horizon`'s mountains.
- **The sea** (a coastal course, `course.json → sea`): every terrain raster
  holds `sea.levelM − 1` m over it, so the app's water plane at `levelM`
  covers it; the canopy is 0 there. No raster has nodata on such a course.
- **Direction of travel:** the route always runs in the direction it is raced
  (uphill for the Koppenberg, the Oude Kwaremont, the Paterberg, the Muur
  van Geraardsbergen, the Molenberg, the Taaienberg and the Poggio di
  Sanremo, which then turns sharp left into the descent).

## `course.json`

```jsonc
{
  "schemaVersion": 1,
  "id": "koppenberg",
  "name": "Koppenberg",
  "region": "Melden, Oudenaarde · Flemish Ardennes",
  // Flemish bergs: { "lambert72": [E, N], "wgs84": [lat, lon] }; elsewhere the CRS is named:
  "origin": { "crs": "EPSG:7791", "projected": [E, N], "wgs84": [lat, lon] },
  "attribution": ["© OpenStreetMap contributors (ODbL)", "…"],
  "sources": [{ "name": "…", "url": "…", "retrieved": "YYYY-MM-DD", "notes": "…" }],

  // The timed climb, as distances along the route (metres).
  "climb": { "startS": 312.0, "endS": 912.0 },

  "stats": {
    "totalLengthM": 0, "climbLengthM": 0, "climbGainM": 0,
    "climbAvgGradePct": 0,
    "climbMaxGradePct10m": 0, "climbMaxGradePct25m": 0, "climbMaxGradePct50m": 0,
    "startElevationM": 0, "summitElevationM": 0,
    // Consecutive 100 m slices of the climb. fromS/toS are distances along the
    // route (same frame as climb.startS/endS), not relative to the climb start;
    // the first slice starts at climb.startS and the last one may be shorter.
    "per100m": [{ "fromS": 312.0, "toS": 412.0, "avgGradePct": 0 }]
  },

  // Resampled centreline at a fixed spacing; all arrays have the same length.
  "route": {
    "spacingM": 1.0,
    "s": [],          // distance along route, metres, starts at 0
    "east": [],       // local metres
    "north": [],      // local metres
    "elev": [],       // smoothed road-surface elevation, metres (the course's vertical datum)
    "gradePct": [],   // d(elev)/ds × 100 from the smoothed curve
    "widthM": [],     // carriageway width
    "surface": []     // index into "surfaces"
    // east/north follow the OSM ways, moved onto the sunken-lane floor (DTM
    // trough fit, the Koppenberg) or onto the middle of the surveyed
    // carriageway (GRB WGO edges, every other berg). widthM is narrowed to the clear floor where a bank rises inside
    // a lane of at most 5 m nominal (never below 2.5 m), and a cobbled one to
    // max_cobbled_width_m where the course sets it (the Muur's Markt: the
    // app's far sett map spans 5.6 m). elev is carried straight across
    // bridges (the Muur's over the Dender, the Molenberg's over the beek by
    // the mill), where the DTM is the water.
    // The Poggio's centreline is moved onto the middle of the surveyed
    // carriageway of the Carta Tecnica Regionale (its road-area polygons),
    // except where it is smoothed on purpose: the fork off the Via Aurelia
    // (OSM's 8 m sideways step) and the summit hairpin's racing line. Its
    // widthM is widened at both (9 m, 11 m), and its carriageway is laid
    // level across in terrain.near (the 1 m DTM blurs the walls at its
    // edges), so elev equals the terrain under the road.
  },
  // "concrete" is appended only when the route has some (the Paterberg's exit
  // along the concrete-plate Stooktestraat); the app draws it as pale slabs and
  // rides it like asphalt.
  "surfaces": ["asphalt", "cobbles"],

  // Rolling-resistance coefficient per surface (sent to the trainer, used by physics).
  "surfaceCrr": { "asphalt": 0.0040, "cobbles": 0.0090 },   // + "concrete": 0.0045 when listed

  "landmarks": [{ "s": 0, "kind": "climbStart|summit|steepest|junction|village|note", "name": "…" }],

  "terrain": {
    "near": { "file": "terrain_near.u16", "encoding": "u16le_cm", "baseM": 0,
              "originEast": 0, "originNorth": 0, "cellM": 1.0, "cols": 0, "rows": 0 },
    // 5 km square centred on the origin; on the Poggio the near DTM is
    // block-averaged into it inside terrain.near's footprint.
    "far":  { "file": "terrain_far.u16",  "encoding": "u16le_cm", "baseM": 0,
              "originEast": 0, "originNorth": 0, "cellM": 10.0, "cols": 0, "rows": 0 },
    // Optional: coarse land out to the skyline beyond "far" (the Poggio: a
    // 44 km square at 50 m centred on the origin, the Alpi Liguri and the
    // coast to Bordighera and Capo Berta). Absent for the Flemish bergs.
    "horizon": { "file": "terrain_horizon.u16", "encoding": "u16le_dm", "baseM": 0,
                 "originEast": -22000, "originNorth": 22000, "cellM": 50.0, "cols": 880, "rows": 880 }
  },
  // Canopy/object height above ground (DSM − DTM), same grid as terrain.near.
  "canopy": { "file": "canopy_near.u16", "encoding": "u16le_cm", "baseM": 0,
              "originEast": 0, "originNorth": 0, "cellM": 1.0, "cols": 0, "rows": 0 },
  // Aerial photo over terrain.near (optional). The app drapes the baked
  // CourseTextures/<id>_ortho_ground.jpg over this footprint. "file" is the
  // raw photo, which stays in scripts/courses/pipeline/<id>/ (not shipped);
  // the app falls back to it only if it is in this folder.
  "ortho": { "file": "ortho_near.jpg", "originEast": 0, "originNorth": 0,
             "widthM": 0, "heightM": 0, "pixelsWide": 0, "pixelsHigh": 0,
             "capturedSeason": "summer|winter", "capturedYear": 0 },
  "scenery": "scenery.json",
  // Optional, a coastal course only (the Poggio): mean sea level in the
  // course's vertical datum (see "The sea" above).
  "sea": { "levelM": 0.0 }
}
```

The Poggio's far land also has its own aerial photo,
`CycleJames/Resources/CourseTextures/poggio_ortho_far.jpg`: AGEA's 2022
ortho from Regione Liguria's WMS, north up, exactly over `terrain.far`'s
footprint at 2.5 m/px (2000 × 2000 px), where the Flemish bergs use the
generic `cj_farfields`.

Attribution lines are shown on the course page. Lines naming
"OpenStreetMap" link to openstreetmap.org/copyright and lines naming
"Modellicentie Gratis Hergebruik" link to that licence
(`CourseLicence` in `CourseDetailView.swift`); keep those names in the text.
The Poggio's Italian sources (Regione Liguria, INGV and AGEA's 2022 ortho) are
CC BY 4.0 and say so in their lines. That licence also asks for a note of any
changes, so the ortho's line says how the photo was changed; keep it in step
with what `textures/bake_course_maps.py` does to the photo.

## `scenery.json`

```jsonc
{
  "schemaVersion": 1,
  "buildings": [{ "ring": [[e, n], …], "heightM": 7.5,
                  "roofShape": "gabled|hipped|flat|unknown|sawtooth|tunnel",
                  "kind": "house|farm|barn|church|chapel|other|greenhouse|cistern", "groundElevM": 0,
                  "eavesM": 6.1, "levels": 2 }],          // eavesM, levels: optional (the Poggio's CTR)
  "trees":     [{ "e": 0, "n": 0, "heightM": 12.0, "crownRadiusM": 3.5,
                  "kind": "deciduous|conifer|pine|umbrellaPine|cypress|palm|fanPalm|olive|araucaria" }],
  "shrubs":    [{ "e": 0, "n": 0, "heightM": 1.8, "radiusM": 0.9 }],
  "landuse":   [{ "kind": "farmland|meadow|forest|residential|orchard|scrub|grass|greenhouse|olive|terraces|garden",
                  "ring": [[e, n], …] }],
  "roads":     [{ "name": "…", "widthM": 3.5, "surface": "asphalt|cobbles|gravel|unpaved",
                  "points": [[e, n], …] }],      // side roads near the route, not the route itself,
                                                  // at grade only (no tunnels or raised decks; see below)
  "fences":    [{ "kind": "fence|wall|hedge", "points": [[e, n], …] }],
  "water":     [{ "kind": "stream|pond", "points": [[e, n], …], "closed": false }],
  // Optional (the Poggio only): walls from a regional map with their surveyed crests.
  "walls":     [{ "kind": "retaining|terrace|masonry|parapet|fence", "points": [[e, n, crestElevM], …],
                  "heightM": 1.6 }]
}
```

All rings are closed implicitly (do not repeat the first point) and wound
counter-clockwise in (east, north).

- `heightM` is a building's top above `groundElevM` (its ridge, or a flat
  roof's parapet); `groundElevM` is the lowest ground in the footprint.
  `eavesM`, where present, is the eaves' height above `groundElevM` (the
  Poggio: the Liguria CTR's surveyed eaves, Z − ground), `levels` an estimate
  of the storeys from it.
- No footprint reaches the ride's carriageway. On the Poggio every ring
  stops at least 0.3 m outside it (the route's `widthM`, both legs of each
  hairpin and of the summit loop): the CTR's footprints overlap its own road
  area by up to half a metre, so the part in the band is pulled back along
  the edge. Mapped greenhouses and buildings the summer 2022 photo and the
  2024 ride show gone are left out.
- Greenhouses (`kind` "greenhouse") are `roofShape` "sawtooth" (multi-span
  glass, Venlo) or "tunnel" (plastic film); `heightM` is the ridge, ~3–6 m.
  A mapped greenhouse that falls more than 2.5 m across its footprint (one
  CTR polygon over several terraces) is written as strips across the fall,
  2 m of it each, every strip its own entry with its own `groundElevM` and a
  ridge at least 2.6 m over its highest ground (`heightM` up to 7 m); strips
  have no `eavesM`.
  A "cistern" is a round irrigation tank (the CTR's Cisterna, Vasca); its
  `heightM` is its rim or, for a tower, its top.
- Tree `kind` is optional: absent where the data cannot tell, so the app
  picks a form from the crown's shape, the landuse and its planting zones.
  The Flemish bergs write "deciduous" everywhere.
- `walls[].points` carry the crest's elevation (same datum as the terrain)
  at every vertex; `heightM` is the wall's typical height, the median of the
  crest over the lower side (retaining walls, terraces) or the higher side
  (free-standing walls) along it. "terrace" is an agricultural dry-stone
  terrace (fasce); "parapet" a masonry wall at the road's edge standing
  0.3–1.4 m over it.
- `roads` are draped on the terrain, so only ways at grade are listed. On
  the Poggio ways in a tunnel, under cover or below ground (OSM `tunnel`,
  `covered`, `layer` < 0: the Aurelia Bis under the summit loop, the coast
  cycleway in the old railway tunnels) are left out, and so are viaducts and
  other bridges whose deck stands >= 2.5 m over the DTM in the LiDAR DSM.
  The Flemish files keep every OSM way as before.
- Landuse "greenhouse" is greenhouse horticulture, "olive" an olive grove,
  "terraces" a terraced slope, "garden" a garden. The app takes the first
  polygon that holds a point, so the Poggio lists the specific kinds first
  and its derived gardens ("residential") and terraced slopes last.
- Optional fields and kinds an older build does not know are ignored by the
  app; every Flemish scenery.json is unchanged by them.

## Pipeline-only data

`build_course.py` writes the raw aerial photo, `course.json → ortho.file`
(`ortho_near.jpg`), into `scripts/courses/pipeline/<course-id>/` rather than
the shipped folder: only `build_scenery.py` and
`textures/bake_course_maps.py` read it, and the app ships the baked
ground photo made from it instead. Pipeline scripts open `ortho.file` from
there and every other file named in `course.json` from the course folder.
