import Foundation
import SwiftData

@Model
final class RideSessionModel {
    var id: UUID = UUID()
    var date: Date = Date()
    var workoutId: String = ""
    var workoutName: String = ""
    var category: String = ""
    var durationSec: Int = 0
    var ftp: Int = 200
    var avgPower: Int = 0
    var avgCadence: Int = 0
    var avgHR: Int = 0
    var peakPower: Int = 0
    var peakHR: Int = 0
    var peakCadence: Int = 0
    var np: Int = 0
    var intensityFactor: Double = 0
    var tss: Int = 0
    var partial: Bool = false
    var sampleInterval: Int = 1

    /// Compact JSON-encoded sample arrays: { "power": [...], "cadence": [...], "hr": [...], "targets": [...] }
    var samplesJSON: Data?

    /// JSON-encoded `[IntervalSummary]` — per-interval averages locked in as
    /// each interval finishes. Optional so older sessions still decode.
    var intervalSummariesJSON: Data?

    init(
        id: UUID = UUID(),
        date: Date = Date(),
        workoutId: String,
        workoutName: String,
        category: String,
        durationSec: Int,
        ftp: Int,
        avgPower: Int,
        avgCadence: Int,
        avgHR: Int,
        peakPower: Int = 0,
        peakHR: Int = 0,
        peakCadence: Int = 0,
        np: Int,
        intensityFactor: Double,
        tss: Int,
        partial: Bool,
        sampleInterval: Int,
        samplesJSON: Data? = nil,
        intervalSummariesJSON: Data? = nil
    ) {
        self.id = id
        self.date = date
        self.workoutId = workoutId
        self.workoutName = workoutName
        self.category = category
        self.durationSec = durationSec
        self.ftp = ftp
        self.avgPower = avgPower
        self.avgCadence = avgCadence
        self.avgHR = avgHR
        self.peakPower = peakPower
        self.peakHR = peakHR
        self.peakCadence = peakCadence
        self.np = np
        self.intensityFactor = intensityFactor
        self.tss = tss
        self.partial = partial
        self.sampleInterval = sampleInterval
        self.samplesJSON = samplesJSON
        self.intervalSummariesJSON = intervalSummariesJSON
    }
}

struct RideSamples: Codable {
    var power: [Int]
    var cadence: [Int]
    var hr: [Int]
    var targets: [Int]
    /// Course rides only, one value per sample: distance along the route
    /// (m), altitude (m) and speed (m/s). Nil for workouts and older rides,
    /// whose JSON has no such keys.
    var distanceM: [Double]? = nil
    var altitudeM: [Double]? = nil
    var speedMps: [Double]? = nil
    /// Course rides: true when virtual power was used before the summit,
    /// so the climb never counts as a personal best. Nil for workouts and
    /// older rides.
    var climbOnVirtualPower: Bool? = nil
    /// Berg series only: each climb's course, in ride order. `distanceM` is
    /// then along the whole ride (easy spins between climbs included), and
    /// a course's own distance is `distanceM - offsetM`. Nil otherwise.
    var segments: [CourseSegment]? = nil
}

/// One climb of a berg series in its saved samples.
struct CourseSegment: Codable, Equatable {
    var courseID: String
    /// Ride distance at the course's start (its `s` = 0), metres.
    var offsetM: Double
    /// Virtual power was used on this climb or on the way to it.
    var climbOnVirtualPower: Bool
}

struct IntervalSummary: Codable, Hashable {
    var name: String
    var durationSec: Int
    var avgPower: Int
    var targetWatts: Int
}

extension RideSessionModel {
    var samples: RideSamples? {
        get {
            guard let data = samplesJSON else { return nil }
            return try? JSONDecoder().decode(RideSamples.self, from: data)
        }
        set {
            samplesJSON = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }

    var intervalSummaries: [IntervalSummary]? {
        get {
            guard let data = intervalSummariesJSON else { return nil }
            return try? JSONDecoder().decode([IntervalSummary].self, from: data)
        }
        set {
            intervalSummariesJSON = newValue.flatMap { try? JSONEncoder().encode($0) }
        }
    }
}
