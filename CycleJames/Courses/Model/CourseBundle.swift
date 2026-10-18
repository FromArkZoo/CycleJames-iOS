import Foundation

/// Everything the simulator needs for one course, loaded from the
/// `Courses/<id>/` folder reference in the app bundle.
struct CourseBundle: Sendable {
    let id: String
    let directory: URL
    let course: CourseFile
    let route: CourseRoute
    let terrainNear: HeightRaster
    let terrainFar: HeightRaster?
    let scenery: SceneryFile?

    var name: String { course.name }
    var climb: CourseFile.ClimbRange { course.climb }

    /// LiDAR vegetation height above the ground, decoded from disk on each
    /// read (about 5 MB as floats), so only what needs it pays for it, and
    /// only while it holds it. Nil when the course has none.
    var canopy: HeightRaster? {
        guard let header = course.canopy else { return nil }
        return try? HeightRaster.load(from: directory.appendingPathComponent(header.file), header: header)
    }

    /// The raw aerial photo, when the course folder has it. The app bundle
    /// doesn't (the world drapes the baked ground photo), so this is nil.
    var orthoURL: URL? {
        guard let o = course.ortho else { return nil }
        let url = directory.appendingPathComponent(o.file)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Rolling-resistance coefficient for a surface index on the route.
    func crr(surfaceIndex: Int) -> Double {
        let name = course.surfaces.indices.contains(surfaceIndex) ? course.surfaces[surfaceIndex] : "asphalt"
        return course.surfaceCrr[name] ?? course.surfaceCrr["asphalt"] ?? 0.004
    }

    static func directory(for id: String, in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: id, withExtension: nil, subdirectory: "Courses")
    }

    /// Reads only `course.json` — cheap enough for list and detail screens.
    static func loadCourseFile(id: String, bundle: Bundle = .main) throws -> CourseFile {
        guard let dir = directory(for: id, in: bundle) else { throw CourseDataError.missingCourse(id) }
        let url = dir.appendingPathComponent("course.json")
        guard let data = try? Data(contentsOf: url) else { throw CourseDataError.missingFile("course.json") }
        return try JSONDecoder().decode(CourseFile.self, from: data)
    }

    /// Full load including rasters and scenery. Takes tens of milliseconds;
    /// call it off the main thread.
    static func load(id: String, bundle: Bundle = .main) throws -> CourseBundle {
        guard let dir = directory(for: id, in: bundle) else { throw CourseDataError.missingCourse(id) }
        let course = try loadCourseFile(id: id, bundle: bundle)
        let route = try CourseRoute(course.route, surfaceNames: course.surfaces)

        func raster(_ header: CourseFile.RasterHeader?) throws -> HeightRaster? {
            guard let header else { return nil }
            return try HeightRaster.load(from: dir.appendingPathComponent(header.file), header: header)
        }

        var scenery: SceneryFile?
        if let name = course.scenery,
           let data = try? Data(contentsOf: dir.appendingPathComponent(name)) {
            scenery = try JSONDecoder().decode(SceneryFile.self, from: data)
        }

        return CourseBundle(
            id: id,
            directory: dir,
            course: course,
            route: route,
            terrainNear: try HeightRaster.load(
                from: dir.appendingPathComponent(course.terrain.near.file),
                header: course.terrain.near
            ),
            terrainFar: try raster(course.terrain.far),
            scenery: scenery
        )
    }
}

/// Lightweight description of a course for list/detail screens.
struct CourseSummary: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let region: String
    let totalLengthM: Double
    let climbLengthM: Double
    let climbGainM: Double
    let climbAvgGradePct: Double
    let climbMaxGradePct: Double
    let climbStartS: Double
    let climbEndS: Double
    let summitElevationM: Double
    let attribution: [String]
    /// Route elevation sampled every ~5 m, for profile charts.
    let profile: [ProfilePoint]
    /// Steepest 10 m of the climb, when the course file has it.
    let climbMaxGradePct10m: Double?
    /// Named points along the route (climb start, steepest, summit…).
    let landmarks: [CourseFile.Landmark]
    /// Contiguous runs of one surface along the route, in race order.
    let surfaceSections: [SurfaceSection]

    struct ProfilePoint: Hashable, Sendable {
        let s: Double
        let elev: Double
        let gradePct: Double
    }

    struct SurfaceSection: Hashable, Sendable {
        let fromS: Double
        let toS: Double
        /// Name from `course.surfaces`, e.g. "cobbles".
        let surface: String
        var lengthM: Double { toS - fromS }
    }

    /// Total length of the route on `surface`, metres.
    func lengthM(on surface: String) -> Double {
        surfaceSections.filter { $0.surface == surface }.reduce(0) { $0 + $1.lengthM }
    }

    /// Landmarks of one kind ("climbStart", "steepest", "summit", …).
    func landmarks(kind: String) -> [CourseFile.Landmark] {
        landmarks.filter { $0.kind == kind }
    }

    /// Linearly interpolated elevation from the sampled profile.
    func elevation(at s: Double) -> Double {
        guard let first = profile.first, let last = profile.last else { return 0 }
        if s <= first.s { return first.elev }
        if s >= last.s { return last.elev }
        var lo = 0, hi = profile.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if profile[mid].s <= s { lo = mid } else { hi = mid }
        }
        let a = profile[lo], b = profile[hi]
        let t = b.s > a.s ? (s - a.s) / (b.s - a.s) : 0
        return a.elev + (b.elev - a.elev) * t
    }

    init(course: CourseFile) {
        id = course.id
        name = course.name
        region = course.region
        totalLengthM = course.stats.totalLengthM
        climbLengthM = course.stats.climbLengthM
        climbGainM = course.stats.climbGainM
        climbAvgGradePct = course.stats.climbAvgGradePct
        climbMaxGradePct = course.stats.climbMaxGradePct25m
            ?? course.stats.climbMaxGradePct10m
            ?? course.route.gradePct.max() ?? 0
        climbStartS = course.climb.startS
        climbEndS = course.climb.endS
        summitElevationM = course.stats.summitElevationM ?? (course.route.elev.max() ?? 0)
        attribution = course.attribution
        let r = course.route
        let step = max(1, Int((5.0 / max(r.spacingM, 0.1)).rounded()))
        var pts: [ProfilePoint] = []
        var i = 0
        while i < r.s.count {
            pts.append(ProfilePoint(s: r.s[i], elev: r.elev[i], gradePct: r.gradePct[i]))
            i += step
        }
        if let last = r.s.indices.last, pts.last?.s != r.s[last] {
            pts.append(ProfilePoint(s: r.s[last], elev: r.elev[last], gradePct: r.gradePct[last]))
        }
        profile = pts
        climbMaxGradePct10m = course.stats.climbMaxGradePct10m
        landmarks = course.landmarks.sorted { $0.s < $1.s }

        var sections: [SurfaceSection] = []
        if !r.surface.isEmpty {
            func name(_ idx: Int) -> String {
                course.surfaces.indices.contains(idx) ? course.surfaces[idx] : "asphalt"
            }
            var runStart = 0
            for i in 1...r.surface.count {
                if i == r.surface.count || r.surface[i] != r.surface[runStart] {
                    // A run ends halfway between its last station and the next.
                    let from = runStart == 0 ? r.s[0] : (r.s[runStart - 1] + r.s[runStart]) / 2
                    let to = i == r.surface.count ? r.s[i - 1] : (r.s[i - 1] + r.s[i]) / 2
                    sections.append(SurfaceSection(fromS: from, toS: to, surface: name(r.surface[runStart])))
                    runStart = i
                }
            }
        }
        surfaceSections = sections
    }
}

/// The courses shipped in the app, in display order.
enum CourseCatalog {
    static let courseIDs = ["koppenberg"]

    static func summaries(bundle: Bundle = .main) -> [CourseSummary] {
        courseIDs.compactMap { id in
            (try? CourseBundle.loadCourseFile(id: id, bundle: bundle)).map(CourseSummary.init(course:))
        }
    }

    /// `summaries()` from the main bundle, decoded once per launch so list
    /// and detail screens can read it from `body` without re-parsing JSON.
    static let all: [CourseSummary] = summaries()

    static func summary(id: String) -> CourseSummary? {
        all.first { $0.id == id }
    }
}
