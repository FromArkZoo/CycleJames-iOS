import Foundation

// Decodable mirrors of the baked course files. The format is defined in
// scripts/courses/FORMAT.md; keep the two in step.

/// `course.json`
struct CourseFile: Codable, Sendable {
    let schemaVersion: Int
    let id: String
    let name: String
    let region: String
    let origin: Origin
    let attribution: [String]
    let sources: [Source]?
    let climb: ClimbRange
    let stats: Stats
    let route: RouteArrays
    let surfaces: [String]
    let surfaceCrr: [String: Double]
    let landmarks: [Landmark]
    let terrain: TerrainSet
    let canopy: RasterHeader?
    let ortho: OrthoHeader?
    let scenery: String?

    struct Origin: Codable, Sendable {
        /// Lambert 72 (EPSG:31370) easting, northing of the local origin.
        let lambert72: [Double]
        /// Latitude, longitude of the local origin.
        let wgs84: [Double]
    }

    struct Source: Codable, Sendable {
        let name: String
        let url: String?
        let retrieved: String?
        let notes: String?
    }

    struct ClimbRange: Codable, Sendable {
        let startS: Double
        let endS: Double
        var lengthM: Double { endS - startS }
    }

    struct Stats: Codable, Sendable {
        let totalLengthM: Double
        let climbLengthM: Double
        let climbGainM: Double
        let climbAvgGradePct: Double
        let climbMaxGradePct10m: Double?
        let climbMaxGradePct25m: Double?
        let climbMaxGradePct50m: Double?
        let startElevationM: Double?
        let summitElevationM: Double?
        let per100m: [Per100]?

        struct Per100: Codable, Sendable, Hashable {
            let fromS: Double
            let toS: Double
            let avgGradePct: Double
        }
    }

    /// Column-oriented centreline arrays, all the same length.
    struct RouteArrays: Codable, Sendable {
        let spacingM: Double
        let s: [Double]
        let east: [Double]
        let north: [Double]
        let elev: [Double]
        let gradePct: [Double]
        let widthM: [Double]
        let surface: [Int]
    }

    struct Landmark: Codable, Sendable, Hashable {
        let s: Double
        let kind: String
        let name: String
    }

    struct TerrainSet: Codable, Sendable {
        let near: RasterHeader
        let far: RasterHeader?
    }

    struct RasterHeader: Codable, Sendable {
        let file: String
        let encoding: String
        let baseM: Double
        /// North-west corner of cell (0,0), local metres.
        let originEast: Double
        let originNorth: Double
        let cellM: Double
        let cols: Int
        let rows: Int
    }

    /// The course's aerial photo. The 3D world drapes the baked
    /// `CourseTextures/<id>_ortho_ground.jpg` over this footprint; the raw
    /// photo in `file` stays with the pipeline and isn't in the app bundle.
    struct OrthoHeader: Codable, Sendable {
        let file: String
        /// North-west corner of the image, local metres.
        let originEast: Double
        let originNorth: Double
        let widthM: Double
        let heightM: Double
        let pixelsWide: Int
        let pixelsHigh: Int
        let capturedSeason: String?
        let capturedYear: Int?
    }
}

/// `scenery.json`. Every collection is optional so a partial file still loads.
struct SceneryFile: Codable, Sendable {
    let schemaVersion: Int
    let buildings: [Building]?
    let trees: [Tree]?
    let shrubs: [Shrub]?
    let landuse: [Landuse]?
    let roads: [Road]?
    let fences: [Fence]?
    let water: [Water]?

    struct Building: Codable, Sendable {
        /// Footprint, counter-clockwise (east, north), not closed.
        let ring: [[Double]]
        let heightM: Double
        let roofShape: String?
        let kind: String?
        let groundElevM: Double?
    }

    struct Tree: Codable, Sendable {
        let e: Double
        let n: Double
        let heightM: Double
        let crownRadiusM: Double
        let kind: String?
    }

    struct Shrub: Codable, Sendable {
        let e: Double
        let n: Double
        let heightM: Double
        let radiusM: Double
    }

    struct Landuse: Codable, Sendable {
        let kind: String
        let ring: [[Double]]
    }

    struct Road: Codable, Sendable {
        let name: String?
        let widthM: Double?
        let surface: String?
        let points: [[Double]]
    }

    struct Fence: Codable, Sendable {
        let kind: String
        let points: [[Double]]
    }

    struct Water: Codable, Sendable {
        let kind: String
        let points: [[Double]]
        let closed: Bool?
    }
}

enum CourseDataError: Error, LocalizedError {
    case missingCourse(String)
    case missingFile(String)
    case badRaster(String)
    case badRoute(String)

    var errorDescription: String? {
        switch self {
        case .missingCourse(let id): "Course \"\(id)\" is not in the app bundle."
        case .missingFile(let f): "Course file \(f) is missing."
        case .badRaster(let why): "Terrain data is unreadable: \(why)"
        case .badRoute(let why): "Route data is unreadable: \(why)"
        }
    }
}
