import Foundation
import SwiftData

/// Debug-only helper invoked from the app entry point when the launch arg
/// `-screenshotSeed` is present. Seeds favourites + a few scheduled rides
/// so App Store screenshots show populated state. No-op in normal launches.
enum ScreenshotSeeder {
    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains("-screenshotSeed")
    }

    static func seed(modelContext: ModelContext) {
        seedFavourites()
        seedScheduledRides(modelContext: modelContext)
    }

    private static func seedFavourites() {
        let ids = ["kitchen-sink-60", "sweet-spot-60", "vo2max-intervals"]
        if let data = try? JSONEncoder().encode(ids) {
            UserDefaults.standard.set(data, forKey: SettingsKeys.favouriteWorkoutIDs)
        }
    }

    private static func seedScheduledRides(modelContext: ModelContext) {
        // Wipe any existing scheduled rides for a clean state.
        let descriptor = FetchDescriptor<ScheduledRideModel>()
        if let existing = try? modelContext.fetch(descriptor) {
            for s in existing { modelContext.delete(s) }
        }

        let g = Calendar(identifier: .gregorian)
        let today = g.startOfDay(for: Date())

        // Pick three future days within the displayed month so the grid
        // shows multiple warm-ring dots.
        let plan: [(daysOut: Int, id: String, name: String, category: String)] = [
            (1, "kitchen-sink-60", "Kitchen Sink", "Sweet Spot"),
            (3, "vo2max-intervals", "VO2max Intervals", "VO2max"),
            (5, "endurance-60", "Endurance 60", "Endurance"),
        ]

        for p in plan {
            guard let date = g.date(byAdding: .day, value: p.daysOut, to: today) else { continue }
            let model = ScheduledRideModel(
                workoutId: p.id,
                workoutName: p.name,
                category: p.category,
                date: date
            )
            modelContext.insert(model)
        }
        try? modelContext.save()
    }
}
