import SwiftUI
import SwiftData

struct RootView: View {
    @StateObject private var trainer = FTMSManager()
    @StateObject private var hr = HRManager()
    @StateObject private var ride = RideController()
    @State private var selection: Tab = .workouts
    @AppStorage(SettingsKeys.hasOnboarded) private var hasOnboarded: Bool = false

    enum Tab: Hashable { case workouts, calendar, history, builder, settings }

    var body: some View {
        TabView(selection: $selection) {
            WorkoutsView()
                .tabItem { Label("Workouts", systemImage: "bolt.heart") }
                .tag(Tab.workouts)

            CalendarView()
                .tabItem { Label("Calendar", systemImage: "calendar") }
                .tag(Tab.calendar)

            HistoryView()
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)

            WorkoutBuilderView()
                .tabItem { Label("Builder", systemImage: "slider.horizontal.3") }
                .tag(Tab.builder)

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .environmentObject(trainer)
        .environmentObject(hr)
        .environmentObject(ride)
        .background(CJColors.bgPrimary.ignoresSafeArea())
        .toolbarBackground(.visible, for: .tabBar)
        .toolbarBackground(CJColors.bgSecondary, for: .tabBar)
        .onAppear { ride.bind(trainer: trainer, hr: hr) }
        .fullScreenCover(isPresented: .constant(!hasOnboarded)) {
            OnboardingView()
        }
    }
}
