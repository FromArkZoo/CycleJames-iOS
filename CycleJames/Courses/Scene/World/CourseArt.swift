import Foundation

/// Art direction for a course that its data files don't carry: where the
/// road runs in a holle weg (sunken lane), and the roadside details placed
/// from photos (street lamps, a wall, fences, stone edge strips, the look of
/// the houses along a stretch).
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
    /// Stone edge strips along the left of the cobbles.
    var kerbs: [Span] = []
    /// Black street lamps along the left, every `spacing` metres.
    var lamps: [(span: Span, spacing: Double)] = []
    /// Brick walls just off the right edge of the road.
    var walls: [Span] = []
    /// Post-and-wire fences: section and side (−1 left, +1 right).
    var fences: [(span: Span, side: Double)] = []
    /// Village stretches, where the verge grass keeps to a thin strip.
    var villages: [Span] = []
    /// Stretches whose roadside buildings have a known look.
    var houseLooks: [HouseLook] = []

    struct HouseLook: Sendable {
        enum Look: Sendable {
            /// White-washed cottages under dark roofs.
            case whitewashedCottages
            /// Red-brick farm buildings with orange pantiles, a cream house.
            case hilltopFarms
        }

        var span: Span
        /// Only buildings this close to the road.
        var maxRouteDistance: Double
        var look: Look
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

    func houseLook(s: Double, routeDistance: Double) -> HouseLook.Look? {
        houseLooks.first { $0.span.contains(s) && routeDistance < $0.maxRouteDistance }?.look
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
    private static let byCourseID: [String: CourseArt] = [
        "koppenberg": CourseArt(
            sunkenLane: [535...648, 765...812],
            kerbs: [302...430, 688...866],
            lamps: [(312...432, 29)],
            walls: [842...868],
            fences: [(700...836, 1), (884...1060, 1), (905...1050, -1)],
            villages: [0...440],
            houseLooks: [
                HouseLook(span: 295...450, maxRouteDistance: 45, look: .whitewashedCottages),
                HouseLook(span: 790...900, maxRouteDistance: 70, look: .hilltopFarms),
            ]
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
