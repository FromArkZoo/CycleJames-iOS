#if DEBUG
import Foundation
import CoreBluetooth
import OSLog

/// Development aid: what the trainer tells us about its gears, so a later
/// session can adapt `FTMSManager.wattbikeMessage` if the Atom Next Gen
/// differs from the layout known from the first-generation Atom (Dual
/// shifter mode, the 24-gear compact presets, packets other than the gear),
/// or drive the gear badge from FTMS if it has no Wattbike service at all.
///
/// Per connection: which services the trainer has, the Wattbike service's
/// characteristics, each notification switched on; each kind of Wattbike
/// packet (characteristic, message type, sub-message, length) in full the
/// first time and every 50th after with its rate; gear and shifter packets
/// whenever they differ from the last of their kind. From FTMS Indoor Bike
/// Data, the trainer's resistance level (if it reports one) and the metres
/// per crank turn (speed over cadence, which steps with each shift on a
/// trainer whose speed follows its virtual gear), logged when either
/// changes: the resistance at most twice a second, the development by 3 %
/// or more at most once a second, and no more than `maxBikeLines` times. A
/// notification without a field keeps its last value.
///
/// Lines go to the unified log (subsystem com.jamesbrowne.cyclejames,
/// category "wattbike": the Xcode console on a device run; unusual lines at
/// .notice so `-courseLogDump` keeps them) and to Documents/wattbike_log.txt,
/// started afresh by the first line of each launch (the previous launch's
/// moves to wattbike_log_previous.txt), which a Mac copies off the phone with
///
///     xcrun devicectl device copy from --device <name or udid> \
///       --domain-type appDataContainer --domain-identifier com.jamesbrowne.cyclejames \
///       --source Documents/wattbike_log.txt --destination ~/Desktop/wattbike_log.txt
@MainActor
enum WattbikeLog {
    private static let logger = Logger(subsystem: "com.jamesbrowne.cyclejames", category: "wattbike")
    /// Packets per kind this connection, and when the first came.
    private static var counts: [String: (n: Int, first: Date)] = [:]
    /// The last gear or shifter packet per kind, less its sequence byte, so
    /// a trainer repeating the same gear doesn't fill the file.
    private static var lastKnown: [String: [UInt8]] = [:]
    private static var connectedAt = Date()
    /// The Indoor Bike Data reading last logged.
    private static var lastBike: (resistance: Int?, development: Double?, at: Date)?
    private static var bikeLines = 0
    private static let maxBikeLines = 2000
    private static var fileStarted = false
    private static var fileFull = false
    private static let maxFileBytes = 512 * 1024
    private static let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    private static let fileURL = directory.appendingPathComponent("wattbike_log.txt")
    private static let previousURL = directory.appendingPathComponent("wattbike_log_previous.txt")

    /// A trainer's services were found: starts the connection's log.
    static func services(_ uuids: [CBUUID], device: String?, wattbike: CBUUID) {
        counts.removeAll()
        lastKnown.removeAll()
        lastBike = nil
        bikeLines = 0
        connectedAt = Date()
        let has = uuids.contains(wattbike)
        let list = uuids.map(\.uuidString).joined(separator: ", ")
        write("— \(Date().formatted(.iso8601)) \(device ?? "trainer"): services \(list)"
              + (has ? "" : " (no Wattbike service \(wattbike.uuidString.prefix(8)): no gear badge)"),
              unusual: true)
    }

    static func service(_ characteristics: [CBCharacteristic]) {
        let list = characteristics
            .map { "\($0.uuid.uuidString) [\(describe($0.properties))]" }
            .joined(separator: ", ")
        write("Wattbike service: \(list)", unusual: true)
    }

    static func notificationState(_ uuid: CBUUID, notifying: Bool, error: String?) {
        write("notify \(uuid.uuidString.prefix(8)): \(notifying ? "on" : "off")\(error.map { " — \($0)" } ?? "")",
              unusual: error != nil)
    }

    static func packet(_ data: Data, from uuid: CBUUID, parsed: FTMSManager.WattbikeMessage?) {
        let b = [UInt8](data)
        let kind = b.count >= 3 ? String(format: "%02x/%02x", b[1], b[2]) : "short"
        let key = "\(uuid.uuidString.prefix(8)) \(kind) len \(b.count)"
        let now = Date()
        var entry = counts[key] ?? (n: 0, first: now)
        entry.n += 1
        counts[key] = entry
        let known: Bool
        switch parsed {
        case .gear?, .shift?: known = true
        default: known = false
        }
        let body = Array(b.dropFirst())
        let changed = known && lastKnown[key] != body
        if known { lastKnown[key] = body }
        guard changed || entry.n == 1 || entry.n % 50 == 0 else { return }
        var rate = ""
        if entry.n % 50 == 0, now > entry.first {
            rate = String(format: " (%.1f/s)", Double(entry.n - 1) / now.timeIntervalSince(entry.first))
        }
        let hex = b.map { String(format: "%02x", $0) }.joined(separator: " ")
        write("\(stamp(now)) \(key) #\(entry.n): \(hex) → \(parsed.map { "\($0)" } ?? "not parsed")\(rate)",
              unusual: !known)
    }

    /// One FTMS Indoor Bike Data notification, logged on change (see above).
    static func bikeData(_ data: Data, parsed: TrainerData) {
        guard bikeLines < maxBikeLines, data.count >= 2 else { return }
        let fields = bikeFields(data)
        // A trainer may split a record across notifications: a field this
        // one lacks keeps its last value rather than reading as a change.
        let resistance = fields.resistance ?? lastBike?.resistance
        let development: Double?
        if let rpm = fields.cadenceRpm, let kph = parsed.speedKph {
            development = rpm > 20 && kph > 0 ? kph / 3.6 / (rpm / 60) : nil
        } else {
            development = lastBike?.development
        }
        let now = Date()
        if let last = lastBike {
            let resisted = resistance != last.resistance
            let moved: Bool
            switch (development, last.development) {
            case let (d?, l?): moved = abs(d - l) >= 0.03 * l
            case (nil, nil): moved = false
            default: moved = true
            }
            guard resisted || moved, now.timeIntervalSince(last.at) >= (resisted ? 0.5 : 1) else { return }
        }
        let first = lastBike == nil
        lastBike = (resistance, development, now)
        bikeLines += 1
        var line = "\(stamp(now)) 2AD2"
        if first { line += String(format: " flags 0x%04x", fields.flags) }
        line += " resistance \(resistance.map(String.init) ?? "absent")"
        line += development.map { String(format: " | %.2f m/turn", $0) } ?? " | –"
        line += " (\(parsed.speedKph.map { String(format: "%.2f km/h", $0) } ?? "– km/h"), "
            + "\(fields.cadenceRpm.map { String(format: "%.1f rpm", $0) } ?? "– rpm"), "
            + "\(parsed.power.map { "\($0) W" } ?? "– W"))"
        if bikeLines == maxBikeLines { line += " — further bike data not logged this connection" }
        write(line, unusual: first)
    }

    /// The Indoor Bike Data fields `FTMSManager.parseIndoorBikeData` skips or
    /// rounds: the flags, the resistance level (bit 5, sint16, unitless) and
    /// the cadence in half rpm.
    nonisolated static func bikeFields(_ data: Data) -> (flags: UInt16, resistance: Int?, cadenceRpm: Double?) {
        let b = [UInt8](data)
        guard b.count >= 2 else { return (0, nil, nil) }
        let flags = UInt16(b[0]) | UInt16(b[1]) << 8
        func u16(_ at: Int) -> UInt16? {
            at + 2 <= b.count ? UInt16(b[at]) | UInt16(b[at + 1]) << 8 : nil
        }
        var off = 2
        if flags & 0x0001 == 0 { off += 2 }                 // instantaneous speed
        if flags & 0x0002 != 0 { off += 2 }                 // average speed
        var cadence: Double?
        if flags & 0x0004 != 0 {                            // instantaneous cadence
            cadence = u16(off).map { Double($0) * 0.5 }
            off += 2
        }
        if flags & 0x0008 != 0 { off += 2 }                 // average cadence
        if flags & 0x0010 != 0 { off += 3 }                 // total distance
        var resistance: Int?
        if flags & 0x0020 != 0 {                            // resistance level
            resistance = u16(off).map { Int(Int16(bitPattern: $0)) }
        }
        return (flags, resistance, cadence)
    }

    private static func stamp(_ now: Date) -> String {
        String(format: "%7.2fs", now.timeIntervalSince(connectedAt))
    }

    private static func write(_ line: String, unusual: Bool = false) {
        if unusual {
            logger.notice("\(line, privacy: .public)")
        } else {
            logger.info("\(line, privacy: .public)")
        }
        append(line)
    }

    private static func append(_ line: String) {
        let fm = FileManager.default
        if !fileStarted {
            fileStarted = true
            if fm.fileExists(atPath: fileURL.path) {
                try? fm.removeItem(at: previousURL)
                try? fm.moveItem(at: fileURL, to: previousURL)
            }
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard !fileFull, let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size > maxFileBytes {
            fileFull = true
            try? handle.write(contentsOf: Data("— log full: further lines in the unified log only\n".utf8))
            return
        }
        try? handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func describe(_ p: CBCharacteristicProperties) -> String {
        var parts: [String] = []
        if p.contains(.read) { parts.append("read") }
        if p.contains(.write) { parts.append("write") }
        if p.contains(.writeWithoutResponse) { parts.append("writeNoResponse") }
        if p.contains(.notify) { parts.append("notify") }
        if p.contains(.indicate) { parts.append("indicate") }
        return parts.joined(separator: ",")
    }
}
#endif
