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
                S("Endurance 2", 45, 63),
                S("Sweet Spot Block", 15, 88), S("Recovery", 5, 55),
                S("Endurance 3", 45, 63),
                S("Tempo", 10, 80),
                S("Endurance 4", 40, 63),
                S("Easy Spin", 10, 55),
                S("Endurance 5", 35, 60),
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
                S("Endurance 2", 55, 62),
                S("Tempo", 10, 78),
                S("Endurance 3", 55, 60),
                S("Easy", 15, 55),
                S("Endurance 4", 50, 62),
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
        ),

        // ---- More Recovery ----
        Workout(
            id: "easy-20",
            name: "Easy 20",
            description: "20-minute easy recovery spin. Wake the legs up without straining anything.",
            category: .recovery,
            intervals: [
                R("Warm Up", 3, 40, 50),
                S("Easy", 14, 50),
                R("Cool Down", 3, 50, 35)
            ]
        ),
        Workout(
            id: "recovery-75",
            name: "Recovery 75",
            description: "75-minute easy ride. Long aerobic flush at very low intensity.",
            category: .recovery,
            intervals: [
                R("Warm Up", 10, 40, 55),
                S("Easy", 55, 55),
                R("Cool Down", 10, 55, 40)
            ]
        ),
        Workout(
            id: "recovery-90",
            name: "Recovery 90",
            description: "90-minute Zone 1-2 ride. Pure aerobic time without any stress.",
            category: .recovery,
            intervals: [
                R("Warm Up", 10, 40, 55),
                S("Easy 1", 35, 55),
                S("Easy 2", 35, 58),
                R("Cool Down", 10, 55, 40)
            ]
        ),
        Workout(
            id: "cadence-recovery-45",
            name: "Cadence Recovery",
            description: "45-minute high-cadence recovery. Light watts but aim for 100+rpm to build pedalling smoothness.",
            category: .recovery,
            intervals: [
                R("Warm Up", 5, 40, 55),
                S("Spin Up 1", 5, 55),
                S("Spin Up 2", 5, 58),
                S("Spin Up 3", 5, 55),
                S("Spin Up 4", 5, 58),
                S("Spin Up 5", 5, 55),
                S("Spin Up 6", 5, 58),
                S("Easy", 5, 55),
                R("Cool Down", 5, 55, 40)
            ]
        ),
        Workout(
            id: "single-leg-30",
            name: "Single-Leg Drills",
            description: "30-minute pedalling-form session. Light watts, alternating single-leg drills to expose dead spots.",
            category: .recovery,
            intervals: [
                R("Warm Up", 5, 40, 55),
                Ssec("Right Leg 1", 30, 50), Ssec("Both", 60, 55),
                Ssec("Left Leg 1", 30, 50),  Ssec("Both", 60, 55),
                Ssec("Right Leg 2", 45, 50), Ssec("Both", 60, 55),
                Ssec("Left Leg 2", 45, 50),  Ssec("Both", 60, 55),
                Ssec("Right Leg 3", 60, 50), Ssec("Both", 60, 55),
                Ssec("Left Leg 3", 60, 50),  Ssec("Both", 60, 55),
                S("Easy", 10, 55),
                R("Cool Down", 4, 55, 40)
            ]
        ),

        // ---- More Endurance ----
        Workout(
            id: "endurance-105",
            name: "Endurance 105",
            description: "1h45 Zone 2 ride. Steady aerobic with one mid-ride tempo block.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance 1", 35, 65),
                S("Tempo Bump", 8, 78),
                S("Endurance 2", 42, 65),
                R("Cool Down", 10, 65, 45)
            ]
        ),
        Workout(
            id: "endurance-135",
            name: "Endurance 135",
            description: "2h15 endurance ride. Steady Z2 with rolling tempo accents.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance 1", 25, 65),
                S("Tempo", 6, 78),
                S("Endurance 2", 25, 65),
                S("Tempo", 6, 80),
                S("Endurance 3", 25, 65),
                S("Tempo", 6, 80),
                S("Endurance 4", 22, 65),
                R("Cool Down", 10, 65, 45)
            ]
        ),
        Workout(
            id: "tempo-45",
            name: "Tempo 45",
            description: "45-minute crisp tempo. 25min at 80% FTP — strong without being threshold.",
            category: .endurance,
            intervals: [
                R("Warm Up", 8, 45, 70),
                S("Tempo", 25, 80),
                R("Cool Down", 12, 70, 40)
            ]
        ),
        Workout(
            id: "tempo-90",
            name: "Tempo 90",
            description: "90-minute tempo emphasis. Three blocks at 78-82% FTP with short resets.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Tempo 1", 18, 78), S("Reset", 4, 60),
                S("Tempo 2", 18, 80), S("Reset", 4, 60),
                S("Tempo 3", 18, 82),
                S("Endurance", 8, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "tempo-120",
            name: "Tempo 120",
            description: "2-hour tempo grind. Long sustained 75-80% blocks — race-pace conditioning.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Tempo 1", 25, 78), S("Reset", 5, 60),
                S("Tempo 2", 25, 80), S("Reset", 5, 60),
                S("Tempo 3", 25, 80),
                S("Endurance", 15, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "coffee-ride-60",
            name: "Coffee Ride",
            description: "60-minute sub-endurance pace. Easier than Z2 — chat-pace social ride feel.",
            category: .endurance,
            intervals: [
                R("Warm Up", 8, 40, 55),
                S("Easy", 15, 60),
                S("Steady", 10, 65),
                S("Easy", 10, 60),
                S("Steady", 10, 65),
                R("Cool Down", 7, 60, 40)
            ]
        ),
        Workout(
            id: "big-gear-75",
            name: "Big Gear Endurance",
            description: "75-minute low-cadence strength endurance. Hold 60-70rpm at endurance watts to build leg force.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Big Gear 1", 8, 70), S("Spin Reset", 3, 60),
                S("Big Gear 2", 8, 72), S("Spin Reset", 3, 60),
                S("Big Gear 3", 8, 72), S("Spin Reset", 3, 60),
                S("Big Gear 4", 8, 75), S("Spin Reset", 3, 60),
                S("Big Gear 5", 8, 75),
                S("Endurance", 5, 65),
                R("Cool Down", 8, 60, 40)
            ]
        ),
        Workout(
            id: "hill-endurance-90",
            name: "Hill Endurance 90",
            description: "90-minute climbing endurance. Six 5min climbs at tempo — outdoor hilly-route feel.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Flat 1", 6, 65),
                S("Climb 1", 5, 80), S("Descent 1", 2, 55),
                S("Flat 2", 6, 65),
                S("Climb 2", 5, 82), S("Descent 2", 2, 55),
                S("Flat 3", 6, 65),
                S("Climb 3", 5, 82), S("Descent 3", 2, 55),
                S("Flat 4", 6, 65),
                S("Climb 4", 5, 84), S("Descent 4", 2, 55),
                S("Flat 5", 6, 65),
                S("Climb 5", 5, 84), S("Descent 5", 2, 55),
                S("Climb 6", 5, 86),
                R("Cool Down", 10, 65, 40)
            ]
        ),

        // ---- More Sweet Spot ----
        Workout(
            id: "ss-short-30",
            name: "Sweet Spot 30",
            description: "30-minute compact sweet spot. 2x8min at 90% FTP. Quality stimulus when busy.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 5, 45, 70),
                S("SS 1", 8, 88), S("Recovery", 3, 55),
                S("SS 2", 8, 92),
                R("Cool Down", 6, 65, 40)
            ]
        ),
        Workout(
            id: "ss-4x10",
            name: "4x10 Sweet Spot",
            description: "70-minute classic 4x10min at 88-92% FTP. Premier sweet spot template.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("SS 1", 10, 88), S("Recovery", 4, 55),
                S("SS 2", 10, 90), S("Recovery", 4, 55),
                S("SS 3", 10, 90), S("Recovery", 4, 55),
                S("SS 4", 10, 92),
                R("Cool Down", 8, 65, 40)
            ]
        ),
        Workout(
            id: "ss-3x15",
            name: "3x15 Sweet Spot",
            description: "75-minute 3x15min at 88-92% FTP. The bread-and-butter aerobic ceiling builder.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("SS 1", 15, 88), S("Recovery", 5, 55),
                S("SS 2", 15, 90), S("Recovery", 5, 55),
                S("SS 3", 15, 92),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "ss-2x30",
            name: "2x30 Sweet Spot",
            description: "90-minute 2x30min at 88-90% FTP. Long-block sweet spot for endurance ceiling.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("SS Block 1", 30, 88), S("Recovery", 8, 55),
                S("SS Block 2", 30, 90),
                R("Cool Down", 12, 65, 40)
            ]
        ),
        Workout(
            id: "ss-75",
            name: "Sweet Spot 75",
            description: "75-minute middle-distance sweet spot. 3x12min with endurance bridges.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("SS 1", 12, 88), S("Endurance", 5, 65),
                S("SS 2", 12, 90), S("Endurance", 5, 65),
                S("SS 3", 12, 92),
                R("Cool Down", 9, 65, 40)
            ]
        ),
        Workout(
            id: "ss-hills-75",
            name: "SS Hills",
            description: "75-minute climbing sweet spot. 5x6min hills at 88-92% FTP — punchier than flat SS.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Climb 1", 6, 88), S("Descent", 3, 55),
                S("Climb 2", 6, 90), S("Descent", 3, 55),
                S("Climb 3", 6, 90), S("Descent", 3, 55),
                S("Climb 4", 6, 92), S("Descent", 3, 55),
                S("Climb 5", 6, 92),
                S("Endurance", 4, 65),
                R("Cool Down", 9, 65, 40)
            ]
        ),

        // ---- More Threshold ----
        Workout(
            id: "threshold-30",
            name: "Threshold 30",
            description: "30-minute compact threshold. 1x15min at FTP. Minimal time, maximum dose.",
            category: .threshold,
            intervals: [
                R("Warm Up", 6, 45, 75),
                S("Opener", 2, 90),
                S("Threshold", 15, 100),
                R("Cool Down", 7, 70, 40)
            ]
        ),
        Workout(
            id: "threshold-3x10",
            name: "3x10 Threshold",
            description: "60-minute 3x10min at 95-102% FTP. Reliable threshold builder.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Threshold 1", 10, 95), S("Recovery", 4, 55),
                S("Threshold 2", 10, 98), S("Recovery", 4, 55),
                S("Threshold 3", 10, 102),
                R("Cool Down", 12, 70, 40)
            ]
        ),
        Workout(
            id: "threshold-1x40",
            name: "Sustained 40",
            description: "75-minute single 40min sustained threshold. Hard mental ride — race-realistic.",
            category: .threshold,
            intervals: [
                R("Warm Up", 12, 45, 80),
                S("Opener", 3, 95),
                S("Threshold Block", 40, 96),
                S("Easy", 5, 60),
                R("Cool Down", 15, 65, 40)
            ]
        ),
        Workout(
            id: "threshold-5x6",
            name: "5x6 Threshold",
            description: "60-minute 5x6min at 102-105% FTP. Slightly above threshold for hard repeats.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Threshold 1", 6, 102), S("Recovery", 3, 55),
                S("Threshold 2", 6, 102), S("Recovery", 3, 55),
                S("Threshold 3", 6, 104), S("Recovery", 3, 55),
                S("Threshold 4", 6, 104), S("Recovery", 3, 55),
                S("Threshold 5", 6, 105),
                R("Cool Down", 9, 65, 40)
            ]
        ),
        Workout(
            id: "threshold-hills-75",
            name: "Threshold Hills",
            description: "75-minute climbing threshold. 4x8min hills at 100% FTP — sustained climbing power.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Climb 1", 8, 98), S("Descent", 4, 55),
                S("Climb 2", 8, 100), S("Descent", 4, 55),
                S("Climb 3", 8, 100), S("Descent", 4, 55),
                S("Climb 4", 8, 102),
                S("Endurance", 5, 65),
                R("Cool Down", 9, 65, 40)
            ]
        ),
        Workout(
            id: "threshold-ou-90",
            name: "Threshold OU 90",
            description: "90-minute over-under threshold. Three sets alternating 92% / 105% to build lactate clearance.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Under", 3, 92), S("Over", 2, 105),
                S("Under", 3, 92), S("Over", 2, 105),
                S("Under", 3, 92),
                S("Recovery", 5, 55),
                S("Under", 3, 93), S("Over", 2, 107),
                S("Under", 3, 93), S("Over", 2, 107),
                S("Under", 3, 93),
                S("Recovery", 5, 55),
                S("Under", 3, 94), S("Over", 2, 108),
                S("Under", 3, 94), S("Over", 2, 108),
                S("Under", 3, 94),
                S("Endurance", 8, 65),
                R("Cool Down", 14, 65, 40)
            ]
        ),

        // ---- More VO2max ----
        Workout(
            id: "vo2-4x4",
            name: "Norwegian 4x4",
            description: "55-minute 4x4min at 105% FTP with 3min recovery. Classic Norwegian protocol — pure VO2max.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 3, 95),
                S("VO2 1", 4, 105), S("Recovery", 3, 50),
                S("VO2 2", 4, 108), S("Recovery", 3, 50),
                S("VO2 3", 4, 108), S("Recovery", 3, 50),
                S("VO2 4", 4, 110),
                R("Cool Down", 9, 60, 40)
            ]
        ),
        Workout(
            id: "vo2-6x3",
            name: "6x3 VO2",
            description: "60-minute 6x3min at 115% FTP. More reps, slightly shorter — high cumulative time at VO2.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 2, 95),
                S("VO2 1", 3, 113), S("Recovery", 3, 50),
                S("VO2 2", 3, 115), S("Recovery", 3, 50),
                S("VO2 3", 3, 115), S("Recovery", 3, 50),
                S("VO2 4", 3, 115), S("Recovery", 3, 50),
                S("VO2 5", 3, 117), S("Recovery", 3, 50),
                S("VO2 6", 3, 117),
                R("Cool Down", 8, 60, 40)
            ]
        ),
        Workout(
            id: "vo2-crushers-45",
            name: "VO2 Crushers",
            description: "45-minute hard short session. 8x90sec at 118% FTP. Pain in a small package.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 2, 95),
                Ssec("VO2 1", 90, 118), Ssec("Recovery", 90, 50),
                Ssec("VO2 2", 90, 118), Ssec("Recovery", 90, 50),
                Ssec("VO2 3", 90, 118), Ssec("Recovery", 90, 50),
                Ssec("VO2 4", 90, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 5", 90, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 6", 90, 120), Ssec("Recovery", 90, 50),
                Ssec("VO2 7", 90, 122), Ssec("Recovery", 90, 50),
                Ssec("VO2 8", 90, 122),
                R("Cool Down", 7, 60, 40)
            ]
        ),
        Workout(
            id: "microbursts-30",
            name: "Microbursts",
            description: "30-minute 15sec on / 15sec off at 130% FTP. Develops repeated short-effort capacity.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 8, 45, 75),
                Ssec("On 1", 15, 130), Ssec("Off 1", 15, 50),
                Ssec("On 2", 15, 130), Ssec("Off 2", 15, 50),
                Ssec("On 3", 15, 130), Ssec("Off 3", 15, 50),
                Ssec("On 4", 15, 130), Ssec("Off 4", 15, 50),
                Ssec("On 5", 15, 130), Ssec("Off 5", 15, 50),
                Ssec("On 6", 15, 130), Ssec("Off 6", 15, 50),
                Ssec("On 7", 15, 130), Ssec("Off 7", 15, 50),
                Ssec("On 8", 15, 130), Ssec("Off 8", 15, 50),
                Ssec("On 9", 15, 130), Ssec("Off 9", 15, 50),
                Ssec("On 10", 15, 130), Ssec("Off 10", 15, 50),
                Ssec("On 11", 15, 130), Ssec("Off 11", 15, 50),
                Ssec("On 12", 15, 130), Ssec("Off 12", 15, 50),
                Ssec("On 13", 15, 130), Ssec("Off 13", 15, 50),
                Ssec("On 14", 15, 130), Ssec("Off 14", 15, 50),
                Ssec("On 15", 15, 132), Ssec("Off 15", 15, 50),
                Ssec("On 16", 15, 132), Ssec("Off 16", 15, 50),
                Ssec("On 17", 15, 132), Ssec("Off 17", 15, 50),
                Ssec("On 18", 15, 132), Ssec("Off 18", 15, 50),
                Ssec("On 19", 15, 132), Ssec("Off 19", 15, 50),
                Ssec("On 20", 15, 132),
                R("Cool Down", 5, 60, 40)
            ]
        ),
        Workout(
            id: "vo2-hills-75",
            name: "VO2 Hills",
            description: "75-minute climbing VO2max. 5x4min hills at 110% FTP. Builds climbing punch.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 12, 45, 75),
                S("Settle", 3, 80),
                S("Hill 1", 4, 108), S("Descent", 4, 50),
                S("Hill 2", 4, 110), S("Descent", 4, 50),
                S("Hill 3", 4, 110), S("Descent", 4, 50),
                S("Hill 4", 4, 112), S("Descent", 4, 50),
                S("Hill 5", 4, 112),
                S("Endurance", 8, 65),
                R("Cool Down", 10, 60, 40)
            ]
        ),
        Workout(
            id: "race-pace-90",
            name: "Race Pace Sim",
            description: "90-minute race-pace simulation. Sustained tempo with attacks, surges, and a sprint finish.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 12, 45, 75),
                S("Race Pace", 12, 82),
                S("Surge", 2, 110), S("Settle", 3, 80),
                S("Race Pace", 10, 84),
                S("Attack 1", 1, 130), S("Settle", 3, 80),
                S("Race Pace", 8, 86),
                S("Attack 2", 1, 130), S("Settle", 3, 80),
                S("Threshold Push", 6, 100), S("Recovery", 4, 55),
                S("Race Pace", 6, 85),
                Ssec("Sprint 1", 20, 220), Ssec("Recovery", 100, 55),
                Ssec("Sprint 2", 30, 240),
                R("Cool Down", 13, 65, 40)
            ]
        ),

        // ---- More 90-minute workouts ----
        Workout(
            id: "vo2-marathon-90",
            name: "VO2 Marathon 90",
            description: "90-minute big-block VO2max. 6x5min at 108-112% FTP — hardest workout in the catalog.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 3, 95),
                S("VO2 1", 5, 108), S("Recovery", 5, 50),
                S("VO2 2", 5, 110), S("Recovery", 5, 50),
                S("VO2 3", 5, 110), S("Recovery", 5, 50),
                S("VO2 4", 5, 110), S("Recovery", 5, 50),
                S("VO2 5", 5, 112), S("Recovery", 5, 50),
                S("VO2 6", 5, 112),
                S("Endurance", 5, 65),
                R("Cool Down", 12, 60, 40)
            ]
        ),
        Workout(
            id: "threshold-classic-90",
            name: "Threshold 90",
            description: "90-minute classic threshold session. 3x15min at 95-100% FTP with endurance bookends.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 5, 90),
                S("Threshold 1", 15, 95), S("Recovery", 5, 55),
                S("Threshold 2", 15, 98), S("Recovery", 5, 55),
                S("Threshold 3", 15, 100),
                S("Endurance", 10, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "endurance-surges-90",
            name: "Endurance Surges 90",
            description: "90-minute endurance ride with 1-minute attacks every 9 minutes. Race-realistic Z2.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance 1", 9, 65), S("Surge 1", 1, 110),
                S("Endurance 2", 9, 65), S("Surge 2", 1, 115),
                S("Endurance 3", 9, 65), S("Surge 3", 1, 115),
                S("Endurance 4", 9, 65), S("Surge 4", 1, 120),
                S("Endurance 5", 9, 65), S("Surge 5", 1, 120),
                S("Endurance 6", 9, 65), S("Surge 6", 1, 125),
                S("Endurance 7", 9, 65),
                R("Cool Down", 12, 65, 40)
            ]
        ),
        Workout(
            id: "big-gear-90",
            name: "Big Gear 90",
            description: "90-minute low-cadence force endurance. Five 10min big-gear blocks at 75% FTP. Build leg strength.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Big Gear 1", 10, 72), S("Spin Reset", 3, 60),
                S("Big Gear 2", 10, 75), S("Spin Reset", 3, 60),
                S("Big Gear 3", 10, 75), S("Spin Reset", 3, 60),
                S("Big Gear 4", 10, 78), S("Spin Reset", 3, 60),
                S("Big Gear 5", 10, 78),
                S("Endurance", 8, 65),
                R("Cool Down", 10, 60, 40)
            ]
        ),

        // ---- More 2hr (120min) workouts ----
        Workout(
            id: "sweet-spot-120",
            name: "Sweet Spot 120",
            description: "2-hour sweet spot session. 3x20min at 88-92% FTP. The workhorse aerobic builder.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Endurance", 10, 65),
                S("SS 1", 20, 88), S("Recovery", 5, 55),
                S("SS 2", 20, 90), S("Recovery", 5, 55),
                S("SS 3", 20, 92),
                S("Endurance", 15, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "tempo-vo2-120",
            name: "Tempo + VO2 120",
            description: "2-hour mixed session. Tempo block first, then VO2max intervals — race-prep favourite.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Tempo", 30, 80),
                S("Endurance", 10, 65),
                S("VO2 1", 4, 110), S("Recovery", 4, 50),
                S("VO2 2", 4, 110), S("Recovery", 4, 50),
                S("VO2 3", 4, 112), S("Recovery", 4, 50),
                S("VO2 4", 4, 112), S("Recovery", 4, 50),
                S("VO2 5", 4, 115),
                S("Endurance", 20, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "hilly-120",
            name: "Hilly 120",
            description: "2-hour hilly endurance ride. Six 12min climbs with descents — outdoor terrain feel.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Climb 1", 12, 80), S("Descent", 4, 55),
                S("Climb 2", 12, 82), S("Descent", 4, 55),
                S("Climb 3", 12, 82), S("Descent", 4, 55),
                S("Climb 4", 12, 84), S("Descent", 4, 55),
                S("Climb 5", 12, 86), S("Descent", 4, 55),
                S("Climb 6", 12, 86),
                R("Cool Down", 14, 65, 40)
            ]
        ),
        Workout(
            id: "threshold-big-120",
            name: "Threshold Big Block",
            description: "2-hour threshold session. 3x20min at 95-100% FTP — long time-at-threshold for race prep.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Endurance", 10, 65),
                S("Threshold 1", 20, 95), S("Recovery", 5, 55),
                S("Threshold 2", 20, 98), S("Recovery", 5, 55),
                S("Threshold 3", 20, 100),
                S("Endurance", 20, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),

        // ---- More 2.5hr (150min) workouts ----
        Workout(
            id: "tempo-150",
            name: "Tempo 150",
            description: "2.5-hour tempo emphasis. Four 25min tempo blocks with endurance bridges.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Tempo 1", 25, 78), S("Endurance", 10, 65),
                S("Tempo 2", 25, 80), S("Endurance", 10, 65),
                S("Tempo 3", 25, 80), S("Endurance", 10, 65),
                S("Tempo 4", 25, 82),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "hilly-150",
            name: "Hilly 150",
            description: "2.5-hour climbing ride. Eight 12min climbs simulate a serious mountain stage.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Climb 1", 12, 78), S("Descent", 4, 55),
                S("Climb 2", 12, 80), S("Descent", 4, 55),
                S("Climb 3", 12, 80), S("Descent", 4, 55),
                S("Climb 4", 12, 82), S("Descent", 4, 55),
                S("Climb 5", 12, 82), S("Descent", 4, 55),
                S("Climb 6", 12, 84), S("Descent", 4, 55),
                S("Climb 7", 12, 84), S("Descent", 4, 55),
                S("Climb 8", 12, 86),
                R("Cool Down", 12, 65, 40)
            ]
        ),
        Workout(
            id: "endurance-pure-150",
            name: "Pure Endurance 150",
            description: "2.5-hour pure Zone 2. No surges, no tempo — just sustained aerobic time.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance 1", 30, 65),
                S("Endurance 2", 30, 65),
                S("Endurance 3", 30, 65),
                S("Endurance 4", 35, 63),
                R("Cool Down", 15, 60, 40)
            ]
        ),
        Workout(
            id: "threshold-marathon-150",
            name: "Threshold Marathon 150",
            description: "2.5-hour threshold-focused ride. 4x12min at FTP plus long endurance bookends.",
            category: .threshold,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Endurance", 10, 65),
                S("Threshold 1", 12, 95), S("Recovery", 5, 55),
                S("Threshold 2", 12, 98), S("Recovery", 5, 55),
                S("Threshold 3", 12, 100), S("Recovery", 5, 55),
                S("Threshold 4", 12, 100),
                S("Endurance", 25, 65),
                S("Endurance", 27, 63),
                R("Cool Down", 15, 65, 40)
            ]
        ),

        // ---- More 3hr (180min) workouts ----
        Workout(
            id: "easy-180",
            name: "Easy 3hr",
            description: "3-hour pure aerobic ride. Steady Z2 throughout — long-ride base building.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 45, 65),
                S("Endurance 1", 30, 65),
                S("Endurance 2", 30, 65),
                S("Endurance 3", 30, 63),
                S("Endurance 4", 30, 63),
                S("Endurance 5", 30, 60),
                R("Cool Down", 15, 60, 40)
            ]
        ),
        Workout(
            id: "tempo-180",
            name: "Tempo 180",
            description: "3-hour tempo grind. Five tempo blocks separated by short endurance — race-pace conditioning.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 70),
                S("Tempo 1", 25, 78), S("Endurance", 5, 65),
                S("Tempo 2", 25, 78), S("Endurance", 5, 65),
                S("Tempo 3", 25, 80), S("Endurance", 5, 65),
                S("Tempo 4", 25, 80), S("Endurance", 5, 65),
                S("Tempo 5", 25, 82),
                R("Cool Down", 25, 65, 40)
            ]
        ),
        Workout(
            id: "hilly-180",
            name: "Hilly 180",
            description: "3-hour mountain stage simulation. Ten 12min climbs separated by short descents.",
            category: .endurance,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Climb 1", 12, 78), S("Descent", 4, 55),
                S("Climb 2", 12, 80), S("Descent", 4, 55),
                S("Climb 3", 12, 80), S("Descent", 4, 55),
                S("Climb 4", 12, 82), S("Descent", 4, 55),
                S("Climb 5", 12, 82), S("Descent", 4, 55),
                S("Climb 6", 12, 84), S("Descent", 4, 55),
                S("Climb 7", 12, 84), S("Descent", 4, 55),
                S("Climb 8", 12, 86), S("Descent", 4, 55),
                S("Climb 9", 12, 86), S("Descent", 4, 55),
                S("Climb 10", 12, 88),
                R("Cool Down", 10, 65, 40)
            ]
        ),
        Workout(
            id: "ss-endurance-180",
            name: "SS Endurance 180",
            description: "3-hour sweet-spot endurance ride. Three SS blocks woven into a long aerobic ride.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 10, 45, 65),
                S("Endurance", 30, 65),
                S("SS 1", 20, 88), S("Endurance", 25, 65),
                S("SS 2", 20, 90), S("Endurance", 25, 65),
                S("SS 3", 20, 90),
                S("Endurance", 20, 65),
                R("Cool Down", 10, 65, 40)
            ]
        ),

        // ---- More 4hr (240min) workouts ----
        Workout(
            id: "easy-240",
            name: "Easy 4hr",
            description: "4-hour pure base ride. Steady Z2 — fat oxidation and aerobic durability.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 45, 65),
                S("Endurance 1", 50, 65),
                S("Endurance 2", 50, 63),
                S("Endurance 3", 50, 63),
                S("Endurance 4", 50, 60),
                R("Cool Down", 25, 55, 40)
            ]
        ),
        Workout(
            id: "tempo-240",
            name: "Tempo 4hr",
            description: "4-hour tempo session. Six tempo blocks for serious race-pace conditioning.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 45, 70),
                S("Tempo 1", 25, 78), S("Endurance", 10, 65),
                S("Tempo 2", 25, 78), S("Endurance", 10, 65),
                S("Tempo 3", 25, 80), S("Endurance", 10, 65),
                S("Tempo 4", 25, 80), S("Endurance", 10, 65),
                S("Tempo 5", 25, 80), S("Endurance", 10, 65),
                S("Tempo 6", 25, 82),
                R("Cool Down", 25, 65, 40)
            ]
        ),
        Workout(
            id: "ss-240",
            name: "Sweet Spot 4hr",
            description: "4-hour sweet-spot endurance epic. Four SS blocks woven into a very long aerobic ride.",
            category: .sweetSpot,
            intervals: [
                R("Warm Up", 15, 45, 65),
                S("Endurance", 25, 65),
                S("SS 1", 20, 88), S("Endurance", 20, 65),
                S("SS 2", 20, 90), S("Endurance", 20, 65),
                S("SS 3", 20, 90), S("Endurance", 15, 65),
                S("SS 4", 20, 92),
                S("Endurance", 25, 63),
                S("Endurance", 25, 60),
                R("Cool Down", 15, 60, 40)
            ]
        ),

        // ---- More 5hr (300min) workouts ----
        Workout(
            id: "easy-300",
            name: "Easy 5hr",
            description: "5-hour Zone 2 grinder. Pure aerobic time — for ultra-endurance and brevet prep.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 45, 65),
                S("Endurance 1", 55, 63),
                S("Endurance 2", 55, 63),
                S("Endurance 3", 55, 60),
                S("Endurance 4", 55, 60),
                S("Endurance 5", 50, 58),
                R("Cool Down", 15, 55, 40)
            ]
        ),
        Workout(
            id: "tempo-300",
            name: "Tempo 5hr",
            description: "5-hour tempo marathon. Seven 30min tempo blocks for serious endurance racers.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 45, 70),
                S("Tempo 1", 30, 78), S("Endurance", 10, 65),
                S("Tempo 2", 30, 78), S("Endurance", 10, 65),
                S("Tempo 3", 30, 80), S("Endurance", 10, 65),
                S("Tempo 4", 30, 80), S("Endurance", 10, 65),
                S("Tempo 5", 30, 80), S("Endurance", 10, 65),
                S("Tempo 6", 30, 80), S("Endurance", 10, 65),
                S("Tempo 7", 30, 82),
                R("Cool Down", 15, 65, 40)
            ]
        ),
        Workout(
            id: "audax-300",
            name: "Audax 5hr",
            description: "5-hour brevet simulation. Long endurance with periodic tempo pulls — randonneur pacing.",
            category: .endurance,
            intervals: [
                R("Warm Up", 15, 45, 65),
                S("Endurance 1", 50, 63),
                S("Tempo Pull", 10, 78),
                S("Endurance 2", 50, 63),
                S("Tempo Pull", 10, 78),
                S("Endurance 3", 50, 63),
                S("Tempo Pull", 10, 80),
                S("Endurance 4", 50, 60),
                S("Tempo Pull", 10, 80),
                S("Endurance 5", 30, 60),
                R("Cool Down", 15, 60, 40)
            ]
        ),

        // ---- Tabata ladders (30-minute and 1-hour) ----
        Workout(
            id: "tabata-starter-30",
            name: "Tabata Starter",
            description: "30-minute Tabata starter. 2x classic Tabata blocks (20s on / 10s off) at 150% FTP. Your entry into true high-intensity intervals.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 8, 45, 75),
                S("Opener", 2, 95),
                Ssec("On 1", 20, 150), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 150), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 150), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 150), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 150), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 150), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 150), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 150), Ssec("Off 8", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 9", 20, 150), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 150), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 150), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 150), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 150), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 150), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 150), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 150),
                R("Cool Down", 6, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-builder-30",
            name: "Tabata Builder",
            description: "30-minute Tabata session. 3x Tabata blocks (20s on / 10s off) at 155% FTP. Building toward the full protocol.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 8, 45, 75),
                Ssec("On 1", 20, 155), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 155), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 155), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 155), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 155), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 155), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 155), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 155), Ssec("Off 8", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 9", 20, 155), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 155), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 155), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 155), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 155), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 155), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 155), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 155), Ssec("Off 16", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 17", 20, 155), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 155), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 155), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 155), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 155), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 155), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 155), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 155),
                R("Cool Down", 5, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-classic-30",
            name: "Tabata Classic",
            description: "30-minute Tabata session. 3x classic Tabata blocks (20s on / 10s off) at 160% FTP. True high-intensity stimulus.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 8, 45, 75),
                Ssec("On 1", 20, 160), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 160), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 160), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 160), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 160), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 160), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 160), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 160), Ssec("Off 8", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 9", 20, 160), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 160), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 160), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 160), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 160), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 160), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 160), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 160), Ssec("Off 16", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 17", 20, 160), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 160), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 160), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 160), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 160), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 160), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 160), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 160),
                R("Cool Down", 4, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-crusher-30",
            name: "Tabata Crusher",
            description: "30-minute Tabata crusher. 4x Tabata blocks (20s on / 10s off) at 165% FTP with short recoveries. Seriously hard.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 7, 45, 78),
                Ssec("On 1", 20, 165), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 165), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 165), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 165), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 165), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 165), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 165), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 165), Ssec("Off 8", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 9", 20, 165), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 165), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 165), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 165), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 165), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 165), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 165), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 165), Ssec("Off 16", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 17", 20, 165), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 165), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 165), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 165), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 165), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 165), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 165), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 165), Ssec("Off 24", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 25", 20, 165), Ssec("Off 25", 10, 45),
                Ssec("On 26", 20, 165), Ssec("Off 26", 10, 45),
                Ssec("On 27", 20, 165), Ssec("Off 27", 10, 45),
                Ssec("On 28", 20, 165), Ssec("Off 28", 10, 45),
                Ssec("On 29", 20, 165), Ssec("Off 29", 10, 45),
                Ssec("On 30", 20, 165), Ssec("Off 30", 10, 45),
                Ssec("On 31", 20, 165), Ssec("Off 31", 10, 45),
                Ssec("On 32", 20, 165),
                R("Cool Down", 4, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-inferno-30",
            name: "Tabata Inferno",
            description: "30-minute Tabata inferno. 4x Tabata blocks (20s on / 10s off) at 170% FTP. The toughest 30-minute session in the catalog.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 7, 45, 78),
                Ssec("On 1", 20, 170), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 170), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 170), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 170), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 170), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 170), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 170), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 170), Ssec("Off 8", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 9", 20, 170), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 170), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 170), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 170), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 170), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 170), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 170), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 170), Ssec("Off 16", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 17", 20, 170), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 170), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 170), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 170), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 170), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 170), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 170), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 170), Ssec("Off 24", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 25", 20, 170), Ssec("Off 25", 10, 45),
                Ssec("On 26", 20, 170), Ssec("Off 26", 10, 45),
                Ssec("On 27", 20, 170), Ssec("Off 27", 10, 45),
                Ssec("On 28", 20, 170), Ssec("Off 28", 10, 45),
                Ssec("On 29", 20, 170), Ssec("Off 29", 10, 45),
                Ssec("On 30", 20, 170), Ssec("Off 30", 10, 45),
                Ssec("On 31", 20, 170), Ssec("Off 31", 10, 45),
                Ssec("On 32", 20, 170),
                R("Cool Down", 4, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-starter-60",
            name: "Tabata Hour",
            description: "60-minute Tabata ride. 5x classic Tabata blocks (20s on / 10s off) at 150% FTP. A full hour of high-intensity work.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                S("Opener", 2, 95),
                Ssec("On 1", 20, 150), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 150), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 150), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 150), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 150), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 150), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 150), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 150), Ssec("Off 8", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 9", 20, 150), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 150), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 150), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 150), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 150), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 150), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 150), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 150), Ssec("Off 16", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 17", 20, 150), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 150), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 150), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 150), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 150), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 150), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 150), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 150), Ssec("Off 24", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 25", 20, 150), Ssec("Off 25", 10, 45),
                Ssec("On 26", 20, 150), Ssec("Off 26", 10, 45),
                Ssec("On 27", 20, 150), Ssec("Off 27", 10, 45),
                Ssec("On 28", 20, 150), Ssec("Off 28", 10, 45),
                Ssec("On 29", 20, 150), Ssec("Off 29", 10, 45),
                Ssec("On 30", 20, 150), Ssec("Off 30", 10, 45),
                Ssec("On 31", 20, 150), Ssec("Off 31", 10, 45),
                Ssec("On 32", 20, 150), Ssec("Off 32", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 33", 20, 150), Ssec("Off 33", 10, 45),
                Ssec("On 34", 20, 150), Ssec("Off 34", 10, 45),
                Ssec("On 35", 20, 150), Ssec("Off 35", 10, 45),
                Ssec("On 36", 20, 150), Ssec("Off 36", 10, 45),
                Ssec("On 37", 20, 150), Ssec("Off 37", 10, 45),
                Ssec("On 38", 20, 150), Ssec("Off 38", 10, 45),
                Ssec("On 39", 20, 150), Ssec("Off 39", 10, 45),
                Ssec("On 40", 20, 150),
                R("Cool Down", 10, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-builder-60",
            name: "Tabata Hour Builder",
            description: "60-minute Tabata session. 6x Tabata blocks (20s on / 10s off) at 155% FTP. Big VO2max volume.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                Ssec("On 1", 20, 155), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 155), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 155), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 155), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 155), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 155), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 155), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 155), Ssec("Off 8", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 9", 20, 155), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 155), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 155), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 155), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 155), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 155), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 155), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 155), Ssec("Off 16", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 17", 20, 155), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 155), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 155), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 155), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 155), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 155), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 155), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 155), Ssec("Off 24", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 25", 20, 155), Ssec("Off 25", 10, 45),
                Ssec("On 26", 20, 155), Ssec("Off 26", 10, 45),
                Ssec("On 27", 20, 155), Ssec("Off 27", 10, 45),
                Ssec("On 28", 20, 155), Ssec("Off 28", 10, 45),
                Ssec("On 29", 20, 155), Ssec("Off 29", 10, 45),
                Ssec("On 30", 20, 155), Ssec("Off 30", 10, 45),
                Ssec("On 31", 20, 155), Ssec("Off 31", 10, 45),
                Ssec("On 32", 20, 155), Ssec("Off 32", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 33", 20, 155), Ssec("Off 33", 10, 45),
                Ssec("On 34", 20, 155), Ssec("Off 34", 10, 45),
                Ssec("On 35", 20, 155), Ssec("Off 35", 10, 45),
                Ssec("On 36", 20, 155), Ssec("Off 36", 10, 45),
                Ssec("On 37", 20, 155), Ssec("Off 37", 10, 45),
                Ssec("On 38", 20, 155), Ssec("Off 38", 10, 45),
                Ssec("On 39", 20, 155), Ssec("Off 39", 10, 45),
                Ssec("On 40", 20, 155), Ssec("Off 40", 10, 45),
                S("Recovery", 4, 50),
                Ssec("On 41", 20, 155), Ssec("Off 41", 10, 45),
                Ssec("On 42", 20, 155), Ssec("Off 42", 10, 45),
                Ssec("On 43", 20, 155), Ssec("Off 43", 10, 45),
                Ssec("On 44", 20, 155), Ssec("Off 44", 10, 45),
                Ssec("On 45", 20, 155), Ssec("Off 45", 10, 45),
                Ssec("On 46", 20, 155), Ssec("Off 46", 10, 45),
                Ssec("On 47", 20, 155), Ssec("Off 47", 10, 45),
                Ssec("On 48", 20, 155),
                R("Cool Down", 8, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-classic-60",
            name: "Tabata Hour Classic",
            description: "60-minute Tabata session. 7x classic Tabata blocks (20s on / 10s off) at 160% FTP. Relentless high-intensity work.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 75),
                Ssec("On 1", 20, 160), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 160), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 160), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 160), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 160), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 160), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 160), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 160), Ssec("Off 8", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 9", 20, 160), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 160), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 160), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 160), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 160), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 160), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 160), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 160), Ssec("Off 16", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 17", 20, 160), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 160), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 160), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 160), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 160), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 160), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 160), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 160), Ssec("Off 24", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 25", 20, 160), Ssec("Off 25", 10, 45),
                Ssec("On 26", 20, 160), Ssec("Off 26", 10, 45),
                Ssec("On 27", 20, 160), Ssec("Off 27", 10, 45),
                Ssec("On 28", 20, 160), Ssec("Off 28", 10, 45),
                Ssec("On 29", 20, 160), Ssec("Off 29", 10, 45),
                Ssec("On 30", 20, 160), Ssec("Off 30", 10, 45),
                Ssec("On 31", 20, 160), Ssec("Off 31", 10, 45),
                Ssec("On 32", 20, 160), Ssec("Off 32", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 33", 20, 160), Ssec("Off 33", 10, 45),
                Ssec("On 34", 20, 160), Ssec("Off 34", 10, 45),
                Ssec("On 35", 20, 160), Ssec("Off 35", 10, 45),
                Ssec("On 36", 20, 160), Ssec("Off 36", 10, 45),
                Ssec("On 37", 20, 160), Ssec("Off 37", 10, 45),
                Ssec("On 38", 20, 160), Ssec("Off 38", 10, 45),
                Ssec("On 39", 20, 160), Ssec("Off 39", 10, 45),
                Ssec("On 40", 20, 160), Ssec("Off 40", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 41", 20, 160), Ssec("Off 41", 10, 45),
                Ssec("On 42", 20, 160), Ssec("Off 42", 10, 45),
                Ssec("On 43", 20, 160), Ssec("Off 43", 10, 45),
                Ssec("On 44", 20, 160), Ssec("Off 44", 10, 45),
                Ssec("On 45", 20, 160), Ssec("Off 45", 10, 45),
                Ssec("On 46", 20, 160), Ssec("Off 46", 10, 45),
                Ssec("On 47", 20, 160), Ssec("Off 47", 10, 45),
                Ssec("On 48", 20, 160), Ssec("Off 48", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 49", 20, 160), Ssec("Off 49", 10, 45),
                Ssec("On 50", 20, 160), Ssec("Off 50", 10, 45),
                Ssec("On 51", 20, 160), Ssec("Off 51", 10, 45),
                Ssec("On 52", 20, 160), Ssec("Off 52", 10, 45),
                Ssec("On 53", 20, 160), Ssec("Off 53", 10, 45),
                Ssec("On 54", 20, 160), Ssec("Off 54", 10, 45),
                Ssec("On 55", 20, 160), Ssec("Off 55", 10, 45),
                Ssec("On 56", 20, 160),
                R("Cool Down", 6, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-crusher-60",
            name: "Tabata Hour Crusher",
            description: "60-minute Tabata crusher. 7x Tabata blocks (20s on / 10s off) at 165% FTP with short recoveries. Brutal.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 78),
                Ssec("On 1", 20, 165), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 165), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 165), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 165), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 165), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 165), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 165), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 165), Ssec("Off 8", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 9", 20, 165), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 165), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 165), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 165), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 165), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 165), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 165), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 165), Ssec("Off 16", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 17", 20, 165), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 165), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 165), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 165), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 165), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 165), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 165), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 165), Ssec("Off 24", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 25", 20, 165), Ssec("Off 25", 10, 45),
                Ssec("On 26", 20, 165), Ssec("Off 26", 10, 45),
                Ssec("On 27", 20, 165), Ssec("Off 27", 10, 45),
                Ssec("On 28", 20, 165), Ssec("Off 28", 10, 45),
                Ssec("On 29", 20, 165), Ssec("Off 29", 10, 45),
                Ssec("On 30", 20, 165), Ssec("Off 30", 10, 45),
                Ssec("On 31", 20, 165), Ssec("Off 31", 10, 45),
                Ssec("On 32", 20, 165), Ssec("Off 32", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 33", 20, 165), Ssec("Off 33", 10, 45),
                Ssec("On 34", 20, 165), Ssec("Off 34", 10, 45),
                Ssec("On 35", 20, 165), Ssec("Off 35", 10, 45),
                Ssec("On 36", 20, 165), Ssec("Off 36", 10, 45),
                Ssec("On 37", 20, 165), Ssec("Off 37", 10, 45),
                Ssec("On 38", 20, 165), Ssec("Off 38", 10, 45),
                Ssec("On 39", 20, 165), Ssec("Off 39", 10, 45),
                Ssec("On 40", 20, 165), Ssec("Off 40", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 41", 20, 165), Ssec("Off 41", 10, 45),
                Ssec("On 42", 20, 165), Ssec("Off 42", 10, 45),
                Ssec("On 43", 20, 165), Ssec("Off 43", 10, 45),
                Ssec("On 44", 20, 165), Ssec("Off 44", 10, 45),
                Ssec("On 45", 20, 165), Ssec("Off 45", 10, 45),
                Ssec("On 46", 20, 165), Ssec("Off 46", 10, 45),
                Ssec("On 47", 20, 165), Ssec("Off 47", 10, 45),
                Ssec("On 48", 20, 165), Ssec("Off 48", 10, 45),
                S("Recovery", 3, 50),
                Ssec("On 49", 20, 165), Ssec("Off 49", 10, 45),
                Ssec("On 50", 20, 165), Ssec("Off 50", 10, 45),
                Ssec("On 51", 20, 165), Ssec("Off 51", 10, 45),
                Ssec("On 52", 20, 165), Ssec("Off 52", 10, 45),
                Ssec("On 53", 20, 165), Ssec("Off 53", 10, 45),
                Ssec("On 54", 20, 165), Ssec("Off 54", 10, 45),
                Ssec("On 55", 20, 165), Ssec("Off 55", 10, 45),
                Ssec("On 56", 20, 165),
                R("Cool Down", 6, 60, 40)
            ]
        ),
        Workout(
            id: "tabata-inferno-60",
            name: "Tabata Hour Inferno",
            description: "60-minute Tabata inferno. 8x Tabata blocks (20s on / 10s off) at 170% FTP. The hardest hour in the catalog.",
            category: .vo2max,
            intervals: [
                R("Warm Up", 10, 45, 78),
                Ssec("On 1", 20, 170), Ssec("Off 1", 10, 45),
                Ssec("On 2", 20, 170), Ssec("Off 2", 10, 45),
                Ssec("On 3", 20, 170), Ssec("Off 3", 10, 45),
                Ssec("On 4", 20, 170), Ssec("Off 4", 10, 45),
                Ssec("On 5", 20, 170), Ssec("Off 5", 10, 45),
                Ssec("On 6", 20, 170), Ssec("Off 6", 10, 45),
                Ssec("On 7", 20, 170), Ssec("Off 7", 10, 45),
                Ssec("On 8", 20, 170), Ssec("Off 8", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 9", 20, 170), Ssec("Off 9", 10, 45),
                Ssec("On 10", 20, 170), Ssec("Off 10", 10, 45),
                Ssec("On 11", 20, 170), Ssec("Off 11", 10, 45),
                Ssec("On 12", 20, 170), Ssec("Off 12", 10, 45),
                Ssec("On 13", 20, 170), Ssec("Off 13", 10, 45),
                Ssec("On 14", 20, 170), Ssec("Off 14", 10, 45),
                Ssec("On 15", 20, 170), Ssec("Off 15", 10, 45),
                Ssec("On 16", 20, 170), Ssec("Off 16", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 17", 20, 170), Ssec("Off 17", 10, 45),
                Ssec("On 18", 20, 170), Ssec("Off 18", 10, 45),
                Ssec("On 19", 20, 170), Ssec("Off 19", 10, 45),
                Ssec("On 20", 20, 170), Ssec("Off 20", 10, 45),
                Ssec("On 21", 20, 170), Ssec("Off 21", 10, 45),
                Ssec("On 22", 20, 170), Ssec("Off 22", 10, 45),
                Ssec("On 23", 20, 170), Ssec("Off 23", 10, 45),
                Ssec("On 24", 20, 170), Ssec("Off 24", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 25", 20, 170), Ssec("Off 25", 10, 45),
                Ssec("On 26", 20, 170), Ssec("Off 26", 10, 45),
                Ssec("On 27", 20, 170), Ssec("Off 27", 10, 45),
                Ssec("On 28", 20, 170), Ssec("Off 28", 10, 45),
                Ssec("On 29", 20, 170), Ssec("Off 29", 10, 45),
                Ssec("On 30", 20, 170), Ssec("Off 30", 10, 45),
                Ssec("On 31", 20, 170), Ssec("Off 31", 10, 45),
                Ssec("On 32", 20, 170), Ssec("Off 32", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 33", 20, 170), Ssec("Off 33", 10, 45),
                Ssec("On 34", 20, 170), Ssec("Off 34", 10, 45),
                Ssec("On 35", 20, 170), Ssec("Off 35", 10, 45),
                Ssec("On 36", 20, 170), Ssec("Off 36", 10, 45),
                Ssec("On 37", 20, 170), Ssec("Off 37", 10, 45),
                Ssec("On 38", 20, 170), Ssec("Off 38", 10, 45),
                Ssec("On 39", 20, 170), Ssec("Off 39", 10, 45),
                Ssec("On 40", 20, 170), Ssec("Off 40", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 41", 20, 170), Ssec("Off 41", 10, 45),
                Ssec("On 42", 20, 170), Ssec("Off 42", 10, 45),
                Ssec("On 43", 20, 170), Ssec("Off 43", 10, 45),
                Ssec("On 44", 20, 170), Ssec("Off 44", 10, 45),
                Ssec("On 45", 20, 170), Ssec("Off 45", 10, 45),
                Ssec("On 46", 20, 170), Ssec("Off 46", 10, 45),
                Ssec("On 47", 20, 170), Ssec("Off 47", 10, 45),
                Ssec("On 48", 20, 170), Ssec("Off 48", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 49", 20, 170), Ssec("Off 49", 10, 45),
                Ssec("On 50", 20, 170), Ssec("Off 50", 10, 45),
                Ssec("On 51", 20, 170), Ssec("Off 51", 10, 45),
                Ssec("On 52", 20, 170), Ssec("Off 52", 10, 45),
                Ssec("On 53", 20, 170), Ssec("Off 53", 10, 45),
                Ssec("On 54", 20, 170), Ssec("Off 54", 10, 45),
                Ssec("On 55", 20, 170), Ssec("Off 55", 10, 45),
                Ssec("On 56", 20, 170), Ssec("Off 56", 10, 45),
                S("Recovery", 2, 50),
                Ssec("On 57", 20, 170), Ssec("Off 57", 10, 45),
                Ssec("On 58", 20, 170), Ssec("Off 58", 10, 45),
                Ssec("On 59", 20, 170), Ssec("Off 59", 10, 45),
                Ssec("On 60", 20, 170), Ssec("Off 60", 10, 45),
                Ssec("On 61", 20, 170), Ssec("Off 61", 10, 45),
                Ssec("On 62", 20, 170), Ssec("Off 62", 10, 45),
                Ssec("On 63", 20, 170), Ssec("Off 63", 10, 45),
                Ssec("On 64", 20, 170),
                R("Cool Down", 6, 60, 40)
            ]
        )
    ]
}
