import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKeys.ftp) private var ftp: Int = AppSettings.defaultFTP
    @State private var ftpInput: String = ""
    @State private var saved = false
    @Query private var rides: [RideSessionModel]
    @Query private var customs: [CustomWorkoutModel]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CJSpacing.l) {
                    section("Training Zones") {
                        VStack(alignment: .leading, spacing: CJSpacing.s) {
                            Text("Current FTP")
                                .font(CJFont.labelUpper)
                                .foregroundStyle(CJColors.textSecondary)
                            Text("\(ftp) W")
                                .font(CJFont.metricMedium)
                                .foregroundStyle(CJColors.textPrimary)

                            HStack {
                                TextField("FTP", text: $ftpInput)
                                    .keyboardType(.numberPad)
                                    .textFieldStyle(.plain)
                                    .padding(CJSpacing.s)
                                    .background(CJColors.bgSecondary)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .foregroundStyle(CJColors.textPrimary)
                                    .frame(maxWidth: 120)
                                Text("W").foregroundStyle(CJColors.textSecondary)
                                Button("Save") { save() }
                                    .buttonStyle(.borderedProminent)
                                    .tint(CJColors.accent)
                                if saved {
                                    Text("Saved")
                                        .font(CJFont.caption)
                                        .foregroundStyle(CJColors.success)
                                        .transition(.opacity)
                                }
                                Spacer()
                            }
                            Text("Used to calculate power zones, IF, and TSS for all workouts.")
                                .font(CJFont.caption)
                                .foregroundStyle(CJColors.textMuted)
                        }
                    }

                    section("Storage") {
                        HStack {
                            Text("Saved rides").foregroundStyle(CJColors.textSecondary)
                            Spacer()
                            Text("\(rides.count)").font(CJFont.bodyBold).foregroundStyle(CJColors.textPrimary)
                        }
                        HStack {
                            Text("Custom workouts").foregroundStyle(CJColors.textSecondary)
                            Spacer()
                            Text("\(customs.count)").font(CJFont.bodyBold).foregroundStyle(CJColors.textPrimary)
                        }
                    }

                    section("About") {
                        HStack {
                            Text("App").foregroundStyle(CJColors.textSecondary)
                            Spacer()
                            Text("CycleJames").font(CJFont.bodyBold).foregroundStyle(CJColors.textPrimary)
                        }
                        HStack {
                            Text("Version").foregroundStyle(CJColors.textSecondary)
                            Spacer()
                            Text(versionString).font(CJFont.bodyBold).foregroundStyle(CJColors.textPrimary)
                        }
                    }
                }
                .padding(CJSpacing.l)
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(CJColors.accent)
                }
            }
            .toolbarBackground(CJColors.bgSecondary, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .onAppear { ftpInput = "\(ftp)" }
        }
    }

    private func save() {
        guard let v = Int(ftpInput) else { return }
        ftp = max(AppSettings.minFTP, min(AppSettings.maxFTP, v))
        ftpInput = "\(ftp)"
        // Flush immediately so the new FTP survives even if the app is killed
        // from the app switcher before the next periodic UserDefaults sync.
        UserDefaults.standard.synchronize()
        withAnimation { saved = true }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation { saved = false }
        }
    }

    private var versionString: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        return "\(v) (\(b))"
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text(title.uppercased())
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            VStack(alignment: .leading, spacing: CJSpacing.s) {
                content()
            }
            .padding(CJSpacing.l)
            .background(CJColors.card)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
    }
}
