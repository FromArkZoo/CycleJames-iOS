import SwiftUI
import SwiftData

@main
struct CycleJamesApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var favourites = FavouritesStore()
    let modelContainer: ModelContainer

    init() {
        do {
            modelContainer = try ModelContainer(
                for: RideSessionModel.self, CustomWorkoutModel.self, ScheduledRideModel.self
            )
        } catch {
            fatalError("ModelContainer init failed: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(.dark)
                .tint(CJColors.accent)
                .environmentObject(favourites)
        }
        .modelContainer(modelContainer)
    }
}
