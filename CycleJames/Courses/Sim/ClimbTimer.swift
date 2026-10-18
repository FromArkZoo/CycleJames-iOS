import Foundation

/// Times one climb within a ride: the exact (interpolated) moments the
/// rider crosses its start and summit, a split every `splitSpacingM` (time
/// since the start), and the work done in between.
///
/// Times are ride time in seconds (moving time, pauses excluded).
/// Distances are along the route, in metres.
struct ClimbTimer: Sendable, Equatable {
    static let defaultSplitSpacingM = 10.0

    let startS: Double
    let endS: Double
    let splitSpacingM: Double
    /// False when the ride began past the climb start: no valid time.
    let isEligible: Bool
    /// Distances from the climb start at which splits are taken.
    let splitDistancesM: [Double]

    /// Ride time at which the rider crossed the climb start.
    private(set) var startTime: Double?
    /// Ride time at which the rider crossed the summit.
    private(set) var summitTime: Double?
    /// Time since the climb start at each of `splitDistances`, filled in as
    /// they are passed; `splits[0]` is 0 and the last one is the climb time.
    private(set) var splits: [Double] = []
    /// Rider work between the start and summit crossings, joules.
    private(set) var workJ: Double = 0

    var lengthM: Double { endS - startS }
    var isComplete: Bool { summitTime != nil }

    /// Start to summit; nil until the summit is reached.
    var climbTimeSec: Double? {
        guard let startTime, let summitTime else { return nil }
        return summitTime - startTime
    }

    var avgPowerW: Double? {
        guard let t = climbTimeSec, t > 0 else { return nil }
        return workJ / t
    }

    init(startS: Double, endS: Double, splitSpacingM: Double = Self.defaultSplitSpacingM, rideStartS: Double) {
        self.startS = startS
        self.endS = max(endS, startS)
        self.splitSpacingM = max(splitSpacingM, 1)
        self.isEligible = rideStartS <= startS
        self.splitDistancesM = Self.splitDistances(lengthM: self.endS - startS, spacingM: self.splitSpacingM)
    }

    /// Distances from the climb start at which splits are taken: every
    /// `spacingM`, plus the full length.
    static func splitDistances(lengthM: Double, spacingM: Double) -> [Double] {
        guard lengthM > 0, spacingM > 0 else { return [0] }
        // The tolerance keeps float noise in `lengthM` from adding a sliver.
        let count = Int((lengthM / spacingM - 1e-6).rounded(.up))
        return (0...count).map { min(Double($0) * spacingM, lengthM) }
    }

    /// Time since the climb start; frozen at the climb time once past the
    /// summit, nil before the start.
    func elapsed(at time: Double) -> Double? {
        guard let startTime else { return nil }
        return (summitTime ?? time) - startTime
    }

    /// Consumes one physics tick: the rider went from `s0` at ride time
    /// `t0` to `s1` at `t1` at a constant `powerW`. Crossings within the
    /// tick are interpolated linearly in distance.
    mutating func advance(fromS s0: Double, toS s1: Double, t0: Double, t1: Double, powerW: Double) {
        guard isEligible, summitTime == nil, s1 > s0, t1 >= t0 else { return }
        func time(at mark: Double) -> Double {
            t0 + (t1 - t0) * (mark - s0) / (s1 - s0)
        }

        if startTime == nil {
            guard s0 <= startS, startS < s1 else { return }
            startTime = time(at: startS)
            splits = [0]
        }
        guard let start = startTime else { return }

        let distances = splitDistancesM
        while splits.count < distances.count {
            let isLast = splits.count == distances.count - 1
            // The summit mark is exactly `endS`, so a ride that stops on it
            // (route end == summit) still counts.
            let mark = isLast ? endS : startS + distances[splits.count]
            guard mark <= s1 else { break }
            splits.append(max(0, time(at: mark) - start))
            if isLast { summitTime = start + splits[splits.count - 1] }
        }

        let enter = max(t0, start)
        let exit = summitTime ?? t1
        workJ += max(0, powerW) * max(0, exit - enter)
    }

    /// Time a reference run (a personal best) took to reach `distance`
    /// from the climb start, interpolated between its splits. Falls back to
    /// an even pace over `totalSec` when the splits are missing or were
    /// taken on a climb of a different length.
    static func referenceTime(
        atDistance distance: Double,
        splits: [Double]?,
        totalSec: Double,
        lengthM: Double,
        spacingM: Double = defaultSplitSpacingM
    ) -> Double {
        guard lengthM > 0 else { return totalSec }
        let d = min(max(distance, 0), lengthM)
        let marks = splitDistances(lengthM: lengthM, spacingM: spacingM)
        guard let splits, splits.count == marks.count, marks.count >= 2 else {
            return totalSec * d / lengthM
        }
        let k = min(Int(d / spacingM), marks.count - 2)
        let span = marks[k + 1] - marks[k]
        let f = span > 0 ? (d - marks[k]) / span : 0
        return splits[k] + (splits[k + 1] - splits[k]) * min(max(f, 0), 1)
    }
}
