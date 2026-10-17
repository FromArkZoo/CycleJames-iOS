import Foundation
import simd

/// Where a point on the road is and which way it faces, in scene space
/// (x = east, y = up, z = −north; see `CourseSpace`).
struct RoutePose: Sendable {
    /// Road-surface point at the requested distance and lateral offset.
    var position: SIMD3<Float>
    /// Unit vector along the road, pitched with the gradient.
    var forward: SIMD3<Float>
    /// Unit horizontal vector to the rider's right.
    var right: SIMD3<Float>
    /// Unit road normal (perpendicular to `forward` and `right`).
    var up: SIMD3<Float>
    /// Compass heading of the road, radians clockwise from north.
    var headingRadians: Double
    var gradePct: Double
    var widthM: Double
    var surfaceIndex: Int

    /// Column-major rotation + translation placing an object on the road,
    /// local −z facing along the road (SceneKit's forward convention).
    var transform: simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(right, 0),
            SIMD4(up, 0),
            SIMD4(-forward, 0),
            SIMD4(position, 1)
        ))
    }
}

/// Conversions between the course's local Lambert 72 metres and scene space.
enum CourseSpace {
    @inline(__always)
    static func scene(east: Double, north: Double, elev: Double) -> SIMD3<Float> {
        SIMD3(Float(east), Float(elev), Float(-north))
    }

    @inline(__always)
    static func local(_ p: SIMD3<Float>) -> (east: Double, north: Double, elev: Double) {
        (Double(p.x), Double(-p.z), Double(p.y))
    }
}

/// Distance-indexed queries over the baked centreline. Everything is
/// interpolated linearly between the 1 m stations; `s` is clamped to the route.
struct CourseRoute: Sendable {
    let s: [Double]
    let east: [Double]
    let north: [Double]
    let elev: [Double]
    let gradePct: [Double]
    let widthM: [Double]
    let surface: [Int]
    let surfaceNames: [String]

    var length: Double { s.last ?? 0 }
    var count: Int { s.count }

    init(_ arrays: CourseFile.RouteArrays, surfaceNames: [String]) throws {
        let n = arrays.s.count
        guard n >= 2 else { throw CourseDataError.badRoute("fewer than two stations") }
        let lengths = [arrays.east.count, arrays.north.count, arrays.elev.count,
                       arrays.gradePct.count, arrays.widthM.count, arrays.surface.count]
        guard lengths.allSatisfy({ $0 == n }) else {
            throw CourseDataError.badRoute("route arrays have different lengths")
        }
        for i in 1..<n where !(arrays.s[i] > arrays.s[i - 1]) {
            throw CourseDataError.badRoute("distances are not strictly increasing at \(i)")
        }
        s = arrays.s
        east = arrays.east
        north = arrays.north
        elev = arrays.elev
        gradePct = arrays.gradePct
        widthM = arrays.widthM
        surface = arrays.surface
        self.surfaceNames = surfaceNames
    }

    /// Segment index `i` and fraction `t` such that the point lies between
    /// stations `i` and `i + 1`.
    func locate(_ distance: Double) -> (i: Int, t: Double) {
        let d = min(max(distance, s[0]), s[s.count - 1])
        var lo = 0, hi = s.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if s[mid] <= d { lo = mid } else { hi = mid }
        }
        let span = s[hi] - s[lo]
        return (lo, span > 0 ? (d - s[lo]) / span : 0)
    }

    @inline(__always)
    private func lerp(_ a: [Double], _ distance: Double) -> Double {
        let (i, t) = locate(distance)
        return a[i] + (a[i + 1] - a[i]) * t
    }

    func elevation(at distance: Double) -> Double { lerp(elev, distance) }
    func grade(at distance: Double) -> Double { lerp(gradePct, distance) }
    func width(at distance: Double) -> Double { lerp(widthM, distance) }

    func surfaceIndex(at distance: Double) -> Int {
        let (i, t) = locate(distance)
        return t < 0.5 ? surface[i] : surface[i + 1]
    }

    func surfaceName(at distance: Double) -> String {
        let idx = surfaceIndex(at: distance)
        return surfaceNames.indices.contains(idx) ? surfaceNames[idx] : "asphalt"
    }

    /// Mean gradient over `[distance, distance + ahead]`, from elevation change.
    func averageGrade(from distance: Double, ahead: Double) -> Double {
        let a = min(max(distance, 0), length)
        let b = min(a + max(ahead, 0.5), length)
        guard b - a > 0.01 else { return grade(at: a) }
        return (elevation(at: b) - elevation(at: a)) / (b - a) * 100
    }

    func planar(at distance: Double) -> SIMD2<Double> {
        SIMD2(lerp(east, distance), lerp(north, distance))
    }

    /// Unit horizontal direction of travel (east, north), measured over ±2 m
    /// so the 1 m resampling doesn't show as kinks.
    func direction(at distance: Double) -> SIMD2<Double> {
        let a = planar(at: distance - 2)
        let b = planar(at: distance + 2)
        let d = b - a
        let len = simd_length(d)
        return len > 1e-6 ? d / len : SIMD2(0, 1)
    }

    /// Pose on the road surface. Positive `lateral` is to the right of the
    /// direction of travel.
    func pose(at distance: Double, lateral: Double = 0) -> RoutePose {
        let dir = direction(at: distance)
        let rightPlanar = SIMD2(dir.y, -dir.x)
        let p = planar(at: distance) + rightPlanar * lateral
        let g = grade(at: distance)
        let position = CourseSpace.scene(east: p.x, north: p.y, elev: elevation(at: distance))

        let pitch = atan(g / 100)
        let horizontalForward = SIMD3(Float(dir.x), 0, Float(-dir.y))
        let forward = simd_normalize(horizontalForward * Float(cos(pitch)) + SIMD3(0, Float(sin(pitch)), 0))
        let right = SIMD3(Float(rightPlanar.x), 0, Float(-rightPlanar.y))
        let up = simd_normalize(simd_cross(right, forward))
        var heading = atan2(dir.x, dir.y)
        if heading < 0 { heading += 2 * .pi }

        return RoutePose(
            position: position, forward: forward, right: right, up: up,
            headingRadians: heading, gradePct: g,
            widthM: width(at: distance), surfaceIndex: surfaceIndex(at: distance)
        )
    }
}
