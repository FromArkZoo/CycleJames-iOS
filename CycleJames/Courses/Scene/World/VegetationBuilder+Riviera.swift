import Foundation
import simd

/// The Riviera's plants (`WorldLook.riviera`), as the photos of the Poggio
/// show them in late March (research look bible, section 3): the species
/// a tree is drawn as, the shrubs and succulents, the verge flora, and a
/// course's hand-placed plants and planting zones, keyed by course id.
///
/// Hand-placed plants are given as route distance on the look bible's
/// frame (from the fork off the Via Aurelia) and moved onto the route by
/// the course's `climb.startS`, which is where that fork is, and the few
/// metres the built line has drifted from the bible's (`Course.drift`).
struct RivieraPlants: Sendable {
    /// What a stretch of the climb grows, for trees the data give no
    /// species for (`VegetationBuilder.pickRivieraForm`).
    enum Mix: Sendable {
        /// The start ramp and the bay below it: Aleppo pines, reeds.
        case seaFront
        /// Villas along the coastal traverse and the ridge: palms,
        /// cypresses, pines, olives, evergreens.
        case villaGardens
        /// The sanctuary's park: stone pines and cypresses.
        case sanctuaryPark
        /// Glasshouses on terraces: olives, the odd cypress and fig.
        case greenhouseBelt
        /// Olive terraces under Monte Calvo.
        case terraces
        /// Poggio at the top: palms, stone pines, cypresses, oleanders.
        case summit
    }

    struct Zone: Sendable {
        var span: ClosedRange<Double>
        /// −1 left, +1 right; nil for both sides.
        var side: Double?
        var maxDistance: Double
        var mix: Mix
    }

    enum Kind: Sendable {
        /// A tree of a species (`pickRivieraForm`'s kinds).
        case tree(String)
        case opuntia
        /// An agave; `spike`: with last year's dead flower stalk.
        case agave(spike: Bool)
        case oleander
        /// A row of glossy evergreen bushes (pittosporum) along the top of
        /// a bank or a wall, to `s + length`.
        case bushes(length: Double)
        /// Bougainvillea over a wall `wall` metres high whose face stands
        /// at the offset, along `length` metres.
        case bougainvillea(wall: Double, length: Double)
        /// A stand of giant reed.
        case reeds
        /// Ice plant over the verge, along `length` metres.
        case iceplant(length: Double)
    }

    struct Plant: Sendable {
        /// Route distance on the look bible's frame (see the type's note).
        var s: Double
        var side: Double
        /// Beyond the carriageway's edge, metres.
        var offset: Double
        var kind: Kind
        var height: Double = 0
        var radius: Double = 0
    }

    /// Clipped hedges: section (look-bible frame), side, height and offset,
    /// as `CourseArt.hedges`.
    struct Hedge: Sendable {
        var span: ClosedRange<Double>
        var side: Double
        var height: Double
        var offset: Double
    }

    /// Ground the scrub fill (`VegetationBuilder.buildRivieraScrub`) keeps
    /// off: paving, parking and open verge where the 2008-2010 canopy
    /// model still has shrubs. Section (look-bible frame), side, and how
    /// far beyond the carriageway's edge.
    struct Bare: Sendable {
        var span: ClosedRange<Double>
        var side: Double
        var maxDistance: Double
    }

    /// A row of shrubs along `points` (course frame, east/north), each
    /// standing only where its ground is at least `rise` over the ground
    /// `front` (east/north metres) from it: on a bank, not at its foot.
    struct Row: Sendable {
        var points: [SIMD2<Double>]
        var front: SIMD2<Double>
        var rise: Double
    }

    struct Course: Sendable {
        var zones: [Zone] = []
        var plants: [Plant] = []
        var hedges: [Hedge] = []
        var bare: [Bare] = []
        /// Ground nothing of the scenery grows on (trees, shrubs, scrub), as
        /// polygons in the course frame (east, north): where the course
        /// has been built over since the LiDAR flight.
        var keepOff: [[SIMD2<Double>]] = []
        /// Planted rows where the data has none, in the course frame.
        var rows: [Row] = []
        /// How far the built route has drifted from the look bible's frame:
        /// (look-bible s, route s − climb start − look-bible s) at places
        /// both name, interpolated between them (`routeS`). The route is
        /// smoothed at its hairpins and centred on the carriageway, so it
        /// runs a few metres short of the OSM line the look bible measured.
        var drift: [SIMD2<Double>] = []

        /// Route distance of a look-bible distance, the climb starting at
        /// `start`.
        func routeS(_ s: Double, start: Double) -> Double {
            guard let first = drift.first, let last = drift.last else { return s + start }
            if s <= first.x { return s + start + first.y }
            if s >= last.x { return s + start + last.y }
            let i = drift.firstIndex { $0.x >= s }!
            let a = drift[i - 1], b = drift[i]
            return s + start + a.y + (b.y - a.y) * (s - a.x) / (b.x - a.x)
        }
    }

    /// The course's own planting, moved onto the route (empty for a course
    /// without an entry).
    var zones: [Zone] = []
    var plants: [Plant] = []
    var hedges: [Hedge] = []
    var bare: [Bare] = []
    var keepOff: [[SIMD2<Double>]] = []
    var rows: [Row] = []
    /// The hand-placed trees, as scenery trees with their species as kind.
    var trees: [SceneryFile.Tree] = []

    /// Whether the scrub keeps off a point `beyond` metres past the edge
    /// at route distance `s` on `side`.
    func isBare(s: Double, side: Double, beyond: Double) -> Bool {
        bare.contains { $0.span.contains(s) && $0.side * side > 0 && beyond <= $0.maxDistance }
    }

    /// Whether a point lies in ground nothing grows on (`Course.keepOff`).
    func keepsOff(east e: Double, north n: Double) -> Bool {
        keepOff.contains { ring in
            var inside = false
            var j = ring.count - 1
            for i in 0..<ring.count {
                let a = ring[i], b = ring[j]
                if (a.y > n) != (b.y > n), e < (b.x - a.x) * (n - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                j = i
            }
            return inside
        }
    }

    func zone(s: Double, side: Double, routeDistance: Double) -> Mix? {
        zones.first { $0.span.contains(s) && routeDistance <= $0.maxDistance && ($0.side.map { $0 * side > 0 } ?? true) }?.mix
    }

    /// The course id hand-placed plants are keyed by: the one given, or, as
    /// the Poggio is the only Riviera course, "poggio" when the look is the
    /// course's own (not a `-courseLook riviera` preview of another road,
    /// which gets the species and flora but none of the Poggio's plants).
    static func key(corridor: RoadCorridor, courseID: String?) -> String? {
        if let courseID { return courseID }
        #if DEBUG
        if WorldLook.launchOverride != nil { return nil }
        #endif
        return corridor.art.look.isRiviera ? "poggio" : nil
    }

    static func make(corridor: RoadCorridor, scenery: SceneryFile?, courseID: String?) -> RivieraPlants {
        guard let id = key(corridor: corridor, courseID: courseID), let course = byCourseID[id] else { return RivieraPlants() }
        let start = corridor.climb.startS
        var out = RivieraPlants()
        out.zones = course.zones.map { z in
            var z = z
            z.span = course.routeS(z.span.lowerBound, start: start)...course.routeS(z.span.upperBound, start: start)
            return z
        }
        out.hedges = course.hedges.map { h in
            var h = h
            h.span = course.routeS(h.span.lowerBound, start: start)...course.routeS(h.span.upperBound, start: start)
            return h
        }
        out.keepOff = course.keepOff
        out.rows = course.rows
        out.bare = course.bare.map { b in
            var b = b
            b.span = course.routeS(b.span.lowerBound, start: start)...course.routeS(b.span.upperBound, start: start)
            return b
        }
        let footprints = FootprintIndex(scenery?.buildings ?? [])
        for p in course.plants {
            var p = p
            p.s = course.routeS(p.s, start: start)
            guard p.s >= 0, p.s <= corridor.route.length else { continue }
            if case let .tree(species) = p.kind {
                let st = corridor.station(at: p.s)
                let at = st.point(lateral: p.side * (st.reach(p.side) + p.offset))
                // (Never inside a house: the survey's offsets are rough.)
                if footprints.contains(east: at.east, north: at.north, margin: 1.0) { continue }
                out.trees.append(SceneryFile.Tree(e: at.east, n: at.north, heightM: p.height, crownRadiusM: p.radius, kind: species))
            } else {
                out.plants.append(p)
            }
        }
        return out
    }

    // MARK: - The Poggio di Sanremo

    /// From the look bible's sections A-J (research/look.md) and the POV
    /// sheets of 30 April 2024; s from the fork off the Aurelia.
    static let poggio = Course(
        zones: [
            Zone(span: -300...420, side: nil, maxDistance: 160, mix: .seaFront),
            Zone(span: 420...1880, side: nil, maxDistance: 160, mix: .villaGardens),
            Zone(span: 1880...2090, side: -1, maxDistance: 140, mix: .sanctuaryPark),
            Zone(span: 1880...2520, side: nil, maxDistance: 160, mix: .villaGardens),
            Zone(span: 2520...2950, side: nil, maxDistance: 200, mix: .greenhouseBelt),
            Zone(span: 2950...3560, side: nil, maxDistance: 200, mix: .terraces),
            Zone(span: 3560...4100, side: nil, maxDistance: 200, mix: .summit),
        ],
        plants: [
            // A. The start ramp: flat-topped, wind-bent pines against the
            // bay below on the left, reeds on the bank above the Aurelia.
            Plant(s: 22, side: -1, offset: 7, kind: .tree("seaPine"), height: 12.5, radius: 2.6),
            Plant(s: 48, side: -1, offset: 10, kind: .tree("seaPine"), height: 11, radius: 2.4),
            Plant(s: 74, side: -1, offset: 6, kind: .tree("seaPine"), height: 13, radius: 2.8),
            Plant(s: 102, side: -1, offset: 12, kind: .tree("seaPine"), height: 10.5, radius: 2.2),
            Plant(s: 132, side: -1, offset: 8, kind: .tree("pine"), height: 12, radius: 3.6),
            Plant(s: 10, side: -1, offset: 4, kind: .reeds),
            Plant(s: 36, side: -1, offset: 5, kind: .reeds),
            Plant(s: 61, side: -1, offset: 4.5, kind: .reeds),
            Plant(s: 88, side: -1, offset: 6, kind: .reeds),
            // C. Hairpin 1: none placed. Its eucalyptus and pines (f10) are
            // the LiDAR's own crowns on the outside, left of route 640-663
            // (a 17.5 m pine, a 17.5 m slim crown drawn as a eucalyptus);
            // on the inside, right, the DSM has no crown within 25 m and the
            // 2024 frame at 338 m shows only sky and lamp posts over the
            // wall. The three placed there stood 4.5-7 m from the other leg,
            // the eucalyptus's bare trunk a chimney over the wall (reviews2).
            // D. Cypresses and pines by the ochre house.
            Plant(s: 505, side: 1, offset: 8, kind: .tree("cypress"), height: 11, radius: 1.2),
            Plant(s: 516, side: 1, offset: 9, kind: .tree("cypress"), height: 9, radius: 1.0),
            Plant(s: 540, side: 1, offset: 11, kind: .tree("pine"), height: 12, radius: 4.2),
            // Cypresses on the terraces above the villa gates, palms higher up.
            Plant(s: 890, side: -1, offset: 7, kind: .tree("cypress"), height: 10, radius: 1.1),
            Plant(s: 905, side: -1, offset: 8, kind: .tree("cypress"), height: 12, radius: 1.2),
            Plant(s: 1058, side: -1, offset: 9, kind: .tree("palm"), height: 9, radius: 4.2),
            Plant(s: 1076, side: -1, offset: 12, kind: .tree("washingtonia"), height: 15, radius: 2.2),
            // E. The Norfolk Island pine and the pink house; the hedge wall.
            Plant(s: 1150, side: 1, offset: 6, kind: .tree("araucaria"), height: 19, radius: 4.2),
            Plant(s: 1166, side: 1, offset: 9, kind: .tree("holmOak"), height: 9, radius: 4),
            // F. Hairpin 2's approach: prickly pear grown into a wall of
            // pads 3 m over the guardrail on the right, over the headland
            // (the 2024 frame at 1350 faces back, so the guardrail and the
            // pears on its left are on the rider's right), and agaves by the
            // guardrail. The ground falls 1-2.5 m behind it, so the pears
            // stand 4-5 m from their feet.
            Plant(s: 1318, side: 1, offset: 1.8, kind: .opuntia, height: 3.6),
            Plant(s: 1329, side: 1, offset: 1.4, kind: .opuntia, height: 4.4),
            Plant(s: 1335, side: 1, offset: 2.3, kind: .opuntia, height: 4.8),
            Plant(s: 1340, side: 1, offset: 1.1, kind: .opuntia, height: 4.2),
            Plant(s: 1345, side: 1, offset: 2.1, kind: .opuntia, height: 4.6),
            Plant(s: 1350, side: 1, offset: 1.2, kind: .opuntia, height: 4.2),
            Plant(s: 1355, side: 1, offset: 2.4, kind: .opuntia, height: 4.0),
            Plant(s: 1362, side: 1, offset: 0.9, kind: .agave(spike: false), height: 1.3),
            Plant(s: 1368, side: 1, offset: 1.4, kind: .agave(spike: true), height: 1.5),
            // 1400-1680 heading W: pines silhouetted against the sea below
            // the guardrail on the left.
            Plant(s: 1438, side: -1, offset: 5, kind: .tree("seaPine"), height: 11, radius: 2.4),
            Plant(s: 1497, side: -1, offset: 8, kind: .tree("seaPine"), height: 12.5, radius: 2.8),
            Plant(s: 1566, side: -1, offset: 6, kind: .tree("seaPine"), height: 10, radius: 2.2),
            Plant(s: 1634, side: -1, offset: 9, kind: .tree("pine"), height: 12, radius: 3.6),
            // Hairpin 3: broadleaves; the palm on the 4 m wall at 1840.
            Plant(s: 1712, side: 1, offset: 6, kind: .tree("holmOak"), height: 10, radius: 4.5),
            Plant(s: 1731, side: 1, offset: 8, kind: .tree("holmOak"), height: 12, radius: 5),
            Plant(s: 1840, side: -1, offset: 2.5, kind: .tree("palm"), height: 8.5, radius: 4),
            // Hairpin 4: the sanctuary's cypresses and stone pines.
            Plant(s: 1930, side: -1, offset: 10, kind: .tree("cypress"), height: 12, radius: 1.2),
            Plant(s: 1956, side: -1, offset: 14, kind: .tree("umbrellaPine"), height: 15, radius: 6.5),
            Plant(s: 1990, side: -1, offset: 18, kind: .tree("umbrellaPine"), height: 14, radius: 6),
            // G. Umbrella pines and a cypress by the side road; the second
            // Norfolk Island pine, by the green villa below the road (on its
            // west side: at 2102, 16 m out, it stood in the villa's 12 m
            // footprint and was dropped).
            Plant(s: 2045, side: -1, offset: 8, kind: .tree("cypress"), height: 11, radius: 1.1),
            Plant(s: 2058, side: -1, offset: 15, kind: .tree("umbrellaPine"), height: 13, radius: 5.5),
            Plant(s: 2115, side: -1, offset: 12, kind: .tree("araucaria"), height: 21, radius: 4.4),
            // The sea view at 2260: the Canary palm over the wall, the
            // bougainvillea down it, pittosporum along its top.
            Plant(s: 2263, side: 1, offset: 3.5, kind: .tree("palm"), height: 9.5, radius: 4.4),
            Plant(s: 2246, side: 1, offset: 0.25, kind: .bougainvillea(wall: 2.3, length: 26)),
            Plant(s: 2228, side: 1, offset: 1.6, kind: .bushes(length: 62)),
            // H. Ice plant over the verge by the terraced houses.
            Plant(s: 2766, side: 1, offset: 0.4, kind: .iceplant(length: 34)),
            // I-J. Olives on the top terraces.
            Plant(s: 3182, side: -1, offset: 4, kind: .tree("olive"), height: 6.5, radius: 3.2),
            Plant(s: 3196, side: -1, offset: 7, kind: .tree("olive"), height: 6, radius: 3),
            Plant(s: 3302, side: -1, offset: 3, kind: .tree("olive"), height: 6.5, radius: 3.4),
            // The summit: oleanders, fan and Canary palms, a stone pine.
            Plant(s: 3672, side: -1, offset: 4, kind: .tree("windmillPalm"), height: 5, radius: 1.5),
            Plant(s: 3690, side: -1, offset: 2, kind: .oleander, height: 2.6),
            Plant(s: 3706, side: -1, offset: 2.5, kind: .oleander, height: 2.2),
            Plant(s: 3700, side: 1, offset: 8, kind: .tree("washingtonia"), height: 14, radius: 2.2),
            Plant(s: 3716, side: 1, offset: 3, kind: .oleander, height: 2.4),
            Plant(s: 3722, side: 1, offset: 10, kind: .tree("palm"), height: 9, radius: 4.2),
            Plant(s: 3655, side: -1, offset: 22, kind: .tree("umbrellaPine"), height: 14, radius: 6),
        ],
        hedges: [
            // E. The 2-3 m dark hedge wall on the right from 1235 (f39);
            // the parapet before it is open to the sea (f37, f38).
            Hedge(span: 1233...1270, side: 1, height: 2.7, offset: 0.6),
        ],
        bare: [
            // Via Val d'Olivi's first leg from the summit junction, right:
            // parked cars and paving in the 2022 ortho (route 4028-4052, the
            // summit's own clearing ends at 4034), houses and asphalt in the
            // summit photos; the LiDAR's 2008-2010 canopy still had shrubs.
            Bare(span: 3744...3768, side: 1, maxDistance: 14),
        ],
        keepOff: [
            // The summit's west car park, between its new wall's face (x =
            // -441.6 - 3.0 (y - 531) / 41.3, fix2-summit) and the junction:
            // bays and cars where the LiDAR had a 6 m tree on the old bank.
            [SIMD2(-433, 531), SIMD2(-442.6, 531), SIMD2(-445.5, 571), SIMD2(-433, 571)],
        ],
        rows: [
            // The bank over that wall, to the foot of the CTR's upper wall
            // 332: oleander and pittosporum 1-2.5 m in the 2023 POV, bare
            // DTM in the world (fix2-summit, 31 October); 1.5 m behind the
            // face, at least 2 m over the bays 1.5 m in front of it.
            Row(points: [SIMD2(-443.1, 531), SIMD2(-444.55, 551), SIMD2(-446.0, 571)], front: SIMD2(3, 0), rise: 2),
        ],
        // The course.json landmarks against route.md's (pipeline note of
        // 29 October 2026): the fork, hairpins 1-3, the sharp left onto the
        // ridge, the N.S. della Guardia junction, Via Firenze, Monte Calvo,
        // Via Firenze rejoining, the summit, the summit loop's hairpin.
        drift: [
            SIMD2(0, 0), SIMD2(365, -5), SIMD2(1383, -6), SIMD2(1723, -8), SIMD2(1939, -9), SIMD2(2083, -10),
            SIMD2(3076, -9), SIMD2(3267, -6), SIMD2(3682, -8), SIMD2(3731, -14.7), SIMD2(3879, -19),
        ])

    static let byCourseID: [String: Course] = ["poggio": poggio]
}

/// Building footprints with a bounding-box prefilter, for "is this inside
/// a house?".
struct FootprintIndex: Sendable {
    private let polys: [(ring: [SIMD2<Double>], lo: SIMD2<Double>, hi: SIMD2<Double>)]

    init(_ buildings: [SceneryFile.Building]) {
        polys = buildings.compactMap { b in
            let ring = b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            guard ring.count >= 3 else { return nil }
            return (ring, ring.reduce(ring[0]) { simd_min($0, $1) }, ring.reduce(ring[0]) { simd_max($0, $1) })
        }
    }

    func contains(east: Double, north: Double, margin: Double = 0) -> Bool {
        let p = SIMD2(east, north)
        for f in polys where p.x >= f.lo.x - margin && p.x <= f.hi.x + margin && p.y >= f.lo.y - margin && p.y <= f.hi.y + margin {
            if LanduseIndex.contains(f.ring, east, north) { return true }
            if margin > 0 {
                for (dx, dy) in [(margin, 0.0), (-margin, 0), (0, margin), (0, -margin)]
                where LanduseIndex.contains(f.ring, east + dx, north + dy) { return true }
            }
        }
        return false
    }
}

extension VegetationBuilder {
    // MARK: - Species

    /// A Riviera tree's form: its species when the data (or a hand-placed
    /// tree) give one, else by its shape (a tall narrow crown is a cypress,
    /// a wide one a stone pine), the landuse it stands in and the course's
    /// planting zone, else a believable mix for the Ligurian coast.
    static func pickRivieraForm(kind: String?, h: Float, r: Float, landuse lu: String?, crowded: Bool,
                                zone: RivieraPlants.Mix?, y: Float, rnd: inout WorldRandom) -> TreeArchetype.Form {
        switch kind {
        case "pine", "seaPine", "aleppoPine": return .aleppoPine
        case "umbrellaPine", "stonePine": return .stonePine
        case "cypress": return .cypress
        case "palm", "phoenix": return h >= 4.5 ? .phoenixPalm : .fanPalm
        case "fanPalm": return h >= 9 ? .washingtonia : .fanPalm
        case "washingtonia": return .washingtonia
        case "windmillPalm", "chamaerops": return .fanPalm
        case "olive": return .olive
        case "araucaria": return .araucaria
        case "holmOak": return .holmOak
        case "eucalyptus": return .eucalyptus
        default: break
        }
        let ratio = h / max(r, 0.5)
        let u = rnd.unit()
        // A tall, narrow crown: a cypress, now and then a Washingtonia.
        // (Guessed fan palms stop at 16 m: alone over a wall at 18-20 m the
        // grey trunk read as a chimney at hairpin 1, route 640-736, where
        // the 2024 frames have eucalyptus and pines and no palm.)
        if ratio >= 4.2, r <= 1.8 { return h > 13 && h <= 16 && u < 0.25 ? .washingtonia : .cypress }
        if kind == "conifer" {
            if r >= 0.4 * h { return .stonePine }
            return ratio >= 3.4 && u < 0.5 ? .cypress : .aleppoPine
        }
        let wide = r >= 0.38 * h && h >= 8
        // Crowns taller than an Aleppo pine or a holm oak grows on these
        // slopes (about 18 m): a stone pine where it spreads, else a
        // eucalypt, now and then an old pine. Stretched to 25 m, a pine's
        // archetype is a pole with tufts.
        if h > 19 {
            if wide { return u < 0.7 ? .stonePine : .eucalyptus }
            return u < 0.6 ? .eucalyptus : u < 0.85 ? .aleppoPine : .stonePine
        }
        /// An olive where one could stand: the Taggiasca of the terraces is
        /// 5-9 m tall, so a taller crown there is something else.
        func olive(or other: TreeArchetype.Form) -> TreeArchetype.Form { h <= 9.5 ? .olive : other }
        switch lu {
        case "orchard", "olive", "terraces", "vineyard":
            return u < 0.85 ? olive(or: .aleppoPine) : .holmOak
        case "greenhouse", "farmland", "allotments":
            return u < 0.6 ? olive(or: .holmOak) : u < 0.8 ? .holmOak : .cypress
        case "forest", "wood", "scrub", "heath":
            return u < 0.55 ? .aleppoPine : u < 0.85 ? .holmOak : wide ? .stonePine : .aleppoPine
        default: break
        }
        switch zone {
        case .seaFront:
            if h > 15, u < 0.15 { return .eucalyptus }
            return u < 0.65 ? .aleppoPine : u < 0.75 && h >= 5 && h <= 12 ? .phoenixPalm : wide ? .stonePine : .holmOak
        case .sanctuaryPark:
            if wide || u < 0.55 { return .stonePine }
            return u < 0.8 ? .cypress : .holmOak
        case .greenhouseBelt:
            return u < 0.45 ? olive(or: .holmOak) : u < 0.7 ? .holmOak : u < 0.85 ? .cypress : .aleppoPine
        case .terraces:
            return u < 0.7 ? olive(or: .aleppoPine) : u < 0.85 ? .aleppoPine : u < 0.92 ? .cypress : .holmOak
        case .summit:
            if h >= 5, h <= 12, u < 0.25 { return .phoenixPalm }
            if h > 12, u < 0.35 { return .washingtonia }
            if h < 7, u < 0.45 { return .fanPalm }
            return wide ? .stonePine : u < 0.6 ? .cypress : .holmOak
        case .villaGardens, nil:
            if lu == "residential" || lu == "garden" || zone == .villaGardens {
                if h >= 5, h <= 13, u < 0.14 { return .phoenixPalm }
                if h > 12, u < 0.2 { return h <= 16 ? .washingtonia : .eucalyptus }
                if h < 7, u < 0.24 { return .fanPalm }
                if ratio > 2.6, u < 0.36 { return .cypress }
                if wide, u < 0.5 { return .stonePine }
                return u < 0.66 ? .aleppoPine : u < 0.82 ? olive(or: .holmOak) : .holmOak
            }
            if wide, u < 0.15 { return .stonePine }
            return u < 0.4 ? .aleppoPine : u < 0.65 ? olive(or: .aleppoPine) : u < 0.9 ? .holmOak : .cypress
        }
    }

    /// The archetype for a Riviera tree: an Aleppo pine with a tall bole and
    /// a small crown is the wind-bent sea-front pine (variant 0).
    static func rivieraArchetype(_ library: TreeLibrary, _ form: TreeArchetype.Form, h: Float, r: Float,
                                 rnd: inout WorldRandom) -> TreeArchetype {
        if form == .aleppoPine {
            let v = h / max(r, 0.5) >= 3.6 ? 0 : 1 + Int(rnd.unit() * 2) % 2
            return library.pick(form, variant: v)
        }
        return library.pick(form, &rnd)
    }

    // MARK: - Shrubs

    enum RivieraShrub {
        case evergreen, oleander, olive, opuntia, agave, reeds
    }

    /// A shrub from the scenery as the Riviera grows it: glossy evergreens
    /// (pittosporum, lentisk, myrtle) mostly, oleanders in gardens (in
    /// leaf, a few early flowers: they bloom from May), young olives on
    /// terraces, giant reed on the banks above the sea, and within
    /// `succulentReach` of the road now and then a prickly pear or an
    /// agave on dry ground (each 0.5-1 k triangles, so none further off,
    /// where they would read as any other bush).
    static func rivieraShrubKind(landuse lu: String?, y: Float, routeDistance: Double, rnd: inout WorldRandom) -> RivieraShrub {
        let u = rnd.unit()
        if y < 26, u < 0.22 { return .reeds }
        let dry = routeDistance < succulentReach
        switch lu {
        case "residential", "garden":
            return u < 0.1 ? .oleander : dry && u < 0.13 ? .agave : dry && u < 0.15 ? .opuntia : .evergreen
        case "orchard", "olive", "terraces", "farmland", "greenhouse":
            return u < 0.4 ? .olive : dry && u < 0.43 ? .opuntia : dry && u < 0.46 ? .agave : .evergreen
        default:
            return u < 0.1 ? .olive : dry && u < 0.13 ? .opuntia : dry && u < 0.16 ? .agave : .evergreen
        }
    }

    /// How far from the route a scenery shrub may be drawn as a succulent.
    static let succulentReach = 24.0

    /// The share of `WorldConfig.shrubDetailRouteRadius` within which the
    /// Riviera's shrubs get their full clump of cards: the Poggio's LiDAR
    /// finds 26 000 shrubs, 11 000 of them in the Flemish radius (1.5 M
    /// triangles with its trees, against the Kwaremont's 0.68 M); past
    /// this they keep the two crossed cards of the light version.
    static let rivieraShrubDetailShare = 0.6

    // MARK: - Walls at the edge

    /// The walls at the carriageway's edge as the plants keep clear of
    /// them (the scenery shrubs, `buildRivieraScrub`). Every Riviera shrub
    /// and scrub card is a camera-facing billboard, so seen along the road
    /// its half-size reaches across: set their radius behind a wall taken
    /// as its offset + 0.55 m, clumps showed their leaves through the
    /// wall's face (reviews2: the render wall at route 2090-2110, which
    /// leans back 1 in 3 over 2.4 m; the honey wall at 4025-4065; the reed
    /// screen at 520). Here a wall's footprint is the one drawn: a
    /// hand-placed wall's offset and depth as `BuildingBuilder.buildEdgeWall`
    /// builds it (sprayed render retaining wall 2.4 m, the first tread
    /// over a wall with fasce 1.55 m, stone retaining wall 0.55 m, parapet
    /// or screen 0.3 m), and the CTR's walls along the edge read as
    /// `BuildingBuilder.EdgeWalls` reads them (retaining, dividing walls
    /// and parapets with 6 or more points within -0.6..2.8 m of the edge),
    /// 0.55 m deep from their surveyed line.
    struct RivieraEdge {
        /// The far side of the footprint beyond the edge (`st.reach`), by
        /// side (0 left, 1 right) and metre of route; 0 where none.
        private let backs: [[Float]]
        /// A parapet or a guardrail at the edge: a drop, its view open.
        private let rails: [[Bool]]
        /// The hand-placed walls with dry-stone terraces (fasce) over them.
        let fasce: [CourseArt.Masonry]

        init(corridor: RoadCorridor, scenery: SceneryFile?) {
            let n = Int(corridor.route.length) + 2
            var backs = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
            var rails = [[Bool]](repeating: [Bool](repeating: false, count: n), count: 2)
            func metres(_ span: ClosedRange<Double>) -> ClosedRange<Int>? {
                let a = max(0, Int(span.lowerBound.rounded(.down))), b = min(n - 1, Int(span.upperBound.rounded(.up)))
                return a <= b ? a...b : nil
            }
            let art = corridor.art
            for m in art.masonry {
                guard let ks = metres(m.span) else { continue }
                let i = m.side < 0 ? 0 : 1
                let depth = m.look == .render && m.retains ? 2.4 : m.terraces > 0 ? BuildingBuilder.fasceFirstTread : m.thickness
                for k in ks {
                    backs[i][k] = max(backs[i][k], Float(m.offset + depth))
                    if !m.retains { rails[i][k] = true }
                }
            }
            for g in art.guardrails {
                guard let ks = metres(g.span) else { continue }
                for k in ks { rails[g.side < 0 ? 0 : 1][k] = true }
            }
            for w in scenery?.walls ?? [] where ["retaining", "masonry", "parapet"].contains(w.kind) {
                let pts = w.points.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
                guard pts.count >= 2,
                      pts.contains(where: { corridor.coarse.query(east: $0.x, north: $0.y).dist < 40 }) else { continue }
                var hits: [(i: Int, k: Int, back: Float)] = []
                for j in 0..<(pts.count - 1) {
                    let a = pts[j], b = pts[j + 1]
                    let steps = max(1, Int((simd_distance(a, b) / 0.5).rounded(.up)))
                    for t in 0...steps where t < steps || j == pts.count - 2 {
                        let p = a + (b - a) * (Double(t) / Double(steps))
                        let q = corridor.coarse.query(east: p.x, north: p.y)
                        guard q.dist < 12 else { continue }
                        let st = corridor.station(at: q.s)
                        let lat = (p.x - st.east) * st.rightE + (p.y - st.north) * st.rightN
                        let side: Double = lat >= 0 ? 1 : -1
                        let beyond = abs(lat) - st.reach(side)
                        guard beyond > -0.6, beyond < 2.8 else { continue }
                        hits.append((side < 0 ? 0 : 1, min(max(Int(q.s), 0), n - 1), Float(beyond + 0.55)))
                    }
                }
                guard hits.count >= 6 else { continue }
                for h in hits { backs[h.i][h.k] = max(backs[h.i][h.k], h.back) }
            }
            self.backs = backs
            self.rails = rails
            fasce = art.masonry.filter { $0.terraces > 0 }
        }

        /// The far side of the edge wall's footprint beyond the edge at
        /// route distance `s` on `side`; 0 where none.
        func back(_ s: Double, side: Double) -> Double {
            let a = backs[side < 0 ? 0 : 1], k = Int(s.rounded(.down))
            return k >= 0 && k < a.count ? Double(a[k]) : 0
        }

        /// A parapet or a guardrail at the edge at `s` on `side`.
        func railed(_ s: Double, side: Double) -> Bool {
            let a = rails[side < 0 ? 0 : 1], k = Int(s.rounded(.down))
            return k >= 0 && k < a.count && a[k]
        }

        /// The hand-placed wall with fasce over it at `s` on `side`.
        func terraces(_ s: Double, side: Double) -> CourseArt.Masonry? {
            fasce.first { $0.side * side > 0 && $0.span.contains(s) }
        }

        /// The share of its height a plant `h` tall standing at `y`,
        /// `beyond` metres past the edge at `s` on `side`, may keep: where
        /// the ground falls away (1.5 m down 8 m out) the sea and the
        /// valley show over the edge in every frame (f20, f24, f37, f38),
        /// so near the road the plants below it stay under the rider's
        /// line of sight: 0.7 m over the edge at a parapet or a guardrail
        /// (its line), else 1 m, dropping a metre in 16 (the coast lies 5-10
        /// degrees down from the road). 1 elsewhere.
        func sightFit(_ corridor: RoadCorridor, s: Double, side: Double, beyond: Double, y: Float, h: Float) -> Float {
            guard beyond < 40 else { return 1 }
            let st = corridor.station(at: s)
            let edgeY = corridor.roadHeight(st, lateral: side * st.reach(side))
            guard Double(y) < edgeY - 0.2 else { return 1 }
            let p = st.point(lateral: side * (st.reach(side) + 8))
            guard Double(corridor.terrain.height(east: p.east, north: p.north)) < edgeY - 1.5 else { return 1 }
            let line = Float(edgeY) + (railed(s, side: side) ? 0.7 : 1.0) - Float(beyond) / 16
            return min(1, (line - y) / max(h, 0.1))
        }

        /// Whether a plant at (east, north), `routeDistance` from the line
        /// at route distance `s`, whose leaves reach `half` metres across,
        /// would show them through an edge wall's face or over the fasce's
        /// faces (look 1000-1130: three or four bare dry-stone faces over
        /// the road wall in the 2024 frame at 1064 m).
        func blocks(_ corridor: RoadCorridor, east: Double, north: Double, s: Double, routeDistance: Double,
                    half: Double) -> Bool {
            let st = corridor.station(at: s)
            let side: Double = (east - st.east) * st.rightE + (north - st.north) * st.rightN >= 0 ? 1 : -1
            let beyond = routeDistance - st.reach(side)
            if let m = terraces(s, side: side), let last = BuildingBuilder.fasceTiers(m, at: s, corridor: corridor).last,
               beyond - half < last.treadEnd {
                return true
            }
            let wall = back(s, side: side)
            return wall > 0 && beyond - half < wall + 0.15
        }
    }

    /// One scenery shrub on the Riviera (`build`'s shrub loop).
    static func rivieraShrub(_ c: inout Cluster, _ sh: SceneryFile.Shrub, y: Float, landuse: String?, routeDistance: Double,
                             detailed: Bool, sky: SkyRaster?) {
        var rnd = WorldRandom(sh.e, sh.n, salt: 31)
        let kind = rivieraShrubKind(landuse: landuse, y: y, routeDistance: routeDistance, rnd: &rnd)
        let h = Float(sh.heightM) * 1.1, r = Float(sh.radiusM) * 1.2
        let base = SIMD3<Float>(Float(sh.e), y, Float(-sh.n))
        let skyHere = sky?.plantSky(east: sh.e, north: sh.n, radius: Double(r)) ?? 1
        switch kind {
        case .opuntia, .agave:
            guard detailed else { return }
            let first = c.full.vertexCount
            if kind == .opuntia {
                opuntia(&c.full, base: base, height: min(max(h, 1.2), 2.6), rnd: &rnd)
            } else {
                agave(&c.full, base: base, size: min(max(h, 0.9), 1.6), spike: rnd.unit() < 0.15, rnd: &rnd)
            }
            patchPhase(&c.full, from: first, phase: rnd.range(0, 6.28), tint: TreeArchetype.packColour(SIMD3(1, 1, 1)))
            skyShade(&c.full, from: first, sky: skyHere, baseY: y, height: h)
        case .reeds:
            let first = c.full.vertexCount
            reedClump(&c.full, base: base, height: rnd.range(3, 4.2), rnd: &rnd)
            skyShade(&c.full, from: first, sky: skyHere, baseY: y, height: 4)
            let firstL = c.light.vertexCount
            reedClump(&c.light, base: base, height: rnd.range(3, 4.2), cards: 2, rnd: &rnd)
            skyShade(&c.light, from: firstL, sky: skyHere, baseY: y, height: 4)
        case .evergreen, .oleander, .olive:
            let uv = kind == .oleander ? TreeArchetype.medOleanderUV : kind == .olive ? TreeArchetype.medOliveUV
                : TreeArchetype.medEvergreenUV
            let colour = kind == .evergreen ? SIMD3<Float>(0.95, 1.0, 0.95) * rnd.range(0.85, 1.1) : SIMD3<Float>(1, 1, 1)
            if detailed {
                let first = c.full.vertexCount
                bush(&c.full, base: base, radius: r, height: h, uv: uv, colour: colour, rnd: &rnd)
                skyShade(&c.full, from: first, sky: skyHere, baseY: y, height: h)
            }
            var light = MeshBuffer(parts: 2)
            let centre = base + SIMD3(0, h * 0.5, 0)
            let radii = SIMD3<Float>(r, h * 0.5, r)
            // (Square, two triangles each, as the Flemish shrubs' light
            // cards: 26 000 of them.)
            for k in 0..<2 {
                let az = rnd.range(0, 3.14) + Float(k) * 1.57
                TreeArchetype.card(&light, centre: centre, size: max(2 * r, h) * 1.1, normal: SIMD3(cos(az), 0.2, sin(az)),
                                   roll: rnd.range(-0.3, 0.3), uv: uv, crownCentre: centre - SIMD3(0, h * 0.3, 0), crownRadii: radii,
                                   height: max(h, 2) * 3, ao: 0.85, bend: 0.6, baseY: y, mirror: k == 1)
            }
            patchPhase(&light, from: 0, phase: rnd.range(0, 6.28), tint: TreeArchetype.packColour(colour))
            skyShade(&light, from: 0, sky: skyHere, baseY: y, height: h)
            c.light.appendExactly(light)
            if !detailed { c.lightOnly.appendExactly(light) }
        }
    }

    /// A cluster with its light-only plants (`Cluster.lightOnly`) added to
    /// its full level when it has one, and the buffer let go of.
    static func foldLightOnly(_ c: Cluster) -> Cluster {
        var c = c
        if !c.full.isEmpty, !c.lightOnly.isEmpty, c.full.sameChannels(as: c.lightOnly) {
            c.full.appendExactly(c.lightOnly)
        }
        c.lightOnly = MeshBuffer(parts: 2)
        return c
    }

    /// A rounded bush of billboard leaf cards through its volume (as the
    /// Flemish shrubs), in one colour.
    static func bush(_ m: inout MeshBuffer, base: SIMD3<Float>, radius r: Float, height h: Float, uv: SIMD4<Float>,
                     colour: SIMD3<Float>, rnd: inout WorldRandom) {
        let first = m.vertexCount
        let centre = base + SIMD3(0, h * 0.5, 0)
        let radii = SIMD3<Float>(r, h * 0.5, r)
        let span = max(2 * r, h)
        let cards = min(7, max(3, Int((span * span * 1.6).rounded())))
        let size = max(0.8, span * 0.6)
        for _ in 0..<cards {
            let d = TreeArchetype.randomDir(&rnd, minY: -0.3)
            TreeArchetype.card(&m, centre: centre + d * radii * rnd.range(0.15, 0.6), size: size * rnd.range(0.85, 1.15), normal: d,
                               roll: rnd.range(0, 6.283), uv: uv, crownCentre: centre - SIMD3(0, h * 0.3, 0), crownRadii: radii,
                               height: max(h, 2) * 3, ao: 0.88, bend: 0.6, baseY: base.y, mirror: rnd.unit() < 0.5,
                               hull: TreeArchetype.hull(for: uv))
        }
        patchPhase(&m, from: first, phase: rnd.range(0, 6.28), tint: TreeArchetype.packColour(colour))
    }

    // MARK: - Scrub

    /// How far from the route the scrub fill reaches (`buildRivieraScrub`),
    /// and where it thins from two cards to one.
    static let scrubReach = 180.0
    static let scrubCrossedReach = 45.0
    /// Within this far of the carriageway's edge a clump is three smaller
    /// cards through its volume, as a bush: one or two big cards there read
    /// as a flat sprite with hard edges (reviews2, battery at route 1650).
    static let scrubLumpyReach = 10.0

    /// The share of the scrub lattice kept `beyond` metres past the edge:
    /// all of it to 40 m, a third at 110 m, a quarter from 150 m; the
    /// clumps kept widen by its inverse root, so the cover holds while
    /// the far slopes (two thirds of the clumps) cost a third as much.
    static func scrubShare(_ beyond: Double) -> Double {
        if beyond <= 40 { return 1 }
        if beyond <= 110 { return 1 - 0.65 * (beyond - 40) / 70 }
        return max(0.25, 0.35 - 0.1 * (beyond - 110) / 40)
    }

    /// How far across a clump's leaves reach from its centre, seen along
    /// the road: half its card (rolled up to 0.4 rad) or, for the three
    /// smaller cards of a near clump, their spread and half one of them.
    static func scrubHalfReach(r: Float, h: Float, cards: Int, wide: Float = 1) -> Float {
        let size = max(2 * r, h) * (cards == 1 ? 1.2 : 1.1)
        if cards >= 3 { return 0.35 * r + size * 0.62 / 2 * (0.92 + 0.39) }
        return size / 2 * (0.92 * wide + 0.39)
    }

    /// The maquis on the banks and slopes: the Poggio's LiDAR canopy (DSM
    /// First − DTM, 2008-2010) is scrub 0.6-5 m tall over a quarter to four
    /// fifths of the ground within 150 m of the road, where its shrubs and
    /// tree crowns (one per canopy blob) cover a tenth at most, so the
    /// banks over the walls drew as lawn with a few round bushes. Here
    /// every lattice point (1.8 m on high, sparser with `bankPlantDensity`
    /// and with distance, `scrubShare`) on scrub-high canopy that is part
    /// of a patch (5 of its 3 x 3 metres over 0.4 m: a wall's crest is a
    /// line), clear of buildings, glass houses, the road, side roads, the
    /// scenery's own plants and the course's bare ground, gets a clump:
    /// dark lentisk / myrtle / broom green, olive grey on the terraces,
    /// lighter and darker by the patch; and the crests of the edge walls
    /// that hold up a bank get a band of it. A clump's leaves stay behind
    /// the edge walls' footprints and off the carriageway (`RivieraEdge`);
    /// on the fasce only low clumps stand, mid-tread; on the side where
    /// the ground falls away (the sea and the valley in every frame: f20,
    /// f24, f37, f38) the scrub near the road stays under the rider's
    /// line of sight. Light-only plants (`Cluster.lightOnly`); the clumps
    /// are kept for the cameras (`ScrubField`). Returns the clumps placed.
    static func buildRivieraScrub(courseID: String, corridor: RoadCorridor, scenery: SceneryFile?, config: WorldConfig,
                                  sky: SkyRaster?, sideRoads: RoadBuilder.SideRoadMask, landuse: LanduseIndex,
                                  edge: RivieraEdge, plants: RivieraPlants?, cleared: (Double, Double) -> Bool,
                                  cluster: (Double, Double, (inout Cluster) -> Void) -> Void) -> Int {
        guard config.bankPlantDensity > 0, let dir = CourseBundle.directory(for: courseID),
              let header = (try? CourseBundle.loadCourseFile(id: courseID))?.canopy,
              let canopy = try? HeightRaster.load(from: dir.appendingPathComponent(header.file), header: header) else { return 0 }
        let cols = canopy.cols, rows = canopy.rows, cell = canopy.cellM
        let oE = canopy.originEast, oN = canopy.originNorth
        // Taken: 2 by buildings (and a metre round them) and glass houses,
        // 1 by the scenery's crowns and shrubs.
        var taken = [UInt8](repeating: 0, count: cols * rows)
        func fill(_ ring: [[Double]], margin: Int) {
            let pts = ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            guard pts.count >= 3 else { return }
            let lo = pts.reduce(pts[0]) { simd_min($0, $1) }, hi = pts.reduce(pts[0]) { simd_max($0, $1) }
            let r0 = max(Int(((oN - hi.y) / cell).rounded(.down)) - margin, 0)
            let r1 = min(Int(((oN - lo.y) / cell).rounded(.up)) + margin, rows - 1)
            guard r0 <= r1 else { return }
            for row in r0...r1 {
                // Where the ring crosses this row's centre line, then the
                // spans between, widened by the margin.
                let y = oN - (Double(row) + 0.5) * cell
                var xs: [Double] = []
                var j = pts.count - 1
                for i in 0..<pts.count {
                    let a = pts[i], b = pts[j]
                    if (a.y > y) != (b.y > y) { xs.append((b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x) }
                    j = i
                }
                xs.sort()
                var k = 0
                while k + 1 < xs.count {
                    let c0 = max(Int(((xs[k] - oE) / cell).rounded(.down)) - margin, 0)
                    let c1 = min(Int(((xs[k + 1] - oE) / cell).rounded(.down)) + margin, cols - 1)
                    if c0 <= c1 {
                        for rr in max(row - margin, 0)...min(row + margin, rows - 1) {
                            for cc in c0...c1 { taken[rr * cols + cc] = 2 }
                        }
                    }
                    k += 2
                }
            }
        }
        func stamp(_ e: Double, _ n: Double, _ radius: Double) {
            let c0 = Int(((e - oE) / cell).rounded(.down)), r0 = Int(((oN - n) / cell).rounded(.down))
            let k = Int((radius / cell).rounded(.up))
            for dr in -k...k {
                for dc in -k...k where Double(dr * dr + dc * dc) * cell * cell <= radius * radius {
                    let rr = r0 + dr, cc = c0 + dc
                    if rr >= 0, rr < rows, cc >= 0, cc < cols, taken[rr * cols + cc] == 0 { taken[rr * cols + cc] = 1 }
                }
            }
        }
        for b in scenery?.buildings ?? [] { fill(b.ring, margin: 1) }
        for l in scenery?.landuse ?? [] where l.kind == "greenhouse" { fill(l.ring, margin: 0) }
        for t in scenery?.trees ?? [] { stamp(t.e, t.n, t.crownRadiusM * 0.9) }
        for sh in scenery?.shrubs ?? [] { stamp(sh.e, sh.n, sh.radiusM * 1.2) }

        func canopyAt(_ col: Int, _ row: Int) -> Float {
            guard col >= 0, col < cols, row >= 0, row < rows else { return 0 }
            let v = canopy.values[row * cols + col]
            return v.isFinite ? v : 0
        }
        let step = 1.8 / max(config.bankPlantDensity, 0.3).squareRoot()
        let reach = min(scrubReach, config.shrubMaxRouteRadius)
        let terrain = corridor.terrain
        var discs: [ScrubField.Disc] = []
        /// One clump into its cluster, light-only, and its disc for the cameras.
        func add(_ m: MeshBuffer, e: Double, n: Double, half: Float, top: Float) {
            cluster(e, n) { c in
                c.light.appendExactly(m)
                c.lightOnly.appendExactly(m)
            }
            discs.append(ScrubField.Disc(e: e, n: n, radius: half, top: top))
        }
        var gy = 0.0
        while gy < Double(rows) * cell {
            var gx = 0.0
            while gx < Double(cols) * cell {
                defer { gx += step }
                var rnd = WorldRandom(gx, gy, salt: 41)
                let e = oE + gx + Double(rnd.range(0, 0.9)) * step, n = oN - gy - Double(rnd.range(0, 0.9)) * step
                let col = Int(((e - oE) / cell).rounded(.down)), row = Int(((oN - n) / cell).rounded(.down))
                let hc = canopyAt(col, row)
                guard hc >= 0.5, hc <= 5, row >= 0, row < rows, col >= 0, col < cols, taken[row * cols + col] == 0 else { continue }
                var patch = 0
                for dr in -1...1 { for dc in -1...1 where canopyAt(col + dc, row + dr) > 0.4 { patch += 1 } }
                guard patch >= 5 else { continue }
                let q = corridor.coarse.query(east: e, north: n)
                guard q.dist <= reach else { continue }
                let st = corridor.station(at: q.s)
                let side: Double = (e - st.east) * st.rightE + (n - st.north) * st.rightN >= 0 ? 1 : -1
                let beyond = q.dist - st.reach(side)
                let share = scrubShare(beyond)
                guard beyond > 0.8, share >= 1 || Double(rnd.unit()) < share,
                      !sideRoads.covers(east: e, north: n), !cleared(e, n),
                      !(plants?.isBare(s: q.s, side: side, beyond: beyond) ?? false) else { continue }
                var y = Float(terrain.height(east: e, north: n))
                guard y.isFinite, y > 0.5 else { continue }
                let lu = landuse.kind(east: e, north: n)
                // Gardens are kept: half the clumps.
                if lu == "residential" || lu == "garden", rnd.unit() < 0.5 { continue }
                let olive = (lu == "terraces" || lu == "olive" || lu == "orchard") && rnd.unit() < 0.6
                var h = min(max(hc, 0.9), 3.4) * rnd.range(0.85, 1.1)
                var r = min(max(0.55 * h + 0.75, 1.15), 2.0) * rnd.range(0.9, 1.15)
                var cards = beyond < scrubLumpyReach ? 3 : q.dist < scrubCrossedReach ? 2 : 1
                let wide = Float(min(1 / share.squareRoot(), 1.8))
                // On the fasce, nothing in front of a face (the 2024 frame
                // at 1064 m: bare dry-stone faces, grass and a few low
                // bushes on the treads): only low clumps in a tread's
                // middle, standing on it, under half the face above.
                if let m = edge.terraces(q.s, side: side) {
                    let tiers = BuildingBuilder.fasceTiers(m, at: q.s, corridor: corridor)
                    if let last = tiers.last, beyond < last.treadEnd + 1 {
                        guard let k = tiers.firstIndex(where: { beyond >= $0.face && beyond < $0.treadEnd }) else { continue }
                        let t = tiers[k], f = beyond - t.face, depth = t.treadEnd - t.face
                        let above = k + 1 < tiers.count ? tiers[k + 1].top - t.top : 1.6
                        guard f >= 0.9, f <= depth - 0.9, rnd.unit() < 0.4 else { continue }
                        y = max(y, Float(t.top))
                        h = min(rnd.range(0.5, 0.85), Float(above) * 0.5)
                        r = rnd.range(0.35, 0.5)
                        cards = 3
                    }
                }
                // Its leaves behind the edge wall's footprint and off the
                // carriageway: a smaller clump where there is less room.
                let wall = edge.back(q.s, side: side)
                let room = Float(beyond - (wall > 0 ? wall + 0.15 : 0.3))
                // And under the rider's line of sight where the ground falls
                // away (`RivieraEdge.sightFit`).
                let fit = min(1, room / scrubHalfReach(r: r, h: h, cards: cards, wide: wide),
                              edge.sightFit(corridor, s: q.s, side: side, beyond: beyond, y: y, h: h))
                guard fit >= 0.45 else { continue }
                h *= fit
                r *= fit
                // Patches some tens of metres across, darker and lighter.
                let wave = 0.5 + 0.5 * sin(e * 0.093 + 1.3) * sin(n * 0.117 + 0.4)
                let shade = (0.8 + 0.3 * Float(wave)) * rnd.range(0.88, 1.08)
                let colour = olive ? SIMD3<Float>(1.0, 1.02, 0.98) * shade : SIMD3<Float>(0.84, 0.92, 0.84) * shade
                let uv = olive ? TreeArchetype.medOliveUV : TreeArchetype.medEvergreenUV
                let base = SIMD3<Float>(Float(e), y, Float(-n))
                let skyHere = sky?.plantSky(east: e, north: n, radius: Double(r)) ?? 1
                let m = scrubClump(centre: base + SIMD3(0, h * 0.5, 0), radii: SIMD3(r, h * 0.5, r), cards: cards, uv: uv,
                                   colour: colour, sky: skyHere, baseY: y, wide: wide, rnd: &rnd)
                add(m, e: e, n: n, half: scrubHalfReach(r: r, h: h, cards: cards, wide: wide), top: y + scrubTop(r: r, h: h))
            }
            gy += step
        }

        // The crest of the edge walls that hold up a bank: overgrown in
        // every photo (lentisk, broom, bramble and ivy over the coping),
        // where the canopy model, 15 years older than the walls' tops are
        // tidy, often has none. Two clumps a station every 1.6 m (less on
        // the lower tiers), their leaves behind the wall's footprint, with
        // gaps; none over fasce (their faces are bare).
        var s = 0.0
        while s < corridor.route.length {
            defer { s += 1.6 / max(config.bankPlantDensity, 0.3).squareRoot() }
            let st = corridor.station(at: s)
            for side in [-1.0, 1.0] {
                guard corridor.art.masonryWidth(s, side: side) > 0, edge.terraces(s, side: side) == nil else { continue }
                let wall = edge.back(s, side: side)
                var rnd = WorldRandom(s, side, salt: 43)
                let edgeY = corridor.roadHeight(st, lateral: side * st.reach(side))
                for k in 0..<2 {
                    if sin(s * 0.047 + side * 1.7 + Double(k)) * sin(s * 0.131 + 0.3) < -0.35 { continue }
                    let h = rnd.range(1.1, 2.3), r = rnd.range(0.8, 1.3)
                    let half = scrubHalfReach(r: r, h: h, cards: 2)
                    let o = wall + 0.15 + Double(half) + Double(k) * 1.6 + Double(rnd.range(0, 0.9))
                    let pt = st.point(lateral: side * (st.reach(side) + o))
                    let col = Int(((pt.east - oE) / cell).rounded(.down)), row = Int(((oN - pt.north) / cell).rounded(.down))
                    guard col >= 0, col < cols, row >= 0, row < rows, taken[row * cols + col] < 2 else { continue }
                    let y = Float(terrain.height(east: pt.east, north: pt.north))
                    // Only on a bank the wall holds up, not over a drop.
                    guard y.isFinite, Double(y) > edgeY + 0.8, !sideRoads.covers(east: pt.east, north: pt.north),
                          !cleared(pt.east, pt.north), !(plants?.isBare(s: s, side: side, beyond: o) ?? false) else { continue }
                    let shade = rnd.range(0.78, 1.02)
                    let colour = SIMD3<Float>(0.84, 0.92, 0.84) * shade
                    let base = SIMD3<Float>(Float(pt.east), y, Float(-pt.north))
                    let skyHere = sky?.plantSky(east: pt.east, north: pt.north, radius: Double(r)) ?? 1
                    // Its cards' lowest corners (rolled up to 0.4 rad) on the
                    // ground, not under it: set back behind the crest, the
                    // clump would otherwise hide behind a tall wall's top
                    // from the road (the render wall at 2100, f57).
                    let lift = max(h * 0.5, max(2 * r, h) * 1.1 * 0.655 + 0.05)
                    let m = scrubClump(centre: base + SIMD3(0, lift, 0), radii: SIMD3(r, h * 0.5, r), cards: 2,
                                       uv: TreeArchetype.medEvergreenUV, colour: colour, sky: skyHere, baseY: y, rnd: &rnd)
                    add(m, e: pt.east, n: pt.north, half: half, top: y + lift + max(2 * r, h) * 0.6)
                }
            }
        }
        // The course's planted rows (`RivieraPlants.Row`), a clump every
        // 1.1 m, oleander among the evergreens.
        for row in plants?.rows ?? [] {
            for j in 0..<max(row.points.count - 1, 0) {
                let a = row.points[j], b = row.points[j + 1]
                let count = max(1, Int((simd_distance(a, b) / 1.1).rounded()))
                for i in 0..<count {
                    let p = a + (b - a) * ((Double(i) + 0.5) / Double(count))
                    var rnd = WorldRandom(p.x, p.y, salt: 47)
                    let y = Float(terrain.height(east: p.x, north: p.y))
                    let below = Float(terrain.height(east: p.x + row.front.x, north: p.y + row.front.y))
                    guard y.isFinite, below.isFinite, Double(y - below) >= row.rise else { continue }
                    let oleander = rnd.unit() < 0.35
                    let h = rnd.range(1.2, 2.4), r = rnd.range(0.6, 0.9)
                    let colour = oleander ? SIMD3<Float>(1, 1, 1) : SIMD3<Float>(0.9, 0.97, 0.9) * rnd.range(0.85, 1.05)
                    let base = SIMD3<Float>(Float(p.x), y, Float(-p.y))
                    let skyHere = sky?.plantSky(east: p.x, north: p.y, radius: Double(r)) ?? 1
                    let m = scrubClump(centre: base + SIMD3(0, h * 0.5, 0), radii: SIMD3(r, h * 0.5, r), cards: 3,
                                       uv: oleander ? TreeArchetype.medOleanderUV : TreeArchetype.medEvergreenUV,
                                       colour: colour, sky: skyHere, baseY: y, rnd: &rnd)
                    add(m, e: p.x, n: p.y, half: scrubHalfReach(r: r, h: h, cards: 3), top: y + scrubTop(r: r, h: h))
                }
            }
        }
        // The scenery's shrubs near the road too, as drawn, for the debug
        // views (`ScrubField.clearSight`); the ride's clearance has them
        // already, from the data.
        for sh in scenery?.shrubs ?? [] {
            let q = corridor.coarse.query(east: sh.e, north: sh.n)
            guard q.dist < 30 else { continue }
            let y = Float(terrain.height(east: sh.e, north: sh.n))
            guard y.isFinite else { continue }
            let r = Float(sh.radiusM) * 1.2, h = Float(sh.heightM) * 1.1
            discs.append(ScrubField.Disc(e: sh.e, n: sh.n, radius: scrubHalfReach(r: r, h: h, cards: 2),
                                         top: y + scrubTop(r: r, h: h), shrub: true))
        }
        ScrubField.publish(ScrubField(courseID: courseID, routeLength: corridor.route.length, discs: discs))
        return discs.reduce(0) { $0 + ($1.shrub ? 0 : 1) }
    }

    /// The top of a clump's cards over its foot.
    static func scrubTop(r: Float, h: Float) -> Float { h * 0.5 + max(2 * r, h) * 0.6 }

    /// One clump of the scrub (`buildRivieraScrub`): `cards` billboards of
    /// a leaf cell through its centre, `wide` times as wide as tall, in one
    /// colour; three and more, smaller ones through its volume, each
    /// trimmed to the cell's leaves.
    static func scrubClump(centre: SIMD3<Float>, radii: SIMD3<Float>, cards: Int, uv: SIMD4<Float>, colour: SIMD3<Float>,
                           sky: Float, baseY: Float, wide: Float = 1, rnd: inout WorldRandom) -> MeshBuffer {
        var m = MeshBuffer(parts: 2)
        let h = radii.y * 2, r = radii.x
        let crownRadii = SIMD3<Float>(r * wide, radii.y, r * wide)
        if cards >= 3 {
            let size = max(2 * r, h) * 1.1 * 0.62
            for k in 0..<cards {
                let a = rnd.range(0, 6.28)
                let o = SIMD3<Float>(cos(a) * r * 0.35, (Float(k) / Float(cards - 1) - 0.5) * h * 0.35, sin(a) * r * 0.35)
                TreeArchetype.card(&m, centre: centre + o, size: size * rnd.range(0.9, 1.1),
                                   normal: simd_normalize(o + SIMD3(0, 0.2, 0)), roll: rnd.range(-0.4, 0.4), uv: uv,
                                   crownCentre: centre - SIMD3(0, h * 0.3, 0), crownRadii: crownRadii, height: max(h, 2) * 3,
                                   ao: 0.84, bend: 0.6, baseY: baseY, mirror: rnd.unit() < 0.5, hull: TreeArchetype.hull(for: uv))
            }
        } else {
            for k in 0..<cards {
                let az = rnd.range(0, 3.14) + Float(k) * 1.57
                TreeArchetype.card(&m, centre: centre, size: max(2 * r, h) * (cards == 1 ? 1.2 : 1.1),
                                   normal: SIMD3(cos(az), 0.2, sin(az)), roll: rnd.range(-0.4, 0.4), uv: uv,
                                   crownCentre: centre - SIMD3(0, h * 0.3, 0), crownRadii: crownRadii, height: max(h, 2) * 3,
                                   ao: 0.82, bend: 0.6, aspect: wide, baseY: baseY, mirror: k == 1 || rnd.unit() < 0.3)
            }
        }
        patchPhase(&m, from: 0, phase: rnd.range(0, 6.28), tint: TreeArchetype.packColour(colour))
        skyShade(&m, from: 0, sky: sky, baseY: baseY, height: h)
        return m
    }

    /// The scrub's clumps as discs for the cameras (`buildRivieraScrub`
    /// publishes them for its course): the ride's `CameraClearance` takes
    /// them as shrubs, so its broadcast moto and orbit keep out of the
    /// scrub and its sight lines rise over it, and the debug broadcast view
    /// comes out of it (`clearSight`). Before, three of the nine broadcast
    /// stations of the 30 October shots stood inside a clump (route 350,
    /// 2400, 2600: the whole frame leaves).
    final class ScrubField: @unchecked Sendable {
        struct Disc {
            var e: Double
            var n: Double
            /// How far its leaves reach across (`scrubHalfReach`).
            var radius: Float
            var top: Float
            /// A scenery shrub (the clearance has those from the data).
            var shrub = false
        }

        let courseID: String
        let routeLength: Double
        let discs: [Disc]
        private let cellM = 8.0
        private var grid: [Int: [Int32]] = [:]

        init(courseID: String, routeLength: Double, discs: [Disc]) {
            self.courseID = courseID
            self.routeLength = routeLength
            self.discs = discs
            for (i, d) in discs.enumerated() {
                let r = Double(d.radius)
                for cz in key(d.n - r)...key(d.n + r) {
                    for cx in key(d.e - r)...key(d.e + r) { grid[cz * 100_000 + cx, default: []].append(Int32(i)) }
                }
            }
        }

        private func key(_ v: Double) -> Int { Int(floor((v + 50_000) / cellM)) }

        /// The highest leaf top over (east, north) within `margin` of a
        /// clump's reach; -infinity where there is none.
        func top(east e: Double, north n: Double, margin: Double = 0) -> Float {
            var top = -Float.infinity
            for i in grid[key(n) * 100_000 + key(e)] ?? [] {
                let d = discs[Int(i)]
                let rr = Double(d.radius) + margin
                if (d.e - e) * (d.e - e) + (d.n - n) * (d.n - n) <= rr * rr { top = max(top, d.top) }
            }
            return top
        }

        /// A camera at `eye` looking at `target` (scene space), out of the
        /// leaves as the ride's rig would put it: raised up to `maxRaise`
        /// over the clumps in the line, else moved to `fallback` (and
        /// raised there), else brought in towards the target until in
        /// front of them.
        func clearSight(eye: SIMD3<Float>, target: SIMD3<Float>, maxRaise: Float = 1,
                        fallback: SIMD3<Float>? = nil) -> SIMD3<Float> {
            func blocked(_ eye: SIMD3<Float>) -> Float? {
                let d = eye - target, len = simd_length(d)
                let n = max(Int(len / 0.25), 1)
                for k in 1...n {
                    let u = Float(k) / Float(n)
                    let p = target + d * u
                    if top(east: Double(p.x), north: Double(-p.z), margin: 0.3) + 0.2 > p.y { return u }
                }
                return nil
            }
            guard let first = blocked(eye) else { return eye }
            if blocked(eye + SIMD3(0, maxRaise, 0)) == nil {
                // As little as it takes, in quarter metres.
                var lift: Float = 0.25
                while lift < maxRaise, blocked(eye + SIMD3(0, lift, 0)) != nil { lift += 0.25 }
                return eye + SIMD3(0, lift, 0)
            }
            if let fallback {
                let moved = clearSight(eye: fallback, target: target, maxRaise: maxRaise)
                if blocked(moved) == nil { return moved }
            }
            // In front of the first clump on the line, at least 1.5 m out.
            let len = simd_length(eye - target)
            let keep = max(first - 0.6 / max(len, 0.01), min(1.5 / max(len, 0.01), 1))
            return target + (eye - target) * keep
        }

        private static let lock = NSLock()
        private static var latest: ScrubField?

        static func publish(_ field: ScrubField) {
            lock.lock()
            latest = field
            lock.unlock()
        }

        /// The scrub last built for `courseID`, or for a route of this
        /// length when no id is known (the debug shots); nil off the Poggio.
        static func current(courseID: String? = nil, routeLength: Double? = nil) -> ScrubField? {
            lock.lock()
            defer { lock.unlock() }
            guard let f = latest else { return nil }
            if let courseID, f.courseID != courseID { return nil }
            if let routeLength, abs(f.routeLength - routeLength) > 0.01 { return nil }
            return f
        }
    }

    // MARK: - Succulents

    /// Prickly pear (Opuntia ficus-indica): flat oval pads, 30-45 cm, each
    /// bearing one to three on its upper rim, as solid lenses with the bark
    /// atlas's pad skin (part 0). `tall`: an old plant grown into a
    /// thicket, its pads in upright chains (one or two on each, up to 30 a
    /// metre), so it reaches its height instead of spreading at 2 m.
    static func opuntia(_ m: inout MeshBuffer, base: SIMD3<Float>, height: Float, tall: Bool = false, rnd: inout WorldRandom) {
        struct Pad { var c: SIMD3<Float>; var up: SIMD3<Float>; var n: SIMD3<Float>; var a: Float; var b: Float; var gen: Int }
        var pads: [Pad] = []
        var open: [Pad] = []
        for k in 0..<3 {
            let az = Float(k) * 2.1 + rnd.range(-0.4, 0.4)
            let tilt = rnd.range(0.05, 0.35)
            let up = simd_normalize(SIMD3<Float>(cos(az) * tilt, 1, sin(az) * tilt))
            let n = simd_normalize(simd_cross(up, SIMD3(-sin(az), 0, cos(az))))
            let a = rnd.range(0.2, 0.26), b = a * rnd.range(0.68, 0.8)
            let p = Pad(c: base + SIMD3(cos(az) * 0.15, a * 0.85, sin(az) * 0.15), up: up, n: n, a: a, b: b, gen: 0)
            pads.append(p)
            open.append(p)
        }
        while let p = open.first, pads.count < (tall ? Int(height * 30) : min(Int(height * 16), 48)) {
            open.removeFirst()
            guard p.c.y + p.a < base.y + height else { continue }
            let kids = p.gen < 1 ? 2 : tall ? (rnd.unit() < 0.4 ? 2 : 1) : 1 + Int(rnd.unit() * 2.4)
            for _ in 0..<kids {
                let ang = rnd.range(-1.0, 1.0)
                let side = simd_cross(p.n, p.up)
                let rim = p.up * cos(ang) + side * sin(ang)
                let attach = p.c + p.up * (p.a * cos(ang)) + side * (p.b * sin(ang))
                // A new pad leans out from its parent's rim and turns a
                // little about it.
                var up = simd_normalize(rim + SIMD3(0, tall ? rnd.range(0.6, 1.1) : rnd.range(0.2, 0.8), 0))
                if up.y < 0.15 { up = simd_normalize(up + SIMD3(0, 0.5, 0)) }
                let turn = rnd.range(-0.9, 0.9)
                var n = simd_normalize(p.n * cos(turn) + simd_cross(up, p.n) * sin(turn))
                n = simd_normalize(n - up * simd_dot(n, up))
                let a = rnd.range(0.17, 0.24), b = a * rnd.range(0.66, 0.8)
                let child = Pad(c: attach + up * (a * 0.9), up: up, n: n, a: a, b: b, gen: p.gen + 1)
                pads.append(child)
                open.append(child)
            }
        }
        let tile = Float(TreeArchetype.MedBark.opuntia.rawValue) * TreeArchetype.barkTileStride
        for (i, p) in pads.enumerated() {
            let side = simd_cross(p.n, p.up)
            let thick: Float = 0.022
            let first = UInt32(m.vertexCount)
            let ou = rnd.range(0, 1), ov = rnd.range(0, 1)
            // Front and back centres, then the rim.
            for sgn: Float in [1, -1] {
                let c = p.c + p.n * (thick * sgn)
                m.vertex(c.x, c.y, c.z, p.n.x * sgn, p.n.y * sgn, p.n.z * sgn, tile + ou + 0.5, ov + 0.5)
                m.texcoord2(0.02, 0)
                m.texcoord3(0.95, 0)
                m.texcoord4(0, 0)
            }
            // A rim for each face, its normals the face's turned a little
            // out: a pad is a flat, thick plate with a rounded edge (one
            // shared rim with radial normals shaded each pad as a balloon).
            let ring = 8
            for sgn: Float in [1, -1] {
                for k in 0..<ring {
                    let t = Float(k) / Float(ring) * 2 * .pi
                    let q = p.c + p.up * (p.a * cos(t)) + side * (p.b * sin(t))
                    let radial = simd_normalize(p.up * (cos(t) / p.a) + side * (sin(t) / p.b))
                    let nr = simd_normalize(p.n * sgn + radial * 0.45)
                    let lx = simd_dot(side, q - p.c) / 0.5
                    let ly = simd_dot(p.up, q - p.c) / 0.5
                    m.vertex(q.x, q.y, q.z, nr.x, nr.y, nr.z, tile + ou + 0.5 + lx, ov + 0.5 - ly)
                    m.texcoord2(0.02 + 0.02 * Float(i % 3), 0)
                    m.texcoord3(0.85, 0)
                    m.texcoord4(0, 0)
                }
            }
            for k in 0..<UInt32(ring) {
                let a = first + 2 + k, b = first + 2 + (k + 1) % UInt32(ring)
                m.tri(first, a, b, part: 0)
                m.tri(first + 1, b + UInt32(ring), a + UInt32(ring), part: 0)
            }
        }
    }

    /// Agave (Agave americana): a rosette of 18 thick, channelled,
    /// blue-grey leaves to `size` metres, the inner ones upright, the outer
    /// ones arching out and down at their tips; `spike`: last year's dead
    /// flower stalk, 5 m, branched near the top. Solid, both faces (part 0).
    static func agave(_ m: inout MeshBuffer, base: SIMD3<Float>, size: Float, spike: Bool, rnd: inout WorldRandom) {
        let tile = Float(TreeArchetype.MedBark.agave.rawValue) * TreeArchetype.barkTileStride
        let up = SIMD3<Float>(0, 1, 0)
        let count = 18
        for k in 0..<count {
            let az = Float(k) * 2.39996 + rnd.range(-0.1, 0.1)
            let age = Float(k) / Float(count - 1)
            let el = 1.35 - 1.05 * age + rnd.range(-0.08, 0.08)
            let len = size * (0.72 + 0.28 * age) * rnd.range(0.85, 1.05)
            let w0 = 0.075 * size * (0.8 + 0.4 * age)
            let dirH = SIMD3<Float>(cos(az), 0, sin(az)), side = SIMD3<Float>(-sin(az), 0, cos(az))
            var p = base + dirH * 0.05 + up * 0.04
            let segs = 3
            var rows: [(SIMD3<Float>, SIMD3<Float>, Float, Float)] = []
            for i in 0...segs {
                let t = Float(i) / Float(segs)
                let e = el - (0.5 + 0.4 * age) * t * t
                let d = dirH * cos(e) + up * sin(e)
                if i > 0 { p += d * (len / Float(segs)) }
                let n = simd_normalize(simd_cross(side, d))
                rows.append((p, n, w0 * (1 - pow(t, 1.3)) + 0.004, t))
            }
            let shade: Float = 0.7 + 0.3 * age
            for face: Float in [1, -1] {
                let first = UInt32(m.vertexCount)
                for (q, n, w, t) in rows {
                    // A shallow channel: the edges up, the midrib down.
                    let pts: [(SIMD3<Float>, Float)] = [(q - side * w + n * (0.4 * w), -1), (q - n * (0.08 * w), 0), (q + side * w + n * (0.4 * w), 1)]
                    for (c, a) in pts {
                        let nn = simd_normalize(n + side * (a * 0.35)) * face
                        m.vertex(c.x, c.y, c.z, nn.x, nn.y, nn.z, tile + 0.5 + a * w / 0.5 * 0.6, t * len / 0.5)
                        m.texcoord2(0.01, 0)
                        m.texcoord3(shade * (face > 0 ? 1 : 0.8), 0)
                        m.texcoord4(0, 0)
                    }
                }
                for i in 0..<UInt32(segs) {
                    let a = first + i * 3, b = a + 3
                    if face > 0 {
                        m.quad(a, a + 1, b + 1, b, part: 0)
                        m.quad(a + 1, a + 2, b + 2, b + 1, part: 0)
                    } else {
                        m.quad(a, b, b + 1, a + 1, part: 0)
                        m.quad(a + 1, b + 1, b + 2, a + 2, part: 0)
                    }
                }
            }
        }
        if spike {
            let first = m.vertexCount
            let lean = SIMD3<Float>(rnd.range(-0.3, 0.3), 0, rnd.range(-0.3, 0.3))
            let top = base + up * rnd.range(4.2, 5.6) + lean
            TreeArchetype.tube(&m, base + up * 0.3, top, 0.07, 0.03, sides: 5, height: 6, baseY: base.y)
            for k in 0..<7 {
                let t = 0.62 + 0.36 * Float(k) / 6
                let at = base + up * 0.3 + (top - base - up * 0.3) * t
                let az = Float(k) * 2.4
                let tip = at + SIMD3(cos(az), 0.25, sin(az)) * (0.45 * (1.1 - t))
                TreeArchetype.tube(&m, at, tip, 0.025, 0.012, sides: 3, height: 6, baseY: base.y)
            }
            TreeArchetype.setBark(&m, from: first, tile: .aleppo)
        }
    }

    // MARK: - Reeds, ice plant, bougainvillea

    /// A stand of giant reed: crossed cards of the reed cell, standing on
    /// `base`, swaying from the top (part 1).
    static func reedClump(_ m: inout MeshBuffer, base: SIMD3<Float>, height h: Float, cards: Int = 3, rnd: inout WorldRandom) {
        let first = m.vertexCount
        let yaw = rnd.range(0, 3.14)
        for k in 0..<cards {
            let a = yaw + Float(k) * .pi / Float(cards)
            let right = SIMD3<Float>(cos(a), 0, sin(a))
            let lean = SIMD3<Float>(rnd.range(-0.08, 0.08), 0, rnd.range(-0.08, 0.08))
            let upv = simd_normalize(SIMD3(0, 1, 0) + lean)
            let normal = simd_normalize(SIMD3(-sin(a), 0.6, cos(a)))
            TreeArchetype.orientedCard(&m, centre: base + upv * (h / 2) - SIMD3(0, 0.05, 0), right: right, up: upv,
                                       width: h * rnd.range(0.85, 1.0), height: h, uv: TreeArchetype.medReedUV, hull: nil,
                                       normal: normal, ao: 0.85, treeHeight: h, sway: 0.3, baseY: base.y)
        }
        patchPhase(&m, from: first, phase: rnd.range(0, 6.28), tint: TreeArchetype.packColour(SIMD3(1, 1, 1) * rnd.range(0.9, 1.08)))
    }

    /// Hand-placed plants and the course's hedges (`RivieraPlants`): the
    /// succulents, oleanders and bushes, reeds, the bougainvillea over its
    /// wall and the ice plant over the verge. Returns counts for the world
    /// log.
    static func buildRivieraPlants(_ plants: RivieraPlants, corridor: RoadCorridor, config: WorldConfig, sky: SkyRaster?,
                                   sideRoads: RoadBuilder.SideRoadMask,
                                   cluster: (Double, Double, (inout Cluster) -> Void) -> Void) -> [String: Int] {
        var counts: [String: Int] = [:]
        let terrain = corridor.terrain
        for p in plants.plants {
            var rnd = WorldRandom(p.s, p.side * p.offset, salt: 37)
            let st = corridor.station(at: p.s)
            let at = st.point(lateral: p.side * (st.reach(p.side) + p.offset))
            let y = Float(terrain.height(east: at.east, north: at.north))
            guard y.isFinite else { continue }
            let base = SIMD3<Float>(Float(at.east), y, Float(-at.north))
            let skyHere = sky?.plantSky(east: at.east, north: at.north, radius: 1) ?? 1
            switch p.kind {
            case .tree:
                continue
            case .opuntia, .agave:
                cluster(at.east, at.north) { c in
                    let first = c.full.vertexCount
                    if case let .agave(spike) = p.kind {
                        agave(&c.full, base: base, size: Float(p.height), spike: spike, rnd: &rnd)
                    } else if p.height > 3 {
                        // An old thicket stands on grey woody trunks; where the
                        // ground falls away behind the guardrail its pads
                        // start a little under the road's level.
                        let edgeY = Float(corridor.roadHeight(st, lateral: p.side * st.reach(p.side)))
                        let lift = min(max(edgeY - 0.9 - y, 0), 2)
                        var foot = base
                        if lift > 0.2 {
                            for k in 0..<3 {
                                let a = rnd.range(0, 6.28) + Float(k) * 2.1
                                let splay = SIMD3<Float>(cos(a), 0, sin(a))
                                TreeArchetype.tube(&c.full, base + splay * 0.15 - SIMD3(0, 0.2, 0),
                                                   base + splay * rnd.range(0.25, 0.45) + SIMD3(0, lift + 0.15, 0),
                                                   0.11, 0.07, sides: 5, height: Float(p.height), baseY: y)
                            }
                            TreeArchetype.setBark(&c.full, from: first, tile: .olive)
                            foot.y += lift
                        }
                        opuntia(&c.full, base: foot, height: Float(p.height) - lift, tall: true, rnd: &rnd)
                    } else {
                        opuntia(&c.full, base: base, height: Float(p.height), rnd: &rnd)
                    }
                    patchPhase(&c.full, from: first, phase: rnd.range(0, 6.28), tint: TreeArchetype.packColour(SIMD3(1, 1, 1)))
                    skyShade(&c.full, from: first, sky: skyHere, baseY: y, height: Float(p.height))
                }
                counts["riviera succulents", default: 0] += 1
            case .oleander:
                cluster(at.east, at.north) { c in
                    let h = Float(p.height), r = h * 0.55
                    let first = c.full.vertexCount
                    bush(&c.full, base: base, radius: r, height: h, uv: TreeArchetype.medOleanderUV, colour: SIMD3(1, 1, 1), rnd: &rnd)
                    skyShade(&c.full, from: first, sky: skyHere, baseY: y, height: h)
                    let firstL = c.light.vertexCount
                    bush(&c.light, base: base, radius: r, height: h, uv: TreeArchetype.medOleanderUV, colour: SIMD3(1, 1, 1), rnd: &rnd)
                    skyShade(&c.light, from: firstL, sky: skyHere, baseY: y, height: h)
                }
                counts["riviera oleanders", default: 0] += 1
            case .reeds:
                cluster(at.east, at.north) { c in
                    let first = c.full.vertexCount
                    reedClump(&c.full, base: base, height: rnd.range(3.2, 4.2), rnd: &rnd)
                    skyShade(&c.full, from: first, sky: skyHere, baseY: y, height: 4)
                    let firstL = c.light.vertexCount
                    reedClump(&c.light, base: base, height: rnd.range(3.2, 4.2), cards: 2, rnd: &rnd)
                    skyShade(&c.light, from: firstL, sky: skyHere, baseY: y, height: 4)
                }
                counts["riviera reeds", default: 0] += 1
            case let .bushes(length):
                // Bushes a metre or two apart along the bank top, on the
                // ground as the LiDAR has it (the bank, not the road).
                var s = p.s
                while s < p.s + length, s <= corridor.route.length {
                    let st2 = corridor.station(at: s)
                    let pt = st2.point(lateral: p.side * (st2.reach(p.side) + p.offset + Double(rnd.range(-0.3, 0.5))))
                    let gy = Float(terrain.height(east: pt.east, north: pt.north))
                    if gy.isFinite, !sideRoads.covers(east: pt.east, north: pt.north) {
                        let b = SIMD3<Float>(Float(pt.east), gy, Float(-pt.north))
                        let h = rnd.range(1.8, 2.8), r = rnd.range(0.9, 1.4)
                        let bsky = sky?.plantSky(east: pt.east, north: pt.north, radius: Double(r)) ?? 1
                        cluster(pt.east, pt.north) { c in
                            let first = c.full.vertexCount
                            bush(&c.full, base: b, radius: r, height: h, uv: TreeArchetype.medEvergreenUV,
                                 colour: SIMD3(0.92, 1.0, 0.95) * rnd.range(0.9, 1.08), rnd: &rnd)
                            skyShade(&c.full, from: first, sky: bsky, baseY: gy, height: h)
                            let firstL = c.light.vertexCount
                            bush(&c.light, base: b, radius: r, height: h, uv: TreeArchetype.medEvergreenUV,
                                 colour: SIMD3(0.92, 1.0, 0.95), rnd: &rnd)
                            skyShade(&c.light, from: firstL, sky: bsky, baseY: gy, height: h)
                        }
                        counts["riviera bushes", default: 0] += 1
                    }
                    s += Double(rnd.range(1.2, 2.0))
                }
            case let .bougainvillea(wall, length):
                // Down the wall's face from its top, in tongues 1-2 m long,
                // and a cushion along the top.
                var s = p.s
                while s < p.s + length, s <= corridor.route.length {
                    let st2 = corridor.station(at: s)
                    let lat = p.side * (st2.reach(p.side) + p.offset)
                    let face = st2.point(lateral: lat)
                    let top = Float(corridor.roadHeight(st2, lateral: p.side * st2.reach(p.side)) + wall)
                    let toRoad2 = SIMD3<Float>(Float(-st2.rightE * p.side), 0, Float(st2.rightN * p.side))
                    let along2 = SIMD3<Float>(Float(st2.dirE), 0, Float(-st2.dirN))
                    let drop = rnd.range(0.8, 2.0) * Float(min(wall / 2.3, 1))
                    cluster(face.east, face.north) { c in
                        let first = c.full.vertexCount
                        for k in 0..<3 {
                            let y0 = top + 0.25 - drop * Float(k) / 2.5
                            let size = rnd.range(0.85, 1.25)
                            let centre = SIMD3<Float>(Float(face.east), y0 - size * 0.35, Float(-face.north))
                                + toRoad2 * rnd.range(0.05, 0.22) + along2 * rnd.range(-0.3, 0.3)
                            let n = simd_normalize(toRoad2 + SIMD3(0, 0.25, 0) + along2 * rnd.range(-0.3, 0.3))
                            TreeArchetype.card(&c.full, centre: centre, size: size, normal: n, roll: rnd.range(0, 6.28),
                                               uv: TreeArchetype.medBougainvilleaUV, crownCentre: centre - toRoad2 * 0.6,
                                               crownRadii: SIMD3(1, 1, 1), height: 3, ao: rnd.range(0.82, 0.95), bend: 0.3,
                                               baseY: top - 2, billboard: false, mirror: rnd.unit() < 0.5,
                                               hull: TreeArchetype.medBougainvilleaHull)
                        }
                        for _ in 0..<2 {
                            let centre = SIMD3<Float>(Float(face.east), top + rnd.range(0.3, 0.7), Float(-face.north))
                                - toRoad2 * rnd.range(0.1, 0.7) + along2 * rnd.range(-0.4, 0.4)
                            TreeArchetype.card(&c.full, centre: centre, size: rnd.range(0.9, 1.3),
                                               normal: TreeArchetype.randomDir(&rnd, minY: 0), roll: rnd.range(0, 6.28),
                                               uv: TreeArchetype.medBougainvilleaUV, crownCentre: centre - SIMD3(0, 0.5, 0),
                                               crownRadii: SIMD3(1, 0.6, 1), height: 3, ao: 0.9, bend: 0.6, baseY: top - 2,
                                               mirror: rnd.unit() < 0.5, hull: TreeArchetype.medBougainvilleaHull)
                        }
                        patchPhase(&c.full, from: first, phase: rnd.range(0, 6.28),
                                   tint: TreeArchetype.packColour(SIMD3(1, 1, 1) * rnd.range(0.92, 1.06)))
                        skyShade(&c.full, from: first, sky: skyHere, baseY: top - 2, height: 3)
                    }
                    s += Double(rnd.range(0.5, 0.8))
                }
                counts["riviera bougainvillea metres", default: 0] += Int(length)
            case let .iceplant(length):
                // Mats lying on the verge, a little proud of it.
                var s = p.s
                while s < p.s + length, s <= corridor.route.length {
                    let st2 = corridor.station(at: s)
                    let o = p.offset + Double(rnd.range(0, 2.2))
                    let pt = RoadBuilder.vergePoint(corridor, st2, side: p.side, offset: o)
                    if !sideRoads.covers(east: pt.east, north: pt.north) {
                        let pn = surfaceNormal(corridor, st2, side: p.side, offset: o)
                        let centre = SIMD3<Float>(Float(pt.east), Float(pt.y), Float(-pt.north)) + pn * rnd.range(0.04, 0.09)
                        cluster(pt.east, pt.north) { c in
                            let first = c.full.vertexCount
                            TreeArchetype.card(&c.full, centre: centre, size: rnd.range(0.9, 1.3),
                                               normal: simd_normalize(pn + TreeArchetype.randomDir(&rnd) * 0.15), roll: rnd.range(0, 6.28),
                                               uv: TreeArchetype.medIceplantUV, crownCentre: centre - pn * 0.6, crownRadii: SIMD3(1, 1, 1),
                                               height: 3, ao: rnd.range(0.85, 0.95), bend: 0.3, baseY: centre.y - 1, billboard: false,
                                               mirror: rnd.unit() < 0.5)
                            patchPhase(&c.full, from: first, phase: rnd.range(0, 6.28), tint: TreeArchetype.packColour(SIMD3(1, 1, 1)))
                            skyShade(&c.full, from: first, sky: skyHere, baseY: centre.y, height: 1)
                        }
                        counts["riviera ice plant mats", default: 0] += 1
                    }
                    s += Double(rnd.range(0.5, 0.9))
                }
            }
        }
        return counts
    }

    // MARK: - Hedges and verge

    /// The Riviera's clipped hedges: pittosporum (green), laurel, ivy
    /// over a fence, and bougainvillea trained as a hedge (the copper
    /// beech's place).
    static func rivieraHedgeLook(_ kind: CourseArt.HedgeKind) -> HedgeLook {
        switch kind {
        // (Cards as large as the Flemish hedges', which set the triangle
        // count a metre.)
        case .green: return HedgeLook(uv: TreeArchetype.medEvergreenUV, cardSize: 0.65...0.85, colour: SIMD3(1.0, 1.05, 1.0))
        case .laurel: return HedgeLook(uv: TreeArchetype.medEvergreenUV, cardSize: 0.9...1.15, colour: SIMD3(0.9, 1.0, 0.95))
        case .ivy: return HedgeLook(uv: TreeArchetype.medEvergreenUV, cardSize: 0.65...0.85, colour: SIMD3(0.8, 0.9, 0.8))
        case .copperBeech: return HedgeLook(uv: TreeArchetype.medBougainvilleaUV, cardSize: 0.65...0.85, colour: SIMD3(1, 1, 1))
        }
    }

    /// The course's own hedges (`RivieraPlants.hedges`), pittosporum.
    static func buildRivieraHedges(_ plants: RivieraPlants, corridor: RoadCorridor, sideRoads: RoadBuilder.SideRoadMask,
                                   sky: SkyRaster?, into out: inout MeshBuffer) {
        let look = rivieraHedgeLook(.green)
        for run in plants.hedges {
            var rnd = WorldRandom(seed: UInt64(max(run.span.lowerBound, 0) * 17 + 13))
            let wave = SIMD3<Double>(Double(rnd.range(0, 6.28)), Double(rnd.range(0, 6.28)), Double(rnd.range(0, 6.28)))
            var stretch: [HedgeSection] = []
            var s = run.span.lowerBound
            while true {
                if let sec = hedgeSection(corridor, side: run.side, height: run.height, offset: run.offset, s: s, wave: wave,
                                          sideRoads: sideRoads, sky: sky) {
                    stretch.append(sec)
                } else {
                    hedgeStretch(stretch, look: look, rnd: &rnd, into: &out)
                    stretch.removeAll()
                }
                if s >= run.span.upperBound { break }
                s = min(s + 0.6, run.span.upperBound)
            }
            hedgeStretch(stretch, look: look, rnd: &rnd, into: &out)
        }
    }

    /// How far past the carriageway's edge the Riviera's verge tufts and
    /// sward reach, and their share of the Flemish density: the Poggio's
    /// edge is a wall for about 60 % of the uphill side and a guardrail or
    /// parapet over a drop on the other (look bible, sections 3-4), and
    /// what verge there is in March is a narrow strip of thin grass and
    /// straw, not a summer meadow's 3 m. (Its triangles were also 0.48 M on
    /// the bare Poggio at the Flemish reach, against the Kwaremont's 0.22 M.)
    static let rivieraVergeReach = 2.2
    static let rivieraGrassShare = 0.8

    /// Mean linear colour of the cj_grass_med.png tufts (bake_riviera_plants.py
    /// prints it): the Riviera's grassTint pulls towards the ground from it.
    static let grassCardColorMed = SIMD3<Float>(0.196, 0.196, 0.082)

    /// The verge in late March, past the mown strip, on the cells of
    /// cj_grass_med.png (`GrassCell` names the Flemish plants in the same
    /// places): Bermuda buttercup (carrot) carpets, red valerian
    /// (knapweed), crown daisies (tansy), wild fennel (nettle) and last
    /// year's straw tussocks (dry). Nil keeps the grass. (The look bible's
    /// verge is green #7a8455 with straw patches #a39c7f: with a third of
    /// the tufts straw, pog4's verges read as August's.)
    static func rivieraGrassCell(_ pick: Float, flowerShare: Float) -> GrassCell? {
        let flowers = flowerShare * 1.4
        if pick < flowers { return [GrassCell.carrot, .carrot, .knapweed, .tansy][min(Int(pick / flowers * 4), 3)] }
        if pick < flowers + 0.07 { return .nettle }
        if pick < flowers + 0.2 { return .dry }
        return nil
    }
}
