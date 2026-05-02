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
        samplesJSON: Data? = nil
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
    }
}

struct RideSamples: Codable {
    var power: [Int]
    var cadence: [Int]
    var hr: [Int]
    var targets: [Int]
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
}
