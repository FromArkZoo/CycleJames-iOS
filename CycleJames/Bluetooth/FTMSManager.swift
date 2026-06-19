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
    private nonisolated static let opSetSimulationParameters: UInt8 = 0x11
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

    /// Identifier of the last successfully-paired trainer. Survives a
    /// disconnect so we can attempt a reconnect via
    /// `retrievePeripherals(withIdentifiers:)`.
    private var lastPeripheralID: UUID?
    /// When true, treat unexpected disconnects as something to recover from
    /// (used while a ride is active). Toggled by `RideController`.
    var autoReconnectEnabled: Bool = false
    private var reconnectTask: Task<Void, Never>?

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
        self.lastPeripheralID = peripheral.identifier
        peripheral.delegate = self
        connectionState = .connecting
        deviceName = peripheral.name
        central.connect(peripheral, options: nil)
    }

    func disconnect() {
        autoReconnectEnabled = false
        cancelReconnect()
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

    /// Try to reconnect to the most recently paired trainer. Used by the
    /// "Reconnect" button in the live-ride disconnect banner and by the
    /// automatic post-disconnect retry while a ride is active.
    func reconnectLast() {
        guard central.state == .poweredOn else { return }
        guard let id = lastPeripheralID else { return }
        guard connectionState != .connected, connectionState != .connecting else { return }
        let known = central.retrievePeripherals(withIdentifiers: [id])
        guard let p = known.first else {
            // No cached peripheral — fall back to a fresh scan.
            startScan()
            return
        }
        connect(p)
    }

    private func cancelReconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    /// Schedules a retry sequence after an unexpected disconnect. Tries at
    /// 3, 8, and 18 seconds, then gives up and waits for manual action.
    private func scheduleAutoReconnect() {
        cancelReconnect()
        reconnectTask = Task { @MainActor [weak self] in
            for delay in [UInt64(3_000_000_000), UInt64(5_000_000_000), UInt64(10_000_000_000)] {
                try? await Task.sleep(nanoseconds: delay)
                if Task.isCancelled { return }
                guard let self else { return }
                guard self.autoReconnectEnabled else { return }
                guard self.connectionState != .connected, self.connectionState != .connecting else { return }
                self.reconnectLast()
            }
        }
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

    /// Encodes an FTMS "Set Indoor Bike Simulation Parameters" payload.
    /// grade is a percentage (0 = flat). Crr/Cw use typical road defaults.
    nonisolated static func simulationParametersData(
        grade: Double,
        windSpeedMps: Double = 0,
        crr: Double = 0.0040,
        cw: Double = 0.51
    ) -> Data {
        var data = Data([opSetSimulationParameters])
        let wind = Int16(clamping: Int((windSpeedMps / 0.001).rounded())).littleEndian
        let gr = Int16(clamping: Int((grade / 0.01).rounded())).littleEndian
        let crrByte = UInt8(max(0, min(255, Int((crr / 0.0001).rounded()))))
        let cwByte = UInt8(max(0, min(255, Int((cw / 0.01).rounded()))))
        withUnsafeBytes(of: wind) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: gr) { data.append(contentsOf: $0) }
        data.append(crrByte)
        data.append(cwByte)
        return data
    }

    /// Puts the trainer into simulation mode at the given grade. Used by
    /// Free Ride at grade 0 so the bike's own gears drive resistance.
    func setSimulationGrade(_ grade: Double) {
        guard hasControl, let char = controlPointChar, let p = peripheral else { return }
        let data = Self.simulationParametersData(grade: grade)
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
            case .poweredOn:
                // Recover from a previously-blocked state. Don't clobber an
                // active scan/connection.
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
            // If we're mid-ride, try a few times to recover before giving up.
            if self.autoReconnectEnabled {
                self.scheduleAutoReconnect()
            }
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
