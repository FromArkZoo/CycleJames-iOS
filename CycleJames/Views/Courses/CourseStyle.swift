import SwiftUI

/// Gradient colour bands shared by every course screen: the profile chart,
/// the sparklines, the HUD badge and the mini profile.
enum CourseGrade {
    static let green = CJColors.success
    static let yellow = Color(red: 0.980, green: 0.800, blue: 0.180)  // #FACC2E
    static let orange = CJColors.warning
    static let red = CJColors.danger
    static let darkRed = Color(red: 0.600, green: 0.070, blue: 0.090) // #991217
    /// Cobbled sections on charts.
    static let cobbles = Color(red: 0.616, green: 0.486, blue: 0.369)  // #9D7C5E

    /// Band index 0…4 (green … dark red) for a gradient in percent.
    static func band(for pct: Double) -> Int {
        switch pct {
        case ..<5: 0
        case ..<10: 1
        case ..<15: 2
        case ..<20: 3
        default: 4
        }
    }

    static func color(band: Int) -> Color {
        [green, yellow, orange, red, darkRed][min(max(band, 0), 4)]
    }

    static func color(for pct: Double) -> Color { color(band: band(for: pct)) }

    /// The band colour for text or icons drawn on the dark app background,
    /// where the darkest red would disappear.
    static func labelColor(for pct: Double) -> Color {
        band(for: pct) == 4 ? Color(red: 1.0, green: 0.42, blue: 0.40) : color(for: pct)
    }

    /// Readable text on top of `color(for:)`.
    static func textColor(for pct: Double) -> Color {
        band(for: pct) >= 3 ? .white : Color.black.opacity(0.85)
    }

    static let legend: [(label: String, color: Color)] = [
        ("< 5%", green), ("5–10", yellow), ("10–15", orange), ("15–20", red), ("> 20%", darkRed),
    ]
}

enum CourseFormat {
    /// "570 m" below 1 km, "1.07 km" above.
    static func distance(_ m: Double) -> String {
        let v = max(0, m)
        if v < 1000 { return "\(Int(v.rounded())) m" }
        return String(format: v < 10_000 ? "%.2f km" : "%.1f km", v / 1000)
    }

    /// `distance` split for a big readout: ("570", "m"), ("1.07", "km").
    static func distanceParts(_ m: Double) -> (value: String, unit: String) {
        let v = max(0, m)
        if v < 1000 { return ("\(Int(v.rounded()))", "m") }
        return (String(format: v < 10_000 ? "%.2f" : "%.1f", v / 1000), "km")
    }

    /// Climb time with tenths: "2:41.3", "1:02:41.3".
    static func climbTime(_ seconds: Double) -> String {
        let tenths = Int((max(0, seconds) * 10).rounded())
        let h = tenths / 36_000
        let m = (tenths % 36_000) / 600
        let s = (tenths % 600) / 10
        let t = tenths % 10
        if h > 0 { return String(format: "%d:%02d:%02d.%d", h, m, s, t) }
        return String(format: "%d:%02d.%d", m, s, t)
    }

    /// Signed delta against a reference time: "−4.2s", "+1.0s".
    static func delta(_ seconds: Double) -> String {
        let v = (seconds * 10).rounded() / 10
        if abs(v) < 0.05 { return "±0.0s" }
        return String(format: "%@%.1fs", v < 0 ? "−" : "+", abs(v))
    }

    static func grade(_ pct: Double, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f%%", pct)
    }
}

/// Navigation values for the 3D course screens, pushed on the Workouts tab's
/// stack.
enum CourseNav: Hashable {
    case list
    case detail(String)
    /// The bergs back to back (`BergSeriesView`).
    case series
}

/// Development launch arguments for screenshots of the course screens, in
/// the style of `-screenshotTab` / `-screenshotWorkout`:
///
///     -screenshotCourses              open the course list
///     -screenshotCourse koppenberg    open that course's detail page
///     -courseRideDemo koppenberg      open its ride view and start with virtual power
///     -courseRideStartS 560           start the demo ride at this distance, m
///     -courseRideWatts 320            virtual power for the demo ride
///     -courseRideCamera close         chase | close | firstPerson | broadcast
///     -courseRideFinish               start next to the end so the finish overlay shows
///     -courseRideStop                 open the stop confirmation once riding
///     -courseRideLandscape            force landscape (the Simulator can't be rotated by script; also the -rideGearDemo ride)
///     -screenshotCourseScroll setup   scroll the detail page to profile / pb / setup / trainer / licences
///     -screenshotCoursePB 227.4       store that personal best first (`none` clears it)
///     -screenshotCourseResetPB        open the "Reset personal best" confirmation
///     -screenshotTrainerChips         (Debug) show every trainer chip state over the ride
///     -courseRideHold                 open the demo ride but wait on the start line
///     -courseSeriesDemo paterberg,molenberg   open the berg series with these climbs (or `all`) and ride it
///     -courseSeriesRecoverySec 12     with -courseSeriesDemo, the easy spin between climbs, s
///     -screenshotCourseSeries         open the berg series setup page
///     -screenshotHistoryDetail        with -screenshotTab history, open the newest ride
///     -screenshotSettings             open Settings from the Workouts tab
///     -courseRideGear 14              (Debug) a Wattbike in gear 14 (0: connected, gear not yet known)
///     -courseRideGearFlash harder     (Debug) with -courseRideGear, hold that flash: harder | easier | top | bottom
///     -courseRideGears                (Debug) loop a scripted run of shifts through the gear badge
///     -screenshotGearBadges           (Debug) every gear badge state over the ride
///     -rideGearDemo [erg]             (Debug) with -screenshotWorkout <id>: open its ride in Free Ride (or ERG),
///                                     a Wattbike's shifts looping, or held with -courseRideGear
///
/// All no-ops in normal launches.
enum CourseLaunchArgs {
    private static let args = ProcessInfo.processInfo.arguments

    private static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    static var screenshotCourses: Bool { args.contains("-screenshotCourses") }
    static var screenshotCourseID: String? { value("-screenshotCourse") }
    static var rideDemoCourseID: String? { value("-courseRideDemo") }
    static var rideStartS: Double? { value("-courseRideStartS").flatMap(Double.init) }
    static var rideWatts: Int? { value("-courseRideWatts").flatMap(Int.init) }
    static var rideCamera: CameraMode? { value("-courseRideCamera").flatMap(CameraMode.init(rawValue:)) }
    static var rideFinish: Bool { args.contains("-courseRideFinish") }
    static var rideStop: Bool { args.contains("-courseRideStop") }
    static var rideLandscape: Bool { args.contains("-courseRideLandscape") }
    static var rideHold: Bool { args.contains("-courseRideHold") }
    /// The series demo's climbs; nil without `-courseSeriesDemo`.
    static var seriesDemoCourseIDs: [String]? {
        guard args.contains("-courseSeriesDemo") else { return nil }
        let list = value("-courseSeriesDemo") ?? "all"
        if list == "all" || list.hasPrefix("-") { return BergSeries.availableIDs }
        return list.split(separator: ",").map(String.init)
    }
    static var seriesDemoRecoverySec: Double? { value("-courseSeriesRecoverySec").flatMap(Double.init) }
    static var screenshotCourseSeries: Bool { args.contains("-screenshotCourseSeries") }
    static var screenshotHistoryDetail: Bool { args.contains("-screenshotHistoryDetail") }
    static var screenshotSettings: Bool { args.contains("-screenshotSettings") }
    /// Section of the detail page to scroll to: profile, pb, setup, trainer, licences.
    static var screenshotCourseScroll: String? { value("-screenshotCourseScroll") }
    /// Seconds, or "none". Stored (without splits) before the detail page
    /// first reads the PB.
    static var screenshotPersonalBest: String? { value("-screenshotCoursePB") }
    static var screenshotResetPB: Bool { args.contains("-screenshotCourseResetPB") }
    /// Debug builds: every trainer chip state over the ride view.
    static var screenshotTrainerChips: Bool { args.contains("-screenshotTrainerChips") }
    /// Debug builds: a Simulator stand-in for a Wattbike's gear reports.
    static var rideGear: Int? { value("-courseRideGear").flatMap(Int.init) }
    static var rideGearFlash: String? { value("-courseRideGearFlash") }
    static var rideGearDemo: Bool { args.contains("-courseRideGears") }
    static var screenshotGearBadges: Bool { args.contains("-screenshotGearBadges") }
    /// The mode `-rideGearDemo` rides the workout in; nil without it.
    static var workoutRideGearDemo: RideMode? {
        guard args.contains("-rideGearDemo") else { return nil }
        return value("-rideGearDemo") == "erg" ? .erg : .freeRide
    }

    /// The demo ride opens once per launch, not every time the detail page
    /// reappears.
    @MainActor private static var rideDemoConsumed = false
    @MainActor private static var personalBestSeedConsumed = false
    @MainActor private static var resetPBPromptConsumed = false
    @MainActor private static var workoutRideGearDemoConsumed = false
    @MainActor private static var seriesDemoConsumed = false

    /// The series demo opens once per launch.
    @MainActor
    static func consumeSeriesDemo() -> CourseRidePlan? {
        guard !seriesDemoConsumed, let ids = seriesDemoCourseIDs, !ids.isEmpty else { return nil }
        seriesDemoConsumed = true
        return CourseRidePlan(courseIDs: ids, recoverySec: seriesDemoRecoverySec ?? Double(AppSettings.seriesRecoveryMin) * 60)
    }

    @MainActor
    static func consumeRideDemo(for courseID: String) -> Bool {
        guard !rideDemoConsumed, rideDemoCourseID == courseID else { return false }
        rideDemoConsumed = true
        return true
    }

    /// Applies `-screenshotCoursePB` once per launch.
    @MainActor
    static func applyPersonalBestSeed(courseID: String) {
        guard !personalBestSeedConsumed, let seed = screenshotPersonalBest else { return }
        personalBestSeedConsumed = true
        if let seconds = Double(seed), seconds > 0 {
            AppSettings.setPersonalBest(seconds: seconds, splits: [], courseID: courseID)
        } else {
            AppSettings.clearPersonalBest(courseID: courseID)
        }
    }

    @MainActor
    static func consumeResetPBPrompt() -> Bool {
        guard !resetPBPromptConsumed, screenshotResetPB else { return false }
        resetPBPromptConsumed = true
        return true
    }

    /// `-rideGearDemo` opens the workout's ride once per launch.
    @MainActor
    static func consumeWorkoutRideGearDemo() -> Bool {
        guard !workoutRideGearDemoConsumed, workoutRideGearDemo != nil else { return false }
        workoutRideGearDemoConsumed = true
        return true
    }
}

/// Dark translucent backing for HUD elements drawn over the 3D scene, so
/// white text stays legible against a bright sky or sunlit fields.
struct HUDPanel: ViewModifier {
    var cornerRadius: CGFloat = CJRadius.overlay

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(.ultraThinMaterial)
                    .overlay(shape.fill(Color.black.opacity(0.42)))
            }
            .overlay(shape.stroke(Color.white.opacity(0.10), lineWidth: 1))
            .clipShape(shape)
            .environment(\.colorScheme, .dark)
    }
}

extension View {
    func hudPanel(cornerRadius: CGFloat = CJRadius.overlay) -> some View {
        modifier(HUDPanel(cornerRadius: cornerRadius))
    }
}
