import Foundation

/// Steady interval helper.
private func S(_ name: String, _ minutes: Double, _ pct: Double) -> Interval {
    .steady(name: name, duration: Int(minutes * 60), powerPercent: pct)
}
private func Ssec(_ name: String, _ seconds: Int, _ pct: Double) -> Interval {
    .steady(name: name, duration: seconds, powerPercent: pct)
}
private func R(_ name: String, _ minutes: Double, _ start: Double, _ end: Double) -> Interval {
    .ramp(name: name, duration: Int(minutes * 60), startPercent: start, endPercent: end)
}

enum BuiltInWorkouts {
    static let all: [Workout] = [
        // VO2max — flagship
        Workout(
            id: "vo2max-intervals",
            name: "VO2max Intervals",
            description: "5x3min at 115% FTP with 3min recovery. Builds max aerobic capacity.",
            category: .vo2max,
            intervals: [
                R("Warmup", 10, 40, 75),
                S("Settle", 5, 75),
                S("VO2max 1", 3, 115), S("Recovery", 3, 50),
                S("VO2max 2", 3, 115), S("Recovery", 3, 50),
                S("VO2max 3", 3, 115), S("Recovery", 3, 50),
                S("VO2max 4", 3, 115), S("Recovery", 3, 50),
                S("VO2max 5", 3, 115), S("Recovery", 3, 50),
                R("Cooldown", 10, 60, 40)
            ]
        ),
        Workout(
            id: "endurance-ride",
            name: "Endurance Ride",
            description: "90min steady Zone 2 at 65% FTP. Builds aerobic base and fat oxidation.",
            category: .endurance,
            intervals: [
                R("Warmup", 10, 40, 65),
                S("Endurance", 70, 65),
                R("Cooldown", 10, 65, 40)
            ]
        ),

        // Recovery
        Workout(
            id: "easy-spin-30",
            name: "Easy Spin",
            description: "30-minute easy recovery spin. Keep it light and loose.",
            category: .recovery,
            intervals: [
                R("Warm Up", 5, 40, 50),
                S("Easy Spin", 20, 50),
                R("Cool Down", 5, 50, 35)
            ]
        ),
        Workout(
            id: "recovery-60",
            name: "Recovery 60",
            description: "60-minute recovery ride. Stay in Zone 1-2 throughout.",
            category: .recovery,
            intervals: [
                R("Warm Up", 10, 40, 55),
                S("Recovery", 40, 55),
                R("Cool Down", 10, 55, 40)
            ]
        ),

        // Endurance
        Workout(
            id: "endurance-60",
            name: "Endurance 60",
            description: "60-minute steady Zone 2 ride. Build your aerobic base.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance", 40, 65),
                R("Cool Down", 10, 65, 45)
            ]
        ),
        Workout(
            id: "endurance-120",
            name: "Endurance 120",
            description: "2-hour endurance ride with small tempo bumps to keep things interesting.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance 1", 30, 65),
                S("Tempo Bump", 5, 78),
                S("Endurance 2", 30, 65),
                S("Tempo Bump", 5, 78),
                S("Endurance 3", 25, 65),
                R("Cool Down", 10, 65, 45)
            ]
        ),
        Workout(
            id: "endurance-150",
            name: "Endurance 150",
            description: "2.5-hour long endurance ride. Steady Zone 2 with tempo pickups.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance 1", 40, 65),
                S("Tempo Surge", 5, 80),
                S("Endurance 2", 40, 65),
                S("Tempo Surge", 5, 80),
                S("Endurance 3", 40, 65),
                R("Cool Down", 10, 65, 45)
            ]
        ),
        Workout(
            id: "grand-fondo",
            name: "Grand Fondo",
            description: "3-hour endurance ride simulating a long group ride with varied tempo.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance", 40, 65),
                S("Tempo Pull", 10, 80),
                S("Endurance", 30, 65),
                S("Climb Effort", 8, 85),
                S("Recovery", 5, 55),
                S("Endurance", 30, 65),
                S("Tempo Pull", 10, 80),
                S("Endurance", 20, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),

        // Sweet Spot
        Workout(
            id: "sweet-spot-60",
            name: "Sweet Spot 60",
            description: "60-minute sweet spot session. 3x10min at 88-93% FTP.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("SS Interval 1", 10, 90), S("Recovery", 5, 55),
                S("SS Interval 2", 10, 90), S("Recovery", 5, 55),
                S("SS Interval 3", 10, 92),
                R("Cool Down", 10, 70, 45)
            ]
        ),
        Workout(
            id: "sweet-spot-90",
            name: "Sweet Spot 90",
            description: "90-minute sweet spot endurance. 3x20min at 88-93% FTP.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Settle", 5, 70),
                S("SS Block 1", 20, 88), S("Recovery", 5, 55),
                S("SS Block 2", 20, 90), S("Recovery", 5, 55),
                S("SS Block 3", 20, 92),
                R("Cool Down", 10, 70, 45)
            ]
        ),
        Workout(
            id: "ss-pyramid",
            name: "SS Pyramid",
            description: "2-hour sweet spot pyramid: 10-15-20-15-10min blocks building intensity.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("SS 10min", 10, 86), S("Recovery", 5, 55),
                S("SS 15min", 15, 88), S("Recovery", 5, 55),
                S("SS 20min", 20, 90), S("Recovery", 5, 55),
                S("SS 15min", 15, 92), S("Recovery", 5, 55),
                S("SS 10min", 10, 94),
                R("Cool Down", 10, 70, 45)
            ]
        ),
        Workout(
            id: "ss-150",
            name: "Sweet Spot 150",
            description: "2.5-hour sweet spot endurance. Long blocks building aerobic ceiling.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Endurance", 15, 65),
                S("SS Block 1", 25, 88), S("Recovery", 5, 55),
                S("Endurance", 10, 65),
                S("SS Block 2", 25, 90), S("Recovery", 5, 55),
                S("Endurance", 10, 65),
                S("SS Block 3", 20, 92),
                S("Endurance", 10, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "ss-180",
            name: "Sweet Spot 180",
            description: "3-hour sweet spot marathon. Long blocks with endurance valleys.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance", 20, 65),
                S("SS Block 1", 20, 88), S("Recovery", 5, 55),
                S("Endurance", 15, 65),
                S("SS Block 2", 20, 90), S("Recovery", 5, 55),
                S("Endurance", 15, 65),
                S("SS Block 3", 20, 88), S("Recovery", 5, 55),
                S("Endurance", 15, 65),
                S("SS Block 4", 15, 92),
                R("Cool Down", 10, 65, 40)
            ]
        ),

        // Threshold
        Workout(
            id: "threshold-test-30",
            name: "Threshold Test",
            description: "30-minute FTP test protocol. 20min all-out effort for FTP estimation.",
            category: .threshold,
            intervals: [
                R("Warm Up", 5, 45, 70),
                Ssec("Opener", 60, 110),
                S("Recovery", 4, 50),
                S("20min Test", 20, 100),
                R("Cool Down", 5, 60, 40)
            ]
        ),
        Workout(
            id: "ftp-builder-60",
            name: "FTP Builder",
            description: "60-minute threshold builder. 2x20min at 95-100% FTP.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Threshold 1", 20, 95),
                S("Recovery", 5, 55),
                S("Threshold 2", 20, 100),
                R("Cool Down", 10, 70, 45)
            ]
        ),
        Workout(
            id: "threshold-repeats-90",
            name: "Threshold Repeats",
            description: "90-minute threshold session. 4x12min at 95-102% FTP. Builds time at threshold.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Settle", 5, 75),
                S("Threshold 1", 12, 95), S("Recovery", 5, 55),
                S("Threshold 2", 12, 97), S("Recovery", 5, 55),
                S("Threshold 3", 12, 100), S("Recovery", 5, 55),
                S("Threshold 4", 12, 102),
                R("Cool Down", 10, 70, 45)
            ]
        ),
        Workout(
            id: "2hr-threshold",
            name: "2hr Threshold",
            description: "2-hour threshold session. Extended time near FTP for race prep.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Threshold 1", 20, 95), S("Recovery", 5, 55),
                S("Threshold 2", 20, 97), S("Recovery", 5, 55),
                S("Threshold 3", 15, 100), S("Recovery", 5, 55),
                S("Threshold 4", 15, 100),
                S("Endurance", 10, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "threshold-endurance-150",
            name: "Threshold Endurance",
            description: "2.5-hour mixed threshold/endurance ride. Simulates race-pace riding.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Endurance", 15, 65),
                S("Threshold 1", 15, 95), S("Recovery", 5, 55),
                S("Endurance", 15, 65),
                S("Threshold 2", 15, 97), S("Recovery", 5, 55),
                S("Endurance", 15, 65),
                S("Threshold 3", 12, 100), S("Recovery", 5, 55),
                S("Endurance", 15, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),

        // VO2max
        Workout(
            id: "vo2max-blasts-30",
            name: "Short VO2max Blasts",
            description: "30-minute short sharp VO2max session. 8x1min at 120% FTP.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 8, 45, 75),
                Ssec("VO2 1", 60, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 2", 60, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 3", 60, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 4", 60, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 5", 60, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 6", 60, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 7", 60, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 8", 60, 120),
                R("Cool Down", 5, 60, 40)
            ]
        ),
        Workout(
            id: "classic-vo2max-60",
            name: "Classic VO2max",
            description: "60-minute VO2max session. 5x3min at 115% FTP with equal recovery.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 2, 110), S("Settle", 3, 55),
                S("VO2 1", 3, 115), S("Recovery", 3, 50),
                S("VO2 2", 3, 115), S("Recovery", 3, 50),
                S("VO2 3", 3, 115), S("Recovery", 3, 50),
                S("VO2 4", 3, 115), S("Recovery", 3, 50),
                S("VO2 5", 3, 115),
                R("Cool Down", 10, 60, 40)
            ]
        ),
        Workout(
            id: "vo2max-marathon-120",
            name: "VO2max Marathon",
            description: "2-hour session with VO2max intervals sandwiched between endurance blocks.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Endurance", 15, 65),
                S("VO2 1", 3, 115), S("Recovery", 3, 50),
                S("VO2 2", 3, 115), S("Recovery", 3, 50),
                S("VO2 3", 3, 118), S("Recovery", 3, 50),
                S("Endurance", 20, 65),
                S("VO2 4", 3, 115), S("Recovery", 3, 50),
                S("VO2 5", 3, 118), S("Recovery", 3, 50),
                S("Endurance", 10, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),

        // Mixed / Special
        Workout(
            id: "kitchen-sink-60",
            name: "Kitchen Sink",
            description: "60-minute mixed intensity session. All zones covered for full stimulation.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Tempo", 5, 80),
                S("Sweet Spot", 5, 90),
                S("Threshold", 3, 100),
                S("Recovery", 3, 50),
                S("VO2 Burst 1", 2, 115), S("Recovery", 2, 50),
                S("VO2 Burst 2", 2, 118), S("Recovery", 2, 50),
                S("Threshold", 5, 97), S("Recovery", 2, 50),
                S("Sweet Spot", 5, 90),
                R("Cool Down", 10, 70, 40)
            ]
        ),
        Workout(
            id: "over-unders-60",
            name: "Over-Unders",
            description: "60-minute over-under session. Alternate above and below threshold to build lactate tolerance.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Under", 2, 92), S("Over", 2, 105),
                S("Under", 2, 92), S("Over", 2, 105),
                S("Under", 2, 92), S("Over", 2, 105),
                S("Recovery", 5, 55),
                S("Under", 2, 93), S("Over", 2, 107),
                S("Under", 2, 93), S("Over", 2, 107),
                S("Under", 2, 93), S("Over", 2, 107),
                R("Cool Down", 10, 70, 40)
            ]
        ),
        Workout(
            id: "ramp-test-30",
            name: "Ramp Test",
            description: "30-minute ramp test for FTP estimation. Progressive ramp to failure.",
            category: .threshold,
            intervals: [
                S("Easy Start", 2, 46),
                Ssec("Step 1", 60, 52), Ssec("Step 2", 60, 58), Ssec("Step 3", 60, 64),
                Ssec("Step 4", 60, 70), Ssec("Step 5", 60, 76), Ssec("Step 6", 60, 82),
                Ssec("Step 7", 60, 88), Ssec("Step 8", 60, 94), Ssec("Step 9", 60, 100),
                Ssec("Step 10", 60, 106), Ssec("Step 11", 60, 112), Ssec("Step 12", 60, 118),
                Ssec("Step 13", 60, 124), Ssec("Step 14", 60, 130), Ssec("Step 15", 60, 136),
                Ssec("Step 16", 60, 142), Ssec("Step 17", 60, 148),
                R("Cool Down", 8, 60, 35)
            ]
        )
    ]
}
