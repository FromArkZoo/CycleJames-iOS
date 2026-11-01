import Foundation
import simd

/// The Ligurian Riviera's buildings (`WorldLook.riviera`, the Poggio di
/// Sanremo), from look.md sections 3 to 5 and the 2024 POV sheets:
///
/// - Villas of two or three storeys and palazzine of three to five, built
///   1950-1980: low hipped roofs (22-25°) of terracotta Marseille tiles
///   (#c4876a) with coppi along the ridges and hips (#a86d55), some flat roof
///   terraces behind a parapet, the odd pergola; render in Ligurian pastels
///   (cream, pale yellow, ochre, pale pink, salmon, white, pale green,
///   weathered grey-beige) chosen per building, louvred persiane in dark
///   green (most), brown or light blue, roll shutters on the palazzine,
///   balconies with black iron rails or white balustrades, garages behind
///   roll-down shutters. No moss, no brick chimneys, no spires.
/// - Greenhouses (serre), the Riviera dei Fiori's signature: old Venlo
///   houses of glass on steel, multi-span (3-3.5 m spans, eaves 3-4.5 m),
///   whitewashed, some half-abandoned, often standing on a stone terrace
///   wall; plastic-film tunnels. One glass part (`GlassPart`), drawn by
///   `WorldShaders.greenhouseSurface`; far from the route a house's roof is
///   one plane whose spans the shader draws.
/// - Round concrete irrigation cisterns (vasche) holding dark green water,
///   and the odd cistern tower.
/// - Churches as Ligurian churches (the Santuario di N.S. della Guardia):
///   old cream-ochre render, a low terracotta roof and a campanile with a
///   belfry, a small grey dome on an octagonal drum and ball finials.
/// - The Poggio's own buildings placed by hand (`rivieraSites`): the
///   Santuario, the summit corner's bar and pharmacy, the ochre and yellow
///   palazzine round Piazza della Libertà, the houses the POV sheets show.
///
/// Everything here runs only for a Riviera course, so the Flemish climbs
/// keep exactly their buildings.
extension BuildingBuilder {
    // MARK: - Codes

    /// Render colours of `WorldShaders.wallSurface`'s Riviera palette (look.md
    /// section 3 paint values); `atlas` keeps the atlas's own warm white.
    enum RenderColour: Int, CaseIterable {
        case atlas = 0, cream, paleYellow, ochre, palePink, salmon, white, paleGreen, greyBeige, pinkBeige,
             santuario, warmYellow, rose, lightGrey, peach, blueGrey
    }

    /// Persiane and painted doors: dark green #1f3d35, brown #6b4a33, light
    /// blue #8fb3d6, faded green.
    enum ShutterColour: Int, CaseIterable { case green = 0, brown, lightBlue, fadedGreen }

    /// `Style.tint` for a Riviera wall: the render and shutter colours over
    /// 128 (`wallCode` adds the kind and the low tint below it; the shader
    /// takes them apart again).
    static func rivieraTint(_ colour: RenderColour, _ shutter: ShutterColour, tint: Int = 0) -> Int {
        tint + 128 * (colour.rawValue + 16 * shutter.rawValue)
    }

    /// What a greenhouse vertex is (`WorldShaders.greenhouseSurface`),
    /// texcoord 1 = (part + seed / 2, span width on `spanRoof`).
    enum GlassPart: Int { case roofGlass = 0, wallGlass, film, steel, spanRoof }

    /// The roofs part the glass goes to on the Riviera (whose `roofSlate`
    /// material is the glass); every Riviera roof is on part 0.
    static let glassPart = 1

    /// Greenhouses this close to the route are built span by span, with
    /// their gables and gutters; further out each is a box whose roof the
    /// shader draws in spans.
    /// (On high; the other tiers and the distance past which none is built
    /// are in `RivieraDetail`.)
    static let greenhouseDetailDistance = 150.0

    enum RivieraForm { case house, palazzina, shed, greenhouse, tunnel, cistern, church }

    // MARK: - Hand-placed

    /// A building of the climb as photographed: the footprint nearest the
    /// point `offset` metres beyond the carriageway edge `s` metres up the
    /// climb (look.md's frame, from the fork; the route's is the climb's
    /// start further on) on `side` (−1 left, +1 right), within `reach`,
    /// built so.
    struct RivieraSite {
        enum Kind {
            /// The Santuario di N.S. della Guardia: a Ligurian church with its
            /// campanile.
            case santuario
            /// A house or block with its colours fixed; `storeys` lifts a
            /// palazzina to its real height where the data has it low.
            case house(colour: RenderColour, shutter: ShutterColour, flat: Bool = false, palazzina: Bool = false,
                       old: Bool = false, balconies: Bool = false, garage: Bool = false, pergola: Bool = false)
            /// The summit corner's bar ("Mt Calvo") and pharmacy: two storeys of
            /// grey-beige render, dark green persiane, a hipped roof, shop
            /// fronts with awnings and a one-storey wing with a white
            /// balustraded terrace.
            case summitBar
            /// The bar's one-storey wing where the survey draws it apart: shop
            /// windows, and on its roof a terrace behind a white balustrade.
            case barTerrace
            /// A round cistern tower beside the road where the data has no
            /// footprint: diameter and height, metres.
            case cisternTower(diameter: Double, height: Double)
            /// A church's bell tower that the survey draws as a footprint of
            /// its own (the CTR's "Campanile"): the tower built on it, its
            /// belfry clear of the nave's ridge, `naveRidge` metres over the
            /// tower's floor.
            case campanile(naveRidge: Double)
            /// A church or chapel footprint: a Ligurian nave, with a campanile
            /// at its back corner when the complex has no tower of its own.
            case churchPart(campanile: Bool)
            /// A footprint not built: a greenhouse whose outline a hand-placed
            /// cistern tower stands in (look s 2690 R: the 2024 POV shows the
            /// tower alone at the road edge, the 2022 ortho bare ground where
            /// the CTR still draws glass).
            case cleared
        }

        var kind: Kind
        var s: Double
        var side: Double
        var offset: Double
        var reach: Double = 25
    }

    /// Distances up the climb from the fork off the Via Aurelia (look.md's
    /// s, along OSM's 3730 m way; `routeS` scales them onto the built
    /// line); sides and colours from look.md section 4, the 2024 POV
    /// sheets and route.md section 10 (whose route s is 300 m more). The
    /// Santuario, the bar and the post office are placed from their OSM
    /// positions projected onto the route.
    static let rivieraSitesByCourse: [String: [RivieraSite]] = [
        "poggio": [
            // Hairpin 1's exit: a cream flat-roofed house with a pergola on its
            // roof terrace (look s 420).
            RivieraSite(kind: .house(colour: .cream, shutter: .green, flat: true, pergola: true),
                        s: 420, side: 1, offset: 12, reach: 30),
            // An ochre house with brown shutters (look s ~500).
            RivieraSite(kind: .house(colour: .ochre, shutter: .brown), s: 500, side: -1, offset: 10, reach: 30),
            // The pale pink three-storey house with light-blue shutters (1150 L).
            RivieraSite(kind: .house(colour: .palePink, shutter: .lightBlue, balconies: true),
                        s: 1150, side: -1, offset: 10, reach: 30),
            // The Santuario, 40 m left at look s ~1990 (OSM way 201021176).
            RivieraSite(kind: .santuario, s: 1986, side: -1, offset: 36, reach: 30),
            // The old grey stone house with iron grilles (2100 R).
            RivieraSite(kind: .house(colour: .lightGrey, shutter: .fadedGreen, old: true), s: 2100, side: 1, offset: 6),
            // The pale green villa by the Norfolk Island pine (~2100).
            RivieraSite(kind: .house(colour: .paleGreen, shutter: .green), s: 2120, side: -1, offset: 12, reach: 30),
            // A modern beige block with dark garage doors (2370 R).
            RivieraSite(kind: .house(colour: .pinkBeige, shutter: .brown, palazzina: true, garage: true),
                        s: 2370, side: 1, offset: 6),
            // The cistern tower (2680-2700 R) and the pale yellow single-storey
            // house with a hipped roof opposite.
            RivieraSite(kind: .cisternTower(diameter: 5.2, height: 6.0), s: 2690, side: 1, offset: 3.5, reach: 12),
            RivieraSite(kind: .house(colour: .paleYellow, shutter: .green), s: 2690, side: -1, offset: 8),
            // A row of beige terraced houses with balconies, flush with the
            // left edge (look.md 2780 L; 2024 frame f88, placed ±50 m by its
            // speed): the survey's one footprint there is the three-storey
            // block 26 m along the edge at look s 2850-2875 (route s
            // 3144-3170, a building site in the 2022 ortho). Before it the
            // ortho has open ground on the left and one villa 10 m back.
            RivieraSite(kind: .house(colour: .greyBeige, shutter: .brown, balconies: true), s: 2862, side: -1, offset: 2,
                        reach: 8),
            // The ochre three-to-four storey block with black railings and
            // garage doors at the road's edge (3580 L: the 2024 frame f107 faces
            // back, so it is on the rider's left; the CTR's only house at the
            // left edge there is footprint 340, 2.7 m off it at route 3880-3895,
            // look 3595-3608 within f107's +-50 m). Offset 8 at look 3580 took
            // the 9 m "barn" 207 set back 10 m instead.
            RivieraSite(kind: .house(colour: .ochre, shutter: .brown, palazzina: true, balconies: true),
                        s: 3600, side: -1, offset: 3, reach: 8),
            // The summit corner: the post office just before the apex on the
            // right; the bar and pharmacy across the junction (left of the
            // descent's first leg, route.md: s 4068).
            RivieraSite(kind: .house(colour: .cream, shutter: .green), s: 3707, side: 1, offset: 8, reach: 14),
            RivieraSite(kind: .summitBar, s: 3764, side: -1, offset: 13, reach: 18),
            // Its one-storey front, an L round the bar's north and west sides
            // (footprint 83, 5.6 m on the LiDAR with the terrace's balustrade):
            // the shop windows under "Mt Calvo" and the white balustraded
            // terrace on its roof, in the bar's own grey-beige (the 2020s
            // summit photo; unlisted, it took a palette colour and the bar
            // read two-tone).
            RivieraSite(kind: .barTerrace, s: 3767, side: -1, offset: 3.5, reach: 4),
        ],
    ]

    /// Route distance of a hand-placed site: look.md's s from the fork, on
    /// OSM's 3730 m way, scaled onto the built climb (2 m smoothing at the
    /// hairpins and the summit's racing line make it about 14 m shorter).
    static func routeS(_ site: RivieraSite, corridor: RoadCorridor) -> Double {
        corridor.climb.startS + site.s * corridor.climb.lengthM / 3730
    }

    /// Greenhouses the survey still draws that are gone: the centre (mean of
    /// its outline's points, course metres east and north) of each CTR
    /// footprint where the 2022 ortho (0.5 m) shows dry scrub terraces or
    /// open ground and the 2024 POV no glass. Not built.
    static let rivieraGoneByCourse: [String: [SIMD2<Double>]] = [
        "poggio": [
            // The start ramp, right, over the 5-6 m wall (look s 0-190): the
            // POV has only the railing against the sky (f0, f2), the ortho
            // scrub on the terraces and parked cars on the open ground.
            SIMD2(383.2, -515.3), SIMD2(346.1, -480.4), SIMD2(353.6, -466.8), SIMD2(366.1, -465.6),
            SIMD2(359.2, -421.0),
            // Before hairpin 2, left (look s 990-1060): bare earth and a
            // track round a shed, one CTR house in seven strips.
            SIMD2(752.3, -603.1), SIMD2(750.5, -598.1), SIMD2(750.1, -591.4), SIMD2(756.6, -584.5),
            SIMD2(757.0, -578.5), SIMD2(757.5, -572.4), SIMD2(749.8, -570.0),
            // The ridge, right (look s 2195-2220): scrub on the terrace over
            // the wall (f70, a rocky bank with scrub).
            SIMD2(684.6, -294.8), SIMD2(683.7, -288.8),
            // At the road's edge, right, route s 2962-3016 (look 2662-2716):
            // the 2024 frames there show no glass at the edge, f85 (facing
            // back) a pale yellow house behind a black fence on the rider's
            // right and f86/f87 (look 2712-2748) a weedy verge, a wire fence
            // and greenhouse frames no higher than the eye beyond it; the
            // 2022 ortho has pale bare ground with scattered marks and no
            // span stripes where the CTR draws these three (3-6 m over the
            // road on the 2008-10 LiDAR: the glass cliff of reviews2 at 3000
            // eye, still a 2-3 m wall at the edge when built to the LiDAR).
            SIMD2(339.0, 13.7), SIMD2(346.5, 2.1), SIMD2(321.7, 26.9),
        ],
    ]

    /// Colours of houses a 2024 POV frame or photo shows, by footprint
    /// centre (as `rivieraGoneByCourse`): the colours the first shoot drew
    /// there, which the reviewers took as right or nearest to the frames,
    /// before fix1-scenery's rebuild shifted the indices that seeded them.
    static let rivieraColoursByCourse: [String: [(centre: SIMD2<Double>, colour: RenderColour, shutter: ShutterColour)]] = [
        "poggio": [
            // Hairpin 1 (route 640): the ochre block with balconies on the
            // right over the wall, the pale pink house further left.
            (SIMD2(238.1, -316.5), .ochre, .green), (SIMD2(219.9, -332.6), .palePink, .green),
            // Below the road at route 1500 R (see `rivieraTopsByCourse`).
            (SIMD2(922.5, -547.7), .cream, .green),
            // Hairpin 2's house on the right (route 1675): pale, near white.
            (SIMD2(973.4, -395.7), .pinkBeige, .green),
            // The lodge by the Santuario's park (route 2273 R, at the edge
            // over its wall): weathered grey-beige; the house below it
            // (2279 R): grey render.
            (SIMD2(864.1, -421.2), .greyBeige, .green), (SIMD2(860.5, -411.0), .blueGrey, .green),
            // Route 2579 L, below the road (f72 has open sea there): pale grey.
            (SIMD2(608.1, -281.8), .lightGrey, .brown),
            // The palazzina at route 2646 R: salmon.
            (SIMD2(565.7, -223.6), .salmon, .fadedGreen),
            // The house set back on the left at route 2740 (look 2440): grey-beige.
            (SIMD2(478.1, -181.7), .greyBeige, .fadedGreen),
            // The palazzina at route 2897 R (look 2597): pale yellow.
            (SIMD2(419.0, -30.8), .paleYellow, .fadedGreen),
            // The last 100 m into the summit (2024 frame f109 at look 3687, facing
            // back): on the rider's right the long pink-red front of garage
            // shutters (CTR 250, flush at route 3948-3965, and 420 after it),
            // on the left the tall ochre-yellow palazzina with balconies (CTR
            // 339, 17 m on the LiDAR, route 3940-3958).
            (SIMD2(-372.0, 524.2), .rose, .brown), (SIMD2(-389.9, 536.2), .palePink, .green),
            (SIMD2(-372.8, 504.0), .ochre, .green),
        ],
    ]

    /// Footprints whose survey height the 2008-10 LiDAR, the 2022 ortho
    /// and the 2024 POV contradict at the road's edge, by centre.
    enum RivieraTop {
        /// Gone: not built.
        case gone
        /// Built with its top this many metres over the road beside it.
        case overRoad(Double)
        /// Dug into the bank: a blank grey concrete front, its top this
        /// many metres over the road (at least the house builder's 2.6 m
        /// over its floor), the bank's grass over it.
        case bank(overRoad: Double)
    }

    static let rivieraTopsByCourse: [String: [(centre: SIMD2<Double>, top: RivieraTop)]] = [
        "poggio": [
            // Route 446-462 R (look 145), CTR "house" 431, flat, 4.6 m: on the
            // LiDAR only 0.3-1.8 m over the DTM, which itself is 3.3-4.1 m
            // over the road there (a structure dug into the bank); f4 shows a
            // concrete wall of 1.5-2 m with grass over it.
            (SIMD2(349.1, -441.8), .bank(overRoad: 2.0)),
            // Route 1498-1518 R (look 1198-1218), CTR 557, flat, 9.5 m on a
            // terrace 3.6 m below the road: the 2022 ortho has its pale flat
            // roof, but f36-f38 (look 1149-1208) show only the parapet, the
            // signs and the sea over it, so its roof is a terrace at about
            // road level (the 2008-10 LiDAR still had a storey 3.4 m over it).
            (SIMD2(922.5, -547.7), .overRoad(0.2)),
            // Route 2716-2724 L (look 2420), CTR shed 1643, 3.3 m on ground 1.2 m
            // below the road: a small pale roof in the 2022 ortho, but its
            // LiDAR surface is at the road's level (canopy p90 0.5 m) and f76
            // has parked cars and the open view on the left there.
            (SIMD2(494.2, -196.7), .overRoad(0.4)),
            // Route 3107-3114 R (look 2807-2814), CTR shed 827: the LiDAR has
            // nothing over the road's level (canopy p90 0.9 m, its ground 1.9 m
            // below the road), the 2022 ortho bare earth, and f88 (look 2784)
            // an ice-plant verge with the open view; the cream box of reviews2.
            (SIMD2(235.3, 83.8), .gone),
        ],
    ]

    /// The centre of a survey footprint: the mean of its outline's points
    /// (course metres east and north), as the tables above are keyed.
    static func footprintCentre(_ b: SceneryFile.Building) -> SIMD2<Double> {
        let pts = b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
        return pts.reduce(SIMD2<Double>.zero, +) / Double(max(pts.count, 1))
    }

    /// The seed of a Riviera footprint's colours and dressing: its centre
    /// rounded to the metre, hashed. The scenery's index moves whenever a
    /// footprint is dropped or added (fix1-scenery's rebuild shifted every
    /// index after 445 and so re-rolled the colours along the whole climb);
    /// the centre stays where the house is.
    static func rivieraKey(_ b: SceneryFile.Building) -> Int {
        let c = footprintCentre(b)
        var r = WorldRandom(c.x.rounded(), c.y.rounded(), salt: 0x5EED)
        return Int(r.next() >> 2)
    }

    /// The 2008-10 LiDAR's surface (DTM + canopy) over a footprint: its
    /// 75th percentile at the points of a metre grid inside it (and its
    /// corners), where the canopy shows something standing (`nil` without
    /// the canopy raster or where it shows nothing over 0.8 m). Glass gives
    /// the laser fewer returns than tiles, so it is read as the glass's
    /// lowest likely top, not its ridge.
    static func lidarTop(_ ring: [SIMD2<Double>], terrain: TerrainSampler, canopy: HeightRaster?) -> Double? {
        guard let canopy, ring.count >= 3 else { return nil }
        var lo = ring[0], hi = ring[0]
        for p in ring { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        var pts = ring
        var y = lo.y + 0.5
        while y < hi.y {
            var x = lo.x + 0.5
            while x < hi.x {
                if pointInRing(SIMD2(x, y), ring) { pts.append(SIMD2(x, y)) }
                x += 1
            }
            y += 1
        }
        var tops: [Double] = [], cans: [Double] = []
        for p in pts {
            let v = Double(canopy.sample(east: p.x, north: p.y))
            let c = v.isNaN ? 0 : v
            cans.append(c)
            tops.append(Double(terrain.height(east: p.x, north: p.y)) + c)
        }
        tops.sort(); cans.sort()
        guard cans[Int(Double(cans.count - 1) * 0.75)] > 0.8 else { return nil }
        return tops[Int(Double(tops.count - 1) * 0.75)]
    }

    /// The course whose hand-placed buildings apply: the one named, or, while
    /// the world builder doesn't pass its id, the Poggio when the course is
    /// drawn in its own Riviera look rather than a Flemish road under
    /// `-courseLook riviera`.
    static func rivieraCourse(_ courseID: String?, corridor: RoadCorridor) -> String? {
        if let courseID { return courseID }
        #if DEBUG
        if WorldLook.launchOverride != nil { return nil }
        #endif
        return corridor.art.look.isRiviera ? "poggio" : nil
    }

    /// The hand-placed sites matched to their footprints (index into the
    /// scenery's buildings; nil for a site built without one), then every
    /// church and chapel as part of its complex (`churchSites`).
    static func rivieraSites(corridor: RoadCorridor, scenery: SceneryFile?, courseID: String?)
        -> [(site: RivieraSite, index: Int?)] {
        let sites = rivieraCourse(courseID, corridor: corridor).flatMap { rivieraSitesByCourse[$0] } ?? []
        let buildings = scenery?.buildings ?? []
        let rings: [[SIMD2<Double>]] = buildings.map { b in
            var r = cleaned(b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil })
            if r.count >= 3, signedArea(r) < 0 { r.reverse() }
            return r
        }
        func isChurch(_ k: Int) -> Bool { buildings[k].kind == "church" || buildings[k].kind == "chapel" }
        var taken = Set<Int>()
        var churches: [Int] = []
        var out: [(site: RivieraSite, index: Int?)] = []
        for site in sites {
            let st = corridor.station(at: routeS(site, corridor: corridor))
            let p = st.point(lateral: site.side * (st.halfWidth + site.offset))
            let at = SIMD2(p.east, p.north)
            var santuario = false
            if case .santuario = site.kind { santuario = true }
            var best: (Int, Double)?
            for (k, ring) in rings.enumerated() where ring.count >= 3 && !taken.contains(k) {
                let kind = buildings[k].kind
                if kind == "greenhouse" { continue }
                if case .cisternTower = site.kind, kind != "cistern" { continue }
                // A house placed by hand never takes a church's footprint.
                if !santuario, isChurch(k) { continue }
                let d = pointInRing(at, ring) ? 0 : distanceToRing(at, ring)
                if d < site.reach, d < (best?.1 ?? .infinity) { best = (k, d) }
            }
            if santuario {
                // The Santuario is built with the survey's churches, even where
                // the survey calls it a house.
                if let (k, _) = best, !isChurch(k) { churches.append(k) }
                continue
            }
            if let (k, _) = best { taken.insert(k) }
            if case let .cisternTower(diameter, _) = site.kind {
                out.append((site, best?.0))
                if best == nil {
                    // Where the tower is built by hand (`emitRivieraExtras`),
                    // the glass it would stand in has gone.
                    let c = st.point(lateral: site.side * (st.halfWidth + site.offset + diameter / 2))
                    let centre = SIMD2(c.east, c.north)
                    for (k, ring) in rings.enumerated() where ring.count >= 3 && buildings[k].kind == "greenhouse" {
                        if pointInRing(centre, ring) || distanceToRing(centre, ring) < diameter / 2 + 0.5 {
                            taken.insert(k)
                            out.append((RivieraSite(kind: .cleared, s: 0, side: 0, offset: 0), k))
                        }
                    }
                }
            } else if let (k, _) = best {
                out.append((site, k))
            }
        }
        let gone = rivieraCourse(courseID, corridor: corridor).flatMap { rivieraGoneByCourse[$0] } ?? []
        for (k, b) in buildings.enumerated() where b.kind == "greenhouse" && !taken.contains(k) && !b.ring.isEmpty {
            let pts = b.ring.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            let c = pts.reduce(SIMD2<Double>.zero, +) / Double(max(pts.count, 1))
            if gone.contains(where: { simd_distance($0, c) < 3.0 }) {
                taken.insert(k)
                out.append((RivieraSite(kind: .cleared, s: 0, side: 0, offset: 0), k))
            }
        }
        churches += buildings.indices.filter { rings[$0].count >= 3 && isChurch($0) && !taken.contains($0) }
        return out + churchSites(churches, rings: rings, buildings: buildings)
    }

    /// Churches and chapels in complexes: footprints within 4 m of one
    /// another (a nave, its side chapels and sacristy, and the bell tower,
    /// which the Liguria CTR draws as a "Campanile" footprint of its own, as
    /// at the Santuario and the Poggio's parish church). The tallest small,
    /// squarish footprint standing above the nave is the campanile (the
    /// Santuario's: 33 m², 12.2 m on the 2008-10 LiDAR over a 10.4 m nave); a
    /// complex without one whose largest footprint is a church's (120 m² and
    /// more) gets one at that nave's back corner. Wayside and cemetery
    /// chapels get none.
    static func churchSites(_ members: [Int], rings: [[SIMD2<Double>]], buildings: [SceneryFile.Building])
        -> [(site: RivieraSite, index: Int?)] {
        var parent = Array(members.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        for i in members.indices {
            for j in members.indices where j > i && ringGap(rings[members[i]], rings[members[j]]) < 4 {
                parent[find(i)] = find(j)
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in members.indices { groups[find(i), default: []].append(members[i]) }
        func area(_ k: Int) -> Double { signedArea(rings[k]) }
        func towerLike(_ k: Int) -> Bool {
            let box = orientedBox(rings[k])
            return area(k) <= 70 && buildings[k].heightM >= 10 && box.halfLong <= 1.8 * box.halfShort
        }
        var out: [(site: RivieraSite, index: Int?)] = []
        for group in groups.values.sorted(by: { $0.min()! < $1.min()! }) {
            guard let main = group.max(by: { area($0) < area($1) }) else { continue }
            let tower: Int? = group.count == 1
                ? (towerLike(main) && buildings[main].heightM >= 12 ? main : nil)
                : group.filter { $0 != main && towerLike($0) && buildings[$0].heightM >= 1.1 * buildings[main].heightM }
                    .max { buildings[$0].heightM < buildings[$1].heightM }
            // The nave's ridge over the tower's floor.
            let naveRidge = tower.map { t in
                buildings[main].heightM + (buildings[main].groundElevM ?? 0) - (buildings[t].groundElevM ?? 0)
            } ?? 0
            for k in group.sorted() {
                let kind: RivieraSite.Kind = k == tower
                    ? .campanile(naveRidge: naveRidge)
                    : .churchPart(campanile: k == main && tower == nil && area(main) >= 120)
                out.append((RivieraSite(kind: kind, s: 0, side: 0, offset: 0), k))
            }
        }
        return out
    }

    /// The gap between two footprints (0 where they touch or overlap).
    static func ringGap(_ a: [SIMD2<Double>], _ b: [SIMD2<Double>]) -> Double {
        if a.contains(where: { pointInRing($0, b) }) || b.contains(where: { pointInRing($0, a) }) { return 0 }
        let ab = a.map { distanceToRing($0, b) }.min() ?? .infinity
        let ba = b.map { distanceToRing($0, a) }.min() ?? .infinity
        return min(ab, ba)
    }

    static func pointInRing(_ p: SIMD2<Double>, _ ring: [SIMD2<Double>]) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    // MARK: - Dispatch

    #if DEBUG
    /// `-rivieraGreenhouses`: a Flemish road's sheds and barns drawn as
    /// greenhouses under `-courseLook riviera`, to judge them on a familiar
    /// road.
    static let debugGreenhouses = ProcessInfo.processInfo.arguments.contains("-rivieraGreenhouses")
    #endif

    /// What a Riviera footprint is.
    static func rivieraForm(_ b: SceneryFile.Building, ring: [SIMD2<Double>], area: Double) -> RivieraForm {
        let kind = b.kind ?? "other"
        #if DEBUG
        if debugGreenhouses, kind == "other" || kind == "barn", area > 80 { return area > 900 ? .tunnel : .greenhouse }
        #endif
        switch kind {
        case "greenhouse": return b.roofShape == "tunnel" ? .tunnel : .greenhouse
        case "cistern": return .cistern
        case "church", "chapel": return .church
        default: break
        }
        // A small round footprint not tagged as a building of its own: a
        // water tank (OSM man_made=storage_tank and the like).
        if kind == "other", area < 160, b.heightM < 8, ring.count >= 8, let c = fitCircle(ring),
           c.radius > 2, ring.allSatisfy({ abs(simd_distance($0, c.centre) - c.radius) < 0.35 }) {
            return .cistern
        }
        if kind == "barn" || kind == "farm" || (kind == "other" && (area < 30 || b.heightM < 3.3)) { return .shed }
        return b.heightM >= 9.5 ? .palazzina : .house
    }

    /// Builds one Riviera footprint (`build` sends every one here when the
    /// course's look is the Riviera).
    static func emitRiviera(_ out: inout Output, ring: [SIMD2<Double>], area: Double, building b: SceneryFile.Building,
                            index: Int, site: RivieraSite.Kind?, corridor: RoadCorridor, tier: RivieraDetail = .high,
                            canopy: HeightRaster? = nil, courseID: String? = nil) {
        let place = lookPlace(ring, corridor: corridor)
        let dist = place?.dist ?? .infinity
        var form = rivieraForm(b, ring: ring, area: area)
        // Colours and dressing seeded by where the footprint is, not by its
        // place in the scenery file (houses: `rivieraSeed`).
        let key = rivieraKey(b)
        let centre = footprintCentre(b)
        let fixedTop = courseID.flatMap { rivieraTopsByCourse[$0] }?
            .first { simd_distance($0.centre, centre) < 3.0 }?.top
        if case .gone? = fixedTop { return }
        var campanile = area >= 120
        switch site {
        case .santuario:
            form = .church
            campanile = true
        case let .churchPart(tower):
            form = .church
            campanile = tower
        case let .campanile(naveRidge):
            emitCampanile(&out, onFootprint: ring, building: b, naveRidge: naveRidge, corridor: corridor)
            return
        case .cleared:
            return
        default:
            break
        }
        switch form {
        case .greenhouse, .tunnel:
            guard dist < tier.greenhouseMaxM else { return }
            let terrain = corridor.terrain
            // At the road, on the terrace behind the edge wall.
            let edge = dist < 90 ? clearOfCarriageway(ring, corridor: corridor, by: greenhouseEdgeClearM,
                                                       within: greenhouseRoadsideM) : (ring: ring, roadside: false)
            guard edge.ring.count >= 3 else { return }
            for band in greenhouseBands(edge.ring, building: b, ground: { Double(terrain.height(east: $0.x, north: $0.y)) },
                                        terrace: edge.roadside) {
                // At the road its glass ends where the LiDAR's surface does.
                let top = edge.roadside ? lidarTop(band.ring, terrain: terrain, canopy: canopy) : nil
                emitGreenhouse(&out, ring: band.ring, area: area, building: band.building, tunnel: form == .tunnel,
                               index: key, corridor: corridor, detail: dist < tier.greenhouseDetailM,
                               groundTop: band.groundTop, roadside: edge.roadside, lidarTop: top)
            }
        case .cistern:
            // Round vasche on a fitted circle; square ones on their own outline.
            if let c = fitCircle(ring), c.radius > 1, ring.count >= 6,
               ring.allSatisfy({ abs(simd_distance($0, c.centre) - c.radius) < max(0.35, 0.08 * c.radius) }) {
                emitCistern(&out, centre: c.centre, radius: c.radius, height: b.heightM, groundElevM: b.groundElevM,
                            index: key, corridor: corridor, detail: dist < tier.houseDetailM)
            } else if let inner = insetRing(ring, by: 0.25) {
                emitTank(&out, outer: ring, inner: inner, height: b.heightM, groundElevM: b.groundElevM, index: key,
                         corridor: corridor)
            }
        case .church:
            emitLigurianChurch(&out, ring: ring, building: b, index: key, corridor: corridor, campanile: campanile)
        case .house, .palazzina, .shed:
            // A house near the Poggio's route keeps the plan it was first built with.
            let seed = rivieraSeed(b, courseID: courseID)
            var plan = rivieraPlan(b, form: form, area: area, index: seed, routeDistance: dist)
            if let pin = courseID.flatMap({ rivieraColoursByCourse[$0] })?
                .first(where: { simd_distance($0.centre, centre) < 3.0 }) {
                plan.style.tint = rivieraTint(pin.colour, pin.shutter)
            }
            var b = b
            switch fixedTop {
            case let .overRoad(m)?, let .bank(m)?:
                // The top set over the road beside the footprint.
                if let place {
                    let road = corridor.roadHeight(corridor.station(at: place.s), lateral: 0)
                    let floorY = b.groundElevM ?? road
                    b = SceneryFile.Building(ring: b.ring, heightM: max(road + m - floorY, 0.5), roofShape: "flat",
                                             kind: b.kind, groundElevM: floorY)
                    plan.roof = .flat
                    plan.style.roof = .slate
                }
                if case .bank? = fixedTop {
                    plan.style.tint = rivieraTint(.lightGrey, .green)
                    plan.style.row = .painted
                    plan.style.windowChance = 0
                    plan.style.plinth = .wall
                    plan.style.plinthHeight = 0
                    plan.balconies = false
                    plan.garage = false
                    plan.pergola = false
                    plan.chimney = false
                    plan.stairHouse = false
                }
            default:
                break
            }
            if let site { plan.apply(site) }
            // Off the carriageway (the summit corner's houses, from s 3680,
            // are built as placed).
            var footprint = ring
            if dist < 60, (place?.s ?? 0) < 3680 {
                footprint = clearOfCarriageway(ring, corridor: corridor, by: houseEdgeClearM, within: houseEdgeClearM).ring
                guard footprint.count >= 3 else { return }
            }
            emitRivieraHouse(&out, ring: footprint, area: area, building: b, plan: plan, index: seed, corridor: corridor,
                             detail: dist < tier.houseDetailM, tier: tier, routeDistance: dist)
        }
    }

    // MARK: - Houses

    /// How a Riviera house is built: its walls' style (atlas row, colours,
    /// plinth, window rhythm), its roof and its extras.
    struct RivieraPlan {
        enum Roof { case hipped, gabled, flat }
        var style: Style
        var roof: Roof
        var pitchDeg: Double
        var balconies: Bool
        /// Iron rails (0), white balustrade (1) or a solid rendered front (2).
        var balconyFront: Int
        var garage: Bool
        var pergola: Bool
        var chimney: Bool
        var stairHouse: Bool
        var shopfronts = false
        var terraceWing = false
        /// Every flat roof a terrace behind a white balustrade (its top the
        /// LiDAR height) rather than a rendered parapet.
        var balustradeRoof = false
        var palazzina: Bool
        var minStoreys = 0

        mutating func apply(_ site: RivieraSite.Kind) {
            switch site {
            case let .house(colour, shutter, flat, palazzina, old, balconies, garage, pergola):
                style.tint = BuildingBuilder.rivieraTint(colour, shutter)
                if old { style.row = .cream; style.roof = .smokedPantile }
                if flat { roof = .flat } else if roof == .flat { roof = .hipped }
                if palazzina {
                    self.palazzina = true
                    minStoreys = 3
                    if !old { style.row = .redBrick }
                }
                self.balconies = self.balconies || balconies
                if balconies { balconyFront = 0 }
                self.garage = self.garage || garage
                self.pergola = pergola
            case .summitBar:
                style.tint = BuildingBuilder.rivieraTint(.greyBeige, .green)
                style.row = .painted
                style.window = .upper
                style.windowChance = 0.95
                style.roof = .redPantile
                roof = .hipped
                pitchDeg = 22
                shopfronts = true
                terraceWing = true
                balconies = false
                garage = false
                chimney = false
                minStoreys = 2
            case .barTerrace:
                style.tint = BuildingBuilder.rivieraTint(.greyBeige, .green)
                style.row = .painted
                style.shed = false
                style.window = .upper
                style.windowChance = 0.95
                roof = .flat
                balustradeRoof = true
                shopfronts = true
                balconies = false
                garage = false
                chimney = false
                pergola = false
                stairHouse = false
            case .santuario, .cisternTower, .campanile, .churchPart, .cleared:
                break
            }
        }
    }

    /// Weighted pick from `options` with `r`.
    static func pickWeighted<T>(_ options: [(Double, T)], _ r: inout WorldRandom) -> T {
        var x = Double(r.unit()) * options.reduce(0) { $0 + $1.0 }
        for (w, v) in options {
            if x < w { return v }
            x -= w
        }
        return options[options.count - 1].1
    }

    /// The plan of an unlisted Riviera building, fixed per footprint.
    static func rivieraPlan(_ b: SceneryFile.Building, form: RivieraForm, area: Double, index: Int,
                            routeDistance: Double) -> RivieraPlan {
        var r = WorldRandom(seed: UInt64(index) &* 0x9E37_79B1 &+ 4242)
        let colours: [(Double, RenderColour)] = form == .palazzina
            ? [(3, .ochre), (3, .paleYellow), (3, .cream), (2, .palePink), (1.5, .salmon), (1.5, .white), (1, .peach),
               (1, .warmYellow), (1, .pinkBeige), (0.6, .greyBeige), (0.4, .lightGrey)]
            : [(3, .cream), (2, .paleYellow), (1.2, .ochre), (1.5, .palePink), (1, .salmon), (1.5, .white),
               (0.4, .paleGreen), (0.8, .greyBeige), (0.8, .pinkBeige), (0.8, .warmYellow), (0.4, .rose),
               (0.6, .lightGrey), (0.8, .peach), (0.2, .blueGrey)]
        let colour = pickWeighted(colours, &r)
        let shutter = pickWeighted([(6, ShutterColour.green), (2, .brown), (1, .lightBlue), (1, .fadedGreen)], &r)
        let shed = form == .shed
        let palazzina = form == .palazzina
        let row: WallRow
        if shed {
            row = r.unit() < 0.5 ? .darkBrick : .painted
        } else if palazzina {
            row = r.unit() < 0.55 ? .redBrick : .painted
        } else {
            row = pickWeighted([(0.68, WallRow.painted), (0.2, .cream), (0.12, .redBrick)], &r)
        }
        var s = Style(row: row, pantile: true, pitchDeg: 0, shed: shed)
        s.seed = r.unit()
        s.tint = row == .darkBrick ? rivieraTint(.atlas, shutter) : rivieraTint(colour, shutter)
        s.roof = row == .cream && r.unit() < 0.6 ? .smokedPantile : .redPantile
        if shed && r.unit() < 0.45 { s.roof = .sheet }
        s.boards = .whiteBoard
        s.plinth = pickWeighted([(0.55, WallKind.cementPlinth), (0.15, .stonePlinth), (0.3, .wall)], &r)
        s.plinthHeight = s.plinth == .wall ? 0 : Double(r.range(0.4, 0.8))
        s.bayPitch = Double(r.range(3.0, 3.8))
        s.windowChance = r.range(0.82, 0.96)
        s.window = pickWeighted([(0.5, OpeningCut.upper), (0.4, .ground), (0.1, .narrow)], &r)
        s.windowScale = Double(r.range(0.95, 1.05))
        s.shedDoor = .steelDoor
        let flatShare = shed ? 0.5 : palazzina ? 0.35 : 0.15
        var roof: RivieraPlan.Roof = r.unit() < Float(flatShare) ? .flat : .hipped
        if b.roofShape == "flat" { roof = .flat }
        if b.roofShape == "gabled" { roof = .gabled }
        if b.roofShape == "hipped" || b.roofShape == "pyramidal" { roof = .hipped }
        if roof == .flat { s.roof = .slate }
        let storeys = Int((b.heightM / 3).rounded(.down))
        return RivieraPlan(style: s, roof: roof, pitchDeg: Double(r.range(20, 25)),
                           balconies: !shed && storeys >= 2 && r.unit() < (palazzina ? 0.9 : 0.55),
                           balconyFront: pickWeighted([(0.5, 0), (0.25, 1), (0.25, 2)], &r),
                           garage: !shed && r.unit() < (palazzina ? 0.6 : 0.4),
                           pergola: !palazzina && roof == .flat && r.unit() < 0.3,
                           chimney: !shed && roof != .flat && r.unit() < 0.35,
                           stairHouse: palazzina && roof == .flat && r.unit() < 0.6,
                           palazzina: palazzina)
    }

    /// One roof plane: rising at the pitch inward from the line through `a`
    /// along `along`, `n` its inward normal in plan.
    struct RoofPlane {
        var a: SIMD2<Double>
        var along: SIMD2<Double>
        var n: SIMD2<Double>
    }

    /// The faces of the lowest roof the planes make over `poly`: each plane's
    /// share, where it lies below every other (the straight-skeleton roof of
    /// a convex plan). Coincident planes keep the first.
    static func envelopeFaces(_ poly: [SIMD2<Double>], planes: [RoofPlane]) -> [(plane: Int, poly: [SIMD2<Double>])] {
        var out: [(plane: Int, poly: [SIMD2<Double>])] = []
        for i in planes.indices {
            var face = poly
            let pi = planes[i]
            for j in planes.indices where j != i {
                let pj = planes[j]
                let m = pj.n - pi.n
                let mm = simd_length_squared(m)
                if mm < 1e-10 {
                    let gap = simd_dot(pj.a - pi.a, pi.n)
                    if gap < -1e-6 || (abs(gap) <= 1e-6 && j < i) { face = []; break }
                    continue
                }
                let k = simd_dot(pj.a, pj.n) - simd_dot(pi.a, pi.n)
                face = clipHalfPlane(face, normal: m, origin: m * (k / mm))
                if face.count < 3 { break }
            }
            if face.count >= 3, signedArea(face) > 0.02 { out.append((i, face)) }
        }
        return out
    }

    /// The height of the lowest plane over `p`.
    static func envelopeHeight(_ p: SIMD2<Double>, planes: [RoofPlane], eaveY: Double, slope: Double) -> Double {
        var h = Double.infinity
        for q in planes { h = min(h, eaveY + slope * simd_dot(p - q.a, q.n)) }
        return h.isFinite ? h : eaveY
    }

    /// The envelope's profile along a -> c: (distance along, height) at its
    /// ends and wherever it bends, collinear points dropped.
    static func envelopeProfile(_ a: SIMD2<Double>, _ c: SIMD2<Double>, planes: [RoofPlane], eaveY: Double,
                                slope: Double) -> [(u: Double, y: Double)] {
        let len = simd_distance(a, c)
        guard len > 1e-6 else { return [] }
        // Each plane's height along the wall: y0 + k t.
        let lines = planes.map { q -> (Double, Double) in
            let y0 = eaveY + slope * simd_dot(a - q.a, q.n)
            return (y0, slope * simd_dot(c - a, q.n))
        }
        var ts: [Double] = [0, 1]
        for i in lines.indices {
            for j in lines.indices where j > i {
                let dk = lines[i].1 - lines[j].1
                guard abs(dk) > 1e-9 else { continue }
                let t = (lines[j].0 - lines[i].0) / dk
                if t > 1e-4, t < 1 - 1e-4 { ts.append(t) }
            }
        }
        ts.sort()
        func env(_ t: Double) -> Double { lines.map { $0.0 + $0.1 * t }.min() ?? eaveY }
        var pts = ts.map { (u: $0 * len, y: env($0)) }
        // Drop points on a straight run (within a centimetre).
        var k = 1
        while k < pts.count - 1 {
            let p0 = pts[k - 1], p1 = pts[k], p2 = pts[k + 1]
            let lin = p0.y + (p2.y - p0.y) * (p1.u - p0.u) / max(p2.u - p0.u, 1e-9)
            if abs(lin - p1.y) < 0.01 || p1.u - p0.u < 0.02 { pts.remove(at: k) } else { k += 1 }
        }
        return pts
    }

    static func isConvex(_ ring: [SIMD2<Double>]) -> Bool {
        let n = ring.count
        for i in 0..<n {
            let a = ring[i], b = ring[(i + 1) % n], c = ring[(i + 2) % n]
            if (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) < -1e-6 { return false }
        }
        return true
    }

    /// Convex hull (counter-clockwise), Andrew's monotone chain.
    static func convexHull(_ pts: [SIMD2<Double>]) -> [SIMD2<Double>] {
        let p = pts.sorted { $0.x < $1.x || ($0.x == $1.x && $0.y < $1.y) }
        guard p.count > 2 else { return p }
        func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
        for q in p {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], q) <= 0 { lower.removeLast() }
            lower.append(q)
        }
        for q in p.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], q) <= 0 { upper.removeLast() }
            upper.append(q)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// A Riviera house or palazzina: walls in its render with persiane or
    /// roll shutters, laid out as the Flemish houses' (`layoutOpenings`); a
    /// hipped (or gabled) roof per plan piece over the lower envelope of
    /// planes rising from its outer walls at 20-25°, overhanging 45 cm, with
    /// a white cornice, a soffit and coppi along the ridges and hips; or a
    /// flat roof terrace behind a rendered parapet. Balconies, a garage, a
    /// chimney, a pergola or stair house as the plan says.
    static func emitRivieraHouse(_ out: inout Output, ring: [SIMD2<Double>], area: Double,
                                 building b: SceneryFile.Building, plan: RivieraPlan, index: Int,
                                 corridor: RoadCorridor, detail: Bool, tier: RivieraDetail = .high,
                                 routeDistance: Double = 0) {
        let terrain = corridor.terrain
        var rnd = WorldRandom(seed: UInt64(index + 1) &* 7919 &+ 31)
        func ground(_ p: SIMD2<Double>) -> Double { Double(terrain.height(east: p.x, north: p.y)) }
        var groundMin = Double.infinity, groundMax = -Double.infinity
        for p in ring {
            let h = ground(p)
            groundMin = min(groundMin, h); groundMax = max(groundMax, h)
        }
        let floorY = b.groundElevM ?? groundMax
        let baseY = min(groundMin, floorY) - 0.4
        var height = max(b.heightM, 2.6)
        if plan.minStoreys > 0 { height = max(height, Double(plan.minStoreys) * 3 + 1) }
        let topY = floorY + height
        var style = plan.style
        var roofKind = plan.roof
        if height < 3.0 || area < 12 { roofKind = .flat }

        // Plan pieces (an L-shaped villa as two hipped wings).
        let pieces = roofKind == .flat ? [ring] : roofPieces(ring)
        let main = pieces.max { signedArea($0) < signedArea($1) } ?? ring
        let mainBox = orientedBox(main)
        var slope = tan(plan.pitchDeg * .pi / 180)
        var eaveY = topY - slope * mainBox.halfShort
        if eaveY - floorY < 2.5 {
            eaveY = floorY + 2.5
            slope = (topY - eaveY) / max(mainBox.halfShort, 0.5)
            if slope < tan(10 * .pi / 180) { roofKind = .flat }
        }
        let flat = roofKind == .flat
        // A flat roof: the parapet's top is the LiDAR height, the terrace a
        // metre below it.
        let parapet = flat ? min(1.0, max(height - 2.6, 0.3)) : 0
        let wallTopFlat = topY
        if eaveY - floorY < 2.9 { style.plinthHeight = min(style.plinthHeight, 0.42) }

        // The terrace wing of the summit bar: the smallest piece, one storey.
        var wingIndex: Int?
        if plan.terraceWing, pieces.count > 1 {
            wingIndex = pieces.indices.min { signedArea(pieces[$0]) < signedArea(pieces[$1]) }
        }

        // The front door on the wall nearest the route.
        let edges: [(piece: Int, a: SIMD2<Double>, c: SIMD2<Double>)] = pieces.enumerated().flatMap { k, piece in
            piece.indices.map { i in (k, piece[i], piece[(i + 1) % piece.count]) }
        }
        var doorEdge = -1
        var best = Double.infinity
        for (e, edge) in edges.enumerated() where simd_distance(edge.a, edge.c) >= 3 {
            let mid = (edge.a + edge.c) / 2
            guard distanceToRing(mid, ring) < 0.05 else { continue }
            let d = corridor.coarse.query(east: mid.x, north: mid.y).dist
            if d < best { best = d; doorEdge = e }
        }

        // Each piece's roof planes: one per outer wall (hipped), or per outer
        // wall along the piece's length (gabled). A concave piece is roofed
        // over its hull.
        struct PieceRoof {
            var planes: [RoofPlane]
            var poly: [SIMD2<Double>]
            var flat: Bool
            var topY: Double
        }
        var roofs: [PieceRoof] = []
        for (k, piece) in pieces.enumerated() {
            if flat || k == wingIndex {
                let deck = k == wingIndex ? floorY + 3.4 : plan.balustradeRoof ? wallTopFlat - 1.0 : wallTopFlat
                roofs.append(PieceRoof(planes: [], poly: piece, flat: true, topY: deck))
                continue
            }
            let convex = isConvex(piece)
            let shape = convex ? piece : convexHull(piece)
            let box = orientedBox(shape)
            var planes: [RoofPlane] = []
            for i in shape.indices {
                let a = shape[i], c = shape[(i + 1) % shape.count]
                let len = simd_distance(a, c)
                guard len > 0.2 else { continue }
                let along = (c - a) / len
                let mid = (a + c) / 2
                // Outer walls only: a cut shared with the next piece stays a gable.
                guard !convex || distanceToRing(mid, ring) < 0.05 else { continue }
                if roofKind == .gabled, abs(simd_dot(along, box.long)) < 0.7 { continue }
                planes.append(RoofPlane(a: a, along: along, n: SIMD2(-along.y, along.x)))
            }
            if planes.isEmpty {
                roofs.append(PieceRoof(planes: [], poly: piece, flat: true, topY: wallTopFlat))
                continue
            }
            roofs.append(PieceRoof(planes: planes, poly: shape, flat: false, topY: topY))
        }

        // Walls.
        for (e, edge) in edges.enumerated() {
            let a = edge.a, c = edge.c
            let len = simd_distance(a, c)
            guard len > 0.05 else { continue }
            let dir = (c - a) / len
            let roof = roofs[edge.piece]
            let mid = (a + c) / 2
            let outside = distanceToRing(mid, ring) < 0.05
            // The wall's top: flat under a parapet or the eave, or up the
            // roof's profile on a gable or a cut.
            var frames: [WallFrame] = []
            let gs = groundSamples(a, c, ground)
            if roof.flat {
                var w = WallFrame(a: a, dir: dir, len: len, top0: roof.topY, top1: roof.topY, floorY: floorY, baseY: baseY,
                                  ground: gs)
                w.eaves = false
                frames = [w]
            } else {
                let prof = envelopeProfile(a, c, planes: roof.planes, eaveY: eaveY, slope: slope)
                if prof.count <= 3 {
                    var w = WallFrame(a: a, dir: dir, len: len, top0: prof.first?.y ?? eaveY, top1: prof.last?.y ?? eaveY,
                                      floorY: floorY, baseY: baseY, ground: gs)
                    if prof.count == 3 { w.uRidge = prof[1].u; w.topRidge = prof[1].y }
                    frames = [w]
                } else {
                    for k in 0..<(prof.count - 1) {
                        let pa = a + dir * prof[k].u, pc = a + dir * prof[k + 1].u
                        let l = prof[k + 1].u - prof[k].u
                        guard l > 0.05 else { continue }
                        frames.append(WallFrame(a: pa, dir: dir, len: l, top0: prof[k].y, top1: prof[k + 1].y,
                                                floorY: floorY, baseY: baseY, ground: groundSamples(pa, pc, ground)))
                    }
                }
            }
            for w in frames {
                guard detail, outside else {
                    if outside {
                        emitBayWall(&out.walls, w, style: style, windows: true, rnd: &rnd)
                    } else {
                        emitWall(&out.walls, w, style: style, openings: [])
                    }
                    continue
                }
                let q = corridor.coarse.query(east: mid.x, north: mid.y)
                let st = corridor.station(at: q.s)
                let toRoad = SIMD2(st.east, st.north) - mid
                let facesRoad = q.dist < 40 && simd_dot(w.nrm, toRoad) > 0.5 * simd_length(toRoad)
                let seen = facesRoad || seenFromRoute(mid, facing: w.nrm, s: q.s, dist: q.dist, corridor: corridor)
                var openings: [Opening]
                if style.shed {
                    openings = layoutShedOpenings(w, style: style, door: e == doorEdge, seen: seen, rnd: &rnd)
                } else if plan.shopfronts && facesRoad {
                    openings = shopfrontOpenings(w, style: style)
                } else {
                    let isDoor = e == doorEdge
                    var garageAt: Double?
                    if isDoor, plan.garage, w.len >= 6.5 { garageAt = w.len * (rnd.unit() < 0.5 ? 0.27 : 0.73) }
                    let doorU: Double? = isDoor ? (garageAt.map { $0 < w.len / 2 ? w.len * 0.72 : w.len * 0.28 }
                        ?? w.len * Double(rnd.range(0.3, 0.7))) : nil
                    openings = layoutOpenings(w, style: style, eaveY: w.maxTop, door: doorU, front: isDoor || facesRoad,
                                              seen: seen, rnd: &rnd)
                    if let g = garageAt {
                        let width = (Double(rnd.range(2.3, 2.7)) * 10).rounded(.down) / 10
                        let u0 = min(max(g - width / 2, 0.3), w.len - width - 0.3)
                        let gate = Opening(cut: .door, u0: u0, u1: u0 + width, y0: floorY, y1: floorY + 2.2,
                                           painted: .steelDoor)
                        openings.removeAll { $0.y0 < floorY + 2.6 && $0.u0 < gate.u1 + 0.3 && gate.u0 < $0.u1 + 0.3 }
                        openings.append(gate)
                    }
                }
                emitWall(&out.walls, w, style: style, openings: openings)
                // Balconies towards the road and the sea (south), and on a
                // palazzina wherever the road sees it; none that would hang
                // over the carriageway.
                let roadGap = [w.a, w.a + w.dir * (w.len / 2), w.a + w.dir * w.len].map {
                    carriagewayGap($0 + w.nrm * 1.25, corridor: corridor) + 1.25
                }.min() ?? .infinity
                if outside, !style.shed, plan.balconies, facesRoad || -w.nrm.y > 0.35 || (plan.palazzina && seen) {
                    emitBalconies(&out, w, plan: plan, near: q.dist < tier.fineRailM, flatBars: tier.flatBars,
                                  maxDepth: roadGap - 0.1, rnd: &rnd)
                }
                if plan.shopfronts, facesRoad { emitAwnings(&out, w) }
            }
        }

        // Roofs.
        let sd = style.seed
        let board = RoofTrim.whiteBoard.rawValue
        for (k, roof) in roofs.enumerated() {
            if roof.flat {
                let balustrade = k == wingIndex || plan.balustradeRoof
                emitTerraceRoof(&out, piece: pieces[k], topY: roof.topY, parapet: balustrade ? 1.0 : parapet,
                                style: style, balustrade: balustrade, seed: sd, fine: routeDistance < tier.fineRoofRailM)
                continue
            }
            let poly = overhang(roof.poly, footprint: ring, d: 0.45) ?? roof.poly
            let cosP = 1 / sqrt(1 + slope * slope)
            let faces = envelopeFaces(poly, planes: roof.planes)
            for face in faces {
                let pl = roof.planes[face.plane]
                let dTop = face.poly.map { simd_dot($0 - pl.a, pl.n) }.max() ?? 0
                emitRoofPolygon(&out.roofs, face.poly, y: { p in eaveY + slope * simd_dot(p - pl.a, pl.n) + 0.03 },
                                uv: { p in (Float(simd_dot(p, pl.along)), Float((dTop - simd_dot(p - pl.a, pl.n)) / cosP)) },
                                id: style.roof.rawValue, seed: sd,
                                up: { p in Float(simd_dot(p - pl.a, pl.n) / cosP) }, part: 0)
                // Its edges: the eaves and verges on the outline, the ridges and
                // hips between faces (each once, from the lower plane index).
                for i in face.poly.indices {
                    let p = face.poly[i], q = face.poly[(i + 1) % face.poly.count]
                    guard simd_distance(p, q) > 0.05 else { continue }
                    let m = (p + q) / 2
                    let yp = eaveY + slope * simd_dot(p - pl.a, pl.n) + 0.03
                    let yq = eaveY + slope * simd_dot(q - pl.a, pl.n) + 0.03
                    if distanceToRing(m, poly) < 1e-3 {
                        guard let n = outward(p, q) else { continue }
                        // Only the outer walls' overhangs: a cut edge meets the
                        // next piece.
                        let gap = distanceToRing(m, ring)
                        guard gap > 0.3 else { continue }
                        emitBoard(&out.roofs, p, q, ya: yp, yb: yq, out: n, depth: abs(yp - yq) < 0.05 ? 0.2 : 0.22,
                                  id: board, seed: sd, part: 0)
                        continue
                    }
                    let hm = eaveY + slope * simd_dot(m - pl.a, pl.n)
                    guard let other = roof.planes.indices.first(where: { j in
                        j != face.plane && abs(eaveY + slope * simd_dot(m - roof.planes[j].a, roof.planes[j].n) - hm) < 1e-3
                    }), other > face.plane, detail || simd_distance(p, q) > 3 else { continue }
                    emitCap(&out.roofs, P3(p, yp), P3(q, yq), seed: sd, segs: detail ? 5 : 3)
                }
            }
            // The soffit: the overhang's underside, level with the fascia's
            // foot, up to the walls (its middle is hidden in the house).
            let soffitY = eaveY - 0.45 * slope - 0.17
            let tris = earClip(poly)
            let first = UInt32(out.roofs.vertexCount)
            for p in poly {
                roofVertex(&out.roofs, P3(p, soffitY), (Float(p.x), Float(p.y)), id: board, seed: sd, up: 0)
            }
            for (i, j, l) in tris { out.roofs.tri(first + UInt32(i), first + UInt32(l), first + UInt32(j), part: 0) }
        }

        // A rendered chimney with a small tiled cap.
        if plan.chimney, !flat {
            let shift: SIMD2<Double> = mainBox.long * (Double(rnd.range(-0.5, 0.5)) * mainBox.halfLong)
            let c: SIMD2<Double> = mainBox.centre + shift + mainBox.short * (mainBox.halfShort * 0.35)
            let roof = roofs.first { !$0.flat }
            let ry = roof.map { envelopeHeight(c, planes: $0.planes, eaveY: eaveY, slope: slope) } ?? eaveY
            var stack = style
            stack.plinth = .wall
            stack.plinthHeight = 0
            emitBox(&out.walls, centre: c, along: mainBox.long, halfA: 0.3, halfB: 0.3, y0: ry - 0.5, y1: ry + 1.0,
                    style: stack, kind: .stack, ground: { _ in ry - 0.5 + 0.6 })
            var cap = MeshBuffer(parts: 1)
            let c3 = SIMD3<Float>(Float(c.x), Float(ry + 1.08), Float(-c.y))
            emitPropBox(&cap, centre: c3, x: SIMD3(Float(mainBox.long.x), 0, Float(-mainBox.long.y)),
                        z: SIMD3(Float(mainBox.short.x), 0, Float(-mainBox.short.y)), half: SIMD3(0.42, 0.05, 0.42))
            appendParts(&out.props, cap, map: [0: PropPart.concrete.rawValue])
        }

        // A flat roof's pergola or stair house.
        if flat, plan.pergola || plan.stairHouse {
            let box = orientedBox(ring)
            let terraceY = topY - parapet
            if plan.stairHouse, box.halfShort > 2.2 {
                let c = box.centre + box.long * (box.halfLong * 0.45)
                emitBox(&out.walls, centre: c, along: box.long, halfA: 1.3, halfB: 1.4, y0: terraceY - 0.2,
                        y1: terraceY + 2.5, floorY: terraceY, style: style, ground: { _ in terraceY })
                emitRoofPolygon(&out.roofs, rectRing(c, box.long, 1.4, 1.5), y: { _ in terraceY + 2.55 },
                                uv: { p in (Float(p.x), Float(p.y)) }, id: RoofCover.slate.rawValue, seed: sd,
                                up: { _ in 0 }, part: 0)
            }
            if plan.pergola, box.halfShort > 1.8 {
                emitPergola(&out, centre: box.centre - box.long * (box.halfLong * 0.3), along: box.long,
                            halfA: min(box.halfLong * 0.5, 2.6), halfB: min(box.halfShort - 0.6, 2.0), y: terraceY)
            }
        }
    }

    @inline(__always)
    static func P3(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }

    /// A rectangle round `c`, `along` its long axis.
    static func rectRing(_ c: SIMD2<Double>, _ along: SIMD2<Double>, _ ha: Double, _ hb: Double) -> [SIMD2<Double>] {
        let a: SIMD2<Double> = along * ha
        let b: SIMD2<Double> = SIMD2(-along.y, along.x) * hb
        var r: [SIMD2<Double>] = [c - a - b, c + a - b, c + a + b, c - a + b]
        if signedArea(r) < 0 { r.reverse() }
        return r
    }

    /// Half-round coppi along a ridge or hip from `a` to `c` (their axis on
    /// the roof's crease), wrapping a little past horizontal, on the atlas's
    /// coppi crown.
    static func emitCap(_ m: inout MeshBuffer, _ a: SIMD3<Float>, _ c: SIMD3<Float>, seed: Float, segs: Int) {
        let axis = c - a
        let len = simd_length(axis)
        guard len > 0.2 else { return }
        let d = axis / len
        var side = simd_cross(d, SIMD3<Float>(0, 1, 0))
        if simd_length(side) < 1e-4 { return }
        side = simd_normalize(side)
        let upv = simd_normalize(simd_cross(side, d))
        let r: Float = 0.12
        let id = RoofCover.smokedPantile.rawValue
        func ring(_ j: Int) -> SIMD3<Float> {
            let ang = -0.44 + Float(j) / Float(segs) * (Float.pi + 0.88)
            return side * (cos(ang) * r) + upv * (sin(ang) * r)
        }
        let first = UInt32(m.vertexCount)
        for (k, e) in [a - upv * 0.05, c - upv * 0.05].enumerated() {
            for j in 0...segs {
                roofVertex(&m, e + ring(j), (0.01 + 0.165 * Float(j) / Float(segs), Float(k) * len), id: id, seed: seed, up: 5)
            }
        }
        for j in 0..<segs {
            let a0 = first + UInt32(j), a1 = a0 + 1, b0 = first + UInt32(segs + 1 + j), b1 = b0 + 1
            m.tri(a0, b0, a1, part: 0)
            m.tri(a1, b0, b1, part: 0)
        }
    }

    /// A flat roof: the terrace's pale tiles a parapet's height under the
    /// top, the parapet's inner faces in the render, a coping along its top;
    /// or (`balustrade`) a white balustrade instead of the parapet.
    static func emitTerraceRoof(_ out: inout Output, piece: [SIMD2<Double>], topY: Double, parapet: Double, style: Style,
                                balustrade: Bool, seed: Float, fine: Bool = true) {
        let floorY = balustrade ? topY : topY - parapet
        emitRoofPolygon(&out.roofs, piece, y: { _ in floorY + 0.02 }, uv: { p in (Float(p.x), Float(p.y)) },
                        id: RoofCover.slate.rawValue, seed: seed, up: { _ in 0 }, part: 0)
        if balustrade {
            var balusters = MeshBuffer(parts: 1)
            for i in piece.indices {
                let a = piece[i], c = piece[(i + 1) % piece.count]
                emitBalustrade(&balusters, a, c, y: floorY, inward: true, near: fine)
            }
            appendParts(&out.props, balusters, map: [0: PropPart.whitePaint.rawValue])
            return
        }
        guard parapet > 0.15 else { return }
        var inner = style
        inner.plinth = .wall
        inner.plinthHeight = 0
        var coping = MeshBuffer(parts: 1)
        for i in piece.indices {
            let a = piece[i], c = piece[(i + 1) % piece.count]
            let len = simd_distance(a, c)
            guard len > 0.1, let n = outward(a, c) else { continue }
            // The inner face looks into the terrace: the edge run backwards,
            // 20 cm in.
            let ia = c - n * 0.2, ic = a - n * 0.2
            var w = WallFrame(a: ia, dir: (ic - ia) / len, len: len, top0: topY, top1: topY, floorY: floorY, baseY: floorY,
                              ground: [floorY, floorY])
            w.eaves = false
            emitWall(&out.walls, w, style: inner, openings: [])
            let mid = (a + c) / 2 - n * 0.1
            let d = (c - a) / len
            emitPropBox(&coping, centre: P3(mid, topY + 0.04), x: SIMD3(Float(d.x), 0, Float(-d.y)),
                        z: SIMD3(Float(n.x), 0, Float(-n.y)), half: SIMD3(Float(len / 2 + 0.04), 0.04, 0.17))
        }
        appendParts(&out.props, coping, map: [0: PropPart.whitePaint.rawValue])
    }

    /// A white balustrade along a -> c standing on `y`: a plinth rail,
    /// balusters every 20 cm (square in plan) and a handrail.
    static func emitBalustrade(_ m: inout MeshBuffer, _ a: SIMD2<Double>, _ c: SIMD2<Double>, y: Double, inward: Bool,
                               height: Double = 1.0, near: Bool = true) {
        let len = simd_distance(a, c)
        guard len > 0.3, let n = outward(a, c) else { return }
        let d = (c - a) / len
        let x = SIMD3<Float>(Float(d.x), 0, Float(-d.y)), z = SIMD3<Float>(Float(n.x), 0, Float(-n.y))
        let line = inward ? -0.1 : 0.0
        func at(_ u: Double, _ h: Double) -> SIMD3<Float> { P3(a + d * u + n * line, y + h) }
        emitPropBox(&m, centre: at(len / 2, 0.06), x: x, z: z, half: SIMD3(Float(len / 2), 0.06, 0.11))
        emitPropBox(&m, centre: at(len / 2, height - 0.05), x: x, z: z, half: SIMD3(Float(len / 2), 0.05, 0.12))
        guard near else {
            emitPropBox(&m, centre: at(len / 2, height / 2), x: x, z: z, half: SIMD3(Float(len / 2), Float(height / 2 - 0.1), 0.04))
            return
        }
        var u = 0.12
        while u < len - 0.08 {
            emitPost(&m, at(u, 0.12), height: Float(height - 0.22), half: 0.035, x: x, z: z)
            u += 0.2
        }
    }

    /// A square upright from `foot`, its four sides only (its ends are
    /// hidden in the rails): 8 triangles.
    static func emitPost(_ m: inout MeshBuffer, _ foot: SIMD3<Float>, height: Float, half: Float, x: SIMD3<Float>,
                         z: SIMD3<Float>) {
        let up = SIMD3<Float>(0, height, 0)
        let corners = [-x - z, x - z, x + z, -x + z].map { foot + $0 * half }
        for k in 0..<4 {
            let a = corners[k], b = corners[(k + 1) % 4]
            let n = simd_normalize((a + b) / 2 - foot)
            let first = UInt32(m.vertexCount)
            for q in [a, b, b + up, a + up] { m.vertex(q.x, q.y, q.z, n.x, n.y, n.z, 0, 0) }
            if simd_dot(simd_cross(b - a, up), n) >= 0 {
                m.quad(first, first + 1, first + 2, first + 3)
            } else {
                m.quad(first, first + 3, first + 2, first + 1)
            }
        }
    }

    /// Balconies on every upper storey of a wall: a slab 1.1 m deep along
    /// most of it with its front a black iron rail, a white balustrade or a
    /// rendered parapet (`RivieraPlan.balconyFront`). Iron bars only near
    /// the route; from further a rail and posts read the same. No deeper
    /// than `maxDepth` (a wall near the carriageway: none over it).
    static func emitBalconies(_ out: inout Output, _ w: WallFrame, plan: RivieraPlan, near: Bool,
                              flatBars: Bool = false, maxDepth: Double = .infinity, rnd: inout WorldRandom) {
        let storeys = max(1, Int(((w.maxTop - w.floorY) / 3 - 1e-6).rounded(.up)))
        guard storeys >= 2, w.len >= 3 else { return }
        let share = plan.palazzina ? Double(rnd.range(0.7, 0.95)) : Double(rnd.range(0.45, 0.8))
        let span = max(2.4, min(w.len - 1.0, w.len * share))
        let u0 = (w.len - span) / 2 + Double(rnd.range(-0.15, 0.15)) * (w.len - span)
        let u1 = u0 + span
        let n = w.nrm
        let depth = min(Double(rnd.range(1.0, 1.25)), maxDepth)
        guard depth >= 0.6 else { return }
        let x = SIMD3<Float>(Float(w.dir.x), 0, Float(-w.dir.y)), z = SIMD3<Float>(Float(n.x), 0, Float(-n.y))
        var slab = MeshBuffer(parts: 1), iron = MeshBuffer(parts: 1), white = MeshBuffer(parts: 1)
        for s in 1..<storeys {
            let y = w.floorY + Double(s) * 3
            guard y + 1.1 < min(w.top(u0), w.top(u1)) - 0.3 else { continue }
            let along: SIMD2<Double> = w.dir * ((u0 + u1) / 2)
            let mid: SIMD2<Double> = w.a + along + n * (depth / 2)
            emitPropBox(&slab, centre: P3(mid, y - 0.07), x: x, z: z, half: SIMD3(Float(span / 2), 0.08, Float(depth / 2)))
            let ia: SIMD2<Double> = w.a + w.dir * u0 + n * 0.05
            let ic: SIMD2<Double> = w.a + w.dir * u1 + n * 0.05
            let fa: SIMD2<Double> = ia + n * (depth - 0.05)
            let fc: SIMD2<Double> = ic + n * (depth - 0.05)
            switch plan.balconyFront {
            case 1:
                emitBalustrade(&white, fc, fa, y: y, inward: false, near: near)
                emitBalustrade(&white, fa, ia, y: y, inward: false, near: near)
                emitBalustrade(&white, ic, fc, y: y, inward: false, near: near)
            case 2:
                // A rendered front in the wall's own colour.
                var front = plan.style
                front.plinth = .wall
                front.plinthHeight = 0
                for (p, q) in [(fa, fc), (ia, fa), (fc, ic)] {
                    let l = simd_distance(p, q)
                    guard l > 0.1 else { continue }
                    let c = (p + q) / 2
                    emitBox(&out.walls, centre: c, along: (q - p) / l, halfA: l / 2, halfB: 0.06, y0: y - 0.15,
                            y1: y + 1.0, floorY: y, style: front, ground: { _ in y - 0.15 })
                }
            default:
                for (p, q) in [(fa, fc), (ia, fa), (fc, ic)] {
                    emitIronRail(&iron, p, q, y: y, near: near, flat: flatBars)
                }
            }
        }
        appendParts(&out.props, slab, map: [0: PropPart.whitePaint.rawValue])
        appendParts(&out.props, iron, map: [0: PropPart.darkMetal.rawValue])
        appendParts(&out.props, white, map: [0: PropPart.whitePaint.rawValue])
    }

    /// A black iron rail along a -> c on `y`, a metre high: handrail, a
    /// bottom bar and square bars every 15 cm (posts every 1.2 m from
    /// further); `flat` bars are a strip each way (4 triangles, not 8),
    /// for the lower tiers (`RivieraDetail.flatBars`).
    static func emitIronRail(_ m: inout MeshBuffer, _ a: SIMD2<Double>, _ c: SIMD2<Double>, y: Double, near: Bool,
                             flat: Bool = false) {
        let len = simd_distance(a, c)
        guard len > 0.1 else { return }
        let d = (c - a) / len
        let n = SIMD2(d.y, -d.x)
        let x = SIMD3<Float>(Float(d.x), 0, Float(-d.y)), z = SIMD3<Float>(Float(n.x), 0, Float(-n.y))
        func at(_ u: Double, _ h: Double) -> SIMD3<Float> { P3(a + d * u, y + h) }
        emitPropBox(&m, centre: at(len / 2, 1.0), x: x, z: z, half: SIMD3(Float(len / 2), 0.025, 0.03))
        emitPropBox(&m, centre: at(len / 2, 0.1), x: x, z: z, half: SIMD3(Float(len / 2), 0.012, 0.012))
        let pitch = near ? 0.15 : 1.2
        var u = near ? 0.075 : 0.05
        while u < len {
            if flat {
                emitFlatPost(&m, at(u, 0.1), height: 0.88, half: 0.009, x: x, z: z)
            } else {
                emitPost(&m, at(u, 0.1), height: 0.88, half: 0.009, x: x, z: z)
            }
            u += pitch
        }
    }

    /// An upright from `foot` as a strip along `x` through its middle,
    /// facing `z` and `-z`: 4 triangles.
    static func emitFlatPost(_ m: inout MeshBuffer, _ foot: SIMD3<Float>, height: Float, half: Float, x: SIMD3<Float>,
                             z: SIMD3<Float>) {
        let up = SIMD3<Float>(0, height, 0)
        let a = foot - x * half, b = foot + x * half
        for n in [z, -z] {
            let first = UInt32(m.vertexCount)
            for q in [a, b, b + up, a + up] { m.vertex(q.x, q.y, q.z, n.x, n.y, n.z, 0, 0) }
            if simd_dot(simd_cross(b - a, up), n) >= 0 {
                m.quad(first, first + 1, first + 2, first + 3)
            } else {
                m.quad(first, first + 3, first + 2, first + 1)
            }
        }
    }

    /// The summit bar's shop fronts: a door cell every 2.6 m bay along the
    /// ground floor, a window over each on the floors above.
    static func shopfrontOpenings(_ w: WallFrame, style: Style) -> [Opening] {
        var out: [Opening] = []
        let bays = max(1, Int(((w.len - 1.0) / 2.6).rounded(.down)))
        let step = (w.len - 1.0) / Double(bays)
        for k in 0..<bays {
            let cu = 0.5 + (Double(k) + 0.5) * step
            if let o = fit(.door, w, style: style, centre: cu, base: w.floorY, drop: 0, clear: out) { out.append(o) }
        }
        let storeys = max(1, Int(((w.maxTop - w.floorY) / 3 - 1e-6).rounded(.up)))
        for s in 1..<max(storeys, 2) {
            for k in 0..<bays {
                let cu = 0.5 + (Double(k) + 0.5) * step
                if let o = fit(.upper, w, style: style, centre: cu, base: w.floorY + Double(s) * 3, drop: 6, clear: out) {
                    out.append(o)
                }
            }
        }
        return out
    }

    /// Awnings over a shop front: green canvas sloping out 1.4 m from 2.7 m.
    static func emitAwnings(_ out: inout Output, _ w: WallFrame) {
        var m = MeshBuffer(parts: 1)
        let n = w.nrm
        let x = SIMD3<Float>(Float(w.dir.x), 0, Float(-w.dir.y))
        let z = SIMD3<Float>(Float(n.x), 0, Float(-n.y))
        let up = SIMD3<Float>(0, 1, 0)
        let u0 = 0.6, u1 = w.len - 0.6
        guard u1 - u0 > 1 else { return }
        // The sloping canvas tilted down 20 degrees, and its valance, in
        // stripes about 30 cm wide, green and white in turn (look.md
        // section 5: the summit's green-and-white striped shop awning), in
        // the Italian atlas's paints (the props' sign face binds
        // cj_signs_it on the Riviera; the Flemish map's cells fall on its
        // blue direction signs there).
        let tilt: Float = 0.35
        let zt = simd_normalize(z * cos(tilt) - up * sin(tilt))
        let lift: SIMD3<Float> = z * 0.7 - up * 0.25
        let stripes = max(2, Int(((u1 - u0) / 0.3).rounded()))
        let half = Float((u1 - u0) / Double(stripes) / 2)
        var white = MeshBuffer(parts: 1)
        for k in 0..<stripes {
            let mid = w.a + w.dir * (u0 + (u1 - u0) * (Double(k) + 0.5) / Double(stripes))
            let c: SIMD3<Float> = P3(mid, w.floorY + 2.75) + lift
            var stripe = MeshBuffer(parts: 1)
            emitPropBox(&stripe, centre: c, x: x, z: zt, half: SIMD3(half, 0.02, 0.75))
            emitPropBox(&stripe, centre: P3(mid, w.floorY + 2.38) + z * 1.4, x: x, z: z, half: SIMD3(half, 0.12, 0.01))
            if k % 2 == 0 {
                m.append(stripe, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
            } else {
                white.append(stripe, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
            }
        }
        let cells = signCellsIT
        for (mesh, key) in [(m, "paint.green"), (white, "paint.white")] where !mesh.isEmpty {
            var mesh = mesh
            if let cell = cells[key] {
                let (u, v) = cell.centre
                for i in 0..<mesh.vertexCount { mesh.uvs[2 * i] = u; mesh.uvs[2 * i + 1] = v }
                appendParts(&out.props, mesh, map: [0: PropPart.signFace.rawValue])
            } else {
                appendParts(&out.props, mesh, map: [0: PropPart.darkWood.rawValue])
            }
        }
    }

    /// A timber pergola on a roof terrace: four posts, two beams, rafters.
    static func emitPergola(_ out: inout Output, centre: SIMD2<Double>, along: SIMD2<Double>, halfA: Double, halfB: Double,
                            y: Double) {
        var m = MeshBuffer(parts: 1)
        let side = SIMD2(-along.y, along.x)
        let x = SIMD3<Float>(Float(along.x), 0, Float(-along.y)), z = SIMD3<Float>(Float(side.x), 0, Float(-side.y))
        for (sa, sb) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] {
            let offA: SIMD2<Double> = along * (sa * halfA)
            let p: SIMD2<Double> = centre + offA + side * (sb * halfB)
            emitPropBox(&m, centre: P3(p, y + 1.15), x: x, z: z, half: SIMD3(0.06, 1.15, 0.06))
        }
        for sb in [-1.0, 1.0] {
            emitPropBox(&m, centre: P3(centre + side * (sb * halfB), y + 2.35), x: x, z: z,
                        half: SIMD3(Float(halfA + 0.3), 0.08, 0.05))
        }
        var t = -halfA
        while t <= halfA + 0.01 {
            emitPropBox(&m, centre: P3(centre + along * t, y + 2.47), x: x, z: z, half: SIMD3(0.03, 0.04, Float(halfB + 0.3)))
            t += 0.5
        }
        appendParts(&out.props, m, map: [0: PropPart.wood.rawValue])
    }

    // MARK: - Greenhouses

    /// A greenhouse whose footprint comes this close to the carriageway's
    /// edge stands on the terrace behind the edge wall (`clearOfCarriageway`).
    static let greenhouseRoadsideM = 3.0
    /// ... and its glass this far behind the edge: clear of the wall the
    /// roadside builds at the edge (its face at reach + 0.14 m) and its
    /// coping.
    static let greenhouseEdgeClearM = 0.7

    /// Metres from a point to the carriageway's edge (`reach`), negative over it.
    static func carriagewayGap(_ p: SIMD2<Double>, corridor: RoadCorridor) -> Double {
        let q = corridor.coarse.query(east: p.x, north: p.y)
        let st = corridor.station(at: q.s)
        let off = p - SIMD2(st.east, st.north)
        let side: Double = off.x * st.rightE + off.y * st.rightN >= 0 ? 1 : -1
        return simd_length(off) - st.reach(side)
    }

    /// A house's walls stand this far off the carriageway's edge at least.
    static let houseEdgeClearM = 0.2

    /// A footprint kept `clear` metres off the carriageway (`RoadCorridor`
    /// `reach`, each side): its outline, a point a metre, pushed out from
    /// the road where it comes closer, then thinned to its corners again;
    /// `roadside` when it came within `within` metres of the edge. The
    /// CTR's greenhouses and some houses reach the edge line or a little
    /// over it (houses at s 1431, 2680, 2707 and 3963 by 0.3-0.5 m). An
    /// empty ring when nothing is left.
    static func clearOfCarriageway(_ ring: [SIMD2<Double>], corridor: RoadCorridor, by clear: Double,
                                   within: Double) -> (ring: [SIMD2<Double>], roadside: Bool) {
        guard ring.count >= 3 else { return (ring, false) }
        var near = false, moved = false
        var pts: [SIMD2<Double>] = []
        for i in ring.indices {
            let a = ring[i], c = ring[(i + 1) % ring.count]
            let n = max(1, Int(simd_distance(a, c).rounded(.up)))
            for k in 0..<n {
                let p = a + (c - a) * (Double(k) / Double(n))
                let q = corridor.coarse.query(east: p.x, north: p.y)
                let st = corridor.station(at: q.s)
                let o = SIMD2(st.east, st.north)
                let off = p - o
                let side: Double = off.x * st.rightE + off.y * st.rightN >= 0 ? 1 : -1
                let gap = simd_length(off) - st.reach(side)
                if gap < within { near = true }
                if gap < clear, simd_length(off) > 1e-6 {
                    pts.append(o + simd_normalize(off) * (st.reach(side) + clear))
                    moved = true
                } else {
                    pts.append(p)
                }
            }
        }
        guard near else { return (ring, false) }
        guard moved else { return (ring, true) }
        // Thinned: a point within 8 cm of the line through its neighbours goes.
        var r = cleaned(pts)
        var i = 0
        while r.count > 3, i < r.count {
            let a = r[(i + r.count - 1) % r.count], p = r[i], c = r[(i + 1) % r.count]
            let d = c - a, l = simd_length(d)
            let off = l > 1e-9 ? abs((p.x - a.x) * d.y - (p.y - a.y) * d.x) / l : 0
            if off < 0.08 { r.remove(at: i) } else { i += 1 }
        }
        guard r.count >= 3, abs(signedArea(r)) > 4 else { return ([], true) }
        return (r, true)
    }

    /// A greenhouse on the terraces, as houses to build. The LiDAR DTM is
    /// interpolated under a glass roof, so it ramps across the footprint
    /// where the real floor is a terrace: on the Poggio the ground inside
    /// 239 of the 913 greenhouse footprints rose to within a metre of the
    /// eaves and through the roof of 71 (the pipeline's strips of 2 m rise
    /// measure the fall at the corners only). A footprint whose ground,
    /// corners and inside, rises more than 2.4 m is cut across the fall (a
    /// plane fitted to that ground) into bands of about 1.9 m rise, none
    /// narrower than 3 m, each on its own lowest ground: the stepped glass
    /// of a terraced slope. Every house, banded or not, keeps its eaves at
    /// least 2.4 m over its highest ground, `groundTop` (where a band still
    /// rises more than 2.1 m, as in a thin strip curving along a contour,
    /// `emitGreenhouse` lifts the eaves past their usual 4.5 m to clear it).
    ///
    /// A house at the road (`terrace`) stands on the terrace behind the
    /// edge wall rather than at the foot of it: its floor is the ground a
    /// third of the way up what is under it (the 1 m DTM ramps from the
    /// road up the wall's face over a metre or two), and the curb's stone
    /// goes down the rest.
    static func greenhouseBands(_ ring: [SIMD2<Double>], building b: SceneryFile.Building,
                                ground: (SIMD2<Double>) -> Double, terrace: Bool = false)
        -> [(ring: [SIMD2<Double>], building: SceneryFile.Building, groundTop: Double)] {
        guard ring.count >= 3 else { return [] }
        var lo = ring[0], hi = ring[0]
        for p in ring { lo = simd_min(lo, p); hi = simd_max(hi, p) }
        let step = max(1.0, (signedArea(ring) / 400).squareRoot())
        var pts = ring
        var y = lo.y + step / 2
        while y < hi.y {
            var x = lo.x + step / 2
            while x < hi.x {
                if pointInRing(SIMD2(x, y), ring) { pts.append(SIMD2(x, y)) }
                x += step
            }
            y += step
        }
        let hs = pts.map(ground)
        let gMin = hs.min() ?? 0, gMax = hs.max() ?? 0
        // Eaves (`emitGreenhouse`: the height less a 0.75 m ridge, at most
        // 4.5 m) 2.4 m over the highest ground.
        func house(_ r: [SIMD2<Double>], floor: Double, top: Double) -> SceneryFile.Building {
            SceneryFile.Building(ring: r.map { [$0.x, $0.y] }, heightM: max(b.heightM, top - floor + 3.15),
                                 roofShape: b.roofShape, kind: b.kind, groundElevM: floor)
        }
        func terraceLevel(_ h: [Double]) -> Double {
            let s = h.sorted()
            return s.isEmpty ? gMax : s[Int(Double(s.count - 1) * 0.35)]
        }
        let whole = [(ring: ring, building: house(ring, floor: terrace ? terraceLevel(hs) : min(b.groundElevM ?? gMax, gMax),
                                                  top: gMax),
                      groundTop: gMax)]
        guard gMax - gMin > 2.4 else { return whole }
        // The fall: the steepest way up a plane fitted to the ground.
        let c = pts.reduce(SIMD2<Double>.zero, +) / Double(pts.count)
        let hMean = hs.reduce(0, +) / Double(hs.count)
        var sxx = 0.0, sxy = 0.0, syy = 0.0, sxz = 0.0, syz = 0.0
        for (p, h) in zip(pts, hs) {
            let d = p - c, z = h - hMean
            sxx += d.x * d.x; sxy += d.x * d.y; syy += d.y * d.y; sxz += d.x * z; syz += d.y * z
        }
        let det = sxx * syy - sxy * sxy
        guard abs(det) > 1e-9 else { return whole }
        let g = SIMD2((sxz * syy - syz * sxy) / det, (syz * sxx - sxz * sxy) / det)
        guard simd_length(g) > 0.03 else { return whole }
        let up = simd_normalize(g)
        let ts = ring.map { simd_dot($0 - c, up) }
        let t0 = ts.min() ?? 0, t1 = ts.max() ?? 0
        let n = min(Int(((gMax - gMin) / 1.9).rounded(.up)), max(Int((t1 - t0) / 3), 1), 6)
        guard n > 1 else { return whole }
        var out: [(ring: [SIMD2<Double>], building: SceneryFile.Building, groundTop: Double)] = []
        for k in 0..<n {
            let a = t0 + (t1 - t0) * Double(k) / Double(n), e = t0 + (t1 - t0) * Double(k + 1) / Double(n)
            var band = clipHalfPlane(ring, normal: up, origin: c + up * a)
            band = clipHalfPlane(band, normal: -up, origin: c + up * e)
            guard band.count >= 3, signedArea(band) > 4 else { continue }
            var bh = band.map(ground)
            for (p, h) in zip(pts, hs) {
                let t = simd_dot(p - c, up)
                if t >= a, t <= e { bh.append(h) }
            }
            let floor = terrace ? terraceLevel(bh) : (bh.min() ?? gMin), top = bh.max() ?? gMax
            out.append((ring: band, building: house(band, floor: floor, top: top), groundTop: top))
        }
        return out.isEmpty ? whole : out
    }

    /// A greenhouse: a glass house of Venlo spans (3-3.5 m, ridges 25°)
    /// along its length, on a concrete curb with, where the ground falls
    /// away, a honey sandstone terrace wall under it; or a film tunnel of
    /// hooped arches. Near the route span by span with gutters and saw-tooth
    /// gables; further out a box whose roof the shader draws in spans.
    /// At the road (`roadside`) the eaves are 2.6-3 m over the terrace and
    /// the ridges under 3.8 m (look.md section 4, the 2023 and 2024 frames
    /// at look s 2560-2615: two to three metres of glass on a 1-1.5 m
    /// wall), where the survey's height would make a glass cliff of the
    /// bank behind; a back sunk in the bank is not seen from the road.
    /// Where the LiDAR's surface over it is known (`lidarTop`, `lidarTop()`)
    /// the ridges stand there instead, the eaves 2.2-3 m over the terrace:
    /// at route 2906-2958 R the 2008-10 surface is 2.1-3.2 m over the road
    /// on a terrace 1-1.4 m up, so the glass rises about 2 m off a wall of
    /// 1.5-2 m (the 2023 photo at look s 2600 and f83: 2-3 m of glass on a
    /// rubble wall of 1.5-2 m); a house on a terrace below the road ends
    /// below it.
    static func emitGreenhouse(_ out: inout Output, ring: [SIMD2<Double>], area: Double, building b: SceneryFile.Building,
                               tunnel: Bool, index: Int, corridor: RoadCorridor, detail: Bool,
                               groundTop: Double? = nil, roadside: Bool = false, lidarTop: Double? = nil) {
        let terrain = corridor.terrain
        func ground(_ p: SIMD2<Double>) -> Double { Double(terrain.height(east: p.x, north: p.y)) }
        var groundMin = Double.infinity, groundMax = -Double.infinity
        for p in ring {
            let h = ground(p)
            groundMin = min(groundMin, h); groundMax = max(groundMax, h)
        }
        var r = WorldRandom(seed: UInt64(index) &* 0x5851_F42D &+ 77)
        let seed = r.unit()
        let floorY = b.groundElevM.map { min($0, groundMax) } ?? groundMax
        let baseY = groundMin - 0.4
        let curbTop = floorY + 0.45
        let box = orientedBox(ring)
        // Spans across the short side, ridges along the long one.
        let width = 2 * box.halfShort
        let spans = tunnel ? max(1, Int((width / 7.5).rounded(.up))) : max(1, Int((width / 3.2).rounded()))
        let spanW = width / Double(spans)
        let ridgeRise = tunnel ? 0 : spanW / 2 * tan(25 * .pi / 180)
        var eave = min(max(b.heightM - ridgeRise, 2.6), roadside ? 3.0 : 4.5)
        if tunnel { eave = min(max(b.heightM, 2.6), roadside ? 3.0 : 3.8) }
        if roadside, !tunnel, let lidarTop {
            eave = min(max(lidarTop - ridgeRise - floorY, 2.2, (groundTop ?? floorY) - floorY + 0.6), 3.0)
        } else if let groundTop {
            eave = roadside ? min(max(eave, groundTop - floorY + 1.0), 3.3) : max(eave, groundTop - floorY + 1.8)
        }
        let eaveY = floorY + eave
        let gs = Float(seed) * 0.999
        // Height of the roof over a point: across from the box's first long
        // side, in spans.
        func across(_ p: SIMD2<Double>) -> Double { simd_dot(p - box.centre, box.short) + box.halfShort }
        func roofY(_ p: SIMD2<Double>) -> Double {
            let x = across(p) / spanW
            let f = x - floor(x)
            if tunnel {
                // A pointed arch, springing a metre and a half up the walls.
                let s = min(max(f, 0), 1) * 2 - 1
                return eaveY - 1.5 + 1.5 * (1 - s * s).squareRoot() + 0.4 * (1 - abs(s))
            }
            return eaveY + ridgeRise * (1 - abs(f - 0.5) * 2)
        }

        // The curb and the stone under it: honey sandstone where the ground
        // has fallen away, concrete over the floor.
        var curb = Style(row: .darkBrick, pantile: false, pitchDeg: 0, shed: true)
        curb.plinth = .dryStone
        curb.plinthHeight = 0
        curb.seed = gs
        curb.tint = 1
        for i in ring.indices {
            let a = ring[i], c = ring[(i + 1) % ring.count]
            let len = simd_distance(a, c)
            guard len > 0.05 else { continue }
            var w = WallFrame(a: a, dir: (c - a) / len, len: len, top0: curbTop, top1: curbTop, floorY: floorY, baseY: baseY,
                              ground: detail ? groundSamples(a, c, ground) : [ground(a), ground(c)])
            w.eaves = false
            emitWall(&out.walls, w, style: curb, openings: [])
        }

        // Glass walls from the curb to the roof line, split at each gutter and
        // ridge so their tops follow the saw-tooth.
        let wallPart = tunnel ? GlassPart.film : GlassPart.wallGlass
        for i in ring.indices {
            let a = ring[i], c = ring[(i + 1) % ring.count]
            let len = simd_distance(a, c)
            guard len > 0.05 else { continue }
            var ts: [Double] = [0, 1]
            if detail || tunnel {
                let xa = across(a) / (spanW / 2), xc = across(c) / (spanW / 2)
                if abs(xc - xa) > 1e-6 {
                    let lo = min(xa, xc), hi = max(xa, xc)
                    var k = floor(lo) + 1
                    while k < hi {
                        ts.append((k - xa) / (xc - xa))
                        k += 1
                    }
                }
                if tunnel {
                    // The arch's curve: eight steps a span.
                    let steps = Int((abs(xc - xa) * 4).rounded(.up))
                    if steps > 1 { for k in 1..<steps { ts.append(Double(k) / Double(steps)) } }
                }
            }
            ts.sort()
            let n = outward(a, c) ?? SIMD2(0, 0)
            for k in 0..<(ts.count - 1) {
                let pa = a + (c - a) * ts[k], pc = a + (c - a) * ts[k + 1]
                guard simd_distance(pa, pc) > 0.02 else { continue }
                let ya = detail || tunnel ? roofY(pa) : eaveY + ridgeRise / 2
                let yc = detail || tunnel ? roofY(pc) : eaveY + ridgeRise / 2
                let ua = Float(len * ts[k]), uc = Float(len * ts[k + 1])
                roofQuad(&out.roofs, [P3(pa, curbTop), P3(pc, curbTop), P3(pc, yc), P3(pa, ya)],
                         facing: SIMD3(Float(n.x), 0, Float(-n.y)),
                         uv: [(ua, 0), (uc, 0), (uc, Float(yc - curbTop)), (ua, Float(ya - curbTop))],
                         id: wallPart.rawValue, seed: gs, up: 0, part: glassPart)
            }
        }

        // The roof.
        if !detail && !tunnel {
            // One plane at mid height; the shader draws the spans.
            emitRoofPolygon(&out.roofs, ring, y: { _ in eaveY + ridgeRise / 2 },
                            uv: { p in (Float(simd_dot(p, box.long)), Float(across(p))) },
                            id: GlassPart.spanRoof.rawValue, seed: gs, up: { _ in Float(spanW) }, part: glassPart)
            return
        }
        let half = tunnel ? 4 : 1
        let stepW = spanW / Double(2 * half)
        for k in 0..<(spans * 2 * half) {
            // A strip from one gutter or ridge (or arch step) to the next.
            let n0 = Double(k) * stepW, n1 = n0 + stepW
            var strip = clipHalfPlane(ring, normal: box.short, origin: box.centre + box.short * (n0 - box.halfShort))
            strip = clipHalfPlane(strip, normal: -box.short, origin: box.centre + box.short * (n1 - box.halfShort))
            guard strip.count >= 3, signedArea(strip) > 0.01 else { continue }
            let rising = (k % 2 == 0)
            let slopeLen = tunnel ? 1.0 : 1 / cos(25 * .pi / 180)
            emitRoofPolygon(&out.roofs, strip, y: { roofY($0) + 0.01 }, uv: { p in
                let d = across(p) - n0
                return (Float(simd_dot(p, box.long)), Float((rising ? stepW - d : d) * slopeLen))
            }, id: (tunnel ? GlassPart.film : GlassPart.roofGlass).rawValue, seed: gs, up: { _ in 0 }, part: glassPart)
        }
        guard !tunnel else { return }
        // Gutters between the spans, ridge bars along the tops.
        for k in 0...(spans * 2) {
            let n = Double(k) * spanW / 2 - box.halfShort
            let gutter = k % 2 == 0
            // The ridge or gutter line across the footprint.
            let line: SIMD2<Double> = box.centre + box.short * n
            let reach: SIMD2<Double> = box.long * (box.halfLong + 1)
            let p0 = line - reach, p1 = line + reach
            guard let seg = clipSegment(p0, p1, to: ring) else { continue }
            let y = (gutter ? eaveY : eaveY + ridgeRise) + (gutter ? 0.0 : 0.04)
            let l = simd_distance(seg.0, seg.1)
            let mid = (seg.0 + seg.1) / 2
            let d = (seg.1 - seg.0) / max(l, 1e-9)
            emitGlassBox(&out.roofs, centre: P3(mid, y - (gutter ? 0.06 : 0)),
                         x: SIMD3(Float(d.x), 0, Float(-d.y)), z: SIMD3(Float(box.short.x), 0, Float(-box.short.y)),
                         half: SIMD3(Float(l / 2), gutter ? 0.07 : 0.035, gutter ? 0.11 : 0.03), seed: gs)
        }
    }

    /// A box of steel on the glass part (gutters, ridge bars).
    static func emitGlassBox(_ m: inout MeshBuffer, centre: SIMD3<Float>, x: SIMD3<Float>, z: SIMD3<Float>,
                             half: SIMD3<Float>, seed: Float) {
        var b = MeshBuffer(parts: 1)
        emitPropBox(&b, centre: centre, x: x, z: z, half: half)
        let first = UInt32(m.vertexCount)
        for i in 0..<b.vertexCount {
            m.vertex(b.positions[3 * i], b.positions[3 * i + 1], b.positions[3 * i + 2],
                     b.normals[3 * i], b.normals[3 * i + 1], b.normals[3 * i + 2], b.uvs[2 * i], b.uvs[2 * i + 1])
            m.texcoord2(Float(GlassPart.steel.rawValue) + seed * 0.5, 0)
        }
        for t in stride(from: 0, to: b.parts[0].count, by: 3) {
            m.tri(first + b.parts[0][t], first + b.parts[0][t + 1], first + b.parts[0][t + 2], part: glassPart)
        }
    }

    /// The part of the segment p0 -> p1 inside a counter-clockwise ring
    /// (its first and last crossing), or nil.
    static func clipSegment(_ p0: SIMD2<Double>, _ p1: SIMD2<Double>, to ring: [SIMD2<Double>]) -> (SIMD2<Double>, SIMD2<Double>)? {
        var ts: [Double] = []
        let d = p1 - p0
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            let e = b - a
            let den = d.x * e.y - d.y * e.x
            guard abs(den) > 1e-12 else { continue }
            let w = a - p0
            let t = (w.x * e.y - w.y * e.x) / den
            let u = (w.x * d.y - w.y * d.x) / den
            if u >= 0, u <= 1, t >= 0, t <= 1 { ts.append(t) }
        }
        guard let lo = ts.min(), let hi = ts.max(), hi - lo > 1e-6 else { return nil }
        let a = p0 + d * lo, b = p0 + d * hi
        return simd_distance(a, b) > 0.3 ? (a + simd_normalize(d) * 0.05, b - simd_normalize(d) * 0.05) : nil
    }

    // MARK: - Cisterns

    /// A round concrete irrigation cistern (vasca): a wall 25 cm thick a
    /// metre or two high round dark green water 35 cm under its rim; over
    /// 3.5 m tall, a closed cistern tower with a flat top.
    static func emitCistern(_ out: inout Output, centre: SIMD2<Double>, radius: Double, height: Double,
                            groundElevM: Double?, index: Int, corridor: RoadCorridor, detail: Bool) {
        let sides = detail ? 28 : 16
        func circle(_ r: Double) -> [SIMD2<Double>] {
            (0..<sides).map { k -> SIMD2<Double> in
                let a = Double(k) / Double(sides) * 2 * .pi
                return centre + SIMD2(cos(a), sin(a)) * r
            }
        }
        emitTank(&out, outer: circle(radius), inner: circle(radius - 0.25), height: height, groundElevM: groundElevM,
                 index: index, corridor: corridor)
    }

    /// A concrete tank on any outline: `outer` its wall's outside, `inner`
    /// its inside 25 cm in (both counter-clockwise, point for point). Open
    /// with water under the rim, or closed over 3.5 m tall.
    static func emitTank(_ out: inout Output, outer ringPts: [SIMD2<Double>], inner top: [SIMD2<Double>], height: Double,
                         groundElevM: Double?, index: Int, corridor: RoadCorridor) {
        let terrain = corridor.terrain
        func ground(_ p: SIMD2<Double>) -> Double { Double(terrain.height(east: p.x, north: p.y)) }
        let sides = ringPts.count
        guard sides >= 3, top.count == sides else { return }
        let gs = ringPts.map(ground)
        let gMax = gs.max() ?? 0, gMin = gs.min() ?? 0
        let tower = height > 3.5
        let topY = (groundElevM.map { max($0, gMax) } ?? gMax) + (tower ? height : min(max(height, 1.1), 2.4))
        var r = WorldRandom(seed: UInt64(index) &* 0x2545_F491 &+ 5)
        var style = Style(row: .darkBrick, pantile: false, pitchDeg: 0, shed: true)
        style.seed = r.unit()
        for k in 0..<sides {
            let a = ringPts[k], c = ringPts[(k + 1) % sides]
            let len = simd_distance(a, c)
            var w = WallFrame(a: a, dir: (c - a) / len, len: len, top0: topY, top1: topY, floorY: gMin, baseY: gMin - 0.4,
                              ground: [gs[k], gs[(k + 1) % sides]])
            w.eaves = false
            emitWall(&out.walls, w, style: style, openings: [])
        }
        if tower {
            emitFlatTop(&out.walls, top, outer: ringPts, y: topY, style: style, closed: true)
            return
        }
        // The rim, the inner face down to the water, the water.
        emitFlatTop(&out.walls, top, outer: ringPts, y: topY, style: style, closed: false)
        let waterY = topY - 0.35
        for k in 0..<sides {
            let a = top[(k + 1) % sides], c = top[k]
            let len = simd_distance(a, c)
            var w = WallFrame(a: a, dir: (c - a) / len, len: len, top0: topY, top1: topY, floorY: waterY - 0.3,
                              baseY: waterY - 0.3, ground: [waterY - 0.3, waterY - 0.3])
            w.eaves = false
            emitWall(&out.walls, w, style: style, openings: [])
        }
        emitPolygon(&out.water, top, y: { _ in waterY }, uv: { p in (Float(p.x), Float(p.y)) }, part: 0)
    }

    /// A horizontal ring (or, `closed`, a disc) of concrete on the walls,
    /// between `inner` and `outer` (both counter-clockwise, matched).
    static func emitFlatTop(_ m: inout MeshBuffer, _ inner: [SIMD2<Double>], outer: [SIMD2<Double>], y: Double,
                            style: Style, closed: Bool) {
        let code = wallCode(.wall, tint: style.tint)
        let uv = atlasUV(col: 3, row: style.row.rawValue, fu: 0.5, fv: 0.5)
        func put(_ p: SIMD2<Double>) -> UInt32 {
            let i = m.vertex(Float(p.x), Float(y), Float(-p.y), 0, 1, 0, uv.0, uv.1)
            m.texcoord2(3, noEaves)
            m.texcoord3(code, style.seed)
            return i
        }
        let n = outer.count
        if closed {
            let first = UInt32(m.vertexCount)
            for p in outer { _ = put(p) }
            for (a, b, c) in earClip(outer) { m.tri(first + UInt32(a), first + UInt32(b), first + UInt32(c)) }
            return
        }
        for k in 0..<n {
            let o0 = put(outer[k]), o1 = put(outer[(k + 1) % n]), i1 = put(inner[(k + 1) % n]), i0 = put(inner[k])
            m.quad(o0, o1, i1, i0)
        }
    }

    /// `ring` (counter-clockwise) moved in by `d`, corners mitred; nil where
    /// it would fold over itself.
    static func insetRing(_ ring: [SIMD2<Double>], by d: Double) -> [SIMD2<Double>]? {
        let n = ring.count
        guard n >= 3 else { return nil }
        var out: [SIMD2<Double>] = []
        for i in 0..<n {
            let p0 = ring[(i + n - 1) % n], p1 = ring[i], p2 = ring[(i + 1) % n]
            guard let n0 = outward(p0, p1), let n1 = outward(p1, p2) else { return nil }
            let e0 = p1 - p0, e1 = p2 - p1
            let a0 = p1 - n0 * d, a1 = p1 - n1 * d
            let cr = e0.x * e1.y - e0.y * e1.x
            if abs(cr) < 1e-6 * simd_length(e0) * simd_length(e1) {
                out.append(a0)
                continue
            }
            let q = a1 - a0
            let corner = a0 + e0 * ((q.x * e1.y - q.y * e1.x) / cr)
            guard simd_distance(corner, p1) <= 4 * d else { return nil }
            out.append(corner)
        }
        let a = signedArea(out)
        return a > 0 && a < signedArea(ring) ? out : nil
    }

    // MARK: - Churches

    /// The render, roof and openings of a Ligurian church: old cream-ochre
    /// render (#d8c8a0) flaking in patches, few and high windows, coppi.
    static func churchStyle() -> Style {
        var style = Style(row: .cream, pantile: true, pitchDeg: 0, shed: false)
        style.tint = rivieraTint(.santuario, .green)
        style.seed = 0.3721
        style.roof = .smokedPantile
        style.boards = .whiteBoard
        style.plinth = .cementPlinth
        style.plinthHeight = 0.6
        style.bayPitch = 4.5
        style.windowChance = 0.45
        style.window = .narrow
        return style
    }

    /// A Ligurian church or chapel on its footprint (the Santuario di N.S.
    /// della Guardia, Commons photos at look s 1920 and 1950): a low gabled
    /// nave in `churchStyle`; with `campanile`, at its back corner away from
    /// the road a square bell tower (`emitCampanile`).
    static func emitLigurianChurch(_ out: inout Output, ring: [SIMD2<Double>], building b: SceneryFile.Building,
                                   index: Int, corridor: RoadCorridor, campanile: Bool = true) {
        let terrain = corridor.terrain
        func ground(_ p: SIMD2<Double>) -> Double { Double(terrain.height(east: p.x, north: p.y)) }
        let gMax = ring.map(ground).max() ?? 0
        let floorY = b.groundElevM ?? gMax
        let box = orientedBox(ring)
        let style = churchStyle()
        let rise = box.halfShort * tan(24 * .pi / 180)
        // With a tower of its own to come, the nave's eave about 8 m up,
        // whatever the tower makes of the LiDAR height; otherwise the
        // footprint's own height is the ridge.
        let naveH = campanile ? min(max(b.heightM * 0.55, 6.5), 9.5) : min(max(b.heightM - rise, 3.2), 11)
        let building = SceneryFile.Building(ring: b.ring, heightM: naveH + rise, roofShape: "gabled", kind: "house",
                                            groundElevM: floorY)
        var plan = RivieraPlan(style: style, roof: .gabled, pitchDeg: 24, balconies: false, balconyFront: 0, garage: false,
                               pergola: false, chimney: false, stairHouse: false, palazzina: false)
        plan.minStoreys = 0
        emitRivieraHouse(&out, ring: ring, area: signedArea(ring), building: building, plan: plan, index: index,
                         corridor: corridor, detail: true)
        guard campanile else { return }

        // The campanile at the back corner, away from the road.
        let toRoad: SIMD2<Double> = {
            let q = corridor.coarse.query(east: box.centre.x, north: box.centre.y)
            let st = corridor.station(at: q.s)
            let d = SIMD2(st.east, st.north) - box.centre
            return simd_length(d) > 1e-6 ? simd_normalize(d) : box.long
        }()
        let back = simd_dot(box.long, toRoad) > 0 ? -box.long : box.long
        let sideDir = simd_dot(box.short, toRoad) > 0 ? -box.short : box.short
        let ts = min(max(box.halfShort * 0.7, 3.2), 4.6)
        let toBack: SIMD2<Double> = back * (box.halfLong - ts / 2 - 0.2)
        let c: SIMD2<Double> = box.centre + toBack + sideDir * (box.halfShort + ts / 2 - 0.4)
        emitCampanile(&out, centre: c, along: box.long, side: ts, floorY: floorY,
                      towerTop: floorY + max(b.heightM * 0.85, naveH + 7.5), style: style, ground: ground)
    }

    /// A bell tower the survey draws on its own footprint (the Santuario's,
    /// the Poggio parish church's): square on the footprint's box, no wider
    /// than the slender towers of the Commons photos (4.6 m), its cornice a
    /// metre under the LiDAR height (the 90th percentile over so small a
    /// footprint falls between the cornice and the drum), but never so low
    /// that the belfry sinks behind the nave: in the Commons photo at look s
    /// 1920 its round-headed openings stand wholly over the roofs, the
    /// cornice some 3.8 m over the ridge (the LiDAR's 12.2 m over the
    /// Santuario's footprint, which takes in the lower roofs round the
    /// tower, would leave the belfry two-thirds hidden).
    static func emitCampanile(_ out: inout Output, onFootprint ring: [SIMD2<Double>], building b: SceneryFile.Building,
                              naveRidge: Double = 0, corridor: RoadCorridor) {
        let terrain = corridor.terrain
        func ground(_ p: SIMD2<Double>) -> Double { Double(terrain.height(east: p.x, north: p.y)) }
        let floorY = b.groundElevM ?? (ring.map(ground).max() ?? 0)
        let box = orientedBox(ring)
        let ts = min(max(2 * (box.halfLong * box.halfShort).squareRoot(), 2.6), 4.6)
        emitCampanile(&out, centre: box.centre, along: box.long, side: ts, floorY: floorY,
                      towerTop: floorY + max(b.heightM - 1.0, naveRidge + 3.8, 8), style: churchStyle(), ground: ground)
    }

    /// A square campanile `ts` across standing on `floorY` to `towerTop`:
    /// cornices, a belfry of round-headed openings on each face, ball
    /// finials at its corners and a small grey dome on an octagonal drum
    /// with a lantern and a cross.
    static func emitCampanile(_ out: inout Output, centre c: SIMD2<Double>, along: SIMD2<Double>, side ts: Double,
                              floorY: Double, towerTop: Double, style: Style, ground: (SIMD2<Double>) -> Double) {
        let belfry = towerTop - 3.4
        emitBox(&out.walls, centre: c, along: along, halfA: ts / 2, halfB: ts / 2, y0: floorY - 0.6, y1: towerTop,
                floorY: floorY, style: style, ground: ground)
        let x = SIMD3<Float>(Float(along.x), 0, Float(-along.y))
        let z = SIMD3<Float>(Float(-along.y), 0, Float(-along.x))
        let c3 = P3(c, 0)
        var trims = MeshBuffer(parts: 1), dark = MeshBuffer(parts: 1), dome = MeshBuffer(parts: 1)
        // Cornices at the belfry's foot and the tower top.
        for (y, h) in [(belfry, 0.12), (towerTop, 0.2)] {
            emitPropBox(&trims, centre: c3 + SIMD3(0, Float(y), 0), x: x, z: z,
                        half: SIMD3(Float(ts / 2 + 0.16), Float(h), Float(ts / 2 + 0.16)))
        }
        // A round-headed opening in each face of the belfry, dark inside.
        for (ax, sgn) in [(x, Float(1)), (x, -1), (z, 1), (z, -1)] {
            let n = simd_cross(ax, SIMD3<Float>(0, 1, 0)) * sgn
            let f = c3 + n * Float(ts / 2 + 0.01)
            emitPropBox(&dark, centre: f + SIMD3(0, Float(belfry + 1.55), 0), x: ax, z: n, half: SIMD3(0.5, 0.95, 0.02))
            TreeArchetype.tube(&dark, f + SIMD3(0, Float(belfry + 2.5), 0) - n * 0.02,
                               f + SIMD3(0, Float(belfry + 2.5), 0) + n * 0.02, 0.5, 0.5, sides: 10, height: 100)
        }
        // The octagonal drum, the dome, its lantern and cross.
        let drumR = Float(ts * 0.36)
        let top = c3 + SIMD3(0, Float(towerTop + 0.2), 0)
        TreeArchetype.tube(&trims, top, top + SIMD3(0, 1.9, 0), drumR, drumR, sides: 8, height: 100)
        let profile: [(Float, Float)] = [(0, 1.08), (0.15, 1.02), (0.45, 0.86), (0.7, 0.6), (0.88, 0.32), (1.0, 0.12)]
        let domeFoot = top + SIMD3(0, 1.9, 0)
        let domeH = drumR * 1.15
        for i in 0..<(profile.count - 1) {
            TreeArchetype.tube(&dome, domeFoot + SIMD3(0, profile[i].0 * domeH, 0),
                               domeFoot + SIMD3(0, profile[i + 1].0 * domeH, 0),
                               profile[i].1 * drumR, profile[i + 1].1 * drumR, sides: 12, height: 100)
        }
        let lantern = domeFoot + SIMD3(0, domeH, 0)
        TreeArchetype.tube(&trims, lantern, lantern + SIMD3(0, 0.6, 0), 0.22, 0.2, sides: 8, height: 100)
        TreeArchetype.tube(&dome, lantern + SIMD3(0, 0.6, 0), lantern + SIMD3(0, 0.85, 0), 0.26, 0.02, sides: 8, height: 100)
        emitPropBox(&dark, centre: lantern + SIMD3(0, 1.2, 0), x: x, z: z, half: SIMD3(0.025, 0.35, 0.025))
        emitPropBox(&dark, centre: lantern + SIMD3(0, 1.3, 0), x: x, z: z, half: SIMD3(0.18, 0.025, 0.025))
        // Ball finials on the tower's corners.
        for (sa, sb) in [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)] as [(Float, Float)] {
            let corner: SIMD3<Float> = x * (sa * Float(ts / 2 - 0.15)) + z * (sb * Float(ts / 2 - 0.15))
            let p: SIMD3<Float> = c3 + corner + SIMD3<Float>(0, Float(towerTop + 0.2), 0)
            TreeArchetype.tube(&trims, p, p + SIMD3(0, 0.25, 0), 0.1, 0.07, sides: 6, height: 100)
            let ball: [(Float, Float)] = [(0, 0.05), (0.08, 0.17), (0.2, 0.22), (0.32, 0.17), (0.4, 0.04)]
            for i in 0..<(ball.count - 1) {
                TreeArchetype.tube(&trims, p + SIMD3(0, 0.25 + ball[i].0, 0), p + SIMD3(0, 0.25 + ball[i + 1].0, 0),
                                   ball[i].1, ball[i + 1].1, sides: 8, height: 100)
            }
        }
        appendParts(&out.props, trims, map: [0: PropPart.whitePaint.rawValue])
        appendParts(&out.props, dark, map: [0: PropPart.darkMetal.rawValue])
        appendParts(&out.props, dome, map: [0: PropPart.greyMetal.rawValue])
    }

    /// A cistern tower placed by hand where the data has no footprint.
    static func emitRivieraExtras(_ out: inout Output, sites: [(site: RivieraSite, index: Int?)], corridor: RoadCorridor) {
        for (site, index) in sites where index == nil {
            guard case let .cisternTower(diameter, height) = site.kind else { continue }
            let st = corridor.station(at: routeS(site, corridor: corridor))
            let p = st.point(lateral: site.side * (st.halfWidth + site.offset + diameter / 2))
            emitCistern(&out, centre: SIMD2(p.east, p.north), radius: diameter / 2, height: height, groundElevM: nil,
                        index: Int(site.s), corridor: corridor, detail: true)
        }
    }
}
