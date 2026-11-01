import Foundation
import simd

/// The Riviera's road doubles back on itself where no Flemish climb does:
/// the Poggio's hairpins turn on a 5-7 m centreline radius with a 5.5 m
/// carriageway, so the inside edge turns on 2-4 m (route.md, from the OSM
/// geometry), their legs run 10-14 m apart either side of the bend, and the
/// summit loop down Via Val d'Olivi comes back within 10-14 m of itself for
/// about 70 m. Fixed lateral columns would fold over each other there, and a
/// 13 m verge would lie across the other leg's tarmac.
extension RoadCorridor {
    /// Cuts each station's cross-section where its points stop being
    /// nearest to their own station: the line midway between two legs, or
    /// the centre a tight bend turns round. A point at lateral `l` on the
    /// section through `c` (unit normal `n`) is as near another station `q`
    /// as its own when `l = |q − c|² / 2 n·(q − c)`; the smallest such `l`
    /// over every other station is where the section must stop. Neighbours
    /// on the same arc give its radius (the fold), the other leg its
    /// midline. The carriageway is drawn to there (`reachLeft`,
    /// `reachRight`) and the verge no further, so two legs' verges meet in
    /// the middle, with no gap for the grid terrain the road pushes down
    /// (`TerrainBuilder`) to show through, and neither folds.
    static func clearances(_ st: inout [Station], vergeWidth: Double) {
        let n = st.count
        guard n > 2 else { return }
        var minE = Double.infinity, maxE = -Double.infinity, minN = Double.infinity, maxN = -Double.infinity
        var maxHW = 0.0
        for s in st {
            minE = min(minE, s.east); maxE = max(maxE, s.east)
            minN = min(minN, s.north); maxN = max(maxN, s.north)
            maxHW = max(maxHW, s.halfWidth)
        }
        // Only cuts nearer than the widest section matter, and a station
        // further than twice that away can't make one.
        let reachMax = maxHW + vergeWidth + 0.5
        let radius = 2 * reachMax, radius2 = radius * radius
        let cell = 4.0
        let cols = Int((maxE - minE) / cell) + 1, rows = Int((maxN - minN) / cell) + 1
        // Stations bucketed by cell (counting sort).
        var start = [Int32](repeating: 0, count: cols * rows + 1)
        var cellOf = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let c = Int((st[i].east - minE) / cell), r = Int((st[i].north - minN) / cell)
            let k = r * cols + c
            cellOf[i] = Int32(k)
            start[k + 1] += 1
        }
        for k in 0..<(cols * rows) { start[k + 1] += start[k] }
        var fill = start
        var items = [Int32](repeating: 0, count: n)
        for i in 0..<n {
            let k = Int(cellOf[i])
            items[Int(fill[k])] = Int32(i)
            fill[k] += 1
        }

        var cutL = [Double](repeating: .infinity, count: n)
        var cutR = cutL
        let span = Int(ceil(radius / cell))
        let pE = st.map(\.east), pN = st.map(\.north)
        for i in 0..<n {
            if i % 512 == 0, Task.isCancelled { return }
            let a = st[i]
            let nE = a.rightE, nN = a.rightN
            let ci = Int((a.east - minE) / cell), ri = Int((a.north - minN) / cell)
            var bestL = Double.infinity, bestR = Double.infinity
            for r in max(0, ri - span)...min(rows - 1, ri + span) {
                for c in max(0, ci - span)...min(cols - 1, ci + span) {
                    let k = r * cols + c
                    var m = Int(start[k])
                    let end = Int(start[k + 1])
                    while m < end {
                        let j = Int(items[m])
                        m += 1
                        let dE = pE[j] - a.east, dN = pN[j] - a.north
                        let d2 = dE * dE + dN * dN
                        guard d2 > 1e-8, d2 < radius2 else { continue }
                        let dot = dE * nE + dN * nN
                        if dot > 1e-6 {
                            bestR = min(bestR, d2 / (2 * dot))
                        } else if dot < -1e-6 {
                            bestL = min(bestL, d2 / (-2 * dot))
                        }
                    }
                }
            }
            cutL[i] = bestL; cutR[i] = bestR
        }
        for i in 0..<n {
            let hw = st[i].halfWidth
            st[i].reachLeft = max(0.02, min(hw, cutL[i]))
            st[i].reachRight = max(0.02, min(hw, cutR[i]))
            st[i].vergeLeft = min(st[i].vergeLeft, max(0, cutL[i] - hw))
            st[i].vergeRight = min(st[i].vergeRight, max(0, cutR[i] - hw))
        }
    }

    /// Where the scenery's paved side roads meet the carriageway: each run
    /// of a side road's 1 m samples that comes within 1.5 m of the edge
    /// gives a mouth where it enters or leaves that band crossing the road
    /// at more than about 25°. Mouths on one side within 4 m merge (a
    /// side road drawn up to the centreline, or crossing).
    static func sideJunctions(stations st: [Station], coarse: CoarseField,
                              scenery: SceneryFile?) -> [(s: Double, side: Double, width: Double)] {
        guard st.count > 1 else { return [] }
        func station(at s: Double) -> Station {
            var lo = 0, hi = st.count - 1
            if s <= st[lo].s { return st[lo] }
            if s >= st[hi].s { return st[hi] }
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if st[mid].s <= s { lo = mid } else { hi = mid }
            }
            return st[lo]
        }
        var out: [(s: Double, side: Double, width: Double)] = []
        for road in RoadBuilder.sideRoadSamples(scenery: scenery) {
            let pts = road.points
            guard pts.count > 2 else { continue }
            var wasNear: Bool?
            for (i, p) in pts.enumerated() {
                let q = coarse.query(east: p.x, north: p.y)
                guard q.dist.isFinite else { wasNear = nil; continue }
                let a = station(at: q.s)
                let isNear = q.dist < a.halfWidth + 1.5
                defer { wasNear = isNear }
                guard let was = wasNear, was != isNear, a.beyond == 0 else { continue }
                let b = pts[max(i - 1, 0)], f = pts[min(i + 1, pts.count - 1)]
                let d = f - b
                let l = simd_length(d)
                guard l > 1e-6 else { continue }
                let cross = abs(d.x / l * a.dirN - d.y / l * a.dirE)
                guard cross > 0.42 else { continue }
                let lat = (p.x - a.east) * a.rightE + (p.y - a.north) * a.rightN
                // The mouth is wider than the road along the main road by
                // the angle it meets it at.
                out.append((q.s, lat >= 0 ? 1 : -1, min(road.halfWidth * 2 / cross, 20)))
            }
        }
        out.sort { $0.s < $1.s }
        var merged: [(s: Double, side: Double, width: Double)] = []
        for j in out {
            if let k = merged.lastIndex(where: { $0.side == j.side && abs($0.s - j.s) < 4 }) {
                merged[k].width = max(merged[k].width, j.width)
            } else {
                merged.append(j)
            }
        }
        return merged
    }

    /// Where a wall stands at the edge (the roadside's `EdgeWalls`: the
    /// CTR's walls along the edge and `CourseArt.masonry`), the tarmac or
    /// the concrete gutter runs on to its face: on the SP55 there is no
    /// grass between the edge line and the wall foot or a parapet (look.md
    /// section 3: "the edge line runs 0.2-0.5 m from the wall foot over a
    /// narrow concrete gutter"; the 2024 frames at 680-714, 1805-1836 and
    /// 2130 m), and the viewpoint lay-bys at 620-750 m are paved out to
    /// their parapets. The strip's width (the wall's offset from the edge)
    /// by side and metre of route, as `EdgeWalls` lays its slots; it eases
    /// out past a wall's ends over twice its width, as a lay-by's taper.
    /// (About 1.6 s on the Poggio in a Debug build: made in `RoadBuilder.
    /// build`, beside the buildings, not in the corridor's own init.)
    static func edgeAprons(_ corridor: RoadCorridor, scenery: SceneryFile?) -> EdgeAprons {
        let walls = scenery?.walls ?? []
        guard corridor.art.look.isRiviera, !walls.isEmpty || !corridor.art.masonry.isEmpty else { return .none }
        let edges = BuildingBuilder.EdgeWalls(corridor: corridor, walls: walls, sideRoads: RoadBuilder.SideRoadMask(scenery: scenery))
        let step = BuildingBuilder.EdgeWalls.step
        let n = Int(corridor.route.length / step) + 2
        var out = [[Float]](repeating: [Float](repeating: 0, count: n), count: 2)
        for run in edges.runs {
            let i = run.side < 0 ? 0 : 1
            let k0 = Int((run.s0 / step).rounded())
            for (j, slot) in run.slots.enumerated() where k0 + j >= 0 && k0 + j < n {
                out[i][k0 + j] = max(out[i][k0 + j], Float(slot.offset))
            }
        }
        let taper = Float(0.5 * step)
        for i in 0..<2 {
            for k in 1..<n { out[i][k] = max(out[i][k], out[i][k - 1] - taper) }
            for k in stride(from: n - 2, through: 0, by: -1) { out[i][k] = max(out[i][k], out[i][k + 1] - taper) }
        }
        return EdgeAprons(widths: out)
    }

    /// The paving past the carriageway edge to the walls (`edgeAprons`):
    /// widths by side (0 left, 1 right) and metre of route.
    struct EdgeAprons: Equatable {
        static let none = EdgeAprons(widths: [])
        let widths: [[Float]]
        var isEmpty: Bool { widths.isEmpty }

        /// The strip's width at route distance `s` on `side`; 0 off the
        /// Riviera and where no wall stands.
        func width(_ s: Double, side: Double) -> Double {
            guard !widths.isEmpty else { return 0 }
            let a = widths[side < 0 ? 0 : 1]
            let k = Int(floor(s / BuildingBuilder.EdgeWalls.step))
            guard k >= 0, k < a.count else { return 0 }
            return Double(a[k])
        }
    }
}
