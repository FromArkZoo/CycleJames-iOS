import Foundation

/// What one course ride climbs: a single course, or several in a row with
/// an easy spin on a flat road between them (`BergSeries`).
struct CourseRidePlan: Hashable, Sendable {
    /// Courses in ride order; never empty.
    let courseIDs: [String]
    /// Easy riding between one climb's finish and the next one's start.
    var recoverySec: Double

    init(courseIDs: [String], recoverySec: Double = 0) {
        precondition(!courseIDs.isEmpty, "a ride climbs at least one course")
        self.courseIDs = courseIDs
        self.recoverySec = max(0, recoverySec)
    }

    static func single(_ courseID: String) -> CourseRidePlan {
        CourseRidePlan(courseIDs: [courseID])
    }

    var isSeries: Bool { courseIDs.count > 1 }
    var legCount: Int { courseIDs.count }
}

/// The bergs ridden back to back: every shipped climb in race order, the
/// rider's choice of which to leave out and how long to spin between them.
enum BergSeries {
    /// History rows for series rides. Not `course_`-prefixed, so nothing
    /// takes it for a single course.
    static let workoutID = "series_bergs"

    /// The Ronde's order (Molenberg early; the Kwaremont and Paterberg,
    /// then the Koppenberg and Taaienberg), and the Muur last, as the old
    /// Ronde finished.
    static let order = ["molenberg", "oudekwaremont", "paterberg", "koppenberg", "taaienberg", "muur"]

    static let recoveryMinuteOptions = [1, 2, 3, 5]
    static let defaultRecoveryMin = 3

    /// The shipped bergs in series order. Courses elsewhere (not in
    /// `order`) aren't part of it.
    static var availableIDs: [String] {
        order.filter(CourseCatalog.courseIDs.contains)
    }

    /// The series as the rider set it up; needs two courses or more.
    static func plan(excluding excluded: Set<String> = AppSettings.seriesExcludedCourseIDs,
                     recoveryMin: Int = AppSettings.seriesRecoveryMin) -> CourseRidePlan? {
        let ids = availableIDs.filter { !excluded.contains($0) }
        guard ids.count >= 2 else { return nil }
        return CourseRidePlan(courseIDs: ids, recoverySec: Double(recoveryMin) * 60)
    }

    /// "Berg series · 6 climbs", for History and the ride screens.
    static func name(legCount: Int) -> String {
        "Berg series · \(legCount) climbs"
    }
}
