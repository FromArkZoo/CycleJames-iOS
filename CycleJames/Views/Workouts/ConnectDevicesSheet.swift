import SwiftUI
import CoreBluetooth

/// Unified connect screen — one sheet that handles both the smart trainer
/// and the heart-rate monitor. Replaces the two separate scan sheets in
/// places where surface area is tight (e.g. the live-ride screen, where
/// two side-by-side connect chips fight with the navigation Back button).
struct ConnectDevicesSheet: View {
    @ObservedObject var trainer: FTMSManager
    @ObservedObject var hr: HRManager
    @Environment(\.dismiss) private var dismiss

    @State private var tab: DeviceTab = .trainer

    enum DeviceTab: String, CaseIterable, Identifiable {
        case trainer = "Trainer"
        case heartRate = "Heart Rate"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Device", selection: $tab) {
                    ForEach(DeviceTab.allCases) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, CJSpacing.l)
                .padding(.vertical, CJSpacing.m)

                Group {
                    switch tab {
                    case .trainer:
                        trainerSection
                    case .heartRate:
                        hrSection
                    }
                }
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("Connect Devices")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        trainer.stopScan()
                        hr.stopScan()
                        dismiss()
                    }
                }
            }
            .onChange(of: tab) { _, new in
                // Pause the inactive scanner so we don't burn radio.
                switch new {
                case .trainer:
                    hr.stopScan()
                    if !trainer.connectionState.isBluetoothBlocked && trainer.connectionState != .connected {
                        trainer.startScan()
                    }
                case .heartRate:
                    trainer.stopScan()
                    if !hr.connectionState.isBluetoothBlocked && hr.connectionState != .connected {
                        hr.startScan()
                    }
                }
            }
            .onAppear {
                if !trainer.connectionState.isBluetoothBlocked && trainer.connectionState != .connected {
                    trainer.startScan()
                }
            }
            .onDisappear {
                trainer.stopScan()
                hr.stopScan()
            }
        }
    }

    @ViewBuilder
    private var trainerSection: some View {
        if trainer.connectionState.isBluetoothBlocked {
            BluetoothEmptyStateView(state: trainer.connectionState)
        } else if trainer.connectionState == .connected {
            connectedRow(name: trainer.deviceName ?? "Trainer", systemImage: "bolt.horizontal.fill") {
                trainer.disconnect()
                trainer.startScan()
            }
        } else {
            scanList(
                state: trainer.connectionState,
                discovered: trainer.discovered,
                emptyMessage: "No trainers found yet.",
                onConnect: { p in trainer.connect(p) }
            )
        }
    }

    @ViewBuilder
    private var hrSection: some View {
        if hr.connectionState.isBluetoothBlocked {
            BluetoothEmptyStateView(state: hr.connectionState)
        } else if hr.connectionState == .connected {
            connectedRow(name: hr.deviceName ?? "Heart Rate", systemImage: "heart.fill") {
                hr.disconnect()
                hr.startScan()
            }
        } else {
            scanList(
                state: hr.connectionState,
                discovered: hr.discovered,
                emptyMessage: "No HR monitors found yet.",
                onConnect: { p in hr.connect(p) }
            )
        }
    }

    @ViewBuilder
    private func connectedRow(name: String, systemImage: String, onDisconnect: @escaping () -> Void) -> some View {
        VStack(spacing: CJSpacing.s) {
            HStack(spacing: CJSpacing.s) {
                Image(systemName: systemImage)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(CJColors.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(CJFont.bodyBold)
                        .foregroundStyle(CJColors.textPrimary)
                    Text("Connected")
                        .font(CJFont.caption)
                        .foregroundStyle(CJColors.success)
                }
                Spacer()
                Button("Disconnect", role: .destructive, action: onDisconnect)
                    .font(CJFont.small)
            }
            .padding(CJSpacing.l)
            .background(CJColors.card)
            .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
            .padding(.horizontal, CJSpacing.l)
            Spacer()
        }
    }

    @ViewBuilder
    private func scanList(
        state: ConnectionState,
        discovered: [CBPeripheral],
        emptyMessage: String,
        onConnect: @escaping (CBPeripheral) -> Void
    ) -> some View {
        VStack(spacing: 0) {
            HStack {
                ProgressView().controlSize(.small).tint(CJColors.accent)
                Text(state == .scanning ? "Scanning…" : (state == .connecting ? "Connecting…" : "Idle"))
                    .font(CJFont.caption)
                    .foregroundStyle(CJColors.textSecondary)
                Spacer()
            }
            .padding(.horizontal, CJSpacing.l)
            .padding(.vertical, CJSpacing.s)

            List {
                if discovered.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(CJColors.textMuted)
                }
                ForEach(discovered, id: \.identifier) { p in
                    Button {
                        onConnect(p)
                    } label: {
                        HStack {
                            Text(p.name ?? "Unknown")
                                .foregroundStyle(CJColors.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(CJColors.textMuted)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CJColors.bgPrimary)
        }
    }
}
