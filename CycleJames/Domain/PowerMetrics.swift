import Foundation

/// Power-based training metrics (Coggan).
enum PowerMetrics {
    /// Normalized Power: 30s rolling avg → 4th power → mean → 4th root.
    static func normalizedPower(_ samples: [Int]) -> Int {
        guard !samples.isEmpty else { return 0 }
        if samples.count < 30 {
            return Int(samples.map(Double.init).reduce(0, +) / Double(samples.count))
        }

        var rollingAverages: [Double] = []
        rollingAverages.reserveCapacity(samples.count - 29)
        var window = 0
        for i in 0..<30 { window += samples[i] }
        rollingAverages.append(Double(window) / 30.0)
        for i in 30..<samples.count {
            window += samples[i] - samples[i - 30]
            rollingAverages.append(Double(window) / 30.0)
        }

        let fourthPowerMean = rollingAverages
            .map { pow($0, 4) }
            .reduce(0, +) / Double(rollingAverages.count)
        return Int(pow(fourthPowerMean, 0.25).rounded())
    }

    /// IF = NP / FTP, rounded to 2 decimals.
    static func intensityFactor(np: Int, ftp: Int) -> Double {
        guard ftp > 0 else { return 0 }
        return (Double(np) / Double(ftp) * 100).rounded() / 100
    }

    /// TSS = (duration_s × NP × IF) / (FTP × 3600) × 100.
    static func tss(durationSec: Int, np: Int, ftp: Int) -> Int {
        guard ftp > 0, np > 0, durationSec > 0 else { return 0 }
        let intensityFactor = Double(np) / Double(ftp)
        let value = (Double(durationSec) * Double(np) * intensityFactor) / (Double(ftp) * 3600) * 100
        return Int(value.rounded())
    }
}

/// Format helpers.
enum TimeFormat {
    static func mmss(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, sec)
        }
        return String(format: "%d:%02d", m, sec)
    }

    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        if h > 0 { return "\(h)h \(m)min" }
        return "\(m)min"
    }
}
