import Foundation
import simd

/// The Riviera's road paint and edges (look.md section 3 "Road", sections 4
/// and 5): Italian markings on the SP55 and the Via Aurelia below it, the
/// zebras and give-way teeth at the summit, the bus stop's yellow box at
/// the Bivio per Poggio, the fans' writing on the tarmac, the narrow
/// concrete gutters at the wall foot and the concrete kerbs inside the
/// hairpins. Drawn into the same meshes as the Flemish paint, kerbs and
/// gutters; the paint's Riviera shader (`WorldShaders.rivieraPaintSurface`)
/// reads texcoord 1 = (paint kind + edge, wear).
///
/// Positions on the climb are the look bible's, measured from the fork off
/// the Aurelia: route s = `climb.startS` + look s.
extension RoadBuilder {
    enum Paint: Double {
        case white = 0, yellow = 1, red = 2, blue = 3, green = 4
    }

    /// Paint laid on the carriageway at (route distance, lateral) points.
    struct PaintBrush {
        let corridor: RoadCorridor
        var mesh = MeshBuffer()

        init(corridor: RoadCorridor) { self.corridor = corridor }

        /// A vertex on the road surface, `lift` above it.
        mutating func vertex(s: Double, lat: Double, paint: Paint, wear: Double, lift: Double) -> UInt32 {
            let st = corridor.station(at: s)
            let p = st.point(lateral: lat)
            let y = corridor.roadHeight(st, lateral: lat) + lift
            let i = UInt32(mesh.vertexCount)
            mesh.vertex(Float(p.east), Float(y), Float(-p.north), 0, 1, 0, Float(lat), Float(s))
            let edge = min(abs(lat) / max(st.reach(lat < 0 ? -1 : 1), 0.1), 0.999)
            mesh.texcoord2(Float(paint.rawValue + edge), Float(min(max(wear, 0), 1)))
            return i
        }

        /// A triangle given as (s, lateral) corners, either winding.
        mutating func triangle(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>,
                               paint: Paint, wear: Double, lift: Double) {
            // Counter-clockwise with lateral across and s up faces the sky.
            let cross = (b.y - a.y) * (c.x - a.x) - (b.x - a.x) * (c.y - a.y)
            let (q, r) = cross >= 0 ? (b, c) : (c, b)
            let i0 = vertex(s: a.x, lat: a.y, paint: paint, wear: wear, lift: lift)
            let i1 = vertex(s: q.x, lat: q.y, paint: paint, wear: wear, lift: lift)
            let i2 = vertex(s: r.x, lat: r.y, paint: paint, wear: wear, lift: lift)
            mesh.tri(i0, i1, i2)
        }

        /// A quadrilateral of (s, lateral) corners in order round it.
        mutating func quad(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>,
                           paint: Paint, wear: Double, lift: Double) {
            triangle(a, b, c, paint: paint, wear: wear, lift: lift)
            triangle(a, c, d, paint: paint, wear: wear, lift: lift)
        }

        /// A brush stroke along (s, lateral) points, `width` wide, with
        /// square ends half a width long so its joints close.
        mutating func stroke(_ pts: [SIMD2<Double>], width: Double, paint: Paint, wear: Double, lift: Double) {
            guard pts.count > 1 else { return }
            for k in 0..<(pts.count - 1) {
                var a = pts[k], b = pts[k + 1]
                let d = b - a
                let l = (d.x * d.x + d.y * d.y).squareRoot()
                guard l > 1e-4 else { continue }
                let t = d / l, n = SIMD2(-t.y, t.x) * (width / 2)
                a -= t * (width / 2); b += t * (width / 2)
                quad(a - n, a + n, b + n, b - n, paint: paint, wear: wear, lift: lift)
            }
        }

        /// A line between two lateral offsets from `s0` to `s1`, following
        /// the road through every station between.
        mutating func band(from s0: Double, to s1: Double, lat: (RoadCorridor.Station) -> (Double, Double),
                           paint: Paint, wear: Double, lift: Double) {
            guard s1 > s0 else { return }
            let st = corridor.stations
            var ss = [s0]
            var lo = 0, hi = st.count - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if st[mid].s <= s0 { lo = mid } else { hi = mid }
            }
            var k = lo + 1
            while k < st.count, st[k].s < s1 {
                if st[k].s > s0 + 0.02 { ss.append(st[k].s) }
                k += 1
            }
            ss.append(s1)
            var prev: (UInt32, UInt32)?
            for s in ss {
                let (a, b) = lat(corridor.station(at: s))
                let ia = vertex(s: s, lat: min(a, b), paint: paint, wear: wear, lift: lift)
                let ib = vertex(s: s, lat: max(a, b), paint: paint, wear: wear, lift: lift)
                if let (pa, pb) = prev { mesh.quad(pa, pb, ib, ia) }
                prev = (ia, ib)
            }
        }
    }

    // MARK: Markings

    /// Italian markings (Regolamento del Codice della Strada, art. 138-141,
    /// as the photos show them on the SP55):
    /// * continuous white edge lines 12 cm wide on both sides almost
    ///   everywhere, 0.38 m in from the carriageway edge (the look bible:
    ///   0.2-0.5 m from the wall foot, over the gutter), 15 cm and 0.5 m in
    ///   on the 9 m Aurelia; 1 m dashes and gaps across side-road mouths
    ///   (the POV at look s 145); thick (25 cm) and set 0.75 m in round the
    ///   inside of the hairpins (PEZ's hairpin photo);
    /// * a short-dash centre line, 3 m dashes and 4.5 m gaps (urban
    ///   pattern), mostly worn and gone near the hairpins; continuous on the
    ///   Aurelia and into the summit junction;
    /// * zebras before and after the summit corner and give-way teeth across
    ///   the arriving lane (the 2023 POV of the junction);
    /// * the yellow bus-stop zig-zag box with BUS on the Aurelia at the
    ///   Bivio per Poggio, on the sea side;
    /// * the fans' writing (`buildFanWriting`).
    static func buildRivieraMarkings(corridor: RoadCorridor, into mesh: inout MeshBuffer) {
        let st = corridor.stations
        guard st.count > 2 else { return }
        var brush = PaintBrush(corridor: corridor)
        let start = corridor.climb.startS, summit = corridor.climb.endS
        let lineW = 0.12, lift = 0.006
        let (inL, inR) = hairpinWeights(st)
        let hairpins = hairpinApexes(st)

        func painted(_ s: RoadCorridor.Station) -> Bool {
            s.beyond < 0.95 && s.halfWidth >= 1.9 && s.surface != corridor.cobbleIndex
                && s.surface != corridor.concreteIndex && !corridor.art.unmarked.contains { $0.contains(s.s) }
        }
        /// The Aurelia: the route before the fork, less the jog onto the ramp.
        func onAurelia(_ s: Double) -> Bool { s < start - 20 }
        /// Gentle noise along the road, 0...1, for how worn the paint is.
        func noise(_ x: Double, _ salt: Double) -> Double {
            let i = floor(x), f = x - i, u = f * f * (3 - 2 * f)
            return hash(i + salt) * (1 - u) + hash(i + 1 + salt) * u
        }

        // Where the edge line breaks into dashes: side-road mouths, the
        // summit junction's far side (Via Grossi Bianchi carries straight on
        // where the race turns left) and the bus stop.
        var breaks: [(span: ClosedRange<Double>, side: Double)] = corridor.junctions.map {
            (span: ($0.s - $0.width / 2 - 1)...($0.s + $0.width / 2 + 1), side: $0.side)
        }
        breaks.append((span: (summit - 16)...(summit + 14), side: 1))
        let busStop = (start - 41)...(start - 25)
        func broken(_ s: Double, _ side: Double) -> Bool {
            breaks.contains { $0.side == side && $0.span.contains(s) }
        }

        // Edge lines.
        for side in [-1.0, 1.0] {
            let inner = side < 0 ? inL : inR
            func spec(_ i: Int) -> (centre: Double, width: Double)? {
                let s = st[i]
                let aurelia = onAurelia(s.s)
                let h = inner[i]
                let w = (aurelia ? 0.15 : lineW) + (0.25 - lineW) * h
                let inset = (aurelia ? 0.5 : 0.38) + 0.37 * h
                let reach = s.reach(side)
                // Where two legs' tarmac meets (inside a corner tighter
                // than the road is wide) the edge is the middle of a paved
                // junction: no line along it.
                guard reach > s.halfWidth - 0.05, reach - inset - w / 2 > 0.3 else { return nil }
                return (side * (reach - inset), w)
            }
            var prev: (UInt32, UInt32)?
            for i in st.indices {
                let s = st[i]
                guard painted(s), !broken(s.s, side), !(side < 0 && busStop.contains(s.s)),
                      let sp = spec(i) else { prev = nil; continue }
                let wear = 0.1 + 0.22 * noise(s.s / 90, side * 31)
                let lo = sp.centre - sp.width / 2, hi = sp.centre + sp.width / 2
                let ia = brush.vertex(s: s.s, lat: lo, paint: .white, wear: wear, lift: lift)
                let ib = brush.vertex(s: s.s, lat: hi, paint: .white, wear: wear, lift: lift)
                if let (pa, pb) = prev { brush.mesh.quad(pa, pb, ib, ia) }
                prev = (ia, ib)
            }
            // 1 m dashes across the mouths.
            for b in breaks where b.side == side {
                var d = b.span.lowerBound
                while d + 1 <= b.span.upperBound {
                    let a = corridor.station(at: d)
                    if painted(a), a.reach(side) > 1.0 {
                        let wear = 0.15 + 0.2 * noise(d / 90, side * 31)
                        brush.band(from: d, to: d + 1, lat: { x in
                            let c = side * (x.reach(side) - 0.38)
                            return (c - lineW / 2, c + lineW / 2)
                        }, paint: .white, wear: wear, lift: lift)
                    }
                    d += 2
                }
            }
        }

        // Centre line.
        func nearHairpin(_ s: Double) -> Bool { hairpins.contains { abs($0.s - s) < 28 } }
        // The fans paint over the old dashes; a dash through a word or a
        // heart reads as our mistake, not theirs.
        let writing = fanWritingSites(corridor: corridor, hairpins: hairpins)
        func underWriting(_ s: Double) -> Bool { writing.contains { s > $0 - 4 && s < $0 + 46 } }
        if let firstS = st.first?.s, let lastS = st.last?.s {
            // Continuous on the Aurelia, up to 45 m before the fork.
            let aureliaEnd = min(start - 45, lastS)
            if aureliaEnd > firstS {
                brush.band(from: max(firstS, st.first(where: painted)?.s ?? firstS), to: aureliaEnd, lat: { x in
                    painted(x) ? (-0.075, 0.075) : (0, 0)
                }, paint: .white, wear: 0.2, lift: lift)
            }
            // Up the climb the dashes come and go: on about half the
            // straights, from fresh to nearly gone. The sources disagree:
            // the race on 18 March 2023 rides over fresh short dashes on the
            // ridge (look s ~2130), the 30 April 2024 POV (sheets zA-zJ)
            // shows none anywhere, the ramp from the fork included, while
            // its edge lines show plainly.
            let approachFrom = summit - 54, approachTo = summit - 25.5
            var d = ((start + 150) / 7.5).rounded(.up) * 7.5
            while d + 3 <= min(approachFrom, lastS) {
                let a = corridor.station(at: d), b = corridor.station(at: d + 3)
                let n = noise(d / 130, 7)
                if painted(a), painted(b), a.halfWidth >= 2.4, !nearHairpin(d), !underWriting(d), n < 0.55 {
                    brush.band(from: d, to: d + 3, lat: { _ in (-lineW / 2, lineW / 2) },
                               paint: .white, wear: 0.3 + 0.75 * n, lift: lift)
                }
                d += 7.5
            }
            // Into the summit junction, 2 m dashes and gaps, fresher (the komoot
            // photo of the corner with the phone box), stopping short of the
            // zebra.
            d = approachFrom
            while d + 2 <= min(approachTo, lastS) {
                if painted(corridor.station(at: d)) {
                    brush.band(from: d, to: d + 2, lat: { _ in (-lineW / 2, lineW / 2) },
                               paint: .white, wear: 0.22, lift: lift)
                }
                d += 4
            }
        }

        // The summit: zebras either side of the corner, give-way teeth
        // across the arriving lane.
        for (s0, len) in [(summit - 24.0, 3.0), (summit + 13.0, 3.0)] {
            zebra(&brush, from: s0, length: len, lift: lift)
        }
        giveWay(&brush, at: summit - 15.5, lift: lift)
        // The painted ring on the apex (look.md section 3; the komoot
        // photo), out in the wide part: the racing line passes within 2 m of
        // the island's tip.
        ring(&brush, at: summit, lat: 2.6, radius: 1.0, lift: lift)

        // The bus stop on the Aurelia's sea side, at the fork.
        if busStop.lowerBound > (st.first?.s ?? 0) {
            busBox(&brush, span: busStop, lift: lift)
        }

        buildFanWriting(&brush, hairpins: hairpins)
        brush.mesh.computeNormals()
        mesh = brush.mesh
    }

    /// A zebra crossing over the whole carriageway: 0.5 m stripes with 0.5
    /// m gaps, `length` metres along the road.
    private static func zebra(_ brush: inout PaintBrush, from s0: Double, length: Double, lift: Double) {
        let a = brush.corridor.station(at: s0 + length / 2)
        guard a.beyond == 0, asphalt(a, brush.corridor) else { return }
        let l0 = -a.reachLeft + 0.3, l1 = a.reachRight - 0.3
        guard l1 - l0 > 2 else { return }
        let n = Int(((l1 - l0) + 0.5) / 1.0)
        let off = l0 + ((l1 - l0) - (Double(n) - 0.5)) / 2
        for k in 0..<n {
            let c = off + Double(k)
            let wear = 0.08 + 0.15 * hash(Double(k) * 3.7 + s0)
            brush.band(from: s0, to: s0 + length, lat: { _ in (c, c + 0.5) }, paint: .white, wear: wear, lift: lift)
        }
    }

    /// Give-way teeth ("denti di squalo") across the arriving lane: 0.5 m
    /// bases, 0.7 m long, pointing at the oncoming traffic, 0.2 m apart.
    private static func giveWay(_ brush: inout PaintBrush, at s: Double, lift: Double) {
        let a = brush.corridor.station(at: s)
        guard a.beyond == 0, asphalt(a, brush.corridor) else { return }
        var c = 0.25
        while c + 0.5 <= a.reachRight - 0.35 {
            let wear = 0.12 + 0.2 * hash(c * 5.1 + s)
            brush.triangle(SIMD2(s, c), SIMD2(s, c + 0.5), SIMD2(s - 0.7, c + 0.25), paint: .white, wear: wear, lift: lift)
            c += 0.7
        }
    }

    /// A ring of paint `radius` metres round (s, lat), round on the ground
    /// even where the road curves: along the road a metre at lateral `l` is
    /// 1 − κl metres of route.
    private static func ring(_ brush: inout PaintBrush, at s0: Double, lat l0: Double, radius: Double, lift: Double) {
        let a = brush.corridor.station(at: s0)
        guard a.beyond == 0, asphalt(a, brush.corridor) else { return }
        var pts: [SIMD2<Double>] = []
        for k in 0...48 {
            let t = Double(k) / 48 * 2 * .pi
            let l = l0 + radius * sin(t)
            let along = radius * cos(t) / max(1 - a.curvature * l, 0.3)
            pts.append(SIMD2(s0 + along, l))
        }
        brush.stroke(pts, width: 0.12, paint: .white, wear: 0.3, lift: lift)
    }

    /// A bus stop on the left edge (CdS art. 151): a yellow line along the
    /// edge, a zig-zag 2 m out from it with 2 m pitch, closing lines at the
    /// ends and BUS in the middle of the box, where the zig-zag breaks.
    private static func busBox(_ brush: inout PaintBrush, span: ClosedRange<Double>, lift: Double) {
        let mid = brush.corridor.station(at: (span.lowerBound + span.upperBound) / 2)
        guard mid.beyond == 0, asphalt(mid, brush.corridor), mid.reachLeft > 3 else { return }
        let w = 0.12, wear = 0.3
        let edge: (RoadCorridor.Station) -> Double = { -($0.reach(-1) - 0.3) }
        brush.band(from: span.lowerBound, to: span.upperBound, lat: { x in (edge(x) - w / 2, edge(x) + w / 2) },
                   paint: .yellow, wear: wear, lift: lift + 0.001)
        let s0 = span.lowerBound, s1 = span.upperBound, sm = (s0 + s1) / 2
        let e0 = edge(brush.corridor.station(at: s0))
        let word = (sm - 1.25)...(sm + 1.25)
        var runs: [[SIMD2<Double>]] = [[]]
        var s = s0, k = 0
        while s <= s1 + 1e-6 {
            let e = edge(brush.corridor.station(at: s))
            if word.contains(s) {
                if !runs[runs.count - 1].isEmpty { runs.append([]) }
            } else {
                runs[runs.count - 1].append(SIMD2(s, k % 2 == 0 ? e + 2.0 : e + 0.6))
            }
            s += 1; k += 1
        }
        for run in runs { brush.stroke(run, width: w, paint: .yellow, wear: wear, lift: lift + 0.001) }
        let e1 = edge(brush.corridor.station(at: s1))
        brush.stroke([SIMD2(s0, e0), SIMD2(s0, e0 + 2.0)], width: w, paint: .yellow, wear: wear, lift: lift + 0.001)
        brush.stroke([SIMD2(s1, e1), SIMD2(s1, e1 + 2.0)], width: w, paint: .yellow, wear: wear, lift: lift + 0.001)
        // BUS, reading for traffic coming the other way (the stop serves the
        // eastbound lane): letters 1.6 m long, the word 1.5 m across, in the box.
        var rng = SplitMix(seed: 9)
        let em = edge(brush.corridor.station(at: sm))
        letters("BUS", &brush, centreS: sm, centreLat: em + 1.05, height: 1.6, width: 0.42,
                facing: -1, paint: .yellow, wear: wear, stroke: 0.12, wobble: 0, rng: &rng, lift: lift + 0.001)
    }

    // MARK: Hairpins

    /// Per station, how much each side is the inside of a hairpin: 1 where
    /// the road turns on under 14 m radius towards that side, easing out
    /// over 30 m radius, held 8 m either side, then averaged over 5 m
    /// either side so the thick inside line widens and steps in over about
    /// 10 m (the Poggio's curvature comes on within a metre or two, and the
    /// line jogged sideways there; seen from above at hairpins 1 and 3).
    static func hairpinWeights(_ st: [RoadCorridor.Station]) -> (left: [Double], right: [Double]) {
        let n = st.count
        var rawL = [Double](repeating: 0, count: n), rawR = rawL
        for i in 0..<n {
            let k = st[i].curvature
            rawR[i] = smoothstepD(1.0 / 30, 1.0 / 14, k)
            rawL[i] = smoothstepD(1.0 / 30, 1.0 / 14, -k)
        }
        func held(_ raw: [Double]) -> [Double] {
            var out = raw
            var lo = 0
            for i in 0..<n {
                while st[i].s - st[lo].s > 8 { lo += 1 }
                var hi = i, m = 0.0
                for j in lo...i { m = max(m, raw[j]) }
                while hi + 1 < n, st[hi + 1].s - st[i].s <= 8 { hi += 1; m = max(m, raw[hi]) }
                out[i] = m
            }
            return out
        }
        func eased(_ w: [Double]) -> [Double] {
            var out = w
            var lo = 0, hi = 0, acc = 0.0
            for i in 0..<n {
                while hi < n, st[hi].s - st[i].s <= 5 { acc += w[hi]; hi += 1 }
                while st[i].s - st[lo].s > 5 { acc -= w[lo]; lo += 1 }
                out[i] = min(max(acc / Double(hi - lo), 0), 1)
            }
            return out
        }
        return (eased(held(rawL)), eased(held(rawR)))
    }

    /// The hairpins: where the road turns more than 100° within 25 m either
    /// side of a bend tighter than 12 m radius. Route distance of the apex
    /// and the side the road turns to.
    static func hairpinApexes(_ st: [RoadCorridor.Station]) -> [(s: Double, side: Double)] {
        var out: [(s: Double, side: Double)] = []
        func heading(_ x: RoadCorridor.Station) -> Double { atan2(x.dirE, x.dirN) }
        var i = 0
        while i < st.count {
            guard abs(st[i].curvature) > 1.0 / 12, st[i].beyond == 0 else { i += 1; continue }
            // The tightest station of this bend.
            var j = i, best = i
            while j < st.count, abs(st[j].curvature) > 1.0 / 12 {
                if abs(st[j].curvature) > abs(st[best].curvature) { best = j }
                j += 1
            }
            var a = best, b = best
            while a > 0, st[best].s - st[a].s < 25 { a -= 1 }
            while b < st.count - 1, st[b].s - st[best].s < 25 { b += 1 }
            var turn = 0.0
            for k in a..<b {
                var d = heading(st[k + 1]) - heading(st[k])
                while d > .pi { d -= 2 * .pi }
                while d < -.pi { d += 2 * .pi }
                turn += d
            }
            if abs(turn) > 100 * .pi / 180 {
                out.append((st[best].s, st[best].curvature > 0 ? 1 : -1))
            }
            i = j
        }
        return out
    }

    // MARK: Gutters and kerbs

    /// How far the paving runs on past the carriageway edge: to the face of
    /// a wall at the edge (`RoadCorridor.edgeAprons`) and 12 cm on under it,
    /// since a battered or sprayed face leans back from its foot line and
    /// would show the verge's first strip at road level; never past the
    /// verge's cut between two legs. 0 off the Riviera.
    static func apronWidth(_ aprons: RoadCorridor.EdgeAprons, _ s: RoadCorridor.Station, side: Double) -> Double {
        let a = aprons.width(s.s, side: side)
        guard a > 0 else { return 0 }
        return max(0, min(a + 0.12, side > 0 ? s.vergeRight : s.vergeLeft))
    }

    /// The tarmac from the carriageway edge on to the face of a wall at the
    /// edge (`apronWidth`; the verge starts there), in the carriageway's
    /// own vertex layout: texcoord 0 (lateral, route distance),
    /// texcoord 1 (lateral over the reach, past 1 here, so no lane oil or
    /// tyre tracks; no mud). Easing to nothing at its ends. On the uphill
    /// side the concrete gutter covers it (`buildRivieraEdges`).
    static func buildRivieraAprons(corridor: RoadCorridor, stations st: [RoadCorridor.Station],
                                   aprons: RoadCorridor.EdgeAprons, into mesh: inout MeshBuffer) {
        guard st.count > 1, !aprons.isEmpty else { return }
        for side in [-1.0, 1.0] {
            let w = st.map { s -> Double in
                guard s.beyond == 0, asphalt(s, corridor) else { return 0 }
                return apronWidth(aprons, s, side: side)
            }
            var prev: UInt32?
            for k in st.indices {
                let wPrev = k > 0 ? w[k - 1] : 0, wNext = k + 1 < st.count ? w[k + 1] : 0
                guard w[k] > 0 || wPrev > 0 || wNext > 0 else { prev = nil; continue }
                let s = st[k]
                let reach = s.reach(side)
                let first = UInt32(mesh.vertexCount)
                // Left to right across the road, as the carriageway's rows.
                for o in side < 0 ? [w[k], 0] : [0, w[k]] {
                    let lat = side * (reach + o)
                    let p = s.point(lateral: lat)
                    mesh.vertex(Float(p.east), Float(corridor.roadHeight(s, lateral: lat)), Float(-p.north), 0, 1, 0,
                                Float(lat), Float(s.s))
                    mesh.texcoord2(Float(1 + o / max(reach, 0.5)), 0)
                }
                if let a = prev, w[k] > 0 || wPrev > 0 { mesh.quad(a, a + 1, first + 1, first) }
                prev = first
            }
        }
    }

    /// The SP55's edges: a narrow concrete gutter (#8f877b, 0.28 m) inside
    /// the carriageway edge wherever the ground rises beyond it (the wall
    /// foot on the uphill side, a cutting), and raised concrete kerbs, 12 cm
    /// high and 15 cm wide, round the inside of the hairpins (look.md:
    /// "mostly no raised kerb ... concrete kerbs at ... hairpin insides").
    /// None on the Aurelia, the side-road mouths or past the route's ends.
    static func buildRivieraEdges(corridor: RoadCorridor, aprons: RoadCorridor.EdgeAprons = .none,
                                  gutter: inout MeshBuffer, kerb: inout MeshBuffer) {
        let st = corridor.stations
        guard st.count > 2 else { return }
        let (inL, inR) = hairpinWeights(st)
        let start = corridor.climb.startS, summit = corridor.climb.endS
        func onRoad(_ s: RoadCorridor.Station) -> Bool {
            s.beyond == 0 && s.s > start - 8 && s.s < summit + 400 && s.surface != corridor.cobbleIndex
        }
        func mouth(_ s: Double, _ side: Double) -> Bool {
            corridor.junctions.contains { $0.side == side && abs($0.s - s) < $0.width / 2 + 0.5 }
        }
        let gutterW = 0.28
        let profile: [(f: Double, lift: Double)] = [(0, 0.016), (0.2, 0.01), (0.5, 0.005), (0.8, 0.01), (1, 0.017)]
        for side in [-1.0, 1.0] {
            let inner = side < 0 ? inL : inR
            // Ground rise 1.5 m beyond the edge, averaged over 8 m either way.
            var rise = st.map { s -> Double in
                let edge = side * s.reach(side)
                let p = s.point(lateral: edge + side * 1.5)
                return Double(corridor.terrain.height(east: p.east, north: p.north)) - corridor.roadHeight(s, lateral: edge)
            }
            var lo = 0, hi = 0, acc = 0.0
            var smooth = rise
            for i in st.indices {
                while hi < st.count, st[hi].s - st[i].s <= 8 { acc += rise[hi]; hi += 1 }
                while st[i].s - st[lo].s > 8 { acc -= rise[lo]; lo += 1 }
                smooth[i] = acc / Double(hi - lo)
            }
            rise = smooth

            // Gutter.
            var prev: UInt32?
            for (i, s) in st.enumerated() {
                guard onRoad(s), rise[i] > 0.6, inner[i] < 0.5, !mouth(s.s, side), s.reach(side) > s.halfWidth - 0.05 else {
                    prev = nil; continue
                }
                let first = UInt32(gutter.vertexCount)
                let reach = s.reach(side)
                // On to the face of a wall at the edge (none: on the edge).
                let apron = apronWidth(aprons, s, side: side)
                let out = s.point(lateral: side * (reach + apron))
                gutter.vertex(Float(out.east), Float(corridor.roadHeight(s, lateral: side * (reach + apron)) + 0.018),
                              Float(-out.north), 0, 1, 0, Float(-apron), Float(s.s))
                gutter.texcoord2(1, 0)
                for (f, lift) in profile {
                    let lat = side * (reach - f * gutterW)
                    let p = s.point(lateral: lat)
                    gutter.vertex(Float(p.east), Float(corridor.roadHeight(s, lateral: lat) + lift), Float(-p.north),
                                  0, 1, 0, Float(f * gutterW), Float(s.s))
                    gutter.texcoord2(Float(1 - f), 0)
                }
                let lat = side * (reach - gutterW)
                let p = s.point(lateral: lat)
                let faceE = Float(-side * s.rightE), faceN = Float(-side * s.rightN)
                gutter.vertex(Float(p.east), Float(corridor.roadHeight(s, lateral: lat) - 0.01), Float(-p.north),
                              faceE, 0, -faceN, Float(gutterW + 0.03), Float(s.s))
                gutter.texcoord2(0, 0)
                if let a = prev {
                    for c in 0..<UInt32(profile.count + 1) {
                        // Mirrored on the right, as `buildGutters`.
                        if side < 0 {
                            gutter.quad(a + c, a + c + 1, first + c + 1, first + c)
                        } else {
                            gutter.quad(a + c + 1, a + c, first + c, first + c + 1)
                        }
                    }
                }
                prev = first
            }

            // Kerb round a hairpin's inside: its face to the road, its top,
            // and its back down to the verge.
            let kerbW = 0.15, kerbH = 0.12
            var prevK: UInt32?
            for (i, s) in st.enumerated() {
                guard onRoad(s), inner[i] > 0.5, s.reach(side) > s.halfWidth - 0.05 else { prevK = nil; continue }
                let reach = s.reach(side)
                let y0 = corridor.roadHeight(s, lateral: side * (reach - kerbW))
                let y1 = corridor.roadHeight(s, lateral: side * reach)
                // Its top on to the face of a wall at the edge.
                let apron = apronWidth(aprons, s, side: side)
                let cols: [(lat: Double, y: Double, u: Double)] = [
                    (reach - kerbW, y0 - 0.01, 0), (reach - kerbW + 0.01, y0 + kerbH, kerbH),
                    (reach + apron - 0.01, y1 + kerbH, kerbH + kerbW + apron),
                    (reach + apron + 0.005, y1 - 0.03, 2 * kerbH + kerbW + apron),
                ]
                let first = UInt32(kerb.vertexCount)
                for c in cols {
                    let p = s.point(lateral: side * c.lat)
                    kerb.vertex(Float(p.east), Float(c.y), Float(-p.north), 0, 1, 0, Float(c.u), Float(s.s))
                    kerb.texcoord2(1, 0)
                }
                if let a = prevK {
                    for c in 0..<UInt32(cols.count - 1) {
                        if side > 0 {
                            kerb.quad(a + c, a + c + 1, first + c + 1, first + c)
                        } else {
                            kerb.quad(a + c, first + c, first + c + 1, a + c + 1)
                        }
                    }
                }
                prevK = first
            }
        }
        gutter.computeNormals()
        kerb.computeNormals()
    }

    // MARK: Fans' writing

    /// What the fans paint: encouragement and riders' names in capitals,
    /// mostly white, now and then in colour (look.md: "VAI", rider names,
    /// squiggles; repainted every year).
    private static let fanWords = ["VAI", "DAI", "FORZA", "ALLEZ", "VAI VAI", "TADEJ", "POGI", "MATHIEU",
                                   "PIPPO", "GANNA", "MILAN", "SLO", "W", "BRAVI", "GO"]

    /// Where the fans write: look s 900, 1430 and 3300 (POV 2023 and 2024)
    /// and just past each hairpin. Each site's words and squiggles run
    /// about 40 m on up the road from it.
    static func fanWritingSites(corridor: RoadCorridor, hairpins: [(s: Double, side: Double)]) -> [Double] {
        let start = corridor.climb.startS, summit = corridor.climb.endS
        var sites: [Double] = [900, 1430, 3300].map { start + $0 }
        sites += hairpins.filter { $0.s > start && $0.s < summit - 30 }.map { $0.s + 16 }
        #if DEBUG
        // -roadWritingAt 250,400: writing at those route distances too, to
        // judge it on a familiar road.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-roadWritingAt"), i + 1 < args.count {
            sites += args[i + 1].split(separator: ",").compactMap { Double($0) }
        }
        #endif
        return sites
    }

    /// The fans' writing (`fanWritingSites`): a few words and squiggles at
    /// each site, in letters 0.5-1.5 m tall, brush-stroked by hand.
    static func buildFanWriting(_ brush: inout PaintBrush, hairpins: [(s: Double, side: Double)]) {
        let corridor = brush.corridor
        let sites = fanWritingSites(corridor: corridor, hairpins: hairpins)
        for (n, site) in sites.enumerated() {
            var rng = SplitMix(seed: UInt64(max(site, 0).rounded()) &* 2654435761 &+ UInt64(n))
            let count = 2 + rng.int(3)
            var s = site
            for _ in 0..<count {
                let a = corridor.station(at: s)
                guard a.beyond == 0, asphalt(a, corridor), a.reachLeft > 1.6, a.reachRight > 1.6 else {
                    s += 9; continue
                }
                let paint: Paint = {
                    let r = rng.unit()
                    return r < 0.66 ? .white : r < 0.76 ? .yellow : r < 0.84 ? .red : r < 0.92 ? .blue : .green
                }()
                let wear = 0.04 + 0.25 * rng.unit()
                let room = (lo: -a.reachLeft + 0.55, hi: a.reachRight - 0.55)
                if rng.unit() < 0.3 {
                    squiggle(&brush, at: s, room: room, paint: paint, wear: wear, rng: &rng)
                    s += 4 + 6 * rng.unit()
                } else {
                    let word = fanWords[rng.int(fanWords.count)]
                    let height = 0.8 + 0.7 * rng.unit()
                    // Across one lane or the whole road.
                    let lane = rng.unit()
                    let span: (Double, Double) = word.count > 4 || lane < 0.3 ? room
                        : lane < 0.65 ? (0.2, room.hi) : (room.lo, -0.2)
                    let letterW = min(0.42 * height + 0.1, (span.1 - span.0) / (Double(word.count) * 1.32))
                    letters(word, &brush, centreS: s + height / 2, centreLat: (span.0 + span.1) / 2, height: height,
                            width: letterW, facing: 1, paint: paint, wear: wear,
                            stroke: 0.09 + 0.06 * rng.unit(), wobble: 0.035, rng: &rng, lift: 0.008)
                    s += height + 3 + 7 * rng.unit()
                }
            }
        }
    }

    /// A word in single-stroke capitals centred on (`centreS`,
    /// `centreLat`), letters `height` long along the road and `width`
    /// across it, reading for traffic going up the route (`facing` 1) or
    /// coming down it (−1). `wobble` jitters the strokes by hand.
    static func letters(_ word: String, _ brush: inout PaintBrush, centreS: Double, centreLat: Double,
                        height: Double, width: Double, facing: Double, paint: Paint, wear: Double,
                        stroke: Double, wobble: Double, rng: inout SplitMix, lift: Double) {
        let pitch = width * 1.3
        let total = pitch * Double(word.count - 1) + width
        // Painted on a bend, the letters keep their shape on the ground: a
        // metre along the road at lateral `l` is 1 − κl metres of route
        // (as `ring`), else a word just past a hairpin's apex squashes by a
        // third towards the inside.
        let kappa = brush.corridor.station(at: centreS).curvature
        var x0 = -total / 2
        for ch in word {
            defer { x0 += pitch }
            guard let glyph = strokeFont[ch] else { continue }
            let slant = wobble > 0 ? (rng.unit() - 0.5) * 0.18 : 0
            let grow = wobble > 0 ? 0.92 + 0.16 * rng.unit() : 1
            for line in glyph {
                let pts: [SIMD2<Double>] = line.map { g in
                    // Glyphs are 4 wide and 6 tall, y up the letter.
                    let x = x0 + g.x / 4 * width * grow + slant * g.y / 6 * height
                    let y = (g.y / 6 - 0.5) * height * grow
                    let jx = wobble * (rng.unit() - 0.5) * 2, jy = wobble * (rng.unit() - 0.5) * 2
                    // Up the letter is along the road towards the reader's
                    // travel; its right is the reader's right.
                    let lat = centreLat + facing * (x + jx)
                    return SIMD2(centreS + facing * (y + jy) / max(1 - kappa * lat, 0.3), lat)
                }
                brush.stroke(pts, width: stroke, paint: paint, wear: wear, lift: lift)
            }
        }
    }

    /// A loose squiggle across the lane: a wave, a loop or a heart.
    private static func squiggle(_ brush: inout PaintBrush, at s: Double, room: (lo: Double, hi: Double),
                                 paint: Paint, wear: Double, rng: inout SplitMix) {
        var pts: [SIMD2<Double>] = []
        let kind = rng.int(3)
        let c = (room.lo + room.hi) / 2 + (rng.unit() - 0.5) * (room.hi - room.lo) * 0.3
        switch kind {
        case 0:
            // A wave across, 2-3 m wide.
            let w = min(2 + rng.unit(), room.hi - room.lo), amp = 0.25 + 0.3 * rng.unit()
            let waves = 1.5 + 1.5 * rng.unit()
            for k in 0...40 {
                let t = Double(k) / 40
                pts.append(SIMD2(s + amp * sin(t * waves * 2 * .pi), c - w / 2 + w * t))
            }
        case 1:
            // A loop, 0.9-1.4 m, not quite closed.
            let r = 0.45 + 0.25 * rng.unit()
            for k in 0...36 {
                let t = Double(k) / 36 * 2.15 * .pi
                pts.append(SIMD2(s + r + r * 1.25 * sin(t), c + r * cos(t)))
            }
        default:
            // A heart, point down the road.
            let r = 0.35 + 0.2 * rng.unit()
            for k in 0...48 {
                let t = Double(k) / 48 * 2 * .pi
                let x = 16 * pow(sin(t), 3)
                let y = 13 * cos(t) - 5 * cos(2 * t) - 2 * cos(3 * t) - cos(4 * t)
                pts.append(SIMD2(s + r * 1.2 + y / 16 * r * 1.2, c + x / 16 * r))
            }
        }
        let jitter = pts.map { $0 + SIMD2((rng.unit() - 0.5) * 0.04, (rng.unit() - 0.5) * 0.04) }
        brush.stroke(jitter, width: 0.1 + 0.05 * rng.unit(), paint: paint, wear: wear, lift: 0.008)
    }

    /// Single-stroke capitals (drawn for this, not traced from any face):
    /// each letter a list of polylines on a 4 x 6 grid, y up.
    static let strokeFont: [Character: [[SIMD2<Double>]]] = {
        func p(_ v: [Double]) -> [SIMD2<Double>] {
            stride(from: 0, to: v.count - 1, by: 2).map { SIMD2(v[$0], v[$0 + 1]) }
        }
        let o: [Double] = [1, 0, 0, 1.5, 0, 4.5, 1, 6, 3, 6, 4, 4.5, 4, 1.5, 3, 0, 1, 0]
        let c: [Double] = [4, 5, 3, 6, 1, 6, 0, 4.5, 0, 1.5, 1, 0, 3, 0, 4, 1]
        let pBowl: [Double] = [0, 0, 0, 6, 3, 6, 4, 5, 4, 3.8, 3, 2.8, 0, 2.8]
        return [
            "A": [p([0, 0, 2, 6, 4, 0]), p([0.8, 2.4, 3.2, 2.4])],
            "B": [p([0, 0, 0, 6, 2.8, 6, 3.6, 5.2, 3.6, 3.8, 2.8, 3, 0, 3]), p([2.8, 3, 3.8, 2.2, 3.8, 0.8, 3, 0, 0, 0])],
            "C": [p(c)],
            "D": [p([0, 0, 0, 6, 2, 6, 3.6, 4.6, 4, 3, 3.6, 1.4, 2, 0, 0, 0])],
            "E": [p([4, 6, 0, 6, 0, 0, 4, 0]), p([0, 3, 3, 3])],
            "F": [p([4, 6, 0, 6, 0, 0]), p([0, 3, 3, 3])],
            "G": [p(Array(c.dropLast(2)) + [4, 1, 4, 2.8, 2.4, 2.8])],
            "H": [p([0, 0, 0, 6]), p([4, 0, 4, 6]), p([0, 3, 4, 3])],
            "I": [p([2, 0, 2, 6])],
            "J": [p([4, 6, 4, 1.5, 3, 0, 1, 0, 0, 1.5])],
            "K": [p([0, 0, 0, 6]), p([4, 6, 0, 2.4]), p([1.3, 3.4, 4, 0])],
            "L": [p([0, 6, 0, 0, 4, 0])],
            "M": [p([0, 0, 0, 6, 2, 2.5, 4, 6, 4, 0])],
            "N": [p([0, 0, 0, 6, 4, 0, 4, 6])],
            "O": [p(o)],
            "P": [p(pBowl)],
            "Q": [p(o), p([2.6, 1.4, 4.2, -0.4])],
            "R": [p(pBowl), p([2.2, 2.8, 4, 0])],
            "S": [p([4, 5, 3, 6, 1, 6, 0, 5, 0, 4, 1, 3.2, 3, 2.8, 4, 2, 4, 1, 3, 0, 1, 0, 0, 1])],
            "T": [p([0, 6, 4, 6]), p([2, 6, 2, 0])],
            "U": [p([0, 6, 0, 1.5, 1, 0, 3, 0, 4, 1.5, 4, 6])],
            "V": [p([0, 6, 2, 0, 4, 6])],
            "W": [p([0, 6, 1, 0, 2, 4, 3, 0, 4, 6])],
            "X": [p([0, 0, 4, 6]), p([0, 6, 4, 0])],
            "Y": [p([0, 6, 2, 3, 4, 6]), p([2, 3, 2, 0])],
            "Z": [p([0, 6, 4, 6, 0, 0, 4, 0])],
            "!": [p([2, 6, 2, 1.8]), p([2, 0.5, 2, 0])],
        ]
    }()

    /// A small seeded generator (SplitMix64), so the writing is the same on
    /// every build.
    struct SplitMix {
        var state: UInt64
        init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    /// One of the Poggio's lanes and driveways, draped as `buildSideRoads`
    /// drapes the Flemish ones (heights from its `ground`), with what the
    /// CTR's and OSM's lines leave out:
    /// - kinks eased round over about 3 m (`eased`);
    /// - never on the carriageway: each cross-section is clipped at its edge
    ///   (laid 5 cm on to it, short of the edge line). The SS1 west of the
    ///   fork (scenery "Corso Giuseppe Mazzini", 7 m) leaves the climb at a
    ///   few degrees, and only its samples whose centre was on the road were
    ///   dropped: from route 304 to 315 its ribbon lay up to 3 m over the
    ///   climb's left lane, a straight seam and an end cap across the lane in
    ///   the first frames of the ride. 31 other lanes poked a corner
    ///   0.05-1.7 m in at their mouths (fix2-road/tools/overlap.py);
    /// - a lane leaving the road at a shallow angle starts where its edge
    ///   leaves the carriageway, not where its centre line does (that left a
    ///   square end with grass beside the fork), and the gore between the two
    ///   is paved where it is level and under 1.5 m wide, closing by 2.1 m.
    ///   POV f0 (route 300): the SS1's tarmac runs on past the climb's left
    ///   edge line to a low wall, with no grass between; the 2022 ortho has
    ///   the 1900 driveway (roads[192]) as a pale strip along the right edge;
    /// - a mouth on the carriageway's edge, not a square end up to a metre
    ///   short of it with the verge between: a cross-section where the centre
    ///   line meets the edge (or the lane's line carried on to it, up to 3 m,
    ///   where the map stops short), flared where the lane meets the road at
    ///   an angle (a 2 m fillet each side, draped on the verge);
    /// - not on banks: samples with > 30 % cross-fall or > 35 % grade are left
    ///   to the ground (draped, they hung down the bank as a ribbon), and the
    ///   tarmac narrows to about two fifths over its last 3 m before such a
    ///   cut, so it does not end square on the grass.
    /// Texcoord 1 = (edge, half width in metres; 0 on the setts, whose y is
    /// mud): edge 1 at the lane's own edges, where
    /// `WorldShaders.rivieraSideAsphaltSurface` frays it into the verge, and
    /// 0 where it meets the carriageway.
    static func appendRivieraSideRoad(_ road: SideRoad, index: Int, corridor: RoadCorridor, reach: Double,
                                      ground: (Double, Double) -> Double, into m: inout MeshBuffer) {
        // Consecutive duplicates would leave a sample without a direction.
        var pts: [SIMD2<Double>] = []
        for p in eased(road.points) where pts.last.map({ simd_distance($0, p) > 1e-3 }) ?? true { pts.append(p) }
        let n = pts.count
        guard n >= 2 else { return }
        let hw = road.halfWidth, part = road.part
        // `keep`: the lane's tarmac runs 5 cm on to the carriageway's edge
        // (well short of the edge line), so no sliver of verge shows
        // between the two at a grazing angle.
        let flareR = 2.0, keep = -0.05, goreFull = 1.5, goreMax = 2.1
        /// Clearance from the carriageway's edge (negative on it).
        func clear(_ p: SIMD2<Double>) -> Double {
            corridor.mainRoadDistance(east: p.x, north: p.y).map { $0.dist - $0.halfWidth } ?? .infinity
        }
        func direction(_ i: Int) -> SIMD2<Double> {
            simd_normalize(pts[min(i + 1, n - 1)] - pts[max(i - 1, 0)])
        }
        /// The point between `a` (clear) and `b` (on the road, or nearer it)
        /// where the clearance is `keep`.
        func edgePoint(_ a: SIMD2<Double>, _ b: SIMD2<Double>) -> SIMD2<Double> {
            var lo = 0.0, hi = 1.0
            for _ in 0..<10 {
                let t = (lo + hi) / 2
                if clear(a + (b - a) * t) < keep { hi = t } else { lo = t }
            }
            return a + (b - a) * lo
        }

        enum Kind { case away, main, partial, steep, kept }
        var kind = [Kind](repeating: .away, count: n)
        var prevY: Double?
        for i in 0..<n {
            let p = pts[i]
            guard corridor.coarse.query(east: p.x, north: p.y).dist < reach else { prevY = nil; continue }
            let d = direction(i), side = SIMD2(d.y, -d.x)
            guard clear(p) >= 0.1 else {
                // On the carriageway: drawn only where an edge is off it.
                kind[i] = max(clear(p - side * hw), clear(p + side * hw)) > 0.1 ? .partial : .main
                prevY = nil
                continue
            }
            let yl = ground(p.x - side.x * hw, p.y - side.y * hw)
            let yc = ground(p.x, p.y)
            let yr = ground(p.x + side.x * hw, p.y + side.y * hw)
            let steep = abs(yl - yr) > 0.6 * hw || prevY.map { abs(yc - $0) > 0.35 } ?? false
            prevY = yc
            kind[i] = steep ? .steep : .kept
        }

        // Along-road distance of each sample from the polyline's start.
        var at = [Double](repeating: 0, count: n)
        for i in 1..<n { at[i] = at[i - 1] + simd_distance(pts[i - 1], pts[i]) }
        let along0 = (Double(index) * 211.7).truncatingRemainder(dividingBy: 2400)

        /// Offsets in from a half's end (the first 0) for its columns
        /// before the middle: as many for every section of the lane.
        func columnOffsets(half: Double) -> [Double] {
            let base = hw > 2.5 ? [0.6, 1.4] : [0.6]
            var out = [0.0]
            for (k, b) in base.enumerated() { out.append(min(b, half * Double(k + 1) / Double(base.count + 1))) }
            return out
        }
        var prev: [UInt32]?
        /// A cross-section at `p`, heading `d`, out to `width` each side;
        /// none, and the strip broken, where no part of it is off the road.
        func section(_ p: SIMD2<Double>, _ d: SIMD2<Double>, along: Double, width: Double) {
            let side = SIMD2(d.y, -d.x)
            let c = clear(p)
            let st = corridor.station(at: corridor.coarse.query(east: p.x, north: p.y).s)
            let sinA = abs(d.x * st.dirN - d.y * st.dirE)
            var w = width
            if c >= keep, c < flareR {
                let u = 1 - max(c, 0) / flareR
                w += flareR * (1 - (1 - u * u).squareRoot()) * smoothstepD(0.35, 0.7, sinA)
            }
            // The two ends: lateral along `side`, and edge (1 the lane's own).
            var ends: [(lat: Double, edge: Double)] = []
            if c >= keep {
                for sgn in [-1.0, 1.0] {
                    let e = p + side * (sgn * w)
                    if clear(e) < keep {
                        ends.append((sgn * simd_distance(p, edgePoint(p, e)), 0))
                        continue
                    }
                    // A narrow, level gore to the carriageway beyond this
                    // edge, where the lane runs beside the road.
                    var end = (lat: sgn * w, edge: 1.0)
                    let far = p + side * (sgn * (w + goreMax))
                    if sinA < 0.5, clear(far) < keep {
                        let q = edgePoint(e, far)
                        let gap = simd_distance(e, q)
                        if abs(ground(q.x, q.y) - ground(e.x, e.y)) < 0.4 {
                            let fill = 1 - smoothstepD(goreFull, goreMax, gap)
                            end = (sgn * (w + gap * fill), 1 - fill)
                        }
                    }
                    ends.append(end)
                }
            } else {
                // The centre on the carriageway: from its edge out to the
                // lane's edge that is off it.
                let sgn: Double = clear(p + side * w) >= clear(p - side * w) ? 1 : -1
                let e = p + side * (sgn * w)
                guard clear(e) >= keep else { prev = nil; return }
                let inner = sgn * (w - simd_distance(e, edgePoint(e, p)))
                ends = sgn > 0 ? [(inner, 0), (w, 1)] : [(-w, 1), (inner, 0)]
            }
            let l = ends[0], r = ends[1], mid = (l.lat + r.lat) / 2
            // The middle's edge from its distance to the nearer own edge, so
            // the fray is as wide in metres on a clipped lane.
            let midEdge = max(0, l.edge * (1 - (mid - l.lat) / w), r.edge * (1 - (r.lat - mid) / w))
            func vertex(_ lat: Double, _ edge: Double) -> UInt32 {
                let q = p + side * lat
                let v = m.vertex(Float(q.x), Float(ground(q.x, q.y) + 0.04), Float(-q.y), 0, 1, 0,
                                 Float(lat), Float(along))
                m.texcoord2(Float(edge), part == 0 ? Float(w) : 0)
                return v
            }
            // Columns 0.6 m (and 1.4 m on a wide road) in from each end,
            // closer where the half is short: the verge rises or falls to
            // the ground within 0.08-0.75 m of the carriageway, and with
            // only the ends and the middle the lane's flat triangles dipped
            // under it there (green slivers along the SS1 at the fork).
            var row: [UInt32] = []
            for (k, f) in columnOffsets(half: mid - l.lat).enumerated() {
                let lat = l.lat + f, t = f / max(mid - l.lat, 1e-6)
                if k == 0 { row.append(vertex(lat, l.edge)) } else { row.append(vertex(lat, l.edge + (midEdge - l.edge) * t)) }
            }
            row.append(vertex(mid, midEdge))
            for f in columnOffsets(half: r.lat - mid).reversed() {
                let t = f / max(r.lat - mid, 1e-6)
                row.append(vertex(r.lat - f, r.edge + (midEdge - r.edge) * t))
            }
            if let a = prev, a.count == row.count {
                for k in 0..<(row.count - 1) { m.quad(a[k], a[k + 1], row[k + 1], row[k], part: part) }
            }
            prev = row
        }
        /// A lane that leaves (or joins) at a shallow angle where the map's
        /// line starts on the carriageway: carried back along its heading,
        /// narrowing to nothing over 8 m, so its edge leaves the road's
        /// edge as a taper, not a square end.
        func taper(from p: SIMD2<Double>, _ d: SIMD2<Double>, along: Double, back: Bool) {
            for t in back ? Array(stride(from: 8.0, through: 1, by: -1)) : Array(stride(from: 1.0, through: 8, by: 1)) {
                let sgn: Double = back ? -1 : 1
                section(p + d * (sgn * t), d, along: along + sgn * t, width: hw * (1 - t / 8.5))
            }
        }

        /// A mouth at `p` on the carriageway's edge (the lane heading `d`
        /// from its start to its end), and a section 0.6 m along the lane
        /// off it, where the verge has risen or fallen to the ground, when
        /// the next sample `q` is further away.
        func mouth(_ p: SIMD2<Double>, _ d: SIMD2<Double>, along: Double, next q: SIMD2<Double>, atStart: Bool) {
            let extra = simd_distance(p, q) > 0.9
            if !atStart, extra { section(p - d * 0.6, d, along: along - 0.6, width: hw) }
            section(p, d, along: along, width: hw)
            if atStart, extra { section(p + d * 0.6, d, along: along + 0.6, width: hw) }
        }

        func drawn(_ k: Kind) -> Bool { k == .kept || k == .partial }
        var i = 0
        while i < n {
            guard drawn(kind[i]) else { i += 1; continue }
            // A run of drawn samples, a...b.
            let a = i
            var b = i
            while b + 1 < n, drawn(kind[b + 1]) { b += 1 }
            prev = nil
            // Narrowing towards a cut at a bank, from the sample beyond it.
            let cutA = a > 0 && kind[a - 1] == .steep ? at[a - 1] : nil
            let cutB = b + 1 < n && kind[b + 1] == .steep ? at[b + 1] : nil
            func width(_ k: Int) -> Double {
                guard kind[k] == .kept else { return hw }
                let toCut = min(cutA.map { at[k] - $0 } ?? .infinity, cutB.map { $0 - at[k] } ?? .infinity)
                return hw * (0.4 + 0.6 * smoothstepD(0.5, 3.5, toCut))
            }
            // The start: the mouth where the line leaves the road, the line
            // carried back to it, or a shallow lane's taper.
            if kind[a] == .kept, a > 0, kind[a - 1] == .main {
                let p = edgePoint(pts[a], pts[a - 1])
                mouth(p, simd_normalize(pts[a] - pts[a - 1]), along: along0 + at[a] - simd_distance(p, pts[a]),
                      next: pts[a], atStart: true)
            } else if a == 0, kind[0] == .kept {
                let d = direction(0), back = pts[0] - d * 3
                if clear(back) < keep {
                    let p = edgePoint(pts[0], back)
                    mouth(p, d, along: along0 - simd_distance(p, pts[0]), next: pts[0], atStart: true)
                }
            } else if a == 0, kind[0] == .partial {
                taper(from: pts[0], direction(0), along: along0, back: true)
            }
            for k in a...b {
                // The centre line crossing the carriageway's edge.
                if k > a, kind[k] != kind[k - 1] {
                    let off = kind[k] == .kept ? pts[k] : pts[k - 1], on = kind[k] == .kept ? pts[k - 1] : pts[k]
                    let p = edgePoint(off, on)
                    mouth(p, simd_normalize(pts[k] - pts[k - 1]), along: along0 + at[k - 1] + simd_distance(pts[k - 1], p),
                          next: off, atStart: kind[k] == .kept)
                }
                section(pts[k], direction(k), along: along0 + at[k], width: width(k))
            }
            // And at the end.
            if kind[b] == .kept, b + 1 < n, kind[b + 1] == .main {
                let p = edgePoint(pts[b], pts[b + 1])
                mouth(p, simd_normalize(pts[b + 1] - pts[b]), along: along0 + at[b] + simd_distance(p, pts[b]),
                      next: pts[b], atStart: false)
            } else if b == n - 1, kind[b] == .kept {
                let d = direction(b), on = pts[b] + d * 3
                if clear(on) < keep {
                    let p = edgePoint(pts[b], on)
                    mouth(p, d, along: along0 + at[b] + simd_distance(p, pts[b]), next: pts[b], atStart: false)
                }
            } else if b == n - 1, kind[b] == .partial {
                taper(from: pts[b], direction(b), along: along0 + at[b], back: false)
            }
            i = b + 1
        }
    }

    /// A side road's 1 m samples, each the mean of the seven about it (fewer
    /// near the ends, which stay put): kinks of the map's lines rounded over
    /// about 3 m, as a lane is laid.
    static func eased(_ p: [SIMD2<Double>]) -> [SIMD2<Double>] {
        guard p.count > 2 else { return p }
        return p.indices.map { i in
            let r = min(3, i, p.count - 1 - i)
            var sum = SIMD2<Double>(0, 0)
            for k in (i - r)...(i + r) { sum += p[k] }
            return sum / Double(2 * r + 1)
        }
    }

    /// Tarmac, where paint goes: not the setts or the concrete lanes.
    private static func asphalt(_ s: RoadCorridor.Station, _ corridor: RoadCorridor) -> Bool {
        s.surface != corridor.cobbleIndex && s.surface != corridor.concreteIndex
    }

    /// A stable 0...1 hash of a number.
    private static func hash(_ x: Double) -> Double {
        let v = sin(x * 12.9898 + 78.233) * 43758.5453
        return v - floor(v)
    }
}
