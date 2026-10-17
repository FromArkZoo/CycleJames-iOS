import Foundation

/// Rendering tier for the 3D ride. `auto` in settings resolves to one of
/// these at ride start from the device's memory, thermal state and Low Power
/// Mode.
enum GraphicsQuality: String, CaseIterable, Sendable {
    /// Every effect on: cascaded shadows, SSAO, dense grass, full tree count.
    case high
    /// Default on recent iPhones: lighter shadows and grass, no SSAO.
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

    /// Resolves the stored setting ("auto" or a raw value) for this device.
    static func resolved(setting: String) -> GraphicsQuality {
        if let explicit = GraphicsQuality(rawValue: setting) { return explicit }
        let info = ProcessInfo.processInfo
        if info.isLowPowerModeEnabled { return .battery }
        switch info.thermalState {
        case .serious, .critical: return .battery
        case .fair: return .balanced
        default: break
        }
        // 6 GB+ (iPhone 13 Pro / 14 / 15 and later) gets the full tier.
        return info.physicalMemory >= 5_500_000_000 ? .high : .balanced
    }
}
