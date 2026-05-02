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
        ),

        // ---- Quick options (≤45min) ----
        Workout(
            id: "easy-15",
            name: "Quick Spin",
            description: "15-minute easy spin. Perfect when you only have a few minutes to move the legs.",
            category: .recovery,
            intervals: [
                R("Warm Up", 3, 40, 50),
                S("Easy", 9, 50),
                R("Cool Down", 3, 50, 35)
            ]
        ),
        Workout(
            id: "easy-45",
            name: "Easy 45",
            description: "45-minute Zone 1-2 ride. Active recovery between hard days.",
            category: .recovery,
            intervals: [
                R("Warm Up", 5, 40, 55),
                S("Easy 1", 15, 55),
                S("Easy 2", 15, 58),
                S("Easy 3", 5, 55),
                R("Cool Down", 5, 55, 40)
            ]
        ),
        Workout(
            id: "endurance-45",
            name: "Endurance 45",
            description: "45-minute Zone 2 ride. Solid aerobic stimulus when time is tight.",
            category: .endurance,
            intervals: [
                R("Warm Up", 5, 45, 65),
                S("Endurance", 30, 65),
                R("Cool Down", 10, 65, 45)
            ]
        ),
        Workout(
            id: "sweet-spot-45",
            name: "Sweet Spot 45",
            description: "45-minute sweet spot session. 2x12min at 90% FTP. Quality bang-for-buck.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 8, 45, 70),
                S("SS 1", 12, 88), S("Recovery", 4, 55),
                S("SS 2", 12, 92),
                R("Cool Down", 9, 70, 40)
            ]
        ),
        Workout(
            id: "threshold-45",
            name: "Threshold 45",
            description: "45-minute threshold session. 2x12min at FTP. Compact and effective.",
            category: .threshold,
            intervals: [
                R("Warm Up", 8, 45, 75),
                S("Threshold 1", 12, 98), S("Recovery", 4, 55),
                S("Threshold 2", 12, 100),
                R("Cool Down", 9, 70, 40)
            ]
        ),

        // ---- Endurance: 75min and the long stuff ----
        Workout(
            id: "endurance-75",
            name: "Endurance 75",
            description: "75-minute Zone 2 ride with two short tempo accelerations.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance 1", 25, 65),
                S("Tempo Bump", 5, 78),
                S("Endurance 2", 25, 65),
                R("Cool Down", 10, 65, 45)
            ]
        ),
        Workout(
            id: "endurance-hills-90",
            name: "Rolling Hills 90",
            description: "90-minute endurance with rolling hill efforts. Simulates outdoor varied terrain.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Flat", 10, 65),
                S("Climb 1", 4, 82), S("Descent", 2, 50),
                S("Flat", 10, 65),
                S("Climb 2", 5, 85), S("Descent", 2, 50),
                S("Flat", 10, 65),
                S("Climb 3", 6, 88), S("Descent", 2, 50),
                S("Flat", 14, 65),
                S("Final Climb", 5, 90),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "long-ride-4hr",
            name: "Long Ride 4hr",
            description: "4-hour endurance ride. Steady Zone 2 with periodic tempo pulls — classic base-builder.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 40, 65),
                S("Endurance 1", 40, 65),
                S("Tempo Pull", 8, 78),
                S("Endurance 2", 35, 65),
                S("Tempo Pull", 8, 78),
                S("Endurance 3", 35, 65),
                S("Tempo Pull", 8, 80),
                S("Endurance 4", 35, 63),
                S("Easy Spin", 10, 58),
                S("Endurance 5", 30, 65),
                R("Cool Down", 16, 60, 40)
            ]
        ),
        Workout(
            id: "long-ride-5hr",
            name: "Epic 5hr",
            description: "5-hour endurance grinder. Long aerobic base with varied tempo and one solid sweet spot block.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 40, 65),
                S("Endurance 1", 45, 65),
                S("Tempo", 10, 78),
                S("Endurance 2", 40, 63),
                S("Sweet Spot Block", 15, 88), S("Recovery", 5, 55),
                S("Endurance 3", 40, 63),
                S("Tempo", 10, 80),
                S("Endurance 4", 40, 63),
                S("Easy Spin", 10, 55),
                S("Endurance 5", 30, 60),
                R("Cool Down", 20, 55, 40)
            ]
        ),
        Workout(
            id: "long-ride-6hr",
            name: "Century 6hr",
            description: "6-hour ultra-endurance ride. Long unbroken aerobic work — for century / brevet preparation.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 40, 60),
                S("Endurance 1", 50, 62),
                S("Tempo", 10, 75),
                S("Endurance 2", 50, 62),
                S("Tempo", 10, 78),
                S("Endurance 3", 50, 60),
                S("Easy", 15, 55),
                S("Endurance 4", 45, 62),
                S("Tempo Surge", 8, 78),
                S("Endurance 5", 35, 60),
                S("Easy Spin", 12, 55),
                S("Endurance 6", 25, 60),
                R("Cool Down", 15, 55, 40)
            ]
        ),

        // ---- More Sweet Spot variety ----
        Workout(
            id: "ss-30-30",
            name: "SS 30/30",
            description: "60-minute short-block sweet spot. 30sec on / 30sec off at 90% FTP. Builds repeat efforts.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                Ssec("On 1", 30, 90), Ssec("Off 1", 30, 60),
                Ssec("On 2", 30, 90), Ssec("Off 2", 30, 60),
                Ssec("On 3", 30, 90), Ssec("Off 3", 30, 60),
                Ssec("On 4", 30, 90), Ssec("Off 4", 30, 60),
                Ssec("On 5", 30, 90), Ssec("Off 5", 30, 60),
                Ssec("On 6", 30, 90), Ssec("Off 6", 30, 60),
                Ssec("On 7", 30, 90), Ssec("Off 7", 30, 60),
                Ssec("On 8", 30, 90), Ssec("Off 8", 30, 60),
                Ssec("On 9", 30, 92), Ssec("Off 9", 30, 60),
                Ssec("On 10", 30, 92), Ssec("Off 10", 30, 60),
                Ssec("On 11", 30, 92), Ssec("Off 11", 30, 60),
                Ssec("On 12", 30, 92), Ssec("Off 12", 30, 60),
                Ssec("On 13", 30, 94), Ssec("Off 13", 30, 60),
                Ssec("On 14", 30, 94), Ssec("Off 14", 30, 60),
                Ssec("On 15", 30, 94), Ssec("Off 15", 30, 60),
                Ssec("On 16", 30, 94), Ssec("Off 16", 30, 60),
                S("Endurance", 8, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),

        // ---- More Threshold variety ----
        Workout(
            id: "threshold-4x8",
            name: "4x8 Threshold",
            description: "60-minute classic 4x8min at 100-104% FTP. Premier threshold workout.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Threshold 1", 8, 100), S("Recovery", 3, 55),
                S("Threshold 2", 8, 102), S("Recovery", 3, 55),
                S("Threshold 3", 8, 102), S("Recovery", 3, 55),
                S("Threshold 4", 8, 104),
                R("Cool Down", 9, 70, 40)
            ]
        ),
        Workout(
            id: "threshold-2x15",
            name: "2x15 Threshold",
            description: "60-minute 2x15min at 95-100% FTP. Builds time at threshold without long recovery.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Threshold 1", 15, 95), S("Recovery", 5, 55),
                S("Threshold 2", 15, 100),
                R("Cool Down", 15, 70, 40)
            ]
        ),

        // ---- More VO2max variety ----
        Workout(
            id: "vo2-30-30",
            name: "VO2 30/30s",
            description: "45-minute Tabata-style VO2max. 30sec at 130% / 30sec at 50%. Brutal but short.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 2, 95),
                Ssec("On 1", 30, 130), Ssec("Off 1", 30, 50),
                Ssec("On 2", 30, 130), Ssec("Off 2", 30, 50),
                Ssec("On 3", 30, 130), Ssec("Off 3", 30, 50),
                Ssec("On 4", 30, 130), Ssec("Off 4", 30, 50),
                Ssec("On 5", 30, 130), Ssec("Off 5", 30, 50),
                Ssec("On 6", 30, 130), Ssec("Off 6", 30, 50),
                Ssec("On 7", 30, 130), Ssec("Off 7", 30, 50),
                Ssec("On 8", 30, 130), Ssec("Off 8", 30, 50),
                S("Recovery Block", 5, 55),
                Ssec("On 9", 30, 130), Ssec("Off 9", 30, 50),
                Ssec("On 10", 30, 130), Ssec("Off 10", 30, 50),
                Ssec("On 11", 30, 130), Ssec("Off 11", 30, 50),
                Ssec("On 12", 30, 130), Ssec("Off 12", 30, 50),
                Ssec("On 13", 30, 130), Ssec("Off 13", 30, 50),
                Ssec("On 14", 30, 130), Ssec("Off 14", 30, 50),
                Ssec("On 15", 30, 130), Ssec("Off 15", 30, 50),
                Ssec("On 16", 30, 130),
                R("Cool Down", 8, 65, 40)
            ]
        ),
        Workout(
            id: "vo2-40-20",
            name: "VO2 40/20s",
            description: "60-minute 40sec on / 20sec off at 120% FTP. Three sets of 10 reps with full recovery between.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                Ssec("On 1", 40, 120), Ssec("Off 1", 20, 50),
                Ssec("On 2", 40, 120), Ssec("Off 2", 20, 50),
                Ssec("On 3", 40, 120), Ssec("Off 3", 20, 50),
                Ssec("On 4", 40, 120), Ssec("Off 4", 20, 50),
                Ssec("On 5", 40, 120), Ssec("Off 5", 20, 50),
                Ssec("On 6", 40, 120), Ssec("Off 6", 20, 50),
                Ssec("On 7", 40, 120), Ssec("Off 7", 20, 50),
                Ssec("On 8", 40, 120), Ssec("Off 8", 20, 50),
                Ssec("On 9", 40, 120), Ssec("Off 9", 20, 50),
                Ssec("On 10", 40, 120),
                S("Recovery Block", 5, 55),
                Ssec("On 11", 40, 120), Ssec("Off 11", 20, 50),
                Ssec("On 12", 40, 120), Ssec("Off 12", 20, 50),
                Ssec("On 13", 40, 120), Ssec("Off 13", 20, 50),
                Ssec("On 14", 40, 120), Ssec("Off 14", 20, 50),
                Ssec("On 15", 40, 120), Ssec("Off 15", 20, 50),
                Ssec("On 16", 40, 120), Ssec("Off 16", 20, 50),
                Ssec("On 17", 40, 120), Ssec("Off 17", 20, 50),
                Ssec("On 18", 40, 120), Ssec("Off 18", 20, 50),
                Ssec("On 19", 40, 120), Ssec("Off 19", 20, 50),
                Ssec("On 20", 40, 120),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "vo2-5x5",
            name: "5x5 VO2",
            description: "75-minute big-block VO2max. 5x5min at 110% FTP. Massive aerobic stimulus.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 3, 95),
                S("VO2 1", 5, 108), S("Recovery", 4, 50),
                S("VO2 2", 5, 110), S("Recovery", 4, 50),
                S("VO2 3", 5, 110), S("Recovery", 4, 50),
                S("VO2 4", 5, 110), S("Recovery", 4, 50),
                S("VO2 5", 5, 112),
                S("Endurance", 5, 65),
                R("Cool Down", 11, 65, 40)
            ]
        ),

        // ---- Anaerobic / Sprint (currently missing) ----
        Workout(
            id: "sprint-power-30",
            name: "Sprint Power",
            description: "30-minute sprint workout. 8x15sec all-out with full recovery. Builds neuromuscular power.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 8, 45, 70),
                S("Activation", 2, 80),
                Ssec("Sprint 1", 15, 200), Ssec("Recovery", 165, 45),
                Ssec("Sprint 2", 15, 220), Ssec("Recovery", 165, 45),
                Ssec("Sprint 3", 15, 240), Ssec("Recovery", 165, 45),
                Ssec("Sprint 4", 15, 240), Ssec("Recovery", 165, 45),
                Ssec("Sprint 5", 15, 250), Ssec("Recovery", 165, 45),
                Ssec("Sprint 6", 15, 250), Ssec("Recovery", 165, 45),
                Ssec("Sprint 7", 15, 260), Ssec("Recovery", 165, 45),
                Ssec("Sprint 8", 15, 260),
                R("Cool Down", 5, 55, 35)
            ]
        ),
        Workout(
            id: "lactate-tolerance-45",
            name: "Lactate Tolerance",
            description: "45-minute anaerobic capacity. 6x90sec at 130% FTP — race-finish punch.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 2, 100),
                Ssec("AC 1", 90, 130), S("Recovery", 3, 50),
                Ssec("AC 2", 90, 130), S("Recovery", 3, 50),
                Ssec("AC 3", 90, 132), S("Recovery", 3, 50),
                Ssec("AC 4", 90, 132), S("Recovery", 3, 50),
                Ssec("AC 5", 90, 135), S("Recovery", 3, 50),
                Ssec("AC 6", 90, 135),
                R("Cool Down", 8, 60, 40)
            ]
        ),
        Workout(
            id: "race-winner-60",
            name: "Race Winner",
            description: "60-minute race-prep mix: tempo, threshold, then sprint finishes. Simulates a real race finale.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Tempo Pace", 8, 80),
                S("Threshold Push", 5, 100), S("Recovery", 3, 55),
                S("Threshold Push", 5, 102), S("Recovery", 3, 55),
                S("Attack 1", 1, 130), Ssec("Recovery", 90, 50),
                S("Attack 2", 1, 130), Ssec("Recovery", 90, 50),
                Ssec("Sprint 1", 20, 220), Ssec("Recovery", 100, 50),
                Ssec("Sprint 2", 20, 240), Ssec("Recovery", 100, 50),
                Ssec("Final Sprint", 30, 250),
                R("Cool Down", 12, 60, 40)
            ]
        ),

        // ---- Tempo focus ----
        Workout(
            id: "tempo-60",
            name: "Tempo 60",
            description: "60-minute steady tempo. 35min at 78-82% FTP — the productive grey zone done right.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Tempo 1", 15, 78),
                S("Easy Reset", 3, 60),
                S("Tempo 2", 17, 82),
                R("Cool Down", 15, 70, 40)
            ]
        )
    ]
}
