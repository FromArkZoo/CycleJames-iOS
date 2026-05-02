import SwiftUI
import CoreBluetooth

struct TrainerScanSheet: View {
    @ObservedObject var manager: FTMSManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if manager.connectionState.isBluetoothBlocked {
                    BluetoothEmptyStateView(state: manager.connectionState)
                } else {
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
                // If BT becomes available while sheet is open, kick off a scan.
                if new == .disconnected { manager.startScan() }
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
        case .bluetoothUnknown: "Initializing Bluetooth…"
        case .bluetoothOff, .bluetoothDenied, .bluetoothUnsupported: ""
        }
    }
}

struct HRScanSheet: View {
    @ObservedObject var manager: HRManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if manager.connectionState.isBluetoothBlocked {
                    BluetoothEmptyStateView(state: manager.connectionState)
                } else {
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
                }
            }
            .background(CJColors.bgPrimary.ignoresSafeArea())
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
                if new == .disconnected { manager.startScan() }
            }
        }
    }
}

/// Shown in place of the scan list when Bluetooth is unavailable: off, denied
/// at the OS level, or unsupported. Includes a CTA that takes the user to the
/// app's Settings page (where they can flip the Bluetooth toggle for our app
/// or the device-wide one).
struct BluetoothEmptyStateView: View {
    let state: ConnectionState

    var body: some View {
        VStack(spacing: CJSpacing.m) {
            Spacer(minLength: 24)
            Image(systemName: iconName)
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(CJColors.accent)
            Text(title)
                .font(CJFont.title)
                .foregroundStyle(CJColors.textPrimary)
                .multilineTextAlignment(.center)
            Text(detail)
                .font(CJFont.body)
                .foregroundStyle(CJColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, CJSpacing.l)

            if state != .bluetoothUnsupported {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Text("Open Settings")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, CJSpacing.l)
                        .padding(.vertical, CJSpacing.s)
                        .foregroundStyle(.white)
                        .background(CJColors.accent)
                        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
                }
                .buttonStyle(.plain)
                .padding(.top, CJSpacing.s)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(CJSpacing.l)
    }

    private var iconName: String {
        switch state {
        case .bluetoothOff: return "wave.3.right.circle"
        case .bluetoothDenied: return "lock.shield"
        case .bluetoothUnsupported: return "exclamationmark.triangle"
        default: return "antenna.radiowaves.left.and.right.slash"
        }
    }

    private var title: String {
        switch state {
        case .bluetoothOff: return "Bluetooth is off"
        case .bluetoothDenied: return "Bluetooth permission needed"
        case .bluetoothUnsupported: return "Bluetooth not supported"
        default: return "Bluetooth unavailable"
        }
    }

    private var detail: String {
        switch state {
        case .bluetoothOff:
            return "Turn Bluetooth on in Settings or Control Center to connect to your trainer or heart-rate monitor."
        case .bluetoothDenied:
            return "CycleJames needs Bluetooth access to talk to your smart trainer. Grant permission in Settings."
        case .bluetoothUnsupported:
            return "This device doesn't support Bluetooth Low Energy."
        default:
            return ""
        }
    }
}
