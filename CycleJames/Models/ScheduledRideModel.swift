import Foundation
import SwiftData

@Model
final class ScheduledRideModel {
    var id: UUID = UUID()
    var workoutId: String = ""
    var workoutName: String = ""
    var category: String = ""
    var date: Date = Date()
    var notes: String?

    init(
        id: UUID = UUID(),
        workoutId: String,
        workoutName: String,
        category: String,
        date: Date,
        notes: String? = nil
    ) {
        self.id = id
        self.workoutId = workoutId
        self.workoutName = workoutName
        self.category = category
        self.date = date
        self.notes = notes
    }
}
