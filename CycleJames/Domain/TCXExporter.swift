import Foundation

/// Builds a TCX (Garmin Training Center XML) document from a saved
/// `RideSessionModel`. TCX is accepted by both Strava and Garmin Connect
/// when uploaded manually via the iOS share sheet.
enum TCXExporter {
    /// Returns the TCX file URL written to a temporary directory, suitable
    /// for sharing with `UIActivityViewController`. Caller is responsible
    /// for cleanup but iOS clears tmp regularly so it's safe to leave.
    static func writeFile(for session: RideSessionModel) throws -> URL {
        let xml = render(session: session)
        let safeName = session.workoutName
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: " ", with: "_")
        let stamp = Self.fileNameDateFormatter.string(from: session.date)
        let filename = "CycleJames_\(safeName)_\(stamp).tcx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Build the TCX XML string. Activity type "Biking" is the standard one
    /// Strava and Garmin Connect parse for indoor cycling rides.
    static func render(session: RideSessionModel) -> String {
        let isoStart = isoDateFormatter.string(from: session.date)
        let samples = session.samples
        let interval = max(1, session.sampleInterval)
        let powers = samples?.power ?? []
        let cads = samples?.cadence ?? []
        let hrs = samples?.hr ?? []

        var trackpoints: [String] = []
        trackpoints.reserveCapacity(powers.count)
        for i in 0..<powers.count {
            let secondOffset = i * interval
            guard let date = Calendar.current.date(byAdding: .second, value: secondOffset, to: session.date) else { continue }
            let stamp = isoDateFormatter.string(from: date)
            let power = max(0, powers[i])
            let cadence = i < cads.count ? max(0, cads[i]) : 0
            let hr = i < hrs.count ? max(0, hrs[i]) : 0
            trackpoints.append(makeTrackpoint(time: stamp, power: power, cadence: cadence, hr: hr))
        }

        let totalSeconds = session.durationSec
        let avgPower = session.avgPower
        let avgHR = session.avgHR
        let avgCadence = session.avgCadence
        let maxPower = session.peakPower
        let maxHR = session.peakHR

        return """
        <?xml version="1.0" encoding="UTF-8" standalone="no"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
                                xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
                                xmlns:ns3="http://www.garmin.com/xmlschemas/ActivityExtension/v2"
                                xmlns:ns2="http://www.garmin.com/xmlschemas/UserProfile/v2"
                                xsi:schemaLocation="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2 http://www.garmin.com/xmlschemas/TrainingCenterDatabasev2.xsd">
          <Activities>
            <Activity Sport="Biking">
              <Id>\(isoStart)</Id>
              <Lap StartTime="\(isoStart)">
                <TotalTimeSeconds>\(totalSeconds)</TotalTimeSeconds>
                <DistanceMeters>0</DistanceMeters>
                <Calories>\(estimateCalories(durationSec: totalSeconds, avgPower: avgPower))</Calories>
        \(maxHR > 0 ? "        <MaximumHeartRateBpm><Value>\(maxHR)</Value></MaximumHeartRateBpm>\n" : "")\
        \(avgHR > 0 ? "        <AverageHeartRateBpm><Value>\(avgHR)</Value></AverageHeartRateBpm>\n" : "")\
                <Intensity>Active</Intensity>
                <Cadence>\(avgCadence)</Cadence>
                <TriggerMethod>Manual</TriggerMethod>
                <Track>
        \(trackpoints.joined(separator: "\n"))
                </Track>
                <Extensions>
                  <ns3:LX>
                    <ns3:AvgWatts>\(avgPower)</ns3:AvgWatts>
                    <ns3:MaxWatts>\(maxPower)</ns3:MaxWatts>
                  </ns3:LX>
                </Extensions>
              </Lap>
              <Notes>CycleJames · \(session.workoutName) · TSS \(session.tss) · IF \(String(format: "%.2f", session.intensityFactor))</Notes>
              <Creator xsi:type="Device_t">
                <Name>CycleJames iOS</Name>
                <UnitId>0</UnitId>
                <ProductID>1</ProductID>
                <Version><VersionMajor>1</VersionMajor><VersionMinor>0</VersionMinor><BuildMajor>0</BuildMajor><BuildMinor>0</BuildMinor></Version>
              </Creator>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>
        """
    }

    private static func makeTrackpoint(time: String, power: Int, cadence: Int, hr: Int) -> String {
        var lines: [String] = []
        lines.append("          <Trackpoint>")
        lines.append("            <Time>\(time)</Time>")
        if hr > 0 {
            lines.append("            <HeartRateBpm><Value>\(hr)</Value></HeartRateBpm>")
        }
        if cadence > 0 {
            lines.append("            <Cadence>\(cadence)</Cadence>")
        }
        lines.append("            <Extensions>")
        lines.append("              <ns3:TPX>")
        lines.append("                <ns3:Watts>\(power)</ns3:Watts>")
        lines.append("              </ns3:TPX>")
        lines.append("            </Extensions>")
        lines.append("          </Trackpoint>")
        return lines.joined(separator: "\n")
    }

    /// Standard back-of-envelope: kJ ≈ kcal for cycling. Avg watts × seconds ÷ 1000.
    private static func estimateCalories(durationSec: Int, avgPower: Int) -> Int {
        let kj = Double(avgPower) * Double(durationSec) / 1000.0
        return Int(kj.rounded())
    }

    private static let isoDateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let fileNameDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmm"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
