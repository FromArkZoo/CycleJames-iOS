import Foundation
import CoreBluetooth
import Combine

/// Connects to FTMS-compatible smart trainers (Wattbike Atom Next Gen, etc.).
@MainActor
final class FTMSManager: NSObject, ObservableObject {
    // FTMS UUIDs (16-bit Bluetooth assigned numbers).
    private static let serviceUUID = CBUUID(string: "1826")
    private static let indoorBikeDataUUID = CBUUID(string: "2AD2")
    private static let controlPointUUID = CBUUID(string: "2AD9")

    // Control point opcodes.
    private static let opRequestControl: UInt8 = 0x00
    private static let opSetTargetPower: UInt8 = 0x05
    private static let opStart: UInt8 = 0x07
    private static let opStop: UInt8 = 0x08

    @Published var connectionState: ConnectionState = .disconnected
    @Published var liveData = TrainerData()
    @Published var deviceName: String?
    @Published var hasControl = false

    /// Discovered peripherals while scanning, keyed by identifier.
    @Published var discovered: [CBPeripheral] = []

    var onData: ((TrainerData) -> Void)?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var bikeDataChar: CBCharacteristic?
    private var controlPointChar: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func startScan() {
        guard central.state == .poweredOn else {
            connectionState = .failed("Bluetooth is not powered on")
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
        bikeDataChar = nil
        controlPointChar = nil
        hasControl = false
        connectionState = .disconnected
        deviceName = nil
    }

    // MARK: Control point writes

    func setTargetPower(_ watts: Int) {
        guard hasControl, let char = controlPointChar, let p = peripheral else { return }
        let clamped = Int16(max(0, min(2000, watts)))
        var data = Data([Self.opSetTargetPower])
        var w = clamped.littleEndian
        withUnsafeBytes(of: &w) { data.append(contentsOf: $0) }
        p.writeValue(data, for: char, type: .withResponse)
    }

    func startTraining() {
        writeControl(Data([Self.opStart]))
    }

    func stopTraining() {
        writeControl(Data([Self.opStop, 0x01])) // reason: user requested
    }

    private func requestControl() {
        writeControl(Data([Self.opRequestControl]))
    }

    private func writeControl(_ data: Data) {
        guard let char = controlPointChar, let p = peripheral else { return }
        p.writeValue(data, for: char, type: .withResponse)
    }

    // MARK: Indoor Bike Data parsing
    // Standard FTMS Indoor Bike Data layout:
    //   uint16 flags (LE)
    //   conditionally: instSpeed(uint16, 0.01 km/h), avgSpeed(uint16),
    //                  instCadence(uint16, 0.5 rpm), avgCadence(uint16),
    //                  totalDistance(uint24), resistanceLevel(sint16),
    //                  instPower(sint16), avgPower(sint16),
    //                  expendedEnergy(5 bytes), heartRate(uint8), ...
    // Bit 0 of flags is "More Data" — when 0, instantaneous speed IS present.
    private func parseIndoorBikeData(_ data: Data) -> TrainerData {
        var d = TrainerData()
        guard data.count >= 2 else { return d }

        let flags = UInt16(data[0]) | (UInt16(data[1]) << 8)
        var off = 2

        @inline(__always) func u16() -> UInt16? {
            guard off + 2 <= data.count else { return nil }
            let v = UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
            off += 2
            return v
        }
        @inline(__always) func i16() -> Int16? {
            guard off + 2 <= data.count else { return nil }
            let v = UInt16(data[off]) | (UInt16(data[off + 1]) << 8)
            off += 2
            return Int16(bitPattern: v)
        }
        @inline(__always) func skip(_ n: Int) { off = min(off + n, data.count) }

        // Bit 0: More Data — when 0, Instantaneous Speed IS present.
        if (flags & 0x0001) == 0 {
            if let v = u16() { d.speedKph = Double(v) * 0.01 }
        }
        // Bit 1: Average Speed
        if (flags & 0x0002) != 0 { skip(2) }
        // Bit 2: Instantaneous Cadence (0.5 rpm)
        if (flags & 0x0004) != 0 {
            if let v = u16() { d.cadence = Int(Double(v) * 0.5) }
        }
        // Bit 3: Average Cadence
        if (flags & 0x0008) != 0 { skip(2) }
        // Bit 4: Total Distance (uint24)
        if (flags & 0x0010) != 0 { skip(3) }
        // Bit 5: Resistance Level
        if (flags & 0x0020) != 0 { skip(2) }
        // Bit 6: Instantaneous Power (sint16)
        if (flags & 0x0040) != 0 {
            if let v = i16() { d.power = Int(v) }
        }
        // Bit 7: Average Power
        if (flags & 0x0080) != 0 { skip(2) }
        // Bit 8: Expended Energy (uint16 + uint16 + uint8 = 5 bytes)
        if (flags & 0x0100) != 0 { skip(5) }
        // Bit 9: Heart Rate (uint8)
        if (flags & 0x0200) != 0, off < data.count {
            d.heartRate = Int(data[off]); off += 1
        }
        return d
    }
}

extension FTMSManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOff, .unauthorized, .unsupported:
                self.connectionState = .failed("Bluetooth unavailable")
            default:
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
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.connectionState = .failed(error?.localizedDescription ?? "Connection failed")
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.connectionState = .disconnected
            self.hasControl = false
            self.peripheral = nil
            self.bikeDataChar = nil
            self.controlPointChar = nil
        }
    }
}

extension FTMSManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let svc = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
            peripheral.discoverCharacteristics([Self.indoorBikeDataUUID, Self.controlPointUUID], for: svc)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            for char in service.characteristics ?? [] {
                if char.uuid == Self.indoorBikeDataUUID {
                    self.bikeDataChar = char
                    peripheral.setNotifyValue(true, for: char)
                } else if char.uuid == Self.controlPointUUID {
                    self.controlPointChar = char
                    peripheral.setNotifyValue(true, for: char)
                    self.requestControl()
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == Self.indoorBikeDataUUID {
                let parsed = self.parseIndoorBikeData(data)
                self.liveData = parsed
                self.onData?(parsed)
            } else if uuid == Self.controlPointUUID {
                // Response: [0x80, opcode, result]. result 0x01 = success.
                if data.count >= 3, data[0] == 0x80, data[1] == Self.opRequestControl, data[2] == 0x01 {
                    self.hasControl = true
                }
            }
        }
    }
}
