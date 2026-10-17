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
    let canopy: HeightRaster?
    let scenery: SceneryFile?

    var name: String { course.name }
    var climb: CourseFile.ClimbRange { course.climb }

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
            canopy: try raster(course.canopy),
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

    struct ProfilePoint: Hashable, Sendable {
        let s: Double
        let elev: Double
        let gradePct: Double
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
}
