import Foundation

/// Art direction for a course that its data files don't carry: where the
/// road runs in a holle weg (sunken lane), and the roadside details placed
/// from photos (street lamps, walls, fences, stone edge strips and gutters,
/// utility poles, the look of the houses along a stretch).
///
/// Hand-placed details are looked up by course id, as route distances. A
/// course without an entry gets its sunken sections from the terrain and
/// none of the hand-placed details, so nothing meant for one climb turns up
/// somewhere else on another route.
struct CourseArt: Sendable {
    typealias Span = ClosedRange<Double>

    /// Holle weg sections: mud on the stones, bank plants, trees leaning
    /// over the lane. Soft-ended by `sunkenWeight`.
    var sunkenLane: [Span] = []
    /// Stone edge strips inside the carriageway edge, flush with the
    /// cobbles: section and side (−1 left, +1 right).
    var kerbs: [(span: Span, side: Double)] = []
    /// Smooth concrete rainwater gutters, 0.6 m wide and slightly dished,
    /// inside the carriageway edge: section and side.
    var gutters: [(span: Span, side: Double)] = []
    /// Street lamps every `spacing` metres: section, side and style.
    var lamps: [(span: Span, spacing: Double, side: Double, style: LampStyle)] = []
    /// Brick walls just off the road edge: section and side.
    var walls: [(span: Span, side: Double)] = []
    /// Post-and-wire fences: section and side (−1 left, +1 right).
    var fences: [(span: Span, side: Double)] = []
    /// Post-and-rail paddock fences: section, side and paint.
    var rails: [(span: Span, side: Double, paint: RailPaint)] = []
    /// Utility poles carrying overhead wires along the road: section,
    /// spacing, side and pole.
    var poles: [(span: Span, spacing: Double, side: Double, kind: PoleKind)] = []
    /// Clipped hedges beside the road: section, side, height, distance of
    /// the hedge's road face beyond the carriageway edge, and kind.
    var hedges: [(span: Span, side: Double, height: Double, offset: Double, kind: HedgeKind)] = []
    /// Raised sett pavements from the carriageway edge towards the house
    /// fronts (the Kwaremont square): section, side and width.
    var pavements: [(span: Span, side: Double, width: Double)] = []
    /// Village stretches, where the verge grass keeps to a thin strip.
    var villages: [Span] = []
    /// Stretches whose roadside buildings have a known look.
    var houseLooks: [HouseLook] = []
    /// Colour of the setts.
    var setts: SettLook = .mixedGrey

    enum SettLook: Sendable {
        /// The texture as baked: grey porphyry with some ochre, brown and
        /// reddish stones among it (the Koppenberg).
        case mixedGrey
        /// Mostly blue-grey, the odd brownish stone (the Kwaremont and
        /// the Paterberg).
        case blueGrey

        /// For `WorldShaders.cobbleSurface`: an rgb multiplier on the
        /// stones' albedo and the share of its saturation kept.
        var tint: SIMD4<Float> {
            switch self {
            case .mixedGrey: return SIMD4(1, 1, 1, 1)
            case .blueGrey: return SIMD4(0.93, 0.98, 1.1, 0.4)
            }
        }
    }

    enum LampStyle: Sendable {
        /// Black post, curved arm, lantern head (the Steengat).
        case curvedBlack
        /// Tall grey post with a curved arm and a slim head.
        case curvedGrey
        /// Black post with a flat LED head on a short arm.
        case ledBlack
    }

    enum RailPaint: Sendable {
        /// Dark-stained timber, two or three rails (the Paterberg paddock).
        case darkStain
        /// White-painted horse-paddock rails.
        case white
        /// Two rails of unpainted, weathered timber.
        case paleTimber
    }

    enum HedgeKind: Sendable {
        /// Beech, hornbeam or privet.
        case green
        /// Purple-red copper beech.
        case copperBeech
        /// Glossy dark cherry laurel.
        case laurel
        /// Dark evergreen grown over with ivy.
        case ivy
    }

    enum PoleKind: Sendable {
        /// Grey concrete poles.
        case concrete
        /// Creosoted timber poles.
        case wood
    }

    struct HouseLook: Sendable {
        enum Look: Sendable {
            /// White-washed cottages under dark roofs.
            case whitewashedCottages
            /// Red-brick farm buildings with orange pantiles, a cream house.
            case hilltopFarms
            /// Red brick under orange pantiles, houses included.
            case redBrickPantiles
            /// Red brick under dark tiles or slate (barns on the Kwaremont).
            case redBrickSlate
            /// White-washed brick under orange pantiles.
            case whitewashedPantiles
            /// Pale rendered walls under dark roofs.
            case paleRender
            /// Pale rendered walls under red-brown tiles.
            case paleRenderTiles
            /// Brown or dark brick under dark tiles or slate.
            case darkBrick
            /// A village street: red brick, white and cream render, the odd
            /// dark-brick house, mostly dark roofs.
            case villageMix
        }

        var span: Span
        /// Only buildings this close to the road.
        var maxRouteDistance: Double
        var look: Look
        /// Only buildings on this side of the road (−1 left, +1 right);
        /// nil for both.
        var side: Double? = nil
        /// Only buildings of this scenery kind ("church", "house", …); nil
        /// for any.
        var kind: String? = nil
    }

    /// 0 outside the sunken lane, easing to 1 inside it.
    func sunkenWeight(_ s: Double) -> Double {
        var w = 0.0
        for span in sunkenLane {
            let a = span.lowerBound, b = span.upperBound
            w = max(w, smoothstepD(a - 15, a + 10, s) * (1 - smoothstepD(b - 10, b + 15, s)))
        }
        return w
    }

    /// Width of the pavement on a side of the road at `s`; 0 where none.
    func pavementWidth(_ s: Double, side: Double) -> Double {
        pavements.filter { $0.side * side > 0 && $0.span.contains(s) }.map(\.width).max() ?? 0
    }

    /// 1 in a village stretch, easing to 0 over about 20 m across its ends
    /// (none where it starts at the route start), so the verge grass
    /// thickens gradually as the houses end.
    func villageWeight(_ s: Double) -> Double {
        var w = 0.0
        for span in villages {
            let a = span.lowerBound, b = span.upperBound
            let rampIn = a <= 0 ? 1 : smoothstepD(a - 10, a + 10, s)
            w = max(w, rampIn * (1 - smoothstepD(b - 10, b + 10, s)))
        }
        return w
    }

    /// The first matching look. `side` is the side of the road the building
    /// stands on (−1 left, +1 right), `kind` its scenery kind.
    func houseLook(s: Double, routeDistance: Double, side: Double, kind: String?) -> HouseLook.Look? {
        houseLookIndex(s: s, routeDistance: routeDistance, side: side, kind: kind).map { houseLooks[$0].look }
    }

    /// Index in `houseLooks` of the look `houseLook` picks.
    func houseLookIndex(s: Double, routeDistance: Double, side: Double, kind: String?) -> Int? {
        houseLooks.firstIndex {
            $0.span.contains(s) && routeDistance < $0.maxRouteDistance
                && ($0.side.map { $0 * side > 0 } ?? true) && ($0.kind.map { $0 == kind } ?? true)
        }
    }

    static func make(bundle: CourseBundle) -> CourseArt {
        if let known = byCourseID[bundle.id] { return known }
        return CourseArt(sunkenLane: detectSunkenLane(route: bundle.route, terrain: bundle.terrainNear))
    }

    // MARK: Hand-placed

    /// Route distances from the photo survey in
    /// scripts/courses/debug/<id>/research_summary.json. The Koppenberg's
    /// sunken sections are where the LiDAR banks are (`detectSunkenLane`
    /// finds about 537-643 and 769-807): from the last Steengat houses to
    /// s ≈ 535 the lane runs along an open field edge.
    ///
    /// On the Oude Kwaremont and the Paterberg the timed climb starts at
    /// s ≈ 300, so a feature x metres up the climb in the survey sits at
    /// s ≈ x + 300.
    private static let byCourseID: [String: CourseArt] = [
        "koppenberg": CourseArt(
            sunkenLane: [535...648, 765...812],
            kerbs: [(302...430, -1), (688...866, -1)],
            lamps: [(312...432, 29, -1, .curvedBlack)],
            walls: [(842...868, 1)],
            fences: [(700...836, 1), (884...1060, 1), (905...1050, -1)],
            villages: [0...440],
            houseLooks: [
                HouseLook(span: 295...450, maxRouteDistance: 45, look: .whitewashedCottages),
                HouseLook(span: 790...900, maxRouteDistance: 70, look: .hilltopFarms),
            ]
        ),
        // Broektestraat across the Scheldt valley, the steep holle weg, the
        // Kwaremont village square and upper Kwaremontplein, the cobbled false
        // flat, the wooded upper holle weg, the N36. Sunken sections: the
        // survey's hollow lanes, which match the LiDAR banks
        // (`detectSunkenLane`: 1042-1218, 1297-1383, 2114-2258). House looks
        // match on the footprint centroid's distance, so deep buildings need
        // a wide gate; `kind` keeps a wide gate to the building meant.
        "oudekwaremont": CourseArt(
            sunkenLane: [1030...1218, 1290...1385, 2060...2262],
            kerbs: [
                (300...409, -1),    // concrete kerb by the hedge and the farm at the start
                (989...1024, 1), (1064...1094, -1),  // edge rows clearly showing at the foot of the cobbles
                (2019...2044, 1),
                (2079...2259, 1),   // flat edge stones under the wooded bank, the line riders take
                (2423...2464, -1),  // to the end of the cobbles
            ],
            lamps: [
                (400...485, 75, -1, .curvedGrey),
                (1342...1440, 35, 1, .ledBlack),
                (1492...1640, 35, -1, .ledBlack),
                (1660...1712, 35, 1, .ledBlack),
            ],
            walls: [(1597...1629, 1)],  // the old pastorie's garden wall, after the house
            fences: [(300...480, 1), (709...779, -1), (859...989, -1), (2079...2298, -1), (2318...2418, -1)],
            rails: [(480...615, -1, .paleTimber)],  // horse paddock: two rails of bare timber
            poles: [(635...780, 40, 1, .wood), (2080...2300, 45, -1, .wood)],
            hedges: [
                (300...350, -1, 2.6, 0.4, .copperBeech),  // at the right-left kink where the climb starts
                (1222...1250, 1, 2.0, 1.0, .green),       // villa on the first Kwaremont houses
                (1395...1428, 1, 2.0, 0.6, .green),       // in front of the dark-brick house
                (1427...1470, -1, 2.2, 0.5, .laurel),     // the closed farm on the square
                (1509...1545, 1, 2.7, 0.5, .copperBeech),
                (1545...1553, 1, 2.6, 0.5, .ivy),
                (2036...2058, -1, 2.2, 1.0, .green),      // Schilderstraat 3
            ],
            pavements: [(1427...1472, 1, 1.4), (1473...1500, 1, 1.0)],  // In 't Palet, the parish hall
            villages: [0...30, 615...700, 1400...1714],
            houseLooks: [
                // Sint-Amandus, about 100 m off the square, is white-washed.
                HouseLook(span: 1440...1520, maxRouteDistance: 150, look: .whitewashedCottages, side: 1, kind: "church"),
                HouseLook(span: 0...40, maxRouteDistance: 50, look: .villageMix),
                // Broektestraat 7: red-brick barn gable on the road and the house; a pale building behind.
                HouseLook(span: 340...415, maxRouteDistance: 27, look: .redBrickPantiles, side: -1),
                HouseLook(span: 340...415, maxRouteDistance: 32, look: .paleRender, side: -1),
                // The chapel of Our Lady of the Cyclists, a red-brick barn under a
                // grey roof, then café 't Juiste Verzet and the farmhouse.
                HouseLook(span: 626...641, maxRouteDistance: 12, look: .whitewashedCottages, side: -1),
                HouseLook(span: 645...660, maxRouteDistance: 16, look: .redBrickSlate, side: -1, kind: "other"),
                HouseLook(span: 662...692, maxRouteDistance: 25, look: .whitewashedPantiles, side: -1),
                HouseLook(span: 825...850, maxRouteDistance: 20, look: .redBrickPantiles, side: 1),  // Broektestraat 20
                HouseLook(span: 1200...1320, maxRouteDistance: 45, look: .villageMix, side: 1),
                // The square: the closed red-brick farm on the left; In 't Palet,
                // the parish hall and a cottage on the right, then the long
                // red-brick barn of Kwaremontplein 22 under dark tiles.
                HouseLook(span: 1420...1500, maxRouteDistance: 30, look: .redBrickPantiles, side: -1),
                HouseLook(span: 1425...1470, maxRouteDistance: 25, look: .paleRender, side: 1),
                HouseLook(span: 1474...1515, maxRouteDistance: 20, look: .redBrickSlate, side: 1),
                // The pastorie's red-brick outbuilding at the gate, then the grey-rendered pastorie.
                HouseLook(span: 1555...1568, maxRouteDistance: 10, look: .redBrickPantiles, side: 1, kind: "other"),
                HouseLook(span: 1572...1600, maxRouteDistance: 20, look: .paleRender, side: 1),
                HouseLook(span: 1500...1650, maxRouteDistance: 45, look: .villageMix),
                // Home Sint-Franciscus (a deep dark-brick complex) and the white school.
                HouseLook(span: 1630...1715, maxRouteDistance: 110, look: .darkBrick, side: 1, kind: "house"),
                HouseLook(span: 1695...1710, maxRouteDistance: 20, look: .paleRender, side: 1, kind: "other"),
                HouseLook(span: 2030...2065, maxRouteDistance: 20, look: .redBrickPantiles, side: -1),  // Schilderstraat 3
                HouseLook(span: 2340...2420, maxRouteDistance: 40, look: .redBrickPantiles, side: -1),  // Schilderstraat 5, 7
            ],
            setts: .blueGrey
        ),
        // Middelloopstraat down the Molenbeek valley, then the cobbles east
        // up the open hillside: the concrete gutter up the left, edge stones
        // on the right, the dark paddock rails along the upper ramp, a
        // low-voltage line on concrete poles over the lower slope, out on
        // the concrete Stooktestraat. No holle weg: the foot is only a
        // shallow cutting facing south, dry, with no mud on the stones.
        "paterberg": CourseArt(
            kerbs: [(300...664, 1)],
            gutters: [(300...664, -1)],
            fences: [(305...385, -1)],  // stock fence on the north bank at the foot
            rails: [(505...635, 1, .darkStain)],
            poles: [(306...505, 38, 1, .concrete)],  // they stop at the tree gate below no. 3
            hedges: [
                (304...345, 1, 1.7, 1.0, .green),   // clipped hedge on the south bank at the foot
                (509...545, -1, 1.6, 2.5, .green),  // no. 3's garden, on raised ground
                (643...664, 1, 2.8, 0.4, .ivy),     // the ivy-grown hedge in front of no. 4
            ],
            houseLooks: [
                HouseLook(span: 270...305, maxRouteDistance: 30, look: .redBrickPantiles, side: -1),  // Middelloopstraat 4
                HouseLook(span: 380...425, maxRouteDistance: 45, look: .redBrickPantiles, side: -1),  // Paterbergstraat 1
                HouseLook(span: 505...555, maxRouteDistance: 40, look: .darkBrick, side: -1),         // Paterbergstraat 3
                HouseLook(span: 628...648, maxRouteDistance: 10, look: .paleRender, side: 1),         // the summit cottage
                HouseLook(span: 645...668, maxRouteDistance: 30, look: .paleRenderTiles, side: 1, kind: "house"),  // no. 4
            ],
            setts: .blueGrey
        ),
    ]

    // MARK: Found in the terrain

    /// Sections where the ground rises at least a metre above the road on
    /// both sides within a few metres of its edges, merged across short gaps.
    static func detectSunkenLane(route: CourseRoute, terrain: HeightRaster) -> [Span] {
        let n = route.count
        guard n > 2 else { return [] }
        var rise = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let s = route.s[i]
            let dir = route.direction(at: s)
            let right = SIMD2(dir.y, -dir.x)
            let centre = SIMD2(route.east[i], route.north[i])
            let half = route.widthM[i] / 2
            var lowest = Double.infinity
            for side in [-1.0, 1.0] {
                var best = -Double.infinity
                for offset in [1.5, 2.5, 3.5, 4.5] {
                    let p = centre + right * (side * (half + offset))
                    let h = Double(terrain.sample(east: p.x, north: p.y))
                    if !h.isNaN { best = max(best, h - route.elev[i]) }
                }
                lowest = min(lowest, best)
            }
            rise[i] = lowest.isFinite ? lowest : 0
        }
        // Smoothed over about 9 m, then thresholded.
        var spans: [Span] = []
        var start: Double?
        for i in 0..<n {
            let lo = max(0, i - 4), hi = min(n - 1, i + 4)
            let mean = rise[lo...hi].reduce(0, +) / Double(hi - lo + 1)
            let s = route.s[i]
            if mean >= 1.0 {
                if start == nil { start = s }
            } else if let a = start {
                spans.append(a...s)
                start = nil
            }
        }
        if let a = start { spans.append(a...route.length) }
        var merged: [Span] = []
        for span in spans {
            if let last = merged.last, span.lowerBound - last.upperBound < 15 {
                merged[merged.count - 1] = last.lowerBound...span.upperBound
            } else {
                merged.append(span)
            }
        }
        return merged.filter { $0.upperBound - $0.lowerBound >= 20 }
    }
}
