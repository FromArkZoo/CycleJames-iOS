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
            /// The blue door and cross of the chapel standing within a few
            /// metres (its walls and roof are the footprint's).
            case chapelFront
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

    /// Width paved on a side of the road at `s`, raised or flush; 0 where
    /// none.
    func pavedWidth(_ s: Double, side: Double) -> Double {
        max(pavementWidth(s, side: side),
            pavedVerges.filter { $0.side * side > 0 && $0.span.contains(s) }.map(\.width).max() ?? 0)
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
        // The Steengat (photos of 2009): cottages on the road edge, setts up
        // to their fronts on the right, a narrow paved strip and small front
        // gardens behind a low hedge on the left, round gully grates down
        // the middle. Widths reach the house fronts in the GRB footprints.
        "koppenberg": CourseArt(
            sunkenLane: [535...648, 765...812],
            kerbs: [(302...430, -1), (688...866, -1)],
            lamps: [(312...432, 29, -1, .curvedBlack)],
            walls: [(842...868, 1)],
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
                Furniture(kind: .chapelFront, s: 635, side: -1, offset: 3),
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
            gutters: [(300...664, -1)],
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
