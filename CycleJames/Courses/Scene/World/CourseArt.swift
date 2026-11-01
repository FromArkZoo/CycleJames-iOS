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
    /// Smooth concrete rainwater gutters, slightly dished, inside the
    /// carriageway edge: section, side and width (the Paterberg's 0.6 m,
    /// the Taaienberg's 0.7 m).
    var gutters: [(span: Span, side: Double, width: Double)] = []
    /// Street lamps every `spacing` metres: section, side and style.
    var lamps: [(span: Span, spacing: Double, side: Double, style: LampStyle)] = []
    /// Brick walls just off the road edge: section, side, height above the
    /// road (a bridge parapet stands up from the deck; its foot goes down
    /// to the ground, to the water under a bridge), distance of the road
    /// face beyond the carriageway edge, and the brick.
    var walls: [(span: Span, side: Double, height: Double, offset: Double, look: WallLook)] = []
    /// Dry-stone retaining walls at the carriageway edge, holding up the
    /// bank behind them (the Muur's park lane): section, side, the most the
    /// wall stands above the road (it never rises above the bank) and its
    /// stones.
    var stoneWalls: [(span: Span, side: Double, height: Double, look: StoneLook)] = []
    /// Post-and-wire fences: section and side (−1 left, +1 right).
    var fences: [(span: Span, side: Double)] = []
    /// Post-and-rail paddock fences: section, side and paint.
    var rails: [(span: Span, side: Double, paint: RailPaint)] = []
    /// Split-chestnut paling (kastanjehekwerk): stakes wired together on
    /// posts, standing on the ground (or a wall) beyond the edge: section,
    /// side, height and offset.
    var palings: [(span: Span, side: Double, height: Double, offset: Double)] = []
    /// Utility poles carrying overhead wires along the road: section,
    /// spacing, side and pole.
    var poles: [(span: Span, spacing: Double, side: Double, kind: PoleKind)] = []
    /// Clipped hedges beside the road: section, side, height, distance of
    /// the hedge's road face beyond the carriageway edge, and kind.
    var hedges: [(span: Span, side: Double, height: Double, offset: Double, kind: HedgeKind)] = []
    /// Raised sett pavements from the carriageway edge towards the house
    /// fronts (the Kwaremont square): section, side and width.
    var pavements: [(span: Span, side: Double, width: Double)] = []
    /// Setts flush with the carriageway from its edge to the house fronts
    /// (the Steengat, the Kwaremont square): section, side and width beyond
    /// the edge, erring wide (the walls stand on them). Spans on one side
    /// don't overlap.
    var pavedVerges: [(span: Span, side: Double, width: Double)] = []
    /// Round cast-iron gully grates down a village street: section, lateral
    /// offset from the centre line (+ right) and spacing.
    var streetGrates: [(span: Span, lateral: Double, spacing: Double)] = []
    /// Spacing of the rectangular cast-iron grates in the `gutters`; 0 for
    /// none.
    var gutterGrateSpacing: Double = 0
    /// Village stretches, where the verge grass keeps to a thin strip.
    var villages: [Span] = []
    /// Mown lawn to the road edge (a park): section and side. Short green
    /// grass only, no flowers, seed heads or rough sward.
    var lawns: [(span: Span, side: Double)] = []
    /// Asphalt wide enough for lines that has none (town streets).
    var unmarked: [Span] = []
    /// Stretches whose roadside buildings have a known look.
    var houseLooks: [HouseLook] = []
    /// The setts' size, joints, shape, colour and wear (`SettStyle`).
    var setts: SettLook = .mixedGrey
    /// Road signs, street plates and traffic mirrors.
    var signs: [SignPost] = []
    /// Benches, tables, posts, cabinets and the like.
    var furniture: [Furniture] = []
    /// Trees standing in recent photos that the leaf-off LiDAR (2013-15)
    /// misses: route distance, side, offset beyond the carriageway edge,
    /// height and crown radius.
    var extraTrees: [(s: Double, side: Double, offset: Double, height: Double, radius: Double)] = []
    /// Pollard willows (knotwilgen): the LiDAR trees of a section, on a
    /// side, up to `maxHeight` and within 15 m of the road.
    var pollards: [(span: Span, side: Double, maxHeight: Double)] = []
    /// Ground the LiDAR's trees and shrubs (2013-15) no longer stand on:
    /// section, side and width beyond the carriageway edge (the
    /// Taaienberg's summit corner, paved round its sculpture in 2023).
    var clearings: [(span: Span, side: Double, width: Double)] = []
    /// Retaining walls and parapets at the carriageway edge on the Riviera
    /// (the Poggio's honey sandstone, grey squared stone and concrete),
    /// built by `BuildingBuilder.buildRivieraRoadside`. Where the regional
    /// map's walls (scenery `walls`) stand at the edge, they give the wall's
    /// line and crest and these only its look and what stands on it.
    var masonry: [Masonry] = []
    /// Galvanised W-beam guardrail ("doppia onda") on C-posts, its rail top
    /// 0.75 m above the road: section, side and the posts' distance beyond
    /// the carriageway edge.
    var guardrails: [(span: Span, side: Double, offset: Double)] = []
    /// Railings, fences and screens standing on the verge (not on a wall):
    /// section, side, distance beyond the edge and kind.
    var railings: [(span: Span, side: Double, offset: Double, kind: Railing)] = []
    /// Words painted big on a wall's road face (the "IL POGGIO" on the
    /// dark wall below the top): middle at route distance `s`, side, the
    /// text and the letters' height.
    var paintedWords: [(s: Double, side: Double, text: String, height: Double)] = []
    /// Black plates with a white chevron on a hairpin's outside wall, at
    /// route distance `s`, pointing the way the road turns.
    var chevrons: [(s: Double, side: Double, pointsLeft: Bool)] = []
    /// A trolleybus line's overhead: two pairs of contact wires over the
    /// road on span wires between steel poles either side (the Via Aurelia
    /// at the Poggio's foot, the Sanremo-Taggia filobus).
    var trolleyWires: [Span] = []
    /// Riviera furniture placed by its map position (course east and north,
    /// metres) rather than along the route, facing `facing` degrees
    /// clockwise from north: things standing well off a tight corner, where
    /// a route distance and offset would swing with the road's heading (the
    /// Poggio's piazza, from its OSM nodes).
    var placed: [(prop: RivieraProp, east: Double, north: Double, facing: Double)] = []
    /// The region the course is drawn as (`WorldLook`).
    var look: WorldLook = .flanders

    /// Plates on one galvanised pole (or a wall bracket), top to bottom:
    /// keys of the sign atlas (cj_signs_map.json, baked by
    /// scripts/courses/textures/bake_signs.py).
    struct SignPost: Sendable {
        enum Mount: Sendable { case pole, wall }
        var s: Double
        var side: Double
        /// Beyond the carriageway edge, metres.
        var offset: Double
        var plates: [String]
        /// Faces traffic coming down: riders going up see the backs.
        var facesDownhill = false
        /// Extra turn towards the road, degrees (negative turns the face
        /// away from it, as a junction mirror looks into the side road). On
        /// a wall it must leave the face looking out of the wall.
        var turn: Double = 8
        /// `.wall`: on a bracket from the nearest footprint wall within a few
        /// metres (`BuildingBuilder.wallMount`), on a pole without one.
        var mount: Mount = .pole
    }

    struct Furniture: Sendable {
        enum Kind: Sendable {
            /// Slatted bench with a backrest: timber or dark recycled plastic.
            case bench(wood: Bool)
            case picnicTable
            /// Hoop stands in a row.
            case bikeStands(Int)
            /// Dark-green electricity kiosk with a pyramid roof.
            case electricityKiosk
            /// Rough old granite marker post.
            case granitePost
            case wasteBasket
            /// Small timber wayside cross.
            case waysideCross
            /// Yellow pipeline marker post, no operator logo.
            case markerPost
            /// Square brick gate pillar, its cap white or stone.
            case gatePillar(whiteCap: Bool)
            /// Grey utility cabinet.
            case cabinet
            /// The door, blue or dark grey, and cross of the chapel standing
            /// within a few metres (its walls and roof are the footprint's).
            case chapelFront(blueDoor: Bool)
            /// The Oudenberg chapel, built whole on the chapel footprint
            /// nearest (in place of its walls and roof): a red-brick
            /// octagon and drum with limestone quoins under a slate dome, a
            /// louvred lantern and a gilt statue, and the baroque porch
            /// towards the footprint's front: an arched door, a niche with a
            /// statue, scrolled shoulders with urns, a pediment and a cross.
            case domedChapel
            /// A tall timber calvary cross with the corpus, on a stone base.
            case calvary
            /// A pair of bronze legs, hips to bare feet, standing on a low
            /// round plinth of pale concrete that serves as a seat (the
            /// sculpture at the top of the Taaienberg, 2023).
            case bronzeLegs
            /// The Riviera's street furniture and landmarks (the Poggio's
            /// summit, jersey blocks, vans), built by
            /// `BuildingBuilder.buildRivieraRoadside`.
            case riviera(RivieraProp)
        }

        var kind: Kind
        var s: Double
        var side: Double
        /// Beyond the carriageway edge, metres.
        var offset: Double
        /// Turn from facing the road, degrees.
        var turn: Double = 0
    }

    /// From the photo survey (scripts/courses/debug/<id>/research_summary.json),
    /// photos of each climb and Belgian reclaimed-sett sizes (Opalis: old
    /// porphyry 13-17 cm square, 11x17 to 14x20 rectangular; joints 3-15 mm
    /// on sand). Laid in arcs or diagonally nowhere yet: the Kwaremont
    /// square's pattern is unconfirmed.
    enum SettLook: Sendable {
        /// The Koppenberg: old porphyry "kinderkoppen", warm and dark greys
        /// with a quarter rust and ochre, near square and strongly domed,
        /// on wide gritty joints.
        case mixedGrey
        /// The Oude Kwaremont: pale grey, buff and bluish split stones,
        /// roughly cubic 14-15 cm but uneven, with fractured, chipped tops,
        /// on sandy joints that gape here and there.
        case paleSplit
        /// The Paterberg: darker, regular, domed setts, roughly square
        /// 13-14 cm, "closer together than the Koppenberg".
        case darkRegular
        /// The Muur: smaller setts than the other bergs (about 12 cm),
        /// grey and blue-grey with a few buff stones, gently domed, close
        /// together, polished in the wheel tracks by the town's traffic.
        case smallWorn
        /// The Molenberg: near-square 13-15 cm setts, mid and dark grey and
        /// blue-grey with a fifth of brown and ochre stones, gently domed
        /// with worn arrises, on wide joints of soil, moss and grass;
        /// uneven, the odd sett sunk.
        case mossyGrey
        /// The Taaienberg: warm and dark greys with brown, ochre and rust
        /// stones, oblong (14-16 cm along the road, 16-22 cm across), domed
        /// and worn smooth, on wide sandy joints.
        case warmOblong
    }

    enum WallLook: Sendable {
        /// Red brick.
        case redBrick
        /// White-washed brick.
        case whitewashed
    }

    enum StoneLook: Sendable {
        /// Flat schist and sandstone slabs in thin courses.
        case slabs
        /// Big rounded brown-grey ironstone blocks.
        case rubble
    }

    enum LampStyle: Sendable {
        /// Black post, curved arm, lantern head (the Steengat).
        case curvedBlack
        /// Tall grey post with a curved arm and a slim head.
        case curvedGrey
        /// Black post with a flat LED head on a short arm.
        case ledBlack
        /// Black post with a four-sided lantern on top (the Muur's park
        /// and the chapel).
        case postLantern
        /// Tall galvanised post, 8.5 m, one straight arm and a flat LED
        /// head (the SP55 and the Poggio's summit).
        case galvanisedLED
        /// Dark-grey cast-iron post with a lantern (Piazza della Libertà,
        /// 2026).
        case castIron
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
        /// The Riviera's timber poles: no cross-arm, a black twisted
        /// low-voltage bundle and a thin telephone line, sagging well.
        case woodBundle
        /// The Riviera's round, tapered concrete poles with the same lines.
        case concreteBundle
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

    /// Width paved on a side of the road at `s`, raised or flush; 0 where
    /// none.
    func pavedWidth(_ s: Double, side: Double) -> Double {
        max(pavementWidth(s, side: side),
            pavedVerges.filter { $0.side * side > 0 && $0.span.contains(s) }.map(\.width).max() ?? 0,
            masonryWidth(s, side: side))
    }

    /// Width a Riviera wall at the edge takes on a side at `s` (its road
    /// face's offset and its thickness); 0 where none. No verge grass grows
    /// in front of it or out of it.
    func masonryWidth(_ s: Double, side: Double) -> Double {
        guard !masonry.isEmpty else { return 0 }
        return masonry.filter { $0.side * side > 0 && $0.span.contains(s) }.map { $0.offset + $0.thickness }.max() ?? 0
    }

    /// Whether a point `beyondEdge` metres past the carriageway edge on
    /// `side` at `s` lies in a clearing.
    func isCleared(s: Double, side: Double, beyondEdge: Double) -> Bool {
        clearings.contains { $0.side * side > 0 && $0.span.contains(s) && beyondEdge < $0.width }
    }

    /// Whether the verge on a side of the road at `s` is mown lawn.
    func isLawn(_ s: Double, side: Double) -> Bool {
        lawns.contains { $0.side * side > 0 && $0.span.contains(s) }
    }

    /// Whether a LiDAR tree is grown as a pollard willow: `side` is the side
    /// of the road it stands on, `routeDistance` its distance from the
    /// centre line.
    func isPollard(s: Double, side: Double, routeDistance: Double, height: Double) -> Bool {
        routeDistance < 15 && pollards.contains { $0.span.contains(s) && $0.side * side > 0 && height <= $0.maxHeight }
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
        var art = byCourseID[bundle.id]
            ?? CourseArt(sunkenLane: detectSunkenLane(route: bundle.route, terrain: bundle.terrainNear))
        #if DEBUG
        if let look = WorldLook.launchOverride { art.look = look }
        // -rivieraRoadsideSample (with -courseLook riviera): a sample of the
        // Riviera's walls, railings, signs and furniture up a course that has
        // none, to judge them on a familiar road.
        if art.look.isRiviera, ProcessInfo.processInfo.arguments.contains("-rivieraRoadsideSample") {
            art.addRivieraSample(climb: bundle.climb.startS...bundle.climb.endS, length: bundle.route.length)
        }
        #endif
        return art
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
        // The Steengat (photos of 2009): cottages on the road edge, setts up
        // to their fronts on the right, a narrow paved strip and small front
        // gardens behind a low hedge on the left, round gully grates down
        // the middle. Widths reach the house fronts in the GRB footprints.
        "koppenberg": CourseArt(
            sunkenLane: [535...648, 765...812],
            kerbs: [(302...430, -1), (688...866, -1)],
            lamps: [(312...432, 29, -1, .curvedBlack)],
            walls: [(842...868, 1, 1.7, 0.4, .redBrick)],
            fences: [(700...836, 1), (884...1060, 1), (905...1050, -1)],
            hedges: [(360...395, -1, 1.0, 0.6, .green)],
            pavedVerges: [
                (302...316, 1, 1.0), (316...335, 1, 4.0), (335...346, 1, 1.5), (346...352, 1, 4.2),
                (352...368, 1, 1.5), (394...428, 1, 1.5),
                (302...324, -1, 0.6), (324...334, -1, 2.6), (334...340, -1, 0.6), (340...358, -1, 1.2),
                (358...414, -1, 0.6), (414...424, -1, 4.9), (424...432, -1, 0.6),
            ],
            streetGrates: [(306...432, 0.3, 26)],
            villages: [0...440],
            houseLooks: [
                HouseLook(span: 295...450, maxRouteDistance: 45, look: .whitewashedCottages),
                HouseLook(span: 790...900, maxRouteDistance: 70, look: .hilltopFarms),
            ],
            signs: [
                // The Rotelenberg's setts: closed to all vehicles, cyclists excepted (OSM).
                SignPost(s: 247, side: 1, offset: 4.8, plates: ["c3", "plate.m11"]),
                // The fork's pole in the gore (2009, plates as of 2021).
                SignPost(s: 298, side: 1, offset: 1.2,
                         plates: ["cycle.route.left", "street.steengat", "tourist.koppenberg.left"]),
                SignPost(s: 440, side: 1, offset: 1.0, plates: ["c3"]),          // by the last house (2009)
                SignPost(s: 870, side: 1, offset: 1.2, plates: ["e3.noparking"]),  // past the farm wall (2017)
            ],
            furniture: [
                Furniture(kind: .cabinet, s: 334, side: -1, offset: 0.4),
                Furniture(kind: .bench(wood: false), s: 708, side: -1, offset: 1.5, turn: 160),  // faces the view back
                Furniture(kind: .wasteBasket, s: 855, side: -1, offset: 3.8),
                Furniture(kind: .waysideCross, s: 1055, side: -1, offset: 1.5),
            ],
            // Knotwilgen on the right of the open ramp (LiDAR trees of 3.9-4.9 m).
            pollards: [(680...730, 1, 6.5)]
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
            walls: [(1597...1629, 1, 1.7, 0.4, .redBrick)],  // the old pastorie's garden wall, after the house
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
            // The square (2017, 2020 photos): setts from the carriageway to
            // the closed farm's hedge, then to its walls and forecourt, a
            // round manhole in the middle.
            pavedVerges: [(1425...1470, -1, 0.7), (1470...1495, -1, 5.4)],
            streetGrates: [(1436...1492, -0.2, 27)],
            villages: [0...30, 615...700, 1400...1714],
            houseLooks: [
                // Sint-Amandus, about 100 m off the square, is white-washed.
                HouseLook(span: 1440...1520, maxRouteDistance: 150, look: .whitewashedCottages, side: 1, kind: "church"),
                HouseLook(span: 0...40, maxRouteDistance: 50, look: .villageMix),
                // Broektestraat 7: red-brick barn gable on the road and the house; a pale building behind.
                HouseLook(span: 340...415, maxRouteDistance: 27, look: .redBrickPantiles, side: -1),
                HouseLook(span: 340...415, maxRouteDistance: 32, look: .paleRender, side: -1),
                // The chapel of Our Lady of the Cyclists (white under a dark roof:
                // a look that never draws orange pantiles), a red-brick barn under
                // a grey roof, then café 't Juiste Verzet and the farmhouse.
                HouseLook(span: 626...641, maxRouteDistance: 12, look: .paleRender, side: -1, kind: "chapel"),
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
            setts: .paleSplit,
            signs: [
                SignPost(s: 338, side: 1, offset: 1.2, plates: ["node.24"]),            // Paddestraat junction
                SignPost(s: 341, side: 1, offset: 1.5, plates: ["mirror"], turn: -35),
                SignPost(s: 798, side: -1, offset: 1.5, plates: ["node.65"]),           // where the route turns right
                SignPost(s: 1251, side: 1, offset: 1.0, plates: ["f1.kwaremont"]),
                // On the gable at the bend, looking back to the side street;
                // as close to its corner (where riders coming up see it) as
                // the gable's verge leaves it head room.
                SignPost(s: 1479, side: 1, offset: 1.9, plates: ["mirror"], turn: 60, mount: .wall),
                SignPost(s: 1484, side: -1, offset: 2.0, plates: ["node.69"]),
                SignPost(s: 1664, side: 1, offset: 1.0, plates: ["f4a.zone30"]),
                SignPost(s: 1672, side: 1, offset: 1.0, plates: ["a23.children"]),
                SignPost(s: 2275, side: 1, offset: 1.5, plates: ["node.19"]),           // the fork
                SignPost(s: 2385, side: 1, offset: 1.0, plates: ["b1.giveway", "plate.100m"]),
                SignPost(s: 2410, side: 1, offset: 1.5, plates: ["mirror"], turn: -45),  // a farm entrance
            ],
            furniture: [
                // Our Lady of the Cyclists: the blue door and the bench beside it.
                Furniture(kind: .chapelFront(blueDoor: true), s: 635, side: -1, offset: 3),
                Furniture(kind: .bench(wood: true), s: 640.8, side: -1, offset: 2.2),
                // Not the three benches facing café 't Juiste Verzet (OSM,
                // 10 m across the road): with no terrace under them they
                // stood alone in the meadow, dark blocks against the light.
                Furniture(kind: .markerPost, s: 929, side: -1, offset: 1.0),
                // In front of the parish hall (OSM).
                Furniture(kind: .bench(wood: true), s: 1462, side: 1, offset: 12.8, turn: 20),
                Furniture(kind: .bench(wood: true), s: 1465, side: 1, offset: 20.7, turn: 20),
            ],
            // Knotwilgen on the bank tops of the valley drag (LiDAR trees of 4.2-5.5 m).
            pollards: [(828...862, 1, 6.5), (893...917, -1, 6.5)]
        ),
        // Middelloopstraat down the Molenbeek valley, then the cobbles east
        // up the open hillside: the concrete gutter up the left, edge stones
        // on the right, the dark paddock rails along the upper ramp, a
        // low-voltage line on concrete poles over the lower slope, out on
        // the concrete Stooktestraat. No holle weg: the foot is only a
        // shallow cutting facing south, dry, with no mud on the stones.
        "paterberg": CourseArt(
            kerbs: [(300...664, 1)],
            gutters: [(300...664, -1, 0.6)],
            fences: [(305...385, -1)],  // stock fence on the north bank at the foot
            rails: [
                (505...635, 1, .darkStain),
                (518...550, -1, .white),  // no. 3's frontage (2011, 2017)
            ],
            poles: [(306...505, 38, 1, .concrete)],  // they stop at the tree gate below no. 3
            hedges: [
                (304...345, 1, 1.7, 1.0, .green),   // clipped hedge on the south bank at the foot
                (509...545, -1, 1.6, 2.5, .green),  // no. 3's garden, on raised ground
                (643...664, 1, 2.8, 0.4, .ivy),     // the ivy-grown hedge in front of no. 4
            ],
            // Gully grates in the gutter (2011: about s 410-430 and 500-515).
            gutterGrateSpacing: 28,
            houseLooks: [
                HouseLook(span: 270...305, maxRouteDistance: 30, look: .redBrickPantiles, side: -1),  // Middelloopstraat 4
                HouseLook(span: 380...425, maxRouteDistance: 45, look: .redBrickPantiles, side: -1),  // Paterbergstraat 1
                HouseLook(span: 505...555, maxRouteDistance: 40, look: .darkBrick, side: -1),         // Paterbergstraat 3
                HouseLook(span: 628...648, maxRouteDistance: 10, look: .paleRender, side: 1),         // the summit cottage
                HouseLook(span: 645...668, maxRouteDistance: 30, look: .paleRenderTiles, side: 1, kind: "house"),  // no. 4
            ],
            setts: .darkRegular,
            signs: [
                SignPost(s: 298, side: -1, offset: 1.0, plates: ["street.paterbergstraat"]),  // at the corner
                SignPost(s: 306, side: -1, offset: 1.2, plates: ["board.paterberg"]),         // in front of the stock fence
                // Facing the traffic coming down: riders see the backs, then
                // the faces once round the turn.
                SignPost(s: 652, side: -1, offset: 1.0, plates: ["a.steep20"], facesDownhill: true),
                SignPost(s: 658, side: -1, offset: 1.0, plates: ["c21.3_5t", "plate.landbouw"], facesDownhill: true),
                SignPost(s: 666, side: 1, offset: 1.5, plates: ["mirror"], turn: -50),       // the T-junction
            ],
            furniture: [
                Furniture(kind: .gatePillar(whiteCap: true), s: 533, side: -1, offset: 1.2),  // no. 3's gate
                Furniture(kind: .granitePost, s: 615, side: -1, offset: 0.8),
                Furniture(kind: .electricityKiosk, s: 641.8, side: 1, offset: 0.45),
                Furniture(kind: .gatePillar(whiteCap: true), s: 650, side: 1, offset: 0.3),   // in no. 4's hedge
                // The rest area on the Stooktestraat (OSM): benches facing the view, a table, bike stands.
                Furniture(kind: .bench(wood: true), s: 683.7, side: -1, offset: 11.4, turn: 180),
                Furniture(kind: .picnicTable, s: 688.2, side: -1, offset: 7.0),
                Furniture(kind: .bench(wood: true), s: 692.6, side: -1, offset: 4.6, turn: 180),
                Furniture(kind: .bikeStands(6), s: 694.4, side: -1, offset: 3.8),
            ],
            // The summit clump in the corner on the left, with its two LiDAR
            // trees: the 2024 ortho's crowns, lime or maple, clear of the
            // Stooktestraat the route turns into.
            extraTrees: [(636, -1, 6, 10, 4), (650, -1, 5, 9.5, 3.8), (640, -1, 13, 11, 4.5)]
        ),
        // Geraardsbergen: the Grotestraat and the Brugstraat over the Dender,
        // the Markt between the town hall and Sint-Bartholomeus, the Vesten
        // along the parking, the Oudebergstraat between houses; then the Muur
        // through the park on the Oudenberg, cut into the hillside (the LiDAR
        // bank rises 1.5-3 m on the left to the hairpin at s ≈ 1300, then
        // lower on the right), and the Kapelmuur up the side of the chapel's
        // grass mound. From the 2024 aerial photo, the GRB facades, the
        // canopy model and photos of 2019-2026 (Commons, Panoramax). The
        // town's pavements are concrete pavers, left to the draped photo.
        "muur": CourseArt(
            sunkenLane: [1170...1300],
            kerbs: [
                (1175...1295, 1),  // the footpath's kerb, on the falling side
                (1405...1442, 1),  // the pale kerb along the lawn up to the chapel
            ],
            lamps: [
                (650...930, 34, -1, .curvedGrey),     // tall grey posts along the Vesten parking
                (1178...1296, 30, 1, .postLantern),   // beside the footpath up the park lane
                (1306...1376, 35, -1, .postLantern),
            ],
            stoneWalls: [
                (1176...1294, -1, 1.8, .slabs),  // stacked schist under the wooded bank
                (1304...1378, 1, 1.0, .slabs),   // the lower bank after the hairpin
                // A knee-high edge of rough ironstone blocks at the foot of the
                // chapel's grass mound, past the bench.
                (1404...1434, -1, 0.45, .rubble),
            ],
            // Setts from the carriageway over the open Markt to the town hall,
            // in front of Sint-Bartholomeus, and over the Vesten's parking;
            // and up to the chapel's steps. With these small setts the far map
            // lays a right-hand strip's courses again on the left 119 m back
            // and 393 m on (450 and 950 courses each way, the map 512 m
            // long), so the strips keep clear of that: the church side ends
            // at 531, where it would lay the chapel's square again.
            pavedVerges: [(446...632, -1, 5.4), (500...531, 1, 5.4), (640...890, -1, 5.4), (1439...1451, -1, 4.2)],
            villages: [0...1160],
            // The Oudenberg's mown grass to the road edge: the chapel's mound
            // on the left, the lawn along the kerb on the right, and past the
            // paved square at the chapel's front the lawn north of the path.
            lawns: [(1395...1438, -1), (1400...1480, 1), (1452...1480, -1)],
            // The Grotestraat (a cycle street), the bridge and the Brugstraat:
            // no lines in the photos of 2019-2026.
            unmarked: [0...444],
            houseLooks: [
                // The neo-Gothic town hall: red brick under slate turrets.
                // (Sint-Bartholomeus keeps the churches' dark brick and slate,
                // near its brown-grey sandstone.)
                HouseLook(span: 540...600, maxRouteDistance: 35, look: .redBrickSlate, side: -1),
                // The red-brick house under orange pantiles left of the lane after the hairpin.
                HouseLook(span: 1335...1385, maxRouteDistance: 30, look: .redBrickPantiles, side: -1),
                HouseLook(span: 0...1630, maxRouteDistance: 60, look: .villageMix),
            ],
            setts: .smallWorn,
            signs: [
                // At the turn onto the Kapelmuur: the node plate and a route arrow right (2022).
                SignPost(s: 1381, side: -1, offset: 1.2, plates: ["node.76", "cycle.route.right"]),
            ],
            furniture: [
                // A grey bench and a bin at the foot of the mound (2024).
                Furniture(kind: .wasteBasket, s: 1397, side: -1, offset: 1.0),
                Furniture(kind: .bench(wood: false), s: 1400, side: -1, offset: 1.2),
                // The chapel (footprint centroid 14 m off s 1453) and the calvary
                // east of it (a lone 6.3 m spike in the canopy model).
                Furniture(kind: .domedChapel, s: 1453, side: -1, offset: 8),
                Furniture(kind: .calvary, s: 1465, side: -1, offset: 6.8),
            ]
        ),
        // Sint-Denijs-Boekel: the concrete Smarre along the valley floor, a
        // sharp left onto the setts and over the beek by the Moldergem mill
        // (low brick parapets, no railings), the mill square, the terrace cut
        // into the hillside under the wood (a bank and evergreens on the
        // right, gardens falling away on the left), the shallow holle weg,
        // the open cutting to the Caildenberg mouth where the setts end
        // (s 557), then narrow cracked asphalt past the farm, the paddock and
        // the chapel of Our Lady of the Seven Sorrows to Moldergem. The setts
        // have an edge row laid lengthwise on both sides and no kerbs or
        // gutters. From the Panoramax pass of 1 March 2026, Commons photos
        // of 2012-2026, the heritage inventory, the 2024 aerial photo and the
        // canopy model (scripts/courses/debug/molenberg/research_summary.json).
        "molenberg": CourseArt(
            sunkenLane: [365...452],
            walls: [
                (328...340, 1, 0.55, 0.1, .redBrick),    // the bridge parapet over the pond and the beek
                (332...338, -1, 0.5, 0.2, .redBrick),    // the mill race's wall, up to the mill's gable
                (540...556, -1, 1.9, 0.7, .whitewashed), // the garden wall under ivy, a big pollard behind
            ],
            // A retaining wall of grey setts in courses under a clipped yew.
            stoneWalls: [(440...452, -1, 0.8, .slabs)],
            fences: [(400...455, 1), (495...556, 1)],  // timber posts and wire on the pasture banks
            rails: [(558...650, 1, .paleTimber)],      // the horse paddock's weathered rails
            // Square concrete poles: on the left to the Caildenberg, then the
            // right past the paddock, the left again to the top.
            poles: [(325...560, 39, -1, .concrete), (585...655, 34, 1, .concrete), (692...780, 41.5, -1, .concrete)],
            hedges: [
                (250...266, 1, 2.8, 1.5, .laurel),   // on the Smarre, before the yellow house
                (365...398, 1, 1.6, 0.2, .ivy),      // dark clipped evergreens and ivy rising from the bank
                (375...390, -1, 2.0, 1.3, .green),   // beech, behind a sandy strip
                (440...452, -1, 1.0, 0.5, .ivy),     // yew on top of the sett wall
                (485...500, 1, 1.8, 0.8, .ivy),      // yew in front of the white house
                (648...668, -1, 1.8, 6.0, .green),   // beech along the farm yard
                (650...760, 1, 2.0, 1.0, .laurel),   // 2.5-3.5 m above the road on its bank (1.5 m in 2015)
                (740...760, -1, 1.6, 0.6, .ivy),     // ivy over a fence
                (765...880, 1, 2.6, 1.0, .laurel),
                (780...880, -1, 1.5, 1.5, .green),   // a young pleached hornbeam on posts and wires
            ],
            // The mill square's setts out to the house fronts, the forecourts of
            // the two white houses, the chapel's apron.
            pavedVerges: [(345...368, 1, 5.4), (474...497, 1, 3.0), (636...643, -1, 2.7)],
            villages: [325...375, 468...500, 690...763],
            houseLooks: [
                // The yellow-rendered house on the Smarre, under orange-red tiles.
                HouseLook(span: 262...290, maxRouteDistance: 14, look: .paleRenderTiles, side: 1),
                // The mill: dark multi-tone red brick under weathered orange-red
                // pantiles, its gable at the road; its barn and sheds beyond.
                HouseLook(span: 335...352, maxRouteDistance: 12, look: .redBrickPantiles, side: -1),
                HouseLook(span: 352...385, maxRouteDistance: 12, look: .redBrickPantiles, side: -1),
                // The miller's house in cream render under dark tiles, then a long
                // low cream range under orange tiles, half in ivy.
                HouseLook(span: 335...352, maxRouteDistance: 15, look: .paleRender, side: 1),
                HouseLook(span: 349...366, maxRouteDistance: 19, look: .paleRenderTiles, side: 1),
                HouseLook(span: 389...405, maxRouteDistance: 12, look: .paleRender, side: -1),  // buff-grey brick, at the edge
                HouseLook(span: 420...437, maxRouteDistance: 24, look: .whitewashedPantiles, side: -1),
                HouseLook(span: 437...460, maxRouteDistance: 18, look: .redBrickPantiles, side: -1),
                HouseLook(span: 460...500, maxRouteDistance: 12, look: .paleRenderTiles, side: 1, kind: "house"),
                // The farm's white-painted range at the road and the farmhouse
                // behind its lawn, orange pantiles.
                HouseLook(span: 545...600, maxRouteDistance: 45, look: .whitewashedPantiles, side: -1),
                HouseLook(span: 634...643, maxRouteDistance: 8, look: .whitewashedPantiles, side: -1, kind: "chapel"),
                HouseLook(span: 660...692, maxRouteDistance: 20, look: .redBrickSlate, side: -1),  // salmon brick, dark tiles
                HouseLook(span: 695...760, maxRouteDistance: 22, look: .paleRender, side: -1),     // the villas
                HouseLook(span: 693...760, maxRouteDistance: 30, look: .redBrickSlate, side: 1),   // over the laurel
            ],
            setts: .mossyGrey,
            signs: [
                // At the turn: Zwalm's plate looking back at the Smarre, and
                // the weight limit and uneven-road warning facing riders.
                SignPost(s: 305, side: -1, offset: 2.5, plates: ["street.molenberg"], turn: 60),
                SignPost(s: 306, side: 1, offset: 1.0, plates: ["c21.3_5t", "a7.uneven"]),
                SignPost(s: 362, side: 1, offset: 1.2, plates: ["place.stdenijsboekel", "plate.wegdek"]),
                SignPost(s: 560, side: 1, offset: 3.0, plates: ["c3", "plate.aangelanden"], turn: 45),  // the Caildenberg
                SignPost(s: 765, side: 1, offset: 2.0, plates: ["street.wijlegem", "street.molenberg"]),
            ],
            furniture: [
                // White-painted brick, a pointed gable with an iron cross, a dark
                // grey glazed door.
                Furniture(kind: .chapelFront(blueDoor: false), s: 639, side: -1, offset: 2.7),
                Furniture(kind: .cabinet, s: 738, side: -1, offset: 0.8),
                Furniture(kind: .wasteBasket, s: 781, side: -1, offset: 1.5),
            ],
            // A lichen-covered pollard by the chapel, 0.8-3 m in the 2015 LiDAR.
            extraTrees: [(646, -1, 4.0, 5.0, 2.2)],
            pollards: [(540...556, -1, 8)]
        ),
        // Etikhove: the concrete Boitsbank past the silos and the paddock, a
        // fork left onto the Taaienberg's concrete foot, then setts from the
        // Fortstraat corner (s 300) to the Bossenaarstraat/Poesthemstraat
        // junction. The cobbled 4.4 m between the surveyed edges is a 0.35 m
        // concrete strip on the left, about 3.25 m of setts and the 0.7 m
        // concrete gutter on the right, flush and the riders' line. The
        // wooded holloway under ivy-clad trees (to s 480), the house in the
        // trees, then open pasture, the farm at the road, a dry-laid stone
        // wall on the left and the bronze legs in the summit garden. From the
        // Panoramax passes of 2 April 2025 (a helmet 360 camera riding up) and
        // 8 March 2026, Commons photos of 2016-2025, the 2024 aerial photo and
        // the canopy model (scripts/courses/debug/taaienberg/research_summary.json).
        "taaienberg": CourseArt(
            sunkenLane: [300...480],
            kerbs: [(299...850, -1)],  // the Fortstraat corner's kerb, then the narrow concrete strip
            gutters: [(300...855, 1, 0.7)],
            stoneWalls: [(595...836, -1, 0.6, .slabs)],  // squared grey blocks, dry-laid, holding up the left verge
            fences: [(545...628, 1), (690...770, 1)],
            rails: [
                (0...205, 1, .darkStain),     // the Boitsbank paddock's dark three-rail fence
                (517...545, 1, .paleTimber),  // grey planks by the open paddock shelter
            ],
            palings: [(799...836, -1, 1.2, 1.0), (838...854, -1, 1.2, 8.5)],  // on the wall, then round the garden
            poles: [(0...205, 40, -1, .concrete), (308...856, 38, 1, .concrete)],
            hedges: [
                (285...318, -1, 2.0, 2.0, .green),        // the corner house's garden at the Fortstraat
                (555...578, -1, 3.8, 1.5, .ivy),          // a tall dark conifer hedge
                (665...672, 1, 1.2, 1.5, .copperBeech),   // red-leaved, behind the farm's mesh fence
                (710...799, -1, 1.5, 0.8, .green),        // on the stone wall, before the white house
                (771...811, 1, 2.8, 1.0, .green),         // beech
                (811...818, 1, 2.5, 1.0, .laurel),
            ],
            // Setts from the gutter to the farmhouse and the barn; the apron
            // laid in arcs round the plinth at the top corner.
            pavedVerges: [(629...668, 1, 3.0), (836...855, -1, 5.4)],
            // Round covers in the setts, left of the middle, about every 45 m.
            streetGrates: [(300...850, -0.5, 45)],
            gutterGrateSpacing: 110,
            villages: [835...1055],
            houseLooks: [
                HouseLook(span: 85...140, maxRouteDistance: 25, look: .redBrickPantiles, side: -1),  // the old farm walls and barns
                HouseLook(span: 150...180, maxRouteDistance: 55, look: .darkBrick, side: 1),  // barns clad in dark timber
                HouseLook(span: 190...237, maxRouteDistance: 25, look: .whitewashedPantiles, side: -1),
                HouseLook(span: 290...320, maxRouteDistance: 36, look: .redBrickPantiles, side: -1),
                HouseLook(span: 460...505, maxRouteDistance: 30, look: .whitewashedPantiles, side: 1),  // the house in the trees
                // The farm at the road: a long cream house under orange-red
                // tiles, then the dark brick barn under black tiles.
                HouseLook(span: 629...650, maxRouteDistance: 22, look: .paleRenderTiles, side: 1, kind: "house"),
                HouseLook(span: 644...690, maxRouteDistance: 16, look: .darkBrick, side: 1),
                HouseLook(span: 690...740, maxRouteDistance: 75, look: .hilltopFarms, side: -1),
                HouseLook(span: 750...775, maxRouteDistance: 12, look: .whitewashedPantiles, side: -1),
                HouseLook(span: 778...792, maxRouteDistance: 20, look: .whitewashedCottages, side: 1),
                HouseLook(span: 780...830, maxRouteDistance: 48, look: .paleRender, side: -1),
                HouseLook(span: 850...860, maxRouteDistance: 20, look: .paleRender, side: -1, kind: "house"),
                HouseLook(span: 840...870, maxRouteDistance: 15, look: .whitewashedPantiles, side: 1),
                HouseLook(span: 865...950, maxRouteDistance: 25, look: .redBrickPantiles),  // Poesthemstraat
            ],
            setts: .warmOblong,
            signs: [
                SignPost(s: 194, side: -1, offset: 0.5, plates: ["street.boitsbank"]),
                SignPost(s: 204, side: -1, offset: 2.0, plates: ["street.taaienberg"]),  // its text unread, a Maarkedal plate
                SignPost(s: 276, side: 1, offset: 1.0, plates: ["node.32", "cycle.route.left"]),
                SignPost(s: 814, side: 1, offset: 0.8, plates: ["cycle.route.right"]),  // the right turn at the top
            ],
            furniture: [
                // On its round plinth at the top corner, facing the road (2023).
                Furniture(kind: .bronzeLegs, s: 842.9, side: -1, offset: 6.3),
                Furniture(kind: .wasteBasket, s: 839, side: -1, offset: 5.5),
            ],
            pollards: [(178...190, 1, 10), (600...625, -1, 8), (640...668, -1, 8), (820...845, -1, 12)],
            // The corner the apron and the plinth took over (open in the 2025
            // photos, the trees behind the paling).
            clearings: [(834...856, -1, 8.0)]
        ),
        // Milano-Sanremo's last climb, drawn as the Riviera (`CourseArt+Poggio`).
        "poggio": .poggio,
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
