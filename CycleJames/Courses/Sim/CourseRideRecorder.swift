import Foundation

/// One sample per second of riding for History: power and cadence averaged
/// over the second, the latest heart rate, and where the rider was at the
/// end of it. The course counterpart of `RideRecorder`, fed by the physics
/// tick instead of BLE callbacks.
final class CourseRideRecorder {
    struct Sample: Equatable {
        var power: Int
        var cadence: Int
        var hr: Int
        var distanceM: Double
        var altitudeM: Double
        var speedMps: Double
    }

    private(set) var samples: [Sample] = []
    /// Seconds accumulated towards the next sample.
    private var bucketSec: Double = 0
    private var bucketPowerJ: Double = 0
    private var bucketCadence: Double = 0

    func reset() {
        samples.removeAll(keepingCapacity: true)
        bucketSec = 0; bucketPowerJ = 0; bucketCadence = 0
    }

    /// Adds `dt` seconds of riding at constant values, emitting a sample at
    /// every whole second crossed. Position is the value at the end of the
    /// tick, so a long tick (after a suspension) repeats it.
    func record(dt: Double, powerW: Double, cadenceRpm: Double, hr: Int,
                distanceM: Double, altitudeM: Double, speedMps: Double) {
        var remaining = max(0, dt)
        while remaining > 0 {
            let take = min(remaining, 1 - bucketSec)
            bucketSec += take
            bucketPowerJ += powerW * take
            bucketCadence += cadenceRpm * take
            remaining -= take
            if bucketSec >= 1 - 1e-9 {
                emit(hr: hr, distanceM: distanceM, altitudeM: altitudeM, speedMps: speedMps)
            }
        }
    }

    /// Writes out the final part-second when the ride ends, so the last
    /// sample carries the finishing position.
    func flush(hr: Int, distanceM: Double, altitudeM: Double, speedMps: Double) {
        guard bucketSec > 1e-6 else { return }
        emit(hr: hr, distanceM: distanceM, altitudeM: altitudeM, speedMps: speedMps)
    }

    private func emit(hr: Int, distanceM: Double, altitudeM: Double, speedMps: Double) {
        let span = max(bucketSec, 1e-9)
        samples.append(Sample(
            power: Int((bucketPowerJ / span).rounded()),
            cadence: Int((bucketCadence / span).rounded()),
            hr: hr,
            distanceM: distanceM,
            altitudeM: altitudeM,
            speedMps: speedMps
        ))
        bucketSec = 0; bucketPowerJ = 0; bucketCadence = 0
    }

    /// Sample interval (1, 5 or 10 s, as `RideRecorder` picks it for long
    /// rides) and the arrays for `RideSessionModel.samplesJSON`. Positions
    /// are rounded (0.1 m, 0.01 m/s) to keep the JSON small.
    func snapshot() -> (interval: Int, samples: RideSamples) {
        let durationMin = Double(samples.count) / 60
        let interval = durationMin > 150 ? 10 : (durationMin > 90 ? 5 : 1)

        func round(_ x: Double, _ step: Double) -> Double { (x / step).rounded() * step }
        var power: [Int] = [], cadence: [Int] = [], hr: [Int] = []
        var distance: [Double] = [], altitude: [Double] = [], speed: [Double] = []
        var i = 0
        while i < samples.count {
            let chunk = samples[i..<min(i + interval, samples.count)]
            let n = chunk.count
            power.append(chunk.map(\.power).reduce(0, +) / n)
            cadence.append(chunk.map(\.cadence).reduce(0, +) / n)
            hr.append(chunk.map(\.hr).reduce(0, +) / n)
            // Position at the end of the chunk; speed averaged over it.
            let last = chunk[chunk.endIndex - 1]
            distance.append(round(last.distanceM, 0.1))
            altitude.append(round(last.altitudeM, 0.1))
            speed.append(round(chunk.map(\.speedMps).reduce(0, +) / Double(n), 0.01))
            i += interval
        }
        return (interval, RideSamples(
            power: power, cadence: cadence, hr: hr,
            targets: Array(repeating: 0, count: power.count),
            distanceM: distance, altitudeM: altitude, speedMps: speed
        ))
    }
}

// MARK: Personal best from History

extension CourseRideRecorder {
    /// A climb timed from saved samples (as `snapshot()` writes them): the
    /// time from crossing `startS` to crossing `endS` and the splits every
    /// `spacingM`, like `ClimbTimer`'s. Crossings are interpolated between
    /// samples, each of which holds the position at the end of its
    /// interval. Nil when the samples don't cover the climb from before its
    /// start to the summit.
    static func climbTiming(
        samples: RideSamples,
        interval: Int,
        startS: Double,
        endS: Double,
        spacingM: Double = ClimbTimer.defaultSplitSpacingM
    ) -> (seconds: Double, splits: [Double])? {
        guard let dist = samples.distanceM, !dist.isEmpty, endS > startS else { return nil }
        let step = Double(max(interval, 1))
        // Where the ride began: the first position less one interval's riding.
        let rideStart = max(0, dist[0] - (samples.speedMps?.first ?? 0) * step)
        guard rideStart <= startS else { return nil }

        // Ride time at which the rider first reached `target`.
        var i = 0
        var prevT = 0.0, prevD = rideStart
        func crossing(_ target: Double) -> Double? {
            while i < dist.count {
                let t = Double(i + 1) * step, d = dist[i]
                if d >= target {
                    let span = d - prevD
                    return span > 0 ? prevT + (target - prevD) / span * (t - prevT) : t
                }
                prevT = t; prevD = d
                i += 1
            }
            return nil
        }

        guard let start = crossing(startS) else { return nil }
        let marks = ClimbTimer.splitDistances(lengthM: endS - startS, spacingM: spacingM)
        var splits: [Double] = []
        for (k, mark) in marks.enumerated() {
            let target = k == marks.count - 1 ? endS : startS + mark
            guard let t = crossing(target) else { return nil }
            splits.append(max(0, t - start))
        }
        guard let seconds = splits.last, seconds > 0 else { return nil }
        return (seconds, splits)
    }

    /// Works a course's personal best out again after a ride was deleted
    /// from History. `sessions` are the saved rides that remain. While the
    /// ride that set the PB is among them the PB stays as it is; otherwise
    /// it becomes the fastest climb they hold (rides on virtual power never
    /// count, nor rides from before the PB was last cleared), or none. A
    /// course without a PB (never set, or reset by the rider) stays without
    /// one.
    @MainActor
    static func recomputePersonalBest(courseID: String, from sessions: [RideSessionModel]) {
        guard let summary = CourseCatalog.summary(id: courseID) else { return }
        recomputePersonalBest(courseID: courseID, climbStartS: summary.climbStartS,
                              climbEndS: summary.climbEndS, from: sessions)
    }

    @MainActor
    static func recomputePersonalBest(courseID: String, climbStartS: Double, climbEndS: Double,
                                      from sessions: [RideSessionModel]) {
        guard AppSettings.personalBestSeconds(courseID: courseID) != nil else { return }
        let workoutID = CourseRideController.workoutID(courseID: courseID)
        let rides = sessions.filter { !$0.isDeleted && $0.workoutId == workoutID }
        if let id = AppSettings.personalBestSessionID(courseID: courseID), rides.contains(where: { $0.id == id }) {
            return
        }
        // A reset PB stays reset: the rides before it are out of the running.
        let clearedAt = AppSettings.personalBestClearedAt(courseID: courseID) ?? .distantPast
        var best: (seconds: Double, splits: [Double], id: UUID)?
        for ride in rides where ride.date >= clearedAt {
            guard let samples = ride.samples, samples.climbOnVirtualPower != true,
                  let timing = climbTiming(samples: samples, interval: ride.sampleInterval,
                                           startS: climbStartS, endS: climbEndS)
            else { continue }
            if timing.seconds < best?.seconds ?? .infinity {
                best = (timing.seconds, timing.splits, ride.id)
            }
        }
        if let best {
            AppSettings.setPersonalBest(seconds: best.seconds, splits: best.splits, courseID: courseID, sessionID: best.id)
        } else {
            AppSettings.clearPersonalBest(courseID: courseID)
        }
    }
}

/// Time-weighted mean of a value over a trailing window, e.g. 3-second
/// power for the HUD.
struct RollingAverage: Sendable {
    let windowSec: Double
    private var entries: [(dt: Double, value: Double)] = []
    private var coveredSec: Double = 0

    init(windowSec: Double) {
        self.windowSec = max(windowSec, 0.001)
    }

    mutating func add(_ value: Double, dt: Double) {
        guard dt > 0 else { return }
        entries.append((dt, value))
        coveredSec += dt
        // Drop whole entries that fall outside the window.
        while let first = entries.first, coveredSec - first.dt >= windowSec {
            coveredSec -= first.dt
            entries.removeFirst()
        }
    }

    /// Mean over the last `windowSec` (or less, early on); the oldest entry
    /// counts only for the part inside the window.
    var mean: Double {
        guard coveredSec > 0 else { return 0 }
        let overflow = max(0, coveredSec - windowSec)
        var sum = 0.0
        for (i, e) in entries.enumerated() {
            sum += e.value * (i == 0 ? e.dt - overflow : e.dt)
        }
        return sum / (coveredSec - overflow)
    }

    mutating func reset() {
        entries.removeAll(keepingCapacity: true)
        coveredSec = 0
    }
}
