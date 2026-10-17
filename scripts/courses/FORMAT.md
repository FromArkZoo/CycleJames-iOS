# Course data format (v1)

Baked course data for the 3D climb simulator. One folder per course under
`CycleJames/Resources/Courses/<course-id>/`, produced by the pipeline in
`scripts/courses/` from open data. The app only reads these files; it never
calls a map or elevation service at runtime.

## Frames and units

- **Horizontal CRS:** Belgian Lambert 72 (EPSG:31370), metres. Every file
  stores *local* coordinates: `east = X72 − originEast`, `north = Y72 − originNorth`,
  where the origin is `course.json → origin`.
- **Vertical:** metres above TAW/DNG (the native datum of DHM Vlaanderen).
- **App mapping (SceneKit, right-handed, y up):** `x = east`, `y = elevation`,
  `z = −north`.
- **Raster layout:** row-major, row 0 is the **north** edge, column 0 the **west**
  edge. `originEast/originNorth` of a raster is the **north-west corner** of
  cell (0,0) in local coordinates. Cell (r,c) centre =
  `(originEast + (c + 0.5)·cellM, originNorth − (r + 0.5)·cellM)`.
- **Raster encoding `u16le_cm`:** little-endian `UInt16`,
  `value_m = baseM + raw / 100`; `raw == 65535` means no data.
- **Direction of travel:** the route always runs in the direction it is raced
  (uphill for the Koppenberg).

## `course.json`

```jsonc
{
  "schemaVersion": 1,
  "id": "koppenberg",
  "name": "Koppenberg",
  "region": "Melden, Oudenaarde · Flemish Ardennes",
  "origin": { "lambert72": [E, N], "wgs84": [lat, lon] },
  "attribution": ["© OpenStreetMap contributors (ODbL)", "…"],
  "sources": [{ "name": "…", "url": "…", "retrieved": "YYYY-MM-DD", "notes": "…" }],

  // The timed climb, as distances along the route (metres).
  "climb": { "startS": 312.0, "endS": 912.0 },

  "stats": {
    "totalLengthM": 0, "climbLengthM": 0, "climbGainM": 0,
    "climbAvgGradePct": 0,
    "climbMaxGradePct10m": 0, "climbMaxGradePct25m": 0, "climbMaxGradePct50m": 0,
    "startElevationM": 0, "summitElevationM": 0,
    "per100m": [{ "fromS": 0, "toS": 100, "avgGradePct": 0 }]
  },

  // Resampled centreline at a fixed spacing; all arrays have the same length.
  "route": {
    "spacingM": 1.0,
    "s": [],          // distance along route, metres, starts at 0
    "east": [],       // local metres
    "north": [],      // local metres
    "elev": [],       // smoothed road-surface elevation, metres TAW
    "gradePct": [],   // d(elev)/ds × 100 from the smoothed curve
    "widthM": [],     // carriageway width
    "surface": []     // index into "surfaces"
  },
  "surfaces": ["asphalt", "cobbles"],

  // Rolling-resistance coefficient per surface (sent to the trainer, used by physics).
  "surfaceCrr": { "asphalt": 0.0040, "cobbles": 0.0090 },

  "landmarks": [{ "s": 0, "kind": "climbStart|summit|steepest|junction|village|note", "name": "…" }],

  "terrain": {
    "near": { "file": "terrain_near.u16", "encoding": "u16le_cm", "baseM": 0,
              "originEast": 0, "originNorth": 0, "cellM": 1.0, "cols": 0, "rows": 0 },
    "far":  { "file": "terrain_far.u16",  "encoding": "u16le_cm", "baseM": 0,
              "originEast": 0, "originNorth": 0, "cellM": 10.0, "cols": 0, "rows": 0 }
  },
  // Canopy/object height above ground (DSM − DTM), same grid as terrain.near.
  "canopy": { "file": "canopy_near.u16", "encoding": "u16le_cm", "baseM": 0,
              "originEast": 0, "originNorth": 0, "cellM": 1.0, "cols": 0, "rows": 0 },
  // Aerial photo draped over terrain.near (optional).
  "ortho": { "file": "ortho_near.jpg", "originEast": 0, "originNorth": 0,
             "widthM": 0, "heightM": 0, "pixelsWide": 0, "pixelsHigh": 0,
             "capturedSeason": "summer|winter", "capturedYear": 0 },
  "scenery": "scenery.json"
}
```

## `scenery.json`

```jsonc
{
  "schemaVersion": 1,
  "buildings": [{ "ring": [[e, n], …], "heightM": 7.5, "roofShape": "gabled|hipped|flat|unknown",
                  "kind": "house|farm|barn|church|chapel|other", "groundElevM": 0 }],
  "trees":     [{ "e": 0, "n": 0, "heightM": 12.0, "crownRadiusM": 3.5, "kind": "deciduous|conifer" }],
  "shrubs":    [{ "e": 0, "n": 0, "heightM": 1.8, "radiusM": 0.9 }],
  "landuse":   [{ "kind": "farmland|meadow|forest|residential|orchard|scrub|grass", "ring": [[e, n], …] }],
  "roads":     [{ "name": "…", "widthM": 3.5, "surface": "asphalt|cobbles|gravel|unpaved",
                  "points": [[e, n], …] }],      // side roads near the route, not the route itself
  "fences":    [{ "kind": "fence|wall|hedge", "points": [[e, n], …] }],
  "water":     [{ "kind": "stream|pond", "points": [[e, n], …], "closed": false }]
}
```

All rings are closed implicitly (do not repeat the first point) and wound
counter-clockwise in (east, north).
