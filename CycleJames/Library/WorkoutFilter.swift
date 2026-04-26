import Foundation

struct DurationBucket: Hashable, Identifiable {
    let label: String
    let min: Int
    let max: Int
    var id: String { label }
}

enum WorkoutFiltering {
    static let durations: [DurationBucket] = [
        DurationBucket(label: "All",   min: 0,        max: .max),
        DurationBucket(label: "30min", min: 25 * 60,  max: 35 * 60),
        DurationBucket(label: "1hr",   min: 55 * 60,  max: 65 * 60),
        DurationBucket(label: "1.5hr", min: 85 * 60,  max: 95 * 60),
        DurationBucket(label: "2hr",   min: 115 * 60, max: 125 * 60),
        DurationBucket(label: "2.5hr", min: 145 * 60, max: 155 * 60),
        DurationBucket(label: "3hr",   min: 175 * 60, max: 185 * 60)
    ]

    enum SortBy: String, CaseIterable, Identifiable {
        case name, duration, category
        var id: String { rawValue }
        var label: String {
            switch self {
            case .name: "Name"
            case .duration: "Duration"
            case .category: "Category"
            }
        }
    }
}

struct WorkoutFilterState: Equatable {
    var search: String = ""
    var category: WorkoutCategory? = nil  // nil = All
    var duration: DurationBucket = WorkoutFiltering.durations[0]
    var sort: WorkoutFiltering.SortBy = .name

    func apply(to workouts: [Workout]) -> [Workout] {
        var result = workouts

        if !search.isEmpty {
            let q = search.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(q)
                    || $0.description.lowercased().contains(q)
                    || $0.category.rawValue.lowercased().contains(q)
            }
        }
        if let category {
            result = result.filter { $0.category == category }
        }
        if duration.label != "All" {
            result = result.filter {
                let d = $0.totalDuration
                return d >= duration.min && d <= duration.max
            }
        }

        result.sort { a, b in
            switch sort {
            case .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .duration: return a.totalDuration < b.totalDuration
            case .category: return a.category.sortOrder < b.category.sortOrder
            }
        }
        return result
    }
}
