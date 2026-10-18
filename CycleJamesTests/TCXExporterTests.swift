import XCTest
@testable import CycleJames

final class TCXExporterTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000)

    private func session(category: String, samples: RideSamples) -> RideSessionModel {
        RideSessionModel(
            date: start, workoutId: "w", workoutName: "Ride", category: category,
            durationSec: samples.power.count, ftp: 250, avgPower: 210, avgCadence: 82, avgHR: 0,
            peakPower: 220, np: 210, intensityFactor: 0.84, tss: 2, partial: false, sampleInterval: 1,
            samplesJSON: try? JSONEncoder().encode(samples)
        )
    }

    private func stamp(_ offset: Int) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: start.addingTimeInterval(TimeInterval(offset)))
    }

    func test_courseRide_writesDistanceAltitudeAndSpeed() {
        let samples = RideSamples(power: [200, 210, 220], cadence: [80, 82, 84], hr: [0, 0, 0], targets: [0, 0, 0],
                                  distanceM: [305, 310, 315.5], altitudeM: [12.3, 12.4, 12.6], speedMps: [5, 5, 5.5])
        let xml = TCXExporter.render(session: session(category: "Climb", samples: samples))

        // Lap distance from where the ride began (305 − 5 m/s × 1 s).
        XCTAssertTrue(xml.contains("<TotalTimeSeconds>3</TotalTimeSeconds>\n        <DistanceMeters>15.5</DistanceMeters>"), xml)
        XCTAssertTrue(xml.contains("<DistanceMeters>5.0</DistanceMeters>"))
        XCTAssertTrue(xml.contains("<DistanceMeters>10.0</DistanceMeters>"))
        XCTAssertTrue(xml.contains("<AltitudeMeters>12.6</AltitudeMeters>"))
        XCTAssertTrue(xml.contains("<ns3:Speed>5.50</ns3:Speed>"))
        // Each sample holds the end of its second.
        XCTAssertTrue(xml.contains("<Time>\(stamp(1))</Time>"))
        XCTAssertTrue(xml.contains("<Time>\(stamp(3))</Time>"))
        XCTAssertFalse(xml.contains("<Time>\(stamp(0))</Time>"))

        // Schema order inside a trackpoint and its TPX extension.
        let first = xml.components(separatedBy: "<Trackpoint>")[1]
        let order = ["<Time>", "<AltitudeMeters>", "<DistanceMeters>", "<Cadence>", "<ns3:Speed>", "<ns3:Watts>"]
            .map { first.range(of: $0)?.lowerBound }
        XCTAssertFalse(order.contains(nil))
        XCTAssertEqual(order.compactMap { $0 }, order.compactMap { $0 }.sorted())
    }

    func test_workout_exportHasNoRouteData() {
        let samples = RideSamples(power: [200, 210], cadence: [80, 82], hr: [120, 121], targets: [200, 200])
        let xml = TCXExporter.render(session: session(category: "Endurance", samples: samples))
        XCTAssertTrue(xml.contains("<DistanceMeters>0</DistanceMeters>"))
        XCTAssertEqual(xml.components(separatedBy: "<DistanceMeters>").count, 2, "only the lap's")
        XCTAssertFalse(xml.contains("AltitudeMeters"))
        XCTAssertFalse(xml.contains("ns3:Speed"))
        XCTAssertTrue(xml.contains("<Time>\(stamp(0))</Time>"))
        XCTAssertTrue(xml.contains("<Time>\(stamp(1))</Time>"))
    }
}
