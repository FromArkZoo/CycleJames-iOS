import Foundation
import CoreBluetooth

@MainActor
final class HRManager: NSObject, ObservableObject {
    private static let serviceUUID = CBUUID(string: "180D")
    private static let measurementUUID = CBUUID(string: "2A37")

    @Published var connectionState: ConnectionState = .disconnected
    @Published var heartRate: Int = 0
    @Published var deviceName: String?
    @Published var discovered: [CBPeripheral] = []

    var onHR: ((Int) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        switch central.state {
        case .poweredOff:
            connectionState = .bluetoothOff; return
        case .unauthorized:
            connectionState = .bluetoothDenied; return
        case .unsupported:
            connectionState = .bluetoothUnsupported; return
        case .unknown, .resetting:
            connectionState = .bluetoothUnknown; return
        case .poweredOn:
            break
        @unknown default:
            return
        }
        discovered.removeAll()
        connectionState = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    func stopScan() {
        central.stopScan()
        if connectionState == .scanning { connectionState = .disconnected }
    }

    func connect(_ peripheral: CBPeripheral) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        deviceName = peripheral.name
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        connectionState = .disconnected
        deviceName = nil
    }

    /// HR measurement format (org.bluetooth.characteristic.heart_rate_measurement):
    /// First byte is flags. Bit 0: 0 = uint8 HR, 1 = uint16 HR.
    private func parseHR(_ data: Data) -> Int {
        guard !data.isEmpty else { return 0 }
        let flags = data[0]
        if (flags & 0x01) != 0 {
            guard data.count >= 3 else { return 0 }
            return Int(UInt16(data[1]) | (UInt16(data[2]) << 8))
        } else {
            guard data.count >= 2 else { return 0 }
            return Int(data[1])
        }
    }
}

extension HRManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                if self.connectionState.isBluetoothBlocked || self.connectionState == .bluetoothUnknown {
                    self.connectionState = .disconnected
                }
            case .poweredOff:
                self.connectionState = .bluetoothOff
            case .unauthorized:
                self.connectionState = .bluetoothDenied
            case .unsupported:
                self.connectionState = .bluetoothUnsupported
            case .unknown, .resetting:
                if self.connectionState == .disconnected {
                    self.connectionState = .bluetoothUnknown
                }
            @unknown default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String : Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor in
            if !self.discovered.contains(where: { $0.identifier == peripheral.identifier }) {
                self.discovered.append(peripheral)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectionState = .connected
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.connectionState = .disconnected
            self.peripheral = nil
        }
    }
}

extension HRManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
            peripheral.discoverCharacteristics([Self.measurementUUID], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for char in service.characteristics ?? [] where char.uuid == Self.measurementUUID {
                peripheral.setNotifyValue(true, for: char)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in
            let hr = self.parseHR(data)
            if hr > 0 {
                self.heartRate = hr
                self.onHR?(hr)
            }
        }
    }
}
