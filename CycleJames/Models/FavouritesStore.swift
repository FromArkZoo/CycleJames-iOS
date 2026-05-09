import Foundation
import Combine

@MainActor
final class FavouritesStore: ObservableObject {
    @Published private(set) var ids: Set<String>

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: SettingsKeys.favouriteWorkoutIDs),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.ids = Set(decoded)
        } else {
            self.ids = []
        }
    }

    func isFavourite(_ id: String) -> Bool { ids.contains(id) }

    func toggle(_ id: String) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        persist()
    }

    private func persist() {
        let data = try? JSONEncoder().encode(Array(ids).sorted())
        defaults.set(data, forKey: SettingsKeys.favouriteWorkoutIDs)
    }
}
