import Foundation

/// Rendering tier for the 3D ride. `auto` in settings resolves to one of
/// these at ride start from the device's memory, thermal state and Low Power
/// Mode; during the ride an automatic tier also sheds effects live when the
/// phone can't keep up (`LiveQualityGovernor`).
enum GraphicsQuality: String, CaseIterable, Sendable {
    /// Every effect on: cascaded shadows, SSAO, dense grass, full tree count.
    /// Automatic only on phones with clear headroom (8 GB and up).
    case high
    /// The automatic default: lighter shadows and grass, no SSAO.
    case balanced
    /// For long rides on battery or a hot phone: minimal effects, 30 fps cap.
    case battery

    var label: String {
        switch self {
        case .high: "High"
        case .balanced: "Balanced"
        case .battery: "Battery saver"
        }
    }

    /// One tier cheaper, or nil from the cheapest.
    var lower: GraphicsQuality? {
        switch self {
        case .high: .balanced
        case .balanced: .battery
        case .battery: nil
        }
    }

    /// True when the stored setting leaves the tier to the app ("auto"), so
    /// it may also step down live during a ride. An explicit choice is kept.
    static func isAutomatic(setting: String) -> Bool {
        GraphicsQuality(rawValue: setting) == nil
    }

    /// Resolves the stored setting ("auto" or a raw value) for this device.
    /// Automatic picks are conservative: memory is the only cheap proxy for
    /// GPU headroom, and a 6 GB A15 measured well under 60 fps on High.
    static func resolved(setting: String) -> GraphicsQuality {
        if let explicit = GraphicsQuality(rawValue: setting) { return explicit }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return .battery }
        switch info.thermalState {
        case .serious, .critical: return .battery
        case .fair: return .balanced
        default: break
        }
        // Under 4 GB (the 3 GB iPhone XR, XS and SE 2 report about 2.9 GB).
        if info.physicalMemory < 3_500_000_000 { return .battery }
        // 8 GB phones (iPhone 15 Pro, 16 and later) report about 7.5-8 GB.
        return info.physicalMemory >= 7_500_000_000 ? .high : .balanced
    }
}
