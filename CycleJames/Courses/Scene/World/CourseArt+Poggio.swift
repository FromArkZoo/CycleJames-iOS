import Foundation

extension CourseArt {
    /// Where the climb starts on the route: the fork off the Via Aurelia
    /// (the Bivio per Poggio), after the 300 m run-in along the Aurelia
    /// (course.json `climb.startS`, 299.99).
    static let poggioClimbStart = 300.0

    /// Route metres per metre of the look bible's survey frame (look.md:
    /// along OSM way 525886322 from the fork, 3730.8 m to the summit
    /// corner). The course's smoothed line on the CTR carriageway is a
    /// little shorter, 3716.3 m (course.json climb 299.99-4016.33), and
    /// its hairpins come 5-7 m earlier: scaled, they land within 2 m (1:
    /// 360 -> 658.6, route 660; 2: 1383 -> 1677.6, 1677; 3: 1723 -> 2016.3,
    /// 2015; the sharp left: 1939 -> 2231.5, 2230).
    static let poggioScale = 3716.34 / 3730.8

    /// The Poggio di Sanremo: the SP55, Via Duca d'Aosta, from the Via
    /// Aurelia up the seaward face of Capo Verde in four hairpins, along
    /// the Costa di Capo Verde ridge through the flower growers'
    /// greenhouses, up Monte Calvo's flank and over the plateau to the
    /// Piazza della Libertà, where the race turns hard left down Via Val
    /// d'Olivi. Drawn as the Riviera on a clear spring afternoon.
    ///
    /// From the photo survey in the research look bible (look.md, sections
    /// 3-6): the labelled frames of the 30 April 2024 ride video (YouTube
    /// F0PhJSzmqV0, placed by its on-screen speed, about ±50 m), Commons
    /// photos (the Aurelia junction's SP55 arrows, 2008; the Santuario),
    /// PezCycling's 2007 hairpin and summit photos, the 2026 piazza
    /// photos and OSM. Distances in comments are from the fork (look.md's
    /// s); `p` scales them to the route and adds the run-in. Sides are the
    /// rider's going up. Walls at the edge follow the Regione Liguria CTR's
    /// retaining walls (scenery `walls`) where it has them; these spans
    /// give their stone and what stands on them, and fill the stretches
    /// the CTR misses.
    static let poggio: CourseArt = {
        func p(_ s: Double) -> Double { poggioClimbStart + s * poggioScale }
        func span(_ a: Double, _ b: Double) -> Span { p(a)...p(b) }
        var art = CourseArt(look: .riviera)
        art.masonry = [
            // A. The start ramp: the 5-6 m honey sandstone wall on the right,
            // a black steel railing on top, then green shade net over a lower
            // bank (frames at 0 and 29 m).
            Masonry(span: span(0, 70), side: 1, height: 4.5...6.0, look: .honeyRubble, top: .blackBars),
            Masonry(span: span(70, 125), side: 1, height: 1.8...3.5, look: .honeyRubble, top: .shadeNet),
            // B. Grey cladding (145 m), sandstone, the reed screen on a low
            // wall (220 m), the tall wall again before hairpin 1 (298 m).
            Masonry(span: span(125, 185), side: 1, height: 1.0...2.2, look: .precastBlocks),
            Masonry(span: span(185, 205), side: 1, height: 1.5...3.0, look: .honeyRubble),
            Masonry(span: span(205, 248), side: 1, height: 0.7...0.7, look: .honeyRubble, retains: false, top: .reedScreen),
            Masonry(span: span(248, 345), side: 1, height: 2.0...4.5, look: .honeyRubble, top: .blackBars),
            // C. Hairpin 1 (right, ~7 m, 340-380): grey squared stone round
            // the outside, a dry-stone wall with a grassy top inside, the
            // rough sandstone after it; the reed screen on its low wall
            // (frame at 470 m).
            Masonry(span: span(342, 378), side: -1, height: 1.2...2.4, look: .greySquared),
            Masonry(span: span(352, 372), side: 1, height: 0.8...1.6, look: .dryStone, coping: false),
            Masonry(span: span(378, 455), side: 1, height: 1.5...3.0, look: .honeyRubble, top: .spear(pillars: false)),
            Masonry(span: span(455, 490), side: 1, height: 0.6...0.6, look: .greyRubble, retains: false, top: .reedScreen),
            // D. The coastal traverse ESE, uphill on the left: continuous
            // sandstone 2-4 m and sun-bleached terraced banks above; on the
            // right the drop, the viewpoint lay-bys' parapets (people sit on
            // them, 620-750) and the villas' spear railings on low stone walls
            // between pillars (840-990), their roofs below the road.
            // ~3 m at 680 (2024), stony terraced banks over it (frames at
            // 654-714 m): the LiDAR bank rises about a metre a metre for
            // 8-10 m behind the wall there, room for four tiers; no coping
            // on the wall under them.
            Masonry(span: span(490, 580), side: -1, height: 1.8...3.4, look: .honeyRubble),
            Masonry(span: span(580, 760), side: -1, height: 1.6...2.6, look: .honeyRubble, coping: false, terraces: 4),
            Masonry(span: span(760, 960), side: -1, height: 1.8...3.4, look: .honeyRubble),
            Masonry(span: span(622, 752), side: 1, height: 0.65...0.65, look: .concrete, offset: 0.9, retains: false,
                    coping: false, top: .tubular),
            Masonry(span: span(805, 838), side: 1, height: 0.7...0.7, look: .concrete, retains: false, coping: false),
            Masonry(span: span(840, 990), side: 1, height: 0.55...0.55, look: .honeyRubble, retains: false,
                    top: .spear(pillars: true)),
            // E. Towards Capo Verde: multi-tier terraces with houses on top
            // (1060), the pink house with light-blue shutters (1150); the sea
            // behind concrete parapets on the right.
            // About 1.5-2.5 m at the road, three or four tiers of terraces
            // above it up to the houses (2024 frame at 1064 m; the bank
            // rises 3.5-5 m in the 8 m behind the wall, then levels off).
            Masonry(span: span(960, 1000), side: -1, height: 1.5...2.8, look: .honeyRubble),
            Masonry(span: span(1000, 1130), side: -1, height: 1.4...2.4, look: .honeyRubble, coping: false, terraces: 5),
            Masonry(span: span(1130, 1340), side: -1, height: 1.5...2.8, look: .honeyRubble),
            Masonry(span: span(992, 1210), side: 1, height: 0.75...0.75, look: .concrete, retains: false, coping: false),
            // F. Hairpin 2 (left, ~1380): on the approach the uphill is still
            // on the left, sandstone with a mesh fence on top, and the
            // guardrail and prickly pear are on the right over the headland
            // (the 2024 frame at 1350 m is from a camera facing back, so
            // look.md's sides are swapped there); then the low wall under a
            // tall mesh fence round the outside; heading west the tall wall
            // on the right; hairpin 3's grey precast blocks; the rendered
            // wall with a palm on top and the parapet with a bar railing over
            // the sea (1840); hairpin 4's grey squared stone beside the
            // Santuario.
            Masonry(span: span(1340, 1372), side: -1, height: 1.5...3.0, look: .honeyRubble, top: .chainLink(green: false)),
            Masonry(span: span(1372, 1398), side: 1, height: 0.6...0.6, look: .greySquared, retains: false,
                    top: .chainLink(green: false)),
            Masonry(span: span(1400, 1690), side: 1, height: 2.5...4.5, look: .honeyRubble),
            Masonry(span: span(1690, 1735), side: 1, height: 1.2...2.6, look: .precastBlocks),
            Masonry(span: span(1700, 1736), side: -1, height: 1.2...2.4, look: .greySquared),
            Masonry(span: span(1740, 1800), side: -1, height: 2.0...3.5, look: .honeyRubble),
            Masonry(span: span(1800, 1905), side: -1, height: 3.0...4.5, look: .render, coping: false),
            Masonry(span: span(1762, 1912), side: 1, height: 0.75...0.75, look: .concrete, retains: false, coping: false,
                    top: .paintedBars),
            // Inside the sharp left: rough rubble with plants on top (2024
            // frames at 1926 and 1956 m, both facing back).
            Masonry(span: span(1908, 1962), side: -1, height: 1.5...3.0, look: .honeyRubble, coping: false),
            // G. The ridge traverse WNW, uphill on the right: sandstone, the
            // shade net over the greenhouse plot (2130-2160), the wall under
            // the pittosporum and the Canary palm (2260), the rubble walls of
            // 2430-2500 and the hedge-topped stone wall opposite.
            Masonry(span: span(1975, 2040), side: 1, height: 1.2...3.0, look: .honeyRubble),
            Masonry(span: span(2110, 2175), side: 1, height: 1.0...2.0, look: .honeyRubble, top: .shadeNet),
            Masonry(span: span(2200, 2340), side: 1, height: 1.2...2.5, look: .honeyRubble),
            Masonry(span: span(2420, 2520), side: 1, height: 1.2...2.5, look: .honeyRubble),
            Masonry(span: span(2430, 2500), side: -1, height: 0.6...0.6, look: .greyRubble, retains: false, coping: false),
            // H. The greenhouse belt: glass houses standing on 1-1.5 m stone
            // walls at the road edge on both sides (2550-2650); the rusty
            // railing at 2930.
            Masonry(span: span(2545, 2655), side: 1, height: 1.0...1.6, look: .honeyRubble),
            Masonry(span: span(2550, 2650), side: -1, height: 1.0...1.5, look: .honeyRubble),
            Masonry(span: span(2895, 2945), side: 1, height: 0.5...0.5, look: .greyRubble, retains: false, coping: false,
                    top: .rusty),
            // I. Monte Calvo's flank. Up to Via Firenze the left lies level
            // with the road (LiDAR DTM, route s 3290-3385): house fronts,
            // garages and the lanes at route s 3310, 3345 and 3369 behind a
            // low garden wall (2024 frames at 2997 and 3031 m). Past the small
            // house at the fork (CTR, route s 3377-3389) the bank rises 2-3 m
            // within 3 m of the edge all the way to the plateau, and the long
            // dark wall the fans paint holds it up (the CTR's wall along the
            // edge from route s 3379 to 3472), olives and a house above it (frames at
            // 3067 m and the 2023 and dusk videos, with the guardrail
            // opposite); then dark rubble on to the plateau (frames at
            // 3147-3351 m). The curving spear railing opposite (3110).
            Masonry(span: span(2993, 3075), side: -1, height: 0.8...0.8, look: .greyRubble, retains: false, coping: false),
            // Opposite, the garden's chain-link on a low wall (2024 frame at
            // 3031 m) along the CTR's 1 m dividing walls (route s 3291-3333;
            // their surveyed crest, up to 2.5 m over the road, is the hedge
            // behind, which built a 2.5 m honey wall ending in a stub).
            Masonry(span: span(2988, 3080), side: 1, height: 0.6...0.8, look: .greyRubble, retains: false, coping: false,
                    top: .chainLink(green: false)),
            Masonry(span: span(3091, 3183), side: -1, height: 1.9...2.5, look: .darkGrey, coping: false),
            Masonry(span: span(3183, 3379), side: -1, height: 1.5...2.6, look: .greyRubble, coping: false),
            // (Set back behind the guardrail, which runs in front of it: the
            // 2024 frame at 3106 m, facing back, has the W-beam at the edge
            // and the spear railing rising behind it.)
            Masonry(span: span(3092, 3132), side: 1, height: 0.6...0.6, look: .greyRubble, offset: 0.9, retains: false,
                    top: .spear(pillars: true)),
            // J. The plateau: a low stone wall on the left (3400), the
            // sandstone pier (3530), the gate on stone pillars (3580) on the
            // right, over the fields (the 2024 frame at 3583 m faces back, so
            // look.md's sides are swapped there; the CTR has no building on
            // the right within 35 m, the ochre block is on the left).
            Masonry(span: span(3380, 3470), side: -1, height: 0.7...1.2, look: .greyRubble, coping: false),
            Masonry(span: span(3515, 3545), side: -1, height: 1.2...2.0, look: .honeyRubble),
            Masonry(span: span(3560, 3600), side: 1, height: 0.6...0.6, look: .honeyRubble, retains: false,
                    top: .spear(pillars: true)),
            // The summit corner: the car park inside the turn is level with
            // the arriving road (LiDAR DTM 161.0-161.4 m, open to it in the
            // 2022 ortho) and a metre or so above Via Val d'Olivi, held there
            // by a low rubble wall with a galvanised railing (the 2020s summit
            // photo; the CTR's wall 217 along the descent's east edge). One
            // wall from just past the apex, so no wall is laid round the
            // 147° corner itself (two there crossed), to the bar's corner.
            Masonry(span: span(3737, 3772), side: -1, height: 0.9...1.6, look: .greyRubble, coping: false, top: .bars),
            // Down Via Val d'Olivi the CTR's low retaining walls along the
            // east bank's foot (walls 140-141, crest at or under the road's
            // level): a low rubble wall facing the road, not a wall holding
            // the road up whose face the bank buried (only its top showed).
            Masonry(span: span(3806, 3860), side: -1, height: 0.5...1.2, look: .greyRubble, coping: false),
        ]
        art.guardrails = [
            // On the drops (look.md section 3): the Aurelia side of the ramp
            // (from where it leaves the Aurelia);
            // much of 600-1000 on the right; hairpin 2's approach and 3's outside;
            // 1400-1680 on the left over the sea; 2000-2100; 3100-3500.
            (span(15, 60), -1, 0.5),
            (span(490, 622), 1, 0.5), (span(752, 805), 1, 0.5), (span(990, 1000), 1, 0.5),
            (span(1210, 1372), 1, 0.5),
            (span(1400, 1690), -1, 0.5),
            (span(1690, 1745), -1, 0.5),
            (span(1915, 1975), 1, 0.5),
            (span(2000, 2100), 1, 0.5),
            // Opposite the painted wall from before its start (the 1960, 2023
            // and dusk frames: the W-beam on the right, curving away with the
            // bend ahead), in front of the spear railing. Not on the plateau's
            // dry earth verge at ~3400 (the 2024 frame at 3408 m: no rail on
            // the right; the next, at 3468 m, has it again).
            (span(3080, 3385), 1, 0.5), (span(3445, 3500), 1, 0.5),
        ]
        art.railings = [
            // The cistern's chain-link behind the guardrail (1320); the
            // olive grove's chain-link and the view east (3185-3260).
            (span(1295, 1342), 1, 1.6, .chainLink(green: false)),
            (span(2960, 2988), 1, 0.8, .chainLink(green: false)),
            (span(3170, 3290), 1, 1.4, .chainLink(green: true)),
            // The works yard's rusty sheets on the left before hairpin 1
            // (frame at 338 m), the Aurelia's balustrade over the beach.
            (span(300, 338), -1, 1.0, .corrugated),
            (span(-300, -10), -1, 1.6, .bars),
        ]
        // "IL POGGIO" (2024-25, the dusk video), hand-painted 1-1.5 m high and
        // spread wide, white #f2f2ee, at the start of the dark wall past the
        // Via Firenze fork (route s 3379), where "1960" and "CHE IL POGGIO"
        // stand right beside the rider in the 2024 and 2023 frames, the
        // guardrail opposite and the right-hand bend (route s 3420-3440)
        // some 40 m ahead. The word is centred on its s and about 12 m long.
        art.paintedWords = [(p(3099), -1, "IL POGGIO", 1.4)]
        // Black plates with a white chevron round the hairpins' outsides
        // (PezCycling 2007), pointing the way the road turns.
        art.chevrons = [
            (p(350), -1, false), (p(360), -1, false), (p(370), -1, false),
            (p(1376), 1, true), (p(1386), 1, true),
            (p(1708), -1, false), (p(1718), -1, false), (p(1728), -1, false),
        ]
        // The Sanremo-Taggia trolleybus along the Aurelia (2008 Commons photo).
        art.trolleyWires = [0...p(-6)]
        art.lamps = [
            // Tall galvanised single-arm LED posts (frames at 66, 338, 1150,
            // 1776-1836, 2264-2367, 2784, 3067, 3260 m), and the summit's.
            (span(-280, -20), 48, -1, .galvanisedLED),
            (span(30, 130), 48, 1, .galvanisedLED),
            (span(300, 340), 40, -1, .galvanisedLED),
            (span(1130, 1180), 45, 1, .galvanisedLED),
            (span(1760, 1900), 46, 1, .galvanisedLED),
            (span(2240, 2400), 50, -1, .galvanisedLED),
            (span(2760, 2860), 50, 1, .galvanisedLED),
            (span(3040, 3290), 55, 1, .galvanisedLED),
            (span(3620, 3720), 40, 1, .galvanisedLED),
        ]
        art.poles = [
            // Timber and concrete poles with sagging overhead lines all the
            // way up (look.md section 6): part of the look.
            (span(130, 330), 38, -1, .woodBundle),
            (span(500, 1000), 42, 1, .concreteBundle),
            (span(1000, 1340), 40, 1, .woodBundle),
            (span(1400, 1690), 40, -1, .woodBundle),
            (span(1975, 2600), 42, 1, .woodBundle),
            (span(2600, 3000), 44, -1, .woodBundle),
            (span(3140, 3700), 40, -1, .concreteBundle),
        ]
        // (The 2-3 m dark hedge at 1235 is the plants' `RivieraPlants.poggio`.)
        art.hedges = [
            (span(130, 330), -1, 1.8, 0.8, .laurel),     // the gardens opposite the start's walls
            (span(2432, 2500), -1, 1.6, 0.6, .laurel),   // on the stone wall opposite the rubble walls
        ]
        art.villages = [0...p(0), p(3376)...p(4010)]  // to the run-out's end (route 4316)
        art.signs = [
            // The Aurelia: the bus stop at the Bivio, the zebra's blue squares,
            // the SP55 arrows on the sea-side pavement (2008 Commons photo).
            SignPost(s: p(-40), side: 1, offset: 1.2, plates: ["it.bus.stop"]),
            SignPost(s: p(-24), side: 1, offset: 1.0, plates: ["it.crossing"]),
            SignPost(s: p(-20), side: -1, offset: 1.2, plates: ["it.crossing"]),
            SignPost(s: p(-8), side: -1, offset: 1.6,
                     plates: ["it.dir.sp55.baiardo", "it.dir.sp55.ceriana", "it.dir.sp55.poggio"]),
            // Up the SP55: the weight limit, the bends.
            SignPost(s: p(30), side: 1, offset: 1.0, plates: ["it.c.3_5t"]),
            SignPost(s: p(300), side: 1, offset: 0.8, plates: ["it.tri.curve.right"]),
            SignPost(s: p(1330), side: 1, offset: 0.8, plates: ["it.tri.curve.left"]),
            SignPost(s: p(1680), side: 1, offset: 0.8, plates: ["it.tri.curve.right"]),
            SignPost(s: p(1890), side: 1, offset: 0.9, plates: ["it.tri.doublecurve.left"]),
            // Convex mirrors at the blind bends and the Santuario's lane.
            SignPost(s: p(372), side: 1, offset: 1.0, plates: ["it.mirror"], turn: -35),
            SignPost(s: p(1392), side: 1, offset: 1.2, plates: ["it.mirror"], turn: 40),
            SignPost(s: p(2080), side: 1, offset: 1.4, plates: ["it.mirror"], turn: -40),
            SignPost(s: p(3372), side: -1, offset: 1.2, plates: ["it.mirror"], turn: -35),
            // Where Poggio's houses begin, at the Via Firenze fork (~3376).
            SignPost(s: p(3380), side: 1, offset: 1.0, plates: ["it.place.poggio"]),
            SignPost(s: p(3650), side: 1, offset: 1.0, plates: ["it.c.50"]),
            // The summit corner's pole: the blue arrows, the weight limit
            // (2020s summit photo); the crossing over Via Val d'Olivi.
            SignPost(s: p(3726), side: -1, offset: 1.4,
                     plates: ["it.dir.ventimiglia", "it.dir.sanremo", "it.dir.imperia", "it.dir.armataggia", "it.c.3_5t"]),
            SignPost(s: p(3715), side: 1, offset: 1.0, plates: ["it.crossing"]),
        ]
        art.furniture = [
            // The side junction's white and red jersey blocks (2040-2070),
            // the growers' white vans on the shoulder (2130-2160).
            Furniture(kind: .riviera(.jerseyBlocks(5)), s: p(2050), side: 1, offset: 0.8),
            Furniture(kind: .riviera(.van), s: p(2135), side: -1, offset: 1.6, turn: 4),
            Furniture(kind: .riviera(.van), s: p(2152), side: -1, offset: 1.8, turn: -6),
            // Gate pillars at the villas and the plateau.
            Furniture(kind: .riviera(.gatePillars(gap: 3.4)), s: p(905), side: 1, offset: 0.3),
            Furniture(kind: .riviera(.gatePillars(gap: 3.0)), s: p(3580), side: 1, offset: 0.3),
            // The summit corner: the planter at the tip, the camera pole, the
            // bins (the phone box stands behind the tip's wall:
            // RoadsideBuilder+PoggioSummit.swift).
            Furniture(kind: .riviera(.planter), s: p(3729), side: -1, offset: 0.8),
            Furniture(kind: .riviera(.cctvPole), s: p(3718), side: -1, offset: 1.0),
            Furniture(kind: .riviera(.wheelieBins), s: p(3690), side: 1, offset: 1.0),
            Furniture(kind: .riviera(.bollards(4)), s: 4006, side: 1, offset: 1.2),
        ]
        // Piazza della Libertà (inaugurated 29 July 2026), the garden 48 m
        // north-west of the apex, right of the arriving road, by its OSM
        // nodes (added 2 September 2026; course frame, EPSG:7791 less the
        // origin): grey gneiss slabs edged in white marble over the garden
        // (leisure=park 1554405014, its paths 1554405011-013), the corten
        // riders on their white wedge (memorial 14141599716), turned to face
        // the summit corner, four timber benches (14141599702-705) and the
        // cast-iron lamps of the photos, at the paths' corners.
        art.placed = [
            (.piazza(width: 26, depth: 11), -465.0, 592.0, 90),
            (.riderSculpture, -465.6, 584.1, 134),
            (.bench, -466.1, 580.9, 0),
            (.bench, -468.4, 584.5, 90),
            (.bench, -463.7, 594.9, 90),
            (.bench, -462.8, 602.8, 90),
            (.castIronLamp, -462.6, 580.2, 0),
            (.castIronLamp, -469.2, 588.4, 0),
            (.castIronLamp, -461.9, 606.8, 0),
        ]
        // The summit's car parks are asphalt with cars on it (2022 ortho),
        // where the LiDAR's 2008-10 surface had low shrubs: the strip at the
        // foot of the west car park's wall (right of the descent's first
        // leg, out to the wall's face 9.3-9.8 m beyond the edge,
        // RoadsideBuilder+PoggioSummit.swift; the shrubs on the bank above
        // it stay, as in the 2023 video) and the car park inside the corner
        // (left of the arriving road, 16 m deep to the bar's front from look
        // 3700, and left of Via Val d'Olivi's first leg to the bar's front:
        // scrub stood on its paving in the fix2 s3 high shot at 4000).
        art.clearings = [(p(3715)...p(3750), 1, 9.0), (p(3685)...p(3700), -1, 10.0), (p(3700)...p(3731), -1, 16.0),
                         (p(3733)...p(3762), -1, 12.0)]
        // The fasce above the walls at look 580-760 and 1000-1130 are bare,
        // sun-bleached dry stone with grassy treads in the 2024 frames (654,
        // 684, 1064 m), where the 2008-10 LiDAR has scrub on the ramp it
        // smooths them into: no scrub or shrubs from the road to just past
        // the top tier's tread (`BuildingBuilder.fasceTier`: 4 tiers, the top
        // tread to 8.4 m beyond the edge; 5 tiers, to 10.4 m). Trees and
        // shrubs stand above it.
        art.clearings += [(span(580, 760), -1, 8.4), (span(1000, 1130), -1, 10.6)]
        return art
    }()
}
