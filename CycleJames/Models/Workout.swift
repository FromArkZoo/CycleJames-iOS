import Foundation

enum WorkoutCategory: String, CaseIterable, Codable, Identifiable, Hashable {
    case vo2max = "VO2max"
    case threshold = "Threshold"
    case sweetSpot = "Sweet Spot"
    case endurance = "Endurance"
    case recovery = "Recovery"

    var id: String { rawValue }
    var sortOrder: Int {
        switch self {
        case .vo2max: 0
        case .threshold: 1
        case .sweetSpot: 2
        case .endurance: 3
        case .recovery: 4
        }
    }
}

enum Interval: Codable, Hashable {
    case steady(name: String, duration: Int, powerPercent: Double)
    case ramp(name: String, duration: Int, startPercent: Double, endPercent: Double)

    var name: String {
        switch self {
        case .steady(let n, _, _): n
        case .ramp(let n, _, _, _): n
        }
    }

    var duration: Int {
        switch self {
        case .steady(_, let d, _): d
        case .ramp(_, let d, _, _): d
        }
    }

    /// Returns power percent at a given second within this interval (linearly interpolated for ramps).
    func powerPercent(atElapsed elapsed: Int) -> Double {
        switch self {
        case .steady(_, _, let pct):
            return pct
        case .ramp(_, let d, let startPct, let endPct):
            guard d > 0 else { return startPct }
            let progress = min(Double(elapsed) / Double(d), 1.0)
            return startPct + (endPct - startPct) * progress
        }
    }

    var midPercent: Double {
        switch self {
        case .steady(_, _, let pct): pct
        case .ramp(_, _, let s, let e): (s + e) / 2
        }
    }

    var maxPercent: Double {
        switch self {
        case .steady(_, _, let pct): pct
        case .ramp(_, _, let s, let e): max(s, e)
        }
    }
}

struct Workout: Identifiable, Hashable, Codable {
    let id: String
    let name: String
    let description: String
    let category: WorkoutCategory
    let intervals: [Interval]
    var isCustom: Bool = false

    var totalDuration: Int { intervals.reduce(0) { $0 + $1.duration } }

    /// Find the interval covering the given absolute elapsed seconds.
    func intervalContext(forElapsed elapsed: Int) -> IntervalContext? {
        var cum = 0
        for (i, iv) in intervals.enumerated() {
            if elapsed < cum + iv.duration {
                let intervalElapsed = elapsed - cum
                return IntervalContext(
                    index: i,
                    interval: iv,
                    elapsed: intervalElapsed,
                    remaining: iv.duration - intervalElapsed,
                    intervalStart: cum
                )
            }
            cum += iv.duration
        }
        return nil
    }
}

struct IntervalContext: Hashable {
    let index: Int
    let interval: Interval
    let elapsed: Int      // seconds into this interval
    let remaining: Int    // seconds until next interval
    let intervalStart: Int // absolute seconds at which this interval starts
}
