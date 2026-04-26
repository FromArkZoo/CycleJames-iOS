import SwiftUI
import CoreBluetooth

struct TrainerScanSheet: View {
    @ObservedObject var manager: FTMSManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                statusHeader
                List {
                    if manager.discovered.isEmpty {
                        Text(manager.connectionState == .scanning ? "Scanning…" : "No trainers found yet.")
                            .foregroundStyle(CJColors.textMuted)
                    }
                    ForEach(manager.discovered, id: \.identifier) { p in
                        Button {
                            manager.connect(p)
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
            .background(CJColors.bgPrimary.ignoresSafeArea())
            .navigationTitle("Connect Trainer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        manager.stopScan()
                        dismiss()
                    }
                }
            }
            .onAppear { manager.startScan() }
            .onDisappear { manager.stopScan() }
            .onChange(of: manager.connectionState) { _, new in
                if new == .connected { dismiss() }
            }
        }
    }

    @ViewBuilder
    private var statusHeader: some View {
        HStack {
            ProgressView().controlSize(.small).tint(CJColors.accent)
            Text(statusText)
                .font(CJFont.caption)
                .foregroundStyle(CJColors.textSecondary)
            Spacer()
        }
        .padding(.horizontal, CJSpacing.l)
        .padding(.vertical, CJSpacing.s)
    }

    private var statusText: String {
        switch manager.connectionState {
        case .scanning: "Scanning for FTMS trainers"
        case .connecting: "Connecting…"
        case .connected: "Connected to \(manager.deviceName ?? "")"
        case .disconnected: "Idle"
        case .failed(let m): "Failed: \(m)"
        }
    }
}

struct HRScanSheet: View {
    @ObservedObject var manager: HRManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if manager.discovered.isEmpty {
                    Text(manager.connectionState == .scanning ? "Scanning…" : "No HR monitors found yet.")
                        .foregroundStyle(CJColors.textMuted)
                }
                ForEach(manager.discovered, id: \.identifier) { p in
                    Button {
                        manager.connect(p)
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
            .navigationTitle("Connect HR Monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        manager.stopScan()
                        dismiss()
                    }
                }
            }
            .onAppear { manager.startScan() }
            .onDisappear { manager.stopScan() }
            .onChange(of: manager.connectionState) { _, new in
                if new == .connected { dismiss() }
            }
        }
    }
}
