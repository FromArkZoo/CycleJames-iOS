import Foundation
import simd

/// The Poggio's summit corner, Piazza della Libertà (look.md section 5),
/// where the map gives a place and the road's stations don't: the west
/// car park's squared-stone wall across the junction with the cars parked
/// nose-in at its foot and the bus shelter at its end (the 2023 summit
/// ride video, the 2022 ortho), the raised car park inside the corner
/// behind its low rubble wall and railing at the tip, the phone box, and
/// the bar's and the pharmacy's signs (the 2020s summit photo).
/// Everything is in the course frame (EPSG:7791 less the course origin).
///
/// The west car park is a plateau at 166.4 m in the LiDAR DTM (2008-10),
/// 5.8 m over the junction (160.0-161.7 m). The 1 m DTM smooths its walls
/// into one grass bank 7 m wide, from x -437 to the CTR's retaining wall
/// at -444 (scenery wall 332's last leg, 1.9 m): the 2022 ortho has the
/// cars' noses at x -441..-442 and the 2023 video a squared-stone wall
/// about 2.1 car heights (3 m) high with a planted bank above it. So: a
/// 3 m wall 2.5 m in front of the CTR's, the DTM cut down to the
/// junction's level in front of it (`levelledNear`), a planted slope on
/// its top and the DTM's bank above that.
extension BuildingBuilder {
    /// The west car park's lower wall face (course frame, south to north):
    /// 2.5 m east of, and parallel to, the CTR's wall 332 (-444.1/531.0
    /// to -447.1/572.3).
    static func poggioWestFace(_ north: Double) -> Double { -441.6 - 3.0 * (north - 531.0) / 41.3 }
    static let poggioWestSpan = 531.0...571.0

    /// The bus shelter at the wall's north end (2023 video: pink-beige
    /// render, a flat roof, open to the road), its back to the wall.
    static let poggioBusShelterNorth = 567.6

    /// The near DTM as the summit's ground is: for the Poggio, a copy cut
    /// down (never filled) to the junction's level between the west car
    /// park's wall and the carriageway, where the 1 m cells smooth the
    /// walls into a bank (the cars and the paving stood on its humps); the
    /// same raster for every other course. The road, the verge, the
    /// terrain, plants and props all read the ground through it
    /// (`RoadCorridor.init`).
    static func levelledNear(_ raster: HeightRaster, courseID: String) -> HeightRaster {
        guard courseID == "poggio", raster.cellM > 0 else { return raster }
        var v = raster.values
        func col(_ e: Double) -> Int { Int(floor((e - raster.originEast) / raster.cellM)) }
        func row(_ n: Double) -> Int { Int(floor((raster.originNorth - n) / raster.cellM)) }
        func centre(_ c: Int, _ r: Int) -> (e: Double, n: Double) {
            (raster.originEast + (Double(c) + 0.5) * raster.cellM, raster.originNorth - (Double(r) + 0.5) * raster.cellM)
        }
        let c0 = max(0, col(-450)), c1 = min(raster.cols - 1, col(-430))
        let r0 = max(0, row(575)), r1 = min(raster.rows - 1, row(527))
        guard c0 < c1, r0 < r1 else { return raster }
        // The junction's level row by row: the lowest of the cells 3.5-5.5 m
        // out from the bank's foot (x -437..-434), eased over five rows.
        var pad = [Float](repeating: 0, count: r1 - r0 + 1)
        for r in r0...r1 {
            var m = Float.infinity
            for e in [-436.5, -435.5, -434.5] {
                let x = raster.values[r * raster.cols + col(e)]
                if !x.isNaN { m = min(m, x) }
            }
            pad[r - r0] = m
        }
        let raw = pad
        for k in pad.indices {
            let lo = max(0, k - 2), hi = min(pad.count - 1, k + 2)
            let w = raw[lo...hi].filter { $0.isFinite }
            pad[k] = w.isEmpty ? .infinity : w.reduce(0, +) / Float(w.count)
        }
        func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
            let t = min(max((x - a) / (b - a), 0), 1)
            return t * t * (3 - 2 * t)
        }
        for r in r0...r1 {
            for c in c0...c1 {
                let (e, n) = centre(c, r)
                // From 1.5 m behind the face (so the cut's edge stands behind
                // it on the terrain's grids; the shrubs on the bank beyond keep
                // their ground) to the carriageway's edge, feathered at the ends.
                let face = poggioWestFace(n)
                guard e > face - 1.5, e < -433.0, pad[r - r0].isFinite else { continue }
                let w = smooth(529.8, 531.2, n) * (1 - smooth(570.0, 573.0, n)) * (1 - smooth(-435.0, -433.0, e))
                guard w > 0 else { continue }
                let i = r * raster.cols + c
                let h = v[i]
                guard !h.isNaN, h > pad[r - r0] else { continue }
                v[i] = h + (pad[r - r0] - h) * Float(w)
            }
        }
        return HeightRaster(cols: raster.cols, rows: raster.rows, cellM: raster.cellM, originEast: raster.originEast,
                            originNorth: raster.originNorth, values: v)
    }

    /// Builds the summit corner on the Poggio; nothing elsewhere.
    static func buildPoggioSummit(corridor: RoadCorridor, scenery: SceneryFile?, kit: inout RoadsideKit) {
        guard rivieraCourse(nil, corridor: corridor) == "poggio" else { return }
        let sideRoads = RoadBuilder.SideRoadMask(scenery: scenery)
        let bays = westCarParkWall(corridor: corridor, kit: &kit)
        // Both car parks are paved to the road (the 2022 ortho: asphalt and
        // cars, no grass): the strip from the wall's foot to the junction's
        // edge, and the raised car park inside the corner from Via Val
        // d'Olivi's wall (-421.5) and the bar's front (~521) to the arriving
        // road's edge.
        summitPaving(rows: Array(stride(from: 531.0, through: 570.0, by: 0.5)), alongNorth: true, corridor: corridor,
                     sideRoads: sideRoads, kit: &kit) { n in
            (poggioWestFace(n) - 0.3, -426.0)
        }
        // (Its service lanes, drawn as side roads, lie under the paving.)
        summitPaving(rows: Array(stride(from: -421.0, through: -397.0, by: 0.5)), alongNorth: false, corridor: corridor,
                     sideRoads: nil, raised: true, kit: &kit) { _ in (521.4, 552.0) }
        // (In the raised car park inside the corner, the paving's own height.)
        func pavedGround(_ p: SIMD2<Double>) -> Double {
            let drawn = summitGround(corridor, p.x, p.y)
            guard p.x > -421.5, p.y < 545 else { return drawn + 0.04 }
            return max(drawn, Double(corridor.terrain.height(east: p.x, north: p.y))) + 0.04
        }
        var rnd = WorldRandom(-440, 550, salt: 117)
        // Nose-in along the wall, 2.5 m bays from its south end to the
        // shelter; a few bays empty, as in the video, and none round the
        // trunk the LiDAR puts 2 m out from the face (scenery tree at
        // -441.5/557.5).
        for bay in bays where bay.p.y > 532.6 && bay.p.y < poggioBusShelterNorth - 2.6 && abs(bay.p.y - 557.5) > 2.2 {
            guard rnd.unit() > 0.16 else { continue }
            let (shape, paint) = randomCar(&rnd)
            let half = Double(carDims(shape).length) / 2
            let c = bay.p + bay.out * (half + 0.45 + Double(rnd.range(0, 0.25)))
            parkedCar(shape, paint: paint, centre: c, facing: -bay.out, ground: pavedGround, kit: &kit)
        }
        busShelter(corridor: corridor, kit: &kit)
        // The raised car park inside the corner, level with the arriving
        // road, a metre over Via Val d'Olivi: a row square to the road
        // between the road and the bar's front (footprints 78 and 83, north
        // side at ~521 m), its west end the wall's line (-421.5).
        var s = 3983.0
        while s < 4011 {
            let st = corridor.station(at: s)
            s += 2.5
            let toRoad = SIMD2(st.rightE, st.rightN)
            let centre = st.point(lateral: -(st.reach(-1) + 2.75))
            let c = SIMD2(centre.east, centre.north)
            let ends = [c + toRoad * 2.3, c - toRoad * 2.3]
            guard ends.allSatisfy({ $0.x > -420.4 && $0.y > 522.4 }), rnd.unit() > 0.15 else { continue }
            let (shape, paint) = randomCar(&rnd)
            parkedCar(shape, paint: paint, centre: c, facing: rnd.unit() < 0.6 ? toRoad : -toRoad, ground: pavedGround,
                      kit: &kit)
        }
        tipWall(corridor: corridor, kit: &kit)
        barSigns(corridor: corridor, kit: &kit)
        // The gravel car park on the right at look ~3610-3635 (the 2024 frame
        // f108 faces back: its black saloon at the image's left is on the
        // rider's right; the 2022 ortho has a strip 6-10 m deep between the
        // road and wall 444 at route 3895-3935, look.md's "car park L" being
        // that frame read as forward).
        let approach: [(Double, CarShape, CarPaint, Double)] = [(3611, .estate, .black, 1.3), (3617, .city, .white, 1.6),
                                                                 (3629.5, .hatch, .silver, 1.4)]
        for (look, shape, paint, gap) in approach {
            let st = corridor.station(at: CourseArt.poggioClimbStart + look * CourseArt.poggioScale)
            let w = Double(carDims(shape).width)
            let c = st.point(lateral: st.reach(1) + gap + w / 2)
            parkedCar(shape, paint: paint, centre: SIMD2(c.east, c.north), facing: SIMD2(-st.dirE, -st.dirN),
                      ground: { summitGround(corridor, $0.x, $0.y) }, kit: &kit)
        }
    }

    /// The height of what is drawn at a point near the road: the
    /// carriageway, the verge mesh's blend from its edge to the DTM within
    /// the verge's width, the DTM beyond (as `RoadBuilder.buildSideRoads`
    /// drapes the lanes).
    static func summitGround(_ corridor: RoadCorridor, _ e: Double, _ n: Double) -> Double {
        let dtm = Double(corridor.terrain.height(east: e, north: n))
        let q = corridor.coarse.query(east: e, north: n)
        guard q.dist < 20 else { return dtm }
        let st = corridor.station(at: q.s)
        let lat = (e - st.east) * st.rightE + (n - st.north) * st.rightN
        let side: Double = lat >= 0 ? 1 : -1
        let o = abs(lat) - st.halfWidth
        guard o < (side > 0 ? st.vergeRight : st.vergeLeft) else { return dtm }
        if o <= 0 { return corridor.roadHeight(st, lateral: lat) }
        let edgeY = corridor.roadHeight(st, lateral: side * st.halfWidth)
        return RoadBuilder.blendedVerge(edgeY: edgeY, dtm: dtm, offset: o) + 0.02
    }

    /// The west car park's lower wall: grey squared stone (#b4ab9b, look.md
    /// section 3), 3 m over the levelled strip in front, its top course a
    /// little uneven, a planted ledge behind it to the DTM's bank. Faces
    /// east, so in the afternoon shade; its normals lean a little up to the
    /// sky (the sunlit junction in front lights it too, which the IBL's
    /// land hemisphere doesn't carry). Its stones' height texcoord starts
    /// 6 m under its foot: the baked light raster (2008-10 LiDAR) still has
    /// the bank's 3-7 m shrub canopy over this strip, where the 2022 ortho
    /// has asphalt and cars, and the masonry shader eases the raster's
    /// occlusion with height up a wall (it read #444645 in shade, luma 70,
    /// against the junction's 173); and no damp band at a foot on tarmac.
    /// Returns the face's points every 2.5 m with the outward direction,
    /// for the cars.
    static func westCarParkWall(corridor: RoadCorridor, kit: inout RoadsideKit) -> [(p: SIMD2<Double>, out: SIMD2<Double>)] {
        func ground(_ p: SIMD2<Double>) -> Double { Double(corridor.terrain.height(east: p.x, north: p.y)) }
        func P(_ p: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(p.x), Float(y), Float(-p.y)) }
        var pts: [SIMD2<Double>] = []
        var n = poggioWestSpan.lowerBound
        while n <= poggioWestSpan.upperBound + 1e-6 {
            pts.append(SIMD2(poggioWestFace(n), n))
            n += 1
        }
        let d = simd_normalize(pts[pts.count - 1] - pts[0])
        let out = SIMD2(d.y, -d.x)
        let up = SIMD3<Float>(0, 1, 0)
        let n3 = SIMD3<Float>(Float(out.x), 0, Float(-out.y))
        let lean = simd_normalize(n3 + up * 0.35), bank = simd_normalize(up + n3 * 0.5)
        // The foot on the levelled strip; the top 3 m over it, its course
        // line wandering a few centimetres and stepping where the stones do.
        var foot: [Double] = [], top: [Double] = []
        for (k, q) in pts.enumerated() {
            let f = ground(q + out * 0.6)
            foot.append(f - 0.3)
            let a = Double(k)
            top.append(f + 3.0 + 0.06 * sin(a * 0.83) + 0.04 * sin(a * 2.1 + 1.3) + (k % 7 < 3 ? 0.05 : 0))
        }
        let capH = 0.16, capOut = 0.035, ledge = 1.9, lift = 6.0
        // The ledge's back on the bank's DTM where that is higher: a planted
        // slope up to the CTR's upper wall, not a trench behind the top.
        let back = pts.indices.map { max(top[$0] + 0.1, ground(pts[$0] - out * ledge) - 0.05) }
        for k in 0..<(pts.count - 1) {
            let a = pts[k], b = pts[k + 1]
            let a0 = Double(k), a1 = Double(k + 1)
            let fq = [Float(foot[k] - lift), Float(foot[k + 1] - lift), Float(foot[k + 1] - lift), Float(foot[k] - lift)]
            kit.stoneQuad([P(a, foot[k]), P(b, foot[k + 1]), P(b, top[k + 1] - capH), P(a, top[k] - capH)],
                          normals: [lean, lean, lean, lean], along: [a0, a1, a1, a0], foot: fq, stone: .greySquared)
            // The top course a few centimetres proud, its top in plan.
            let ca = a + out * capOut, cb = b + out * capOut
            let ba = a - out * 0.45, bb = b - out * 0.45
            kit.stoneQuad([P(ca, top[k] - capH - 0.02), P(cb, top[k + 1] - capH - 0.02), P(cb, top[k + 1]), P(ca, top[k])],
                          normals: [lean, lean, lean, lean], along: [a0, a1, a1, a0], foot: fq, stone: .greySquared)
            kit.stoneQuad([P(ca, top[k]), P(cb, top[k + 1]), P(bb, top[k + 1]), P(ba, top[k])],
                          normals: [up, up, up, up], along: [a0, a1, a1, a0], foot: fq, stone: .greySquared)
            kit.stoneQuad([P(ca, top[k] - capH - 0.02), P(cb, top[k + 1] - capH - 0.02), P(b, top[k + 1] - capH - 0.02),
                           P(a, top[k] - capH - 0.02)],
                          normals: [-up, -up, -up, -up], along: [a0, a1, a1, a0], foot: fq, stone: .greySquared)
            // The planted slope behind it, back into the DTM's bank: its
            // normals kept within 30 degrees of up, so the shader grasses it
            // as a top (steeper, it drew a second stone face over the wall).
            let la = a - out * ledge, lb = b - out * ledge
            kit.stoneQuad([P(ba, top[k] - 0.04), P(bb, top[k + 1] - 0.04), P(lb, back[k + 1]), P(la, back[k])],
                          normals: [bank, bank, bank, bank], along: [a0, a1, a1, a0], foot: fq, stone: .dryStone)
        }
        // The ends, back into the bank.
        for (k, sign) in [(0, -1.0), (pts.count - 1, 1.0)] {
            let q = pts[k] + out * capOut
            let e = SIMD2(-out.y, out.x) * sign
            let nn = SIMD3<Float>(Float(e.x), 0, Float(-e.y))
            let b2 = q - out * ledge
            let low = min(foot[k], ground(b2) - 0.3)
            kit.stoneQuad([P(q, foot[k]), P(b2, low), P(b2, back[k]), P(q, top[k])], normals: [nn, nn, nn, nn],
                          along: [0, ledge, ledge, 0],
                          foot: [Float(foot[k] - lift), Float(low - lift), Float(low - lift), Float(foot[k] - lift)],
                          stone: .greySquared)
        }
        var bays: [(p: SIMD2<Double>, out: SIMD2<Double>)] = []
        var next = 0.0, run = 0.0
        for k in pts.indices {
            if k > 0 { run += simd_distance(pts[k - 1], pts[k]) }
            if run >= next { bays.append((pts[k], out)); next = run + 2.5 }
        }
        return bays
    }

    /// Paving (cast concrete, #b5b2aa) laid row by row over a car park: on
    /// each row (north `rows` running east, or east `rows` running north)
    /// from `extent`'s start to the carriageway's edge or a lane's (drawn
    /// already, where `sideRoads` is given), or the extent's end; 4 cm over
    /// what is drawn there (`raised`: or over the DTM, if higher: a car park
    /// above the road beside it), so it meets the road's edge without a gap
    /// and covers the ground's humps. Its height texcoord starts 6 m under
    /// it, as the wall's (no damp, no foot shade from the 2008-10 canopy in
    /// the light raster).
    static func summitPaving(rows: [Double], alongNorth: Bool, corridor: RoadCorridor, sideRoads: RoadBuilder.SideRoadMask?,
                             raised: Bool = false, kit: inout RoadsideKit, extent: (Double) -> (Double, Double)) {
        func point(_ r: Double, _ t: Double) -> SIMD2<Double> { alongNorth ? SIMD2(t, r) : SIMD2(r, t) }
        func onRoad(_ p: SIMD2<Double>) -> Bool {
            if let q = corridor.mainRoadDistance(east: p.x, north: p.y), q.dist <= q.halfWidth + 0.02 { return true }
            return false
        }
        func onLane(_ p: SIMD2<Double>) -> Bool { sideRoads?.covers(east: p.x, north: p.y, margin: 0) ?? false }
        // Each row's span: from its start until the road (found to 5 cm).
        var spans: [(Double, Double)?] = []
        for r in rows {
            let (t0, tMax) = extent(r)
            guard !onRoad(point(r, t0)), !onLane(point(r, t0)) else { spans.append(nil); continue }
            var t = t0
            while t < tMax, !onRoad(point(r, t + 0.25)), !onLane(point(r, t + 0.25)) {
                t += 0.25
            }
            var lo = t, hi = min(t + 0.25, tMax)
            if hi > lo {
                for _ in 0..<3 {
                    let mid = (lo + hi) / 2
                    if onRoad(point(r, mid)) { hi = mid } else { lo = mid }
                }
            }
            spans.append(lo - t0 > 0.3 ? (t0, lo) : nil)
        }
        let n = 14
        let up = SIMD3<Float>(0, 1, 0)
        for k in 0..<(rows.count - 1) {
            guard let sa = spans[k], let sb = spans[k + 1] else { continue }
            func vert(_ r: Double, _ s: (Double, Double), _ j: Int) -> SIMD3<Float> {
                let p = point(r, s.0 + (s.1 - s.0) * Double(j) / Double(n))
                var y = summitGround(corridor, p.x, p.y)
                if raised { y = max(y, Double(corridor.terrain.height(east: p.x, north: p.y))) }
                return SIMD3(Float(p.x), Float(y + 0.04), Float(-p.y))
            }
            for j in 0..<n {
                let q = [vert(rows[k], sa, j), vert(rows[k], sa, j + 1), vert(rows[k + 1], sb, j + 1), vert(rows[k + 1], sb, j)]
                kit.stoneQuad(q, normals: [up, up, up, up], along: [0, 1, 1, 0], foot: q.map { $0.y - 6 }, stone: .concrete)
            }
        }
    }

    /// The bus shelter at the wall's north end: rendered back and side
    /// walls, a flat roof slab overhanging the front, a bench. (Render
    /// white: the sign atlas and the stones have no pink-beige #e8d6cc.)
    static func busShelter(corridor: RoadCorridor, kit: inout RoadsideKit) {
        let n0 = poggioBusShelterNorth
        let a2 = simd_normalize(SIMD2(poggioWestFace(n0 + 1) - poggioWestFace(n0 - 1), 2.0))
        let o2 = SIMD2(a2.y, -a2.x)
        let L: Float = 1.9, D: Float = 0.8, H: Float = 2.5
        let c2 = SIMD2(poggioWestFace(n0), n0) + o2 * (Double(D) + 0.05)
        let g = Float(summitGround(corridor, c2.x, c2.y)) + 0.02
        let along = SIMD3<Float>(Float(a2.x), 0, Float(-a2.y)), out = SIMD3<Float>(Float(o2.x), 0, Float(-o2.y))
        let c = SIMD3<Float>(Float(c2.x), g, Float(-c2.y))
        kit.stoneBox(c - out * (D - 0.09) + SIMD3(0, H / 2, 0), along: along, half: SIMD3(L, H / 2, 0.09), stone: .whiteRender,
                     footY: g - 2)
        for sx in [-1.0, 1.0] as [Float] {
            kit.stoneBox(c + along * (sx * (L - 0.09)) + SIMD3(0, H / 2, 0), along: along, half: SIMD3(0.09, H / 2, D),
                         stone: .whiteRender, footY: g - 2)
        }
        kit.stoneBox(c + out * 0.15 + SIMD3(0, H + 0.1, 0), along: along, half: SIMD3(L + 0.15, 0.1, D + 0.25),
                     stone: .whiteRender, footY: g - 2)
        var seat = MeshBuffer(parts: 1)
        emitPropBox(&seat, centre: c - out * (D - 0.45) + SIMD3(0, 0.46, 0), x: along, z: out, half: SIMD3(L - 0.4, 0.03, 0.2))
        kit.paint(seat, "paint.timber")
        // The timetable in its frame on the side wall.
        var plate = MeshBuffer(parts: 1)
        emitPropBox(&plate, centre: c + along * (L + 0.1) + out * (D - 0.35) + SIMD3(0, 1.5, 0), x: out, z: along,
                    half: SIMD3(0.25, 0.32, 0.01))
        kit.paint(plate, "it.bus.stop")
    }

    /// The low grey rubble wall that holds the raised car park up at the
    /// corner's tip, from the planter to where the CourseArt span along Via
    /// Val d'Olivi takes over, with its galvanised railing; and the phone
    /// box behind it (the 2020s summit photo: the wall starts at the
    /// planter; the box stands at the railing's start).
    static func tipWall(corridor: RoadCorridor, kit: inout RoadsideKit) {
        let p = CourseArt.poggioClimbStart, k = CourseArt.poggioScale
        let stP = corridor.station(at: p + 3729 * k)
        let planter = RoadBuilder.vergePoint(corridor, stP, side: -1, offset: stP.reach(-1) - stP.halfWidth + 0.8)
        let stS = corridor.station(at: p + 3737 * k)
        let spanStart = stS.point(lateral: -(stS.reach(-1) + 0.14))
        let a = SIMD2(planter.east, planter.north), b = SIMD2(spanStart.east, spanStart.north)
        let len = simd_distance(a, b)
        guard len > 1.2 else { return }
        let d = (b - a) / len
        let start = a + d * 0.85
        // Its face away from the car park: the side the ground is lower.
        var out = SIMD2(d.y, -d.x)
        func ground(_ q: SIMD2<Double>) -> Double { summitGround(corridor, q.x, q.y) }
        if ground(start + out * 1.2) > ground(start - out * 1.2) { out = -out }
        func P(_ q: SIMD2<Double>, _ y: Double) -> SIMD3<Float> { SIMD3(Float(q.x), Float(y), Float(-q.y)) }
        let n3 = SIMD3<Float>(Float(out.x), 0, Float(-out.y)), up = SIMD3<Float>(0, 1, 0)
        let steps = max(1, Int((simd_distance(start, b) / 0.8).rounded(.up)))
        var line: [(p: SIMD2<Double>, y: Double)] = []
        var prev: (SIMD2<Double>, Double, Double)?
        for j in 0...steps {
            let q = start + (b - start) * (Double(j) / Double(steps))
            let inner = ground(q - out * 1.0), outer = ground(q + out * 0.5)
            let top = max(inner + 0.12, outer + 0.4), foot = outer - 0.25
            line.append((q, top))
            if let pr = prev {
                let (pq, pf, pt) = pr
                kit.stoneQuad([P(pq, pf), P(q, foot), P(q, top), P(pq, pt)], normals: [n3, n3, n3, n3],
                              along: [Double(j - 1) * 0.8, Double(j) * 0.8, Double(j) * 0.8, Double(j - 1) * 0.8],
                              foot: [Float(pf), Float(foot), Float(foot), Float(pf)], stone: .greyRubble)
                let ib = pq - out * 0.4, iq = q - out * 0.4
                kit.stoneQuad([P(pq, pt), P(q, top), P(iq, top), P(ib, pt)], normals: [up, up, up, up],
                              along: [0, 1, 1, 0], foot: [Float(pf), Float(foot), Float(foot), Float(pf)], stone: .greyRubble)
            }
            prev = (q, foot, top)
        }
        emitRailing(.bars, line: line, side: -1, kit: &kit)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-poggioNoPhoneBox") { return }
        #endif
        // The Telecom box (look.md: removed 2023/24 by one account, still
        // "the famous phone booth at the summit" in the 2024 ride's notes).
        let box2 = start + d * 0.9 - out * 1.0
        let g = SIMD3<Float>(Float(box2.x), Float(ground(box2)), Float(-box2.y))
        let fwd = SIMD3<Float>(Float(out.x), 0, Float(-out.y))
        phoneBox(at: g, x: simd_cross(fwd, up), fwd: fwd, kit: &kit)
    }

    /// The bar's and the pharmacy's signs on the one-storey front of
    /// footprint 83 facing the raised car park (the 2020s summit photo:
    /// "FARMACIA" on a green band and the green cross at its east end,
    /// "Mt Calvo" in orange-red letters further west, under the terrace).
    static func barSigns(corridor: RoadCorridor, kit: inout RoadsideKit) {
        func ground(_ q: SIMD2<Double>) -> Double { Double(corridor.terrain.height(east: q.x, north: q.y)) }
        // The front's two legs (east to west) and the signs' centres along them.
        let east = (a: SIMD2(-403.7, 520.8), b: SIMD2(-411.1, 519.1))
        let west = (a: SIMD2(-411.6, 520.4), b: SIMD2(-417.7, 519.0))
        func frame(_ leg: (a: SIMD2<Double>, b: SIMD2<Double>), at t: Double) -> (c: SIMD2<Double>, x: SIMD3<Float>, n: SIMD3<Float>) {
            let d = simd_normalize(leg.b - leg.a)
            let n = SIMD2(d.y, -d.x)
            // Facing the car park (north), reading left to right from it.
            let nn = n.y > 0 ? n : -n
            let x = SIMD2(nn.y, -nn.x) * -1
            return (leg.a + (leg.b - leg.a) * t + nn * 0.12, SIMD3(Float(x.x), 0, Float(-x.y)), SIMD3(Float(nn.x), 0, Float(-nn.y)))
        }
        // FARMACIA on its green band.
        let f = frame(east, at: 0.42)
        let fy = Float(ground(f.c)) + 3.05
        let fc = SIMD3<Float>(Float(f.c.x), fy, Float(-f.c.y))
        var band = MeshBuffer(parts: 1)
        emitPropBox(&band, centre: fc, x: f.x, z: f.n, half: SIMD3(1.55, 0.24, 0.04))
        kit.paint(band, "paint.green")
        var white = MeshBuffer(parts: 1)
        strokeText("FARMACIA", centre: fc + f.n * 0.045, x: f.x, n: f.n, height: 0.3, into: &white)
        kit.paint(white, "paint.white")
        // The cross on its bracket, square to the front.
        let e = frame(east, at: 0.06)
        let cc = SIMD3<Float>(Float(e.c.x), Float(ground(e.c)) + 3.3, Float(-e.c.y)) + e.n * 0.55
        var cross = MeshBuffer(parts: 1), bracket = MeshBuffer(parts: 1)
        emitPropBox(&cross, centre: cc, x: e.n, z: e.x, half: SIMD3(0.12, 0.33, 0.05))
        emitPropBox(&cross, centre: cc, x: e.n, z: e.x, half: SIMD3(0.33, 0.12, 0.05))
        emitPropBox(&bracket, centre: cc - e.n * 0.38, x: e.n, z: e.x, half: SIMD3(0.12, 0.02, 0.02))
        kit.paint(cross, "paint.bin.green")
        kit.dark.append(bracket, sx: 1, sy: 1, sz: 1, yaw: 0, tx: 0, ty: 0, tz: 0)
        // Mt Calvo, orange-red letters on a dark board.
        let m = frame(west, at: 0.45)
        let mc = SIMD3<Float>(Float(m.c.x), Float(ground(m.c)) + 3.1, Float(-m.c.y))
        var board = MeshBuffer(parts: 1), letters = MeshBuffer(parts: 1)
        emitPropBox(&board, centre: mc, x: m.x, z: m.n, half: SIMD3(1.7, 0.3, 0.03))
        kit.paint(board, "paint.tyre")
        strokeText("MT CALVO", centre: mc + m.n * 0.035, x: m.x, n: m.n, height: 0.38, into: &letters)
        kit.paint(letters, "paint.orange")
    }

    /// Capital letters drawn in strokes on a plane (`x` along the line,
    /// `n` its normal, up vertical): flat quads, 2 cm proud.
    static func strokeText(_ text: String, centre: SIMD3<Float>, x: SIMD3<Float>, n: SIMD3<Float>, height h: Float,
                           into m: inout MeshBuffer) {
        let glyphs: [Character: [(Float, Float, Float, Float)]] = [
            "M": [(0, 0, 0, 1), (0, 1, 0.3, 0.45), (0.3, 0.45, 0.6, 1), (0.6, 1, 0.6, 0)],
            "T": [(0, 1, 0.6, 1), (0.3, 1, 0.3, 0)],
            "C": [(0.6, 1, 0, 1), (0, 1, 0, 0), (0, 0, 0.6, 0)],
            "A": [(0, 0, 0.3, 1), (0.3, 1, 0.6, 0), (0.13, 0.42, 0.47, 0.42)],
            "L": [(0, 1, 0, 0), (0, 0, 0.55, 0)],
            "V": [(0, 1, 0.3, 0), (0.3, 0, 0.6, 1)],
            "O": [(0, 0, 0, 1), (0, 1, 0.6, 1), (0.6, 1, 0.6, 0), (0.6, 0, 0, 0)],
            "F": [(0, 0, 0, 1), (0, 1, 0.55, 1), (0, 0.55, 0.45, 0.55)],
            "R": [(0, 0, 0, 1), (0, 1, 0.5, 1), (0.5, 1, 0.6, 0.88), (0.6, 0.88, 0.6, 0.64), (0.6, 0.64, 0.5, 0.52),
                  (0.5, 0.52, 0, 0.52), (0.28, 0.52, 0.6, 0)],
            "I": [(0.3, 0, 0.3, 1)],
        ]
        let pitch: Float = 0.82, w: Float = 0.075 * h / 0.4
        let total = Float(text.count) * pitch - (pitch - 0.6)
        let up = SIMD3<Float>(0, 1, 0)
        let origin = centre - x * (total * h / 2) - up * (h / 2)
        for (i, ch) in text.enumerated() {
            for (x0, y0, x1, y1) in glyphs[ch] ?? [] {
                let a = origin + x * ((Float(i) * pitch + x0) * h) + up * (y0 * h)
                let b = origin + x * ((Float(i) * pitch + x1) * h) + up * (y1 * h)
                let dir = simd_normalize(b - a)
                let side = simd_normalize(simd_cross(n, dir)) * (w / 2)
                let ext = dir * (w / 2)
                let lift = n * 0.02
                let a0 = a - ext + lift, b0 = b + ext + lift
                let q: [SIMD3<Float>] = [a0 - side, b0 - side, b0 + side, a0 + side]
                let first = UInt32(m.vertexCount)
                for v in q { m.vertex(v.x, v.y, v.z, n.x, n.y, n.z, 0, 0) }
                if simd_dot(simd_cross(q[1] - q[0], q[2] - q[0]), n) > 0 {
                    m.quad(first, first + 1, first + 2, first + 3)
                } else {
                    m.quad(first, first + 3, first + 2, first + 1)
                }
            }
        }
    }
}
