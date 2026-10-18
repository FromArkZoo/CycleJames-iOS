#if DEBUG
import Foundation
import OSLog

/// Development aid: with `-courseLogDump <seconds>`, writes this process's
/// log (errors, faults and the runtime warnings SwiftUI, UIKit, SceneKit and
/// Metal report through it) to the app's temporary directory (cj_log.txt)
/// that long after the 3D view opens. Scripts can't see the Simulator's
/// console, so this is how a screenshot run checks for runtime problems.
enum CourseLogDump {
    nonisolated(unsafe) private static var scheduled = false

    static func scheduleIfRequested() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-courseLogDump"), !scheduled else { return }
        scheduled = true
        let delay = (i + 1 < args.count ? Double(args[i + 1]) : nil) ?? 20
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { write() }
    }

    private static func write() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cj_log.txt")
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier),
              let entries = try? store.getEntries() else {
            try? "log store unavailable\n".write(to: url, atomically: true, encoding: .utf8)
            return
        }
        var lines: [String] = []
        for case let entry as OSLogEntryLog in entries {
            let level: String
            switch entry.level {
            case .fault: level = "FAULT"
            case .error: level = "ERROR"
            case .notice: level = "notice"
            case .info, .debug: continue
            default: level = "log"
            }
            lines.append("\(level) [\(entry.subsystem):\(entry.category)] \(entry.composedMessage)")
        }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
