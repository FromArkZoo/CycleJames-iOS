import SceneKit

/// Road-aligned meshes along the corridor: the carriageway (asphalt,
/// cobbles and concrete), the verge either side, the stone edge strips and
/// the concrete gutters.
///
/// The verge is terrain, sampled from the same LiDAR as the grid but laid
/// out in (distance, lateral) so its first column is exactly the road edge.
/// That keeps the sunken lane's banks crisp right where they leave the
/// stones, with no z-fighting against the road. Its last column dips below
/// the grid terrain, which takes over from there.
enum RoadBuilder {
    struct Output {
        var asphalt = MeshBuffer()
        var cobbles = MeshBuffer()
        var concrete = MeshBuffer()
        var verge = MeshBuffer()
        var kerb = MeshBuffer()
        var gutter = MeshBuffer()
        /// Raised sett pavements and flush paved verges (pavementSetts).
        var pavements = MeshBuffer()
        /// White lines on two-lane asphalt roads.
        var markings = MeshBuffer()
        /// Red cycle lanes beside them on the widest roads.
        var cycleLanes = MeshBuffer()
        /// Side roads near the route, draped on the 1 m terrain: part 0
        /// asphalt, part 1 cobbles.
        var sideRoads = MeshBuffer(parts: 2)
    }

    /// Lateral columns of the carriageway, as fractions of the half width.
    private static let roadColumns: [Double] = [-1, -0.94, -0.62, -0.28, 0, 0.28, 0.62, 0.94, 1]
    /// Verge columns outward from the road edge for a 13 m verge.
    private static let vergeColumns: [Double] = [0, 0.14, 0.38, 0.72, 1.15, 1.7, 2.4, 3.3, 4.4, 5.8, 7.5, 9.5, 11.5, 13.0]
    private static let coarseVergeColumns: [Double] = [0, 0.14, 0.5, 1.1, 2.0, 3.3, 5.0, 7.5, 10.5, 13.0]

    /// Every second station where the road runs straight (battery tier).
    private static func thinned(_ s: [RoadCorridor.Station]) -> [RoadCorridor.Station] {
        var out: [RoadCorridor.Station] = []
        out.reserveCapacity(s.count / 2 + 2)
        for (i, st) in s.enumerated() {
            if i == 0 || i == s.count - 1 || i % 2 == 0 || abs(st.curvature) > 0.03 || st.surface != s[i - 1].surface {
                out.append(st)
            }
        }
        return out
    }

    static func build(corridor: RoadCorridor, coarse: Bool = false) -> Output {
        var out = Output()
        let st = coarse ? thinned(corridor.stations) : corridor.stations
        let vergeColumns = coarse ? Self.coarseVergeColumns : Self.vergeColumns
        let cobble = corridor.cobbleIndex
        let nRoad = roadColumns.count
        let nVerge = vergeColumns.count
        out.asphalt.reserve(vertices: st.count * nRoad, indices: st.count * (nRoad - 1) * 6)
        out.cobbles.reserve(vertices: st.count * nRoad, indices: st.count * (nRoad - 1) * 6)
        out.verge.reserve(vertices: st.count * nVerge * 2, indices: st.count * (nVerge - 1) * 12)

        // Carriageway: one row of vertices per station, written into the
        // mesh for the surface of the strip that starts at that station.
        // Each mesh gets its own copy of the rows it uses.
        let strips = pavedVergeStrips(corridor.art)
        func roadRow(_ k: Int, into mesh: inout MeshBuffer) -> UInt32 {
            let s = st[k]
            let first = UInt32(mesh.vertexCount)
            let mud = corridor.art.sunkenWeight(s.s)
            let reachL = 1 - 0.3 * flushPaving(corridor.art, strips: strips, s: s.s, side: -1)
            let reachR = 1 - 0.3 * flushPaving(corridor.art, strips: strips, s: s.s, side: 1)
            for f in roadColumns {
                let lat = f * s.halfWidth
                let p = s.point(lateral: lat)
                let y = corridor.roadHeight(s, lateral: lat)
                mesh.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(lat), Float(s.s))
                // (0 centre .. 1 edge, mud along the sunken lane); 0.7 at
                // an edge the flush paving carries on from.
                mesh.texcoord2(Float(abs(f) * (f < 0 ? reachL : reachR)), Float(mud))
            }
            return first
        }
        var lastRow: [Int: (mesh: Int, row: UInt32)] = [:]
        // Mesh per strip: 0 asphalt, 1 cobbles, 2 concrete.
        var meshes = [out.asphalt, out.cobbles, out.concrete]
        out.asphalt = MeshBuffer(); out.cobbles = MeshBuffer()  // keep the reserved buffers uniquely owned
        for k in 0..<(st.count - 1) {
            let surface = st[k].surface
            let target = cobble != nil && surface == cobble ? 1
                : corridor.concreteIndex != nil && surface == corridor.concreteIndex ? 2 : 0
            let a: UInt32
            if let prev = lastRow[k], prev.mesh == target { a = prev.row } else { a = roadRow(k, into: &meshes[target]) }
            let b = roadRow(k + 1, into: &meshes[target])
            lastRow[k + 1] = (target, b)
            for c in 0..<(nRoad - 1) {
                let a0 = a + UInt32(c), a1 = a0 + 1, b0 = b + UInt32(c), b1 = b0 + 1
                meshes[target].quad(a0, a1, b1, b0)
            }
        }
        for k in meshes.indices { meshes[k].computeNormals() }
        out.asphalt = meshes[0]; out.cobbles = meshes[1]; out.concrete = meshes[2]

        // Verge, both sides.
        let terrain = corridor.terrain
        for side in [-1.0, 1.0] {
            if Task.isCancelled { return out }
            var prev: UInt32?
            for k in 0..<st.count {
                let s = st[k]
                let verge = side > 0 ? s.vergeRight : s.vergeLeft
                let scale = verge / vergeColumns.last!
                let edgeLat = side * s.halfWidth
                let edgeY = corridor.roadHeight(s, lateral: edgeLat)
                let skirt = 0.35 * smoothstepD(2, 6, verge)
                let sunk = corridor.art.sunkenWeight(s.s)
                let first = UInt32(out.verge.vertexCount)
                for (c, o0) in vergeColumns.enumerated() {
                    let o = o0 * scale
                    let p = s.point(lateral: edgeLat + side * o)
                    let dtm = Double(terrain.height(east: p.east, north: p.north))
                    let y = vergeColumnY(c, of: nVerge, edgeY: edgeY, dtm: dtm, offset: o, skirt: skirt)
                    out.verge.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(p.east), Float(-p.north))
                    let rise = y - edgeY
                    let bank = Float(sunk * smoothstepD(0.15, 0.9, rise))
                    let grass = Float((1 - sunk) * smoothstepD(0.1, 0.35, o) * (1 - smoothstepD(2.0, 4.0, o)))
                    let mud = Float(sunk * (1 - smoothstepD(0.3, 1.2, o)))
                    out.verge.texcoord2(bank, grass)
                    out.verge.texcoord3(mud, 0)
                }
                if let a = prev {
                    for c in 0..<(nVerge - 1) {
                        let a0 = a + UInt32(c), a1 = a0 + 1, b0 = first + UInt32(c), b1 = b0 + 1
                        // Keep the winding counter-clockwise from above on both sides.
                        if side > 0 { out.verge.quad(a0, a1, b1, b0) } else { out.verge.quad(a0, b0, b1, a1) }
                    }
                }
                prev = first
            }
        }
        out.verge.computeNormals()

        buildKerbs(corridor: corridor, into: &out.kerb)
        buildGutters(corridor: corridor, into: &out.gutter)
        buildPavements(corridor: corridor, into: &out.pavements, kerb: &out.kerb)
        buildPavedVerges(corridor: corridor, stations: st, columns: vergeColumns, into: &out.pavements)
        buildMarkings(corridor: corridor, into: &out.markings, cycleLanes: &out.cycleLanes)
        return out
    }

    /// Raised sett pavements, 10 cm up a stone kerb from the carriageway
    /// edge, `width` wide, dropping back to the verge at their outer edge.
    /// The kerb (its face and a 12 cm top, pale as the other kerbs) goes
    /// into `kerb`; the setts start behind it.
    private static func buildPavements(corridor: RoadCorridor, into mesh: inout MeshBuffer, kerb: inout MeshBuffer) {
        let kerbH = 0.1, kerbW = 0.12
        for (span, side, width) in corridor.art.pavements {
            var prev: (pavement: UInt32, kerb: UInt32)?
            for s in corridor.stations where span.contains(s.s) && s.beyond == 0 {
                let edge = side * s.halfWidth
                let edgeY = corridor.roadHeight(s, lateral: edge)
                let outer = RoadBuilder.vergePoint(corridor, s, side: side, offset: width)
                let topY = max(edgeY, outer.y) + kerbH
                // Kerb: foot, top at the road, top at the setts (u across it
                // in metres, as `buildKerbs`).
                let mud = Float(corridor.art.sunkenWeight(s.s))
                let kerbCols: [(lat: Double, y: Double, u: Double)] = [
                    (edge, edgeY - 0.01, kerbW + kerbH), (edge + side * 0.005, topY, kerbW), (edge + side * kerbW, topY, 0),
                ]
                let firstKerb = UInt32(kerb.vertexCount)
                for (lat, y, u) in kerbCols {
                    let p = s.point(lateral: lat)
                    kerb.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(u), Float(s.s))
                    kerb.texcoord2(1, mud)
                }
                // Pavement: its inner edge on the kerb and its outer edge,
                // clear of the setts' edge burial and edge dirt (0.35), which
                // would otherwise bury the whole pavement; then its foot on
                // the verge, where the setts sink into the soil (1). The
                // drop's texture runs back across the pavement by its
                // height, so it shows setts, not one sett drawn out into
                // stripes, and stays within the pavement's u.
                let footY = outer.y - 0.05
                let cols: [(lat: Double, y: Double, u: Double, edge: Float)] = [
                    (edge + side * kerbW, topY, edge + side * kerbW, 0.35),
                    (edge + side * width, topY, edge + side * width, 0.35),
                    (edge + side * (width + 0.005), footY, edge + side * (width - min(topY - footY, 0.3)), 1),
                ]
                let first = UInt32(mesh.vertexCount)
                for (lat, y, u, e) in cols {
                    let p = s.point(lateral: lat)
                    mesh.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(u), Float(s.s))
                    mesh.texcoord2(e, 0)
                }
                if let (a, k) = prev {
                    // Mirrored on the left, as for the verge.
                    for c in 0..<UInt32(cols.count - 1) {
                        if side > 0 {
                            mesh.quad(a + c, a + c + 1, first + c + 1, first + c)
                        } else {
                            mesh.quad(a + c, first + c, first + c + 1, a + c + 1)
                        }
                    }
                    for c in 0..<UInt32(kerbCols.count - 1) {
                        if side > 0 {
                            kerb.quad(k + c, k + c + 1, firstKerb + c + 1, firstKerb + c)
                        } else {
                            kerb.quad(k + c, firstKerb + c, firstKerb + c + 1, k + c + 1)
                        }
                    }
                }
                prev = (first, firstKerb)
            }
        }
        mesh.computeNormals()
        kerb.computeNormals()
    }

    /// Height of verge column `c` (of `count`) at `offset` beyond the
    /// carriageway edge: the edge, a small drop off it, the eased LiDAR
    /// ground, and the last column sunk by `skirt` under the grid terrain.
    @inline(__always)
    static func vergeColumnY(_ c: Int, of count: Int, edgeY: Double, dtm: Double, offset o: Double, skirt: Double) -> Double {
        if c == 0 { return edgeY }
        if c == 1 { return edgeY - 0.015 }
        if c == count - 1 { return dtm - skirt }
        return blendedVerge(edgeY: edgeY, dtm: dtm, offset: o)
    }

    /// The flush paved verges (`CourseArt.pavedVerges`) as strips: touching
    /// spans on one side make one strip, laid from one middle line, so its
    /// setts run on where its width steps.
    static func pavedVergeStrips(_ art: CourseArt) -> [(span: CourseArt.Span, side: Double, maxWidth: Double)] {
        var out: [(span: CourseArt.Span, side: Double, maxWidth: Double)] = []
        for side in [-1.0, 1.0] {
            let spans = art.pavedVerges.filter { $0.side * side > 0 }.sorted { $0.span.lowerBound < $1.span.lowerBound }
            for v in spans {
                if let last = out.last, last.side == side, v.span.lowerBound <= last.span.upperBound + 0.01 {
                    out[out.count - 1] = (last.span.lowerBound...max(last.span.upperBound, v.span.upperBound), side,
                                          max(last.maxWidth, v.width))
                } else {
                    out.append((v.span, side, v.width))
                }
            }
        }
        return out
    }

    /// 1 where the flush paving carries the setts on from the carriageway
    /// edge on `side` at `s` with no edge stones between them, easing to 0
    /// over 2 m across the ends of its `strips` (`pavedVergeStrips`). There
    /// the carriageway's texcoord 1 x runs out to 0.7 at that edge, not 1:
    /// the setts' edge burial and edge dirt (from 0.82 and 0.6) would
    /// otherwise sink its outer setts in soil, a stoneless seam against the
    /// clean paving. Its wheel tracks stay put (the shader takes the half
    /// width as |u| / edge, which only moves them under 1 m half width).
    static func flushPaving(_ art: CourseArt, strips: [(span: CourseArt.Span, side: Double, maxWidth: Double)],
                            s: Double, side: Double) -> Double {
        if art.kerbs.contains(where: { $0.side * side > 0 && $0.span.contains(s) }) { return 0 }
        var w = 0.0
        for strip in strips where strip.side * side > 0 {
            let a = strip.span.lowerBound, b = strip.span.upperBound
            w = max(w, smoothstepD(a - 1, a + 1, s) * (1 - smoothstepD(b - 1, b + 1, s)))
        }
        return w
    }

    /// The setts' texcoord u on a paved strip `offset` metres beyond the
    /// carriageway edge: metres from the strip's middle line (which keeps
    /// to the edge), rising to the right as on the carriageway. It stays
    /// within the shader's neighbour search however wide the strip and
    /// wherever the road widens (`SettStyleTests`).
    static func pavedVergeU(side: Double, offset: Double, maxWidth: Double) -> Double {
        side * (offset - maxWidth / 2)
    }

    /// Courses of the far map a side's paved strips are moved on from the
    /// raised pavements, whose setts they share: the right's land a third
    /// and the left's two thirds of the way from the carriageway's courses
    /// to the pavements' (`WorldMaterials.settCourseOffsets`), so no two of
    /// the four come within about 950 courses (140-160 m of road) of each
    /// other. (A third of the map each would bring the right's within 130
    /// courses of the carriageway's, which keys the far map's joints and
    /// colours the same way.)
    static func pavedVergeCourses(side: Double) -> Int {
        let n = SettFarMap.courses
        let pavements = Int(WorldMaterials.settCourseOffsets[2])
        let own = Int((Double(pavements) * (side > 0 ? 1 : 2) / 3).rounded())
        return ((own - pavements) % n + n) % n
    }

    /// The setts' texcoord v on a paved strip at `s`: moved on by its side's
    /// `pavedVergeCourses` of `depth`, so it lays courses of its own and
    /// shows neither the raised pavements' stones nor the strip's across the
    /// street (`SettStyleTests`).
    static func pavedVergeV(side: Double, s: Double, depth: Float) -> Double {
        s + Double(pavedVergeCourses(side: side)) * Double(depth)
    }

    /// Setts flush with the carriageway out to the house fronts, a little
    /// over the verge mesh: at its stations, on its surface between its
    /// columns (so nothing pokes through), and dropping to it where the
    /// strip ends. Texcoord 0 = (`pavedVergeU`, `pavedVergeV`), texcoord 1
    /// = (edge, mud): clean at the carriageway, grimier towards the walls,
    /// sunk at the foot. Drawn with the pavements' setts.
    private static func buildPavedVerges(corridor: RoadCorridor, stations st: [RoadCorridor.Station], columns: [Double],
                                         into mesh: inout MeshBuffer) {
        let art = corridor.art
        let lift = 0.012
        let depth = art.setts.style.layout.x
        for strip in pavedVergeStrips(art) {
            let side = strip.side
            let n = max(4, Int((strip.maxWidth / 0.6).rounded(.up)))
            var prev: UInt32?
            for s in st where strip.span.contains(s.s) && s.beyond == 0 {
                // The verge mesh's own row here, to lie on (narrower inside
                // a bend, where wider rows would fold over each other).
                let verge = side > 0 ? s.vergeRight : s.vergeLeft
                let width = min(art.pavedVerges.filter { $0.side * side > 0 && $0.span.contains(s.s) }.map(\.width).max() ?? 0,
                                verge - 0.3)
                guard width > 0.1 else { prev = nil; continue }
                let scale = verge / columns.last!
                let edgeLat = side * s.halfWidth
                let edgeY = corridor.roadHeight(s, lateral: edgeLat)
                let skirt = 0.35 * smoothstepD(2, 6, verge)
                let rowY: [Double] = columns.enumerated().map { c, o0 in
                    let p = s.point(lateral: edgeLat + side * o0 * scale)
                    let dtm = Double(corridor.terrain.height(east: p.east, north: p.north))
                    return vergeColumnY(c, of: columns.count, edgeY: edgeY, dtm: dtm, offset: o0 * scale, skirt: skirt)
                }
                func vergeY(_ o: Double) -> Double {
                    let x = o / max(scale, 1e-6)
                    guard let k = columns.firstIndex(where: { $0 >= x }), k > 0 else { return rowY[x <= 0 ? 0 : rowY.count - 1] }
                    let t = (x - columns[k - 1]) / max(columns[k] - columns[k - 1], 1e-9)
                    return rowY[k - 1] + (rowY[k] - rowY[k - 1]) * t
                }
                let mud = Float(art.sunkenWeight(s.s))
                let v = Float(pavedVergeV(side: side, s: s.s, depth: depth))
                let first = UInt32(mesh.vertexCount)
                for k in 0...(n + 1) {
                    // n + 1 columns across the paving, then its foot.
                    let o = k <= n ? width * Double(k) / Double(n) : width + 0.005
                    let y = k == 0 ? edgeY + 0.003 : k <= n ? vergeY(o) + lift : vergeY(width + 0.05) - 0.03
                    let p = s.point(lateral: edgeLat + side * o)
                    let f = Float(min(o, width) / width)
                    let edge: Float = k > n ? 1 : 0.35 + 0.25 * f * f
                    let u = pavedVergeU(side: side, offset: min(o, width), maxWidth: strip.maxWidth)
                    mesh.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(u), v)
                    mesh.texcoord2(edge, mud)
                }
                if let a = prev {
                    // Mirrored on the left, as for the verge.
                    for c in 0..<UInt32(n + 1) {
                        if side > 0 {
                            mesh.quad(a + c, a + c + 1, first + c + 1, first + c)
                        } else {
                            mesh.quad(a + c, first + c, first + c + 1, a + c + 1)
                        }
                    }
                }
                prev = first
            }
        }
        mesh.computeNormals()
    }

    /// Belgian rural markings where the route is on a two-lane asphalt road
    /// at least 6 m wide (the Oude Kwaremont's exit along the N36), the
    /// extension past the finish included: solid edge lines and a 3 m dash
    /// every 12 m down the middle. From 9 m wide the road has red cycle
    /// lanes, 1.3 m, outside the edge lines. Narrower lanes and the
    /// cobbles have none.
    private static func buildMarkings(corridor: RoadCorridor, into mesh: inout MeshBuffer,
                                      cycleLanes lanes: inout MeshBuffer) {
        let lineW = 0.12, lift = 0.006
        func painted(_ s: RoadCorridor.Station) -> Bool {
            s.beyond < 0.95 && s.halfWidth >= 3.0 && s.surface != corridor.cobbleIndex
                && s.surface != corridor.concreteIndex
        }
        func hasLanes(_ s: RoadCorridor.Station) -> Bool { s.halfWidth >= 4.5 }
        func edgeLine(_ s: RoadCorridor.Station) -> Double { s.halfWidth - (hasLanes(s) ? 1.45 : 0.35) }

        /// A strip between two lateral offsets, from station to station.
        func strip(_ into: inout MeshBuffer, from a: (RoadCorridor.Station) -> Double,
                   to b: (RoadCorridor.Station) -> Double, where on: (RoadCorridor.Station) -> Bool, lift: Double) {
            var prev: UInt32?
            for s in corridor.stations {
                guard on(s) else { prev = nil; continue }
                let first = UInt32(into.vertexCount)
                for lat in [a(s), b(s)] {
                    let p = s.point(lateral: lat)
                    let y = corridor.roadHeight(s, lateral: lat) + lift
                    into.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(lat), Float(s.s))
                    // (edge, mud) for the paved shaders the cycle lanes use.
                    into.texcoord2(0.5, 0)
                }
                if let q = prev { into.quad(q, q + 1, first + 1, first) }
                prev = first
            }
        }
        for side in [-1.0, 1.0] {
            // Lines run from smaller to larger lateral offset, so quads face up on both sides.
            if side < 0 {
                strip(&mesh, from: { -edgeLine($0) - lineW / 2 }, to: { -edgeLine($0) + lineW / 2 }, where: painted, lift: lift)
                strip(&lanes, from: { -$0.halfWidth + 0.1 }, to: { -edgeLine($0) - lineW / 2 },
                      where: { painted($0) && hasLanes($0) }, lift: lift * 0.5)
            } else {
                strip(&mesh, from: { edgeLine($0) - lineW / 2 }, to: { edgeLine($0) + lineW / 2 }, where: painted, lift: lift)
                strip(&lanes, from: { edgeLine($0) + lineW / 2 }, to: { $0.halfWidth - 0.1 },
                      where: { painted($0) && hasLanes($0) }, lift: lift * 0.5)
            }
        }
        // Centre dashes at exact positions, whatever the station spacing.
        guard let firstS = corridor.stations.first?.s, let lastS = corridor.stations.last?.s else { return }
        var d = (firstS / 12).rounded(.up) * 12
        while d + 3 <= lastS {
            let a = corridor.station(at: d), b = corridor.station(at: d + 3)
            if painted(a) && painted(b) {
                let first = UInt32(mesh.vertexCount)
                for st in [a, b] {
                    for lat in [-lineW / 2, lineW / 2] {
                        let p = st.point(lateral: lat)
                        let y = corridor.roadHeight(st, lateral: lat) + lift
                        mesh.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(lat), Float(st.s))
                        mesh.texcoord2(0.5, 0)
                    }
                }
                mesh.quad(first, first + 1, first + 3, first + 2)
            }
            d += 12
        }
        mesh.computeNormals()
        lanes.computeNormals()
    }

    /// Side roads draped over the terrain where it is meshed at 1 m, a few
    /// centimetres proud (their material also pulls them towards the camera
    /// so they never fight the ground). Gravel and dirt tracks are left to
    /// the ground textures.
    static func buildSideRoads(corridor: RoadCorridor, scenery: SceneryFile?, reach: Double) -> MeshBuffer {
        var m = MeshBuffer(parts: 2)
        let terrain = corridor.terrain
        // Height of what is drawn there: the main road's verge where it
        // reaches (it sits above a falling DTM near the carriageway, and
        // would otherwise cover the junction), the DTM beyond it.
        func ground(_ e: Double, _ n: Double) -> Double {
            let dtm = Double(terrain.height(east: e, north: n))
            let q = corridor.coarse.query(east: e, north: n)
            guard q.dist < 20 else { return dtm }
            let st = corridor.station(at: q.s)
            let lat = (e - st.east) * st.rightE + (n - st.north) * st.rightN
            let side: Double = lat >= 0 ? 1 : -1
            let o = abs(lat) - st.halfWidth
            guard o < (side > 0 ? st.vergeRight : st.vergeLeft) else { return dtm }
            if o <= 0 { return corridor.roadHeight(st, lateral: lat) }
            let edgeY = corridor.roadHeight(st, lateral: side * st.halfWidth)
            return blendedVerge(edgeY: edgeY, dtm: dtm, offset: o) + 0.02
        }
        for (index, road) in sideRoadSamples(scenery: scenery).enumerated() {
            if Task.isCancelled { break }
            let part = road.part, hw = road.halfWidth, pts = road.points
            var prev: (UInt32, UInt32, UInt32)?
            // The setts are keyed on this distance: each road starts its own
            // courses, so no two show the same stones.
            var along = (Double(index) * 211.7).truncatingRemainder(dividingBy: 2400)
            for i in pts.indices {
                let p = pts[i]
                if i > 0 { along += simd_distance(pts[i - 1], p) }
                let q = corridor.coarse.query(east: p.x, north: p.y)
                // Only near the route (1 m terrain), and off the main road
                // (its extensions past the ends too): up to its edge, so the
                // junction meets the carriageway.
                let onMain = corridor.mainRoadDistance(east: p.x, north: p.y).map { $0.dist < $0.halfWidth + 0.1 } ?? false
                guard q.dist < reach, !onMain else { prev = nil; continue }
                let a = pts[max(i - 1, 0)], b = pts[min(i + 1, pts.count - 1)]
                var d = b - a
                let l = simd_length(d)
                guard l > 1e-6 else { continue }
                d /= l
                let side = SIMD2(d.y, -d.x)
                let pl = p - side * hw, pr = p + side * hw
                let yl = ground(pl.x, pl.y) + 0.04
                let yc = ground(p.x, p.y) + 0.04
                let yr = ground(pr.x, pr.y) + 0.04
                // Left edge, centre, right edge: texcoord 1 = (0 centre .. 1
                // edge, mud), which the setts' edge burial and the wheel
                // tracks read.
                let il = m.vertex(Float(pl.x), Float(yl), Float(-pl.y), 0, 1, 0, Float(-hw), Float(along))
                m.texcoord2(1, 0)
                let ic = m.vertex(Float(p.x), Float(yc), Float(-p.y), 0, 1, 0, 0, Float(along))
                m.texcoord2(0, 0)
                let ir = m.vertex(Float(pr.x), Float(yr), Float(-pr.y), 0, 1, 0, Float(hw), Float(along))
                m.texcoord2(1, 0)
                if let (a0, c0, b0) = prev {
                    m.quad(a0, c0, ic, il, part: part)
                    m.quad(c0, b0, ir, ic, part: part)
                }
                prev = (il, ic, ir)
            }
        }
        m.computeNormals()
        return m
    }

    /// A paved side road from the scenery, resampled at 1 m.
    struct SideRoad {
        var points: [SIMD2<Double>]
        var halfWidth: Double
        /// 0 asphalt, 1 cobbles.
        var part: Int
    }

    /// The scenery's paved roads, as `buildSideRoads` drapes them. Gravel
    /// and dirt tracks are left out (the ground textures carry them).
    static func sideRoadSamples(scenery: SceneryFile?) -> [SideRoad] {
        var out: [SideRoad] = []
        for road in scenery?.roads ?? [] {
            let surf = road.surface ?? "asphalt"
            guard surf == "asphalt" || surf == "cobbles" else { continue }
            let raw = road.points.compactMap { $0.count >= 2 ? SIMD2($0[0], $0[1]) : nil }
            guard raw.count >= 2 else { continue }
            var pts: [SIMD2<Double>] = []
            for i in 0..<(raw.count - 1) {
                let a = raw[i], b = raw[i + 1]
                let n = max(Int(simd_distance(a, b).rounded(.up)), 1)
                for k in 0..<n { pts.append(a + (b - a) * (Double(k) / Double(n))) }
            }
            pts.append(raw[raw.count - 1])
            out.append(SideRoad(points: pts, halfWidth: max((road.widthM ?? 3.5) / 2, 1.2), part: surf == "cobbles" ? 1 : 0))
        }
        return out
    }

    /// Where the side roads are, for keeping plants off them: their 1 m
    /// samples hashed into 2 m cells.
    struct SideRoadMask: Sendable {
        private static let cell = 2.0
        private var cells: [Int64: [SIMD3<Double>]] = [:]
        private var maxHalfWidth = 0.0

        init(scenery: SceneryFile?) {
            for road in RoadBuilder.sideRoadSamples(scenery: scenery) {
                maxHalfWidth = max(maxHalfWidth, road.halfWidth)
                for p in road.points {
                    cells[Self.key(p.x, p.y), default: []].append(SIMD3(p.x, p.y, road.halfWidth))
                }
            }
        }

        private static func key(_ e: Double, _ n: Double) -> Int64 {
            Int64(floor(e / cell)) &* 1_000_003 &+ Int64(floor(n / cell))
        }

        /// True when (east, north) is on a side road, or within `margin` of
        /// its edge.
        func covers(east e: Double, north n: Double, margin: Double = 0.3) -> Bool {
            guard !cells.isEmpty else { return false }
            let reach = maxHalfWidth + margin + 1
            let r = Int(ceil(reach / Self.cell))
            let ci = Int64(floor(e / Self.cell)), cj = Int64(floor(n / Self.cell))
            for di in -r...r {
                for dj in -r...r {
                    guard let pts = cells[(ci + Int64(di)) &* 1_000_003 &+ (cj + Int64(dj))] else { continue }
                    for p in pts {
                        let need = p.z + margin + 0.5  // half the 1 m sample spacing
                        let dx = p.x - e, dy = p.y - n
                        if dx * dx + dy * dy < need * need { return true }
                    }
                }
            }
            return false
        }
    }

    /// Verge height `offset` metres out from the road edge: the LiDAR
    /// ground, eased in from the edge quickly where it rises (banks) and
    /// gently where it falls away (the culvert, embankments).
    @inline(__always)
    static func blendedVerge(edgeY: Double, dtm: Double, offset o: Double) -> Double {
        let diff = dtm - edgeY
        let w = diff > 0 ? smoothstepD(0.08, 0.75, o) : smoothstepD(0.15, 2.6, o)
        return edgeY + diff * w
    }

    /// A point on the verge surface, matching the verge mesh between its
    /// columns closely enough to stand plants on.
    static func vergePoint(_ corridor: RoadCorridor, _ st: RoadCorridor.Station, side: Double,
                           offset o: Double) -> (east: Double, north: Double, y: Double, edgeY: Double) {
        let edgeLat = side * st.halfWidth
        let edgeY = corridor.roadHeight(st, lateral: edgeLat)
        let p = st.point(lateral: edgeLat + side * o)
        let dtm = Double(corridor.terrain.height(east: p.east, north: p.north))
        return (p.east, p.north, blendedVerge(edgeY: edgeY, dtm: dtm, offset: o), edgeY)
    }

    /// Long granite edge stones flush with the cobbles, 2 cm proud, along
    /// the inside of the carriageway edge on the given side.
    private static func buildKerbs(corridor: RoadCorridor, into mesh: inout MeshBuffer) {
        let width = 0.24, proud = 0.02
        for (span, side) in corridor.art.kerbs {
            var prev: UInt32?
            for s in corridor.stations where span.contains(s.s) && s.beyond == 0 {
                let outer = side * s.halfWidth, inner = side * (s.halfWidth - width)
                let yO = corridor.roadHeight(s, lateral: outer) + proud
                let yI = corridor.roadHeight(s, lateral: inner) + proud
                let yBase = corridor.roadHeight(s, lateral: inner) - 0.01
                let po = s.point(lateral: outer - side * 0.005), pi = s.point(lateral: inner)
                // The inner face looks across the road, away from `side`.
                let faceE = Float(-side * s.rightE), faceN = Float(-side * s.rightN)
                let first = UInt32(mesh.vertexCount)
                mesh.vertex(Float(po.east), Float(yO), Float(-po.north), 0, 1, 0, 0, Float(s.s))
                mesh.vertex(Float(pi.east), Float(yI), Float(-pi.north), 0, 1, 0, Float(width), Float(s.s))
                mesh.vertex(Float(pi.east), Float(yBase), Float(-pi.north), faceE, 0, -faceN, Float(width + 0.03), Float(s.s))
                let mud = Float(corridor.art.sunkenWeight(s.s))
                for _ in 0..<3 { mesh.texcoord2(1, mud) }
                if let p = prev {
                    // Mirrored on the right, so the faces stay front-facing.
                    if side < 0 {
                        mesh.quad(p, p + 1, first + 1, first)
                        mesh.quad(p + 1, p + 2, first + 2, first + 1)
                    } else {
                        mesh.quad(p + 1, p, first, first + 1)
                        mesh.quad(p + 2, p + 1, first + 1, first + 2)
                    }
                }
                prev = first
            }
        }
        mesh.computeNormals()
    }

    /// Precast concrete rainwater gutters, 0.6 m wide, along the inside of
    /// the carriageway edge (the Paterberg's left side). The section dips
    /// 1.2 cm to its middle; it sits just proud of the road mesh it covers.
    private static func buildGutters(corridor: RoadCorridor, into mesh: inout MeshBuffer) {
        let width = 0.6
        // Across the gutter from the road edge inwards: fraction of the width, lift above the road.
        let profile: [(f: Double, lift: Double)] = [(0, 0.018), (0.2, 0.011), (0.5, 0.006), (0.8, 0.011), (1, 0.02)]
        let n = UInt32(profile.count)
        for (span, side) in corridor.art.gutters {
            var prev: UInt32?
            for s in corridor.stations where span.contains(s.s) && s.beyond == 0 {
                let first = UInt32(mesh.vertexCount)
                for (f, lift) in profile {
                    let lat = side * (s.halfWidth - f * width)
                    let p = s.point(lateral: lat)
                    let y = corridor.roadHeight(s, lateral: lat) + lift
                    mesh.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(f * width), Float(s.s))
                    mesh.texcoord2(Float(1 - f), Float(corridor.art.sunkenWeight(s.s)))
                }
                // A short face down to the cobbles on the road side.
                let lat = side * (s.halfWidth - width)
                let p = s.point(lateral: lat)
                let faceE = Float(-side * s.rightE), faceN = Float(-side * s.rightN)
                mesh.vertex(Float(p.east), Float(corridor.roadHeight(s, lateral: lat) - 0.01), Float(-p.north),
                            faceE, 0, -faceN, Float(width + 0.03), Float(s.s))
                mesh.texcoord2(0, Float(corridor.art.sunkenWeight(s.s)))
                if let p = prev {
                    for c in 0..<n {
                        // Mirrored on the right, as for the kerbs.
                        if side < 0 {
                            mesh.quad(p + c, p + c + 1, first + c + 1, first + c)
                        } else {
                            mesh.quad(p + c + 1, p + c, first + c, first + c + 1)
                        }
                    }
                }
                prev = first
            }
        }
        mesh.computeNormals()
    }
}
