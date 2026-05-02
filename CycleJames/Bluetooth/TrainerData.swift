import Foundation

struct TrainerData: Equatable {
    var power: Int = 0
    var cadence: Int = 0
    var speedKph: Double = 0
    var heartRate: Int = 0
}

enum ConnectionState: Equatable {
    case disconnected
    case scanning
    case connecting
    case connected
    case failed(String)
    /// User has not yet been prompted; CBCentralManager is initialising.
    case bluetoothUnknown
    /// User explicitly denied Bluetooth permission to the app.
    case bluetoothDenied
    /// Bluetooth radio is off at the OS level.
    case bluetoothOff
    /// Device hardware does not support BLE (rare — older iPods).
    case bluetoothUnsupported

    /// True if user can take action to recover (toggle BT, grant permission).
    /// Drives the empty-state UI in the scan sheets.
    var isBluetoothBlocked: Bool {
        switch self {
        case .bluetoothDenied, .bluetoothOff, .bluetoothUnsupported:
            return true
        default:
            return false
        }
    }
}
