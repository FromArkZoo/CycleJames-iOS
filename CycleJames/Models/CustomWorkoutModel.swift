import Foundation
import SwiftData

@Model
final class CustomWorkoutModel {
    var id: String = ""
    var name: String = ""
    var workoutDescription: String = ""
    var category: String = ""
    var createdAt: Date = Date()

    /// JSON-encoded array of `Interval`
    var intervalsJSON: Data?

    init(
        id: String,
        name: String,
        description: String,
        category: WorkoutCategory,
        intervals: [Interval],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.workoutDescription = description
        self.category = category.rawValue
        self.createdAt = createdAt
        self.intervalsJSON = try? JSONEncoder().encode(intervals)
    }

    var intervals: [Interval] {
        guard let data = intervalsJSON,
              let decoded = try? JSONDecoder().decode([Interval].self, from: data) else {
            return []
        }
        return decoded
    }

    func toWorkout() -> Workout {
        Workout(
            id: id,
            name: name,
            description: workoutDescription,
            category: WorkoutCategory(rawValue: category) ?? .endurance,
            intervals: intervals,
            isCustom: true
        )
    }
}
