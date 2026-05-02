import SwiftUI

struct OnboardingView: View {
    @AppStorage(SettingsKeys.ftp) private var ftp: Int = AppSettings.defaultFTP
    @AppStorage(SettingsKeys.hasOnboarded) private var hasOnboarded: Bool = false

    @State private var ftpInput: String = "\(AppSettings.defaultFTP)"
    @State private var showFTPHelp: Bool = false
    @FocusState private var ftpFocused: Bool

    private var parsedFTP: Int? {
        guard let v = Int(ftpInput.trimmingCharacters(in: .whitespaces)) else { return nil }
        guard v >= AppSettings.minFTP && v <= AppSettings.maxFTP else { return nil }
        return v
    }

    var body: some View {
        ZStack {
            CJColors.bgPrimary.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: CJSpacing.l) {
                    header
                    ftpCard
                    explainerCard
                    Spacer(minLength: 80)
                }
                .padding(CJSpacing.l)
            }

            VStack {
                Spacer()
                continueButton
                    .padding(CJSpacing.l)
                    .background(
                        LinearGradient(
                            colors: [CJColors.bgPrimary.opacity(0), CJColors.bgPrimary],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
            }
        }
        .sheet(isPresented: $showFTPHelp) { ftpHelpSheet }
        .onAppear {
            ftpInput = "\(ftp)"
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: CJSpacing.xs) {
            Text("WELCOME")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.accent)
            Text("CycleJames")
                .font(.system(size: 36, weight: .bold))
                .foregroundStyle(CJColors.textPrimary)
            Text("Structured indoor cycling on your smart trainer.")
                .font(CJFont.body)
                .foregroundStyle(CJColors.textSecondary)
        }
        .padding(.top, CJSpacing.l)
    }

    @ViewBuilder
    private var ftpCard: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            Text("Your FTP")
                .font(CJFont.labelUpper)
                .foregroundStyle(CJColors.textSecondary)
            Text("Functional Threshold Power — the watts you can hold for an hour. Every workout's targets scale from this.")
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: CJSpacing.s) {
                TextField("FTP", text: $ftpInput)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.plain)
                    .focused($ftpFocused)
                    .padding(CJSpacing.s)
                    .background(CJColors.bgSecondary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .foregroundStyle(CJColors.textPrimary)
                    .font(CJFont.metricMedium)
                    .frame(maxWidth: 160)
                Text("watts")
                    .font(CJFont.body)
                    .foregroundStyle(CJColors.textSecondary)
                Spacer()
            }

            Button {
                showFTPHelp = true
            } label: {
                Label("Don't know your FTP?", systemImage: "questionmark.circle")
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.accent)
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    @ViewBuilder
    private var explainerCard: some View {
        VStack(alignment: .leading, spacing: CJSpacing.s) {
            row(icon: "antenna.radiowaves.left.and.right",
                title: "Connect over Bluetooth",
                detail: "Pairs with FTMS-compatible smart trainers and any standard heart-rate strap.")
            divider
            row(icon: "slider.horizontal.3",
                title: "Adjust intensity live",
                detail: "Tweak watts mid-ride or insert a custom interval if you want to go harder.")
            divider
            row(icon: "lock.shield",
                title: "Your data stays on device",
                detail: "No accounts, no cloud, no analytics. Ever.")
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private var divider: some View {
        Rectangle()
            .fill(CJColors.border.opacity(0.5))
            .frame(height: 1)
            .padding(.vertical, 4)
    }

    @ViewBuilder
    private func row(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: CJSpacing.m) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(CJColors.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(CJFont.bodyBold)
                    .foregroundStyle(CJColors.textPrimary)
                Text(detail)
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var continueButton: some View {
        let isValid = parsedFTP != nil
        Button {
            commit()
        } label: {
            Text("CONTINUE")
                .font(.system(size: 17, weight: .bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, CJSpacing.l)
                .foregroundStyle(.white)
                .background(isValid ? CJColors.accent : CJColors.accentDim)
                .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        }
        .buttonStyle(.plain)
        .disabled(!isValid)
    }

    @ViewBuilder
    private var ftpHelpSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: CJSpacing.l) {
                    Text("FTP — Functional Threshold Power — is roughly the highest power you can sustain for an hour.")
                        .font(CJFont.body)
                        .foregroundStyle(CJColors.textPrimary)

                    sectionTitle("Quick estimates")
                    bullet("If you're brand new, start with 150 W. You can refine it after a few rides.")
                    bullet("Recreational rider, fit: try 180–220 W.")
                    bullet("Racer or experienced cyclist: 220–300 W or higher.")

                    sectionTitle("Field test (most accurate)")
                    bullet("After a 15-minute warmup, ride as hard as you can sustain for 20 minutes flat-out.")
                    bullet("FTP ≈ average power over those 20 minutes × 0.95.")

                    sectionTitle("Other ways")
                    bullet("Most cycling apps and head units estimate FTP from past rides.")
                    bullet("If you've raced a 40k time trial, your average power there is a close proxy.")

                    Text("You can change this in Settings any time. Workouts scale automatically.")
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.textMuted)
                        .padding(.top, CJSpacing.m)
                }
                .padding(CJSpacing.l)
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("About FTP")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showFTPHelp = false }
                }
            }
        }
    }

    @ViewBuilder
    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(CJFont.labelUpper)
            .foregroundStyle(CJColors.accent)
            .padding(.top, CJSpacing.s)
    }

    @ViewBuilder
    private func bullet(_ s: String) -> some View {
        HStack(alignment: .top, spacing: CJSpacing.s) {
            Text("•").foregroundStyle(CJColors.textMuted)
            Text(s).foregroundStyle(CJColors.textSecondary).font(CJFont.body)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func commit() {
        guard let v = parsedFTP else { return }
        ftp = v
        hasOnboarded = true
    }
}
