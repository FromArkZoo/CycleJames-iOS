import Foundation

/// Per-second sampling of ride metrics. Downsamples on retrieval for long rides.
final class RideRecorder {
    private struct Sample {
        var power: Int
        var cadence: Int
        var hr: Int
        var target: Int
    }

    private(set) var isRecording = false
    private var samples: [Sample] = []

    func start() {
        samples.removeAll(keepingCapacity: true)
        isRecording = true
    }

    func record(power: Int, cadence: Int, hr: Int, target: Int) {
        guard isRecording else { return }
        samples.append(Sample(power: power, cadence: cadence, hr: hr, target: target))
    }

    func stop() { isRecording = false }
    func reset() { samples.removeAll(keepingCapacity: false); isRecording = false }

    /// Returns sampleInterval (1, 5, or 10 seconds) and arrays.
    func snapshot() -> (interval: Int, samples: RideSamples) {
        let durationMin = Double(samples.count) / 60.0
        let interval: Int = durationMin > 150 ? 10 : (durationMin > 90 ? 5 : 1)

        if interval == 1 {
            return (1, RideSamples(
                power: samples.map(\.power),
                cadence: samples.map(\.cadence),
                hr: samples.map(\.hr),
                targets: samples.map(\.target)
            ))
        }

        var p: [Int] = [], c: [Int] = [], h: [Int] = [], t: [Int] = []
        let n = samples.count
        var i = 0
        while i < n {
            let end = min(i + interval, n)
            let chunk = samples[i..<end]
            let count = chunk.count
            p.append(chunk.map(\.power).reduce(0, +) / count)
            c.append(chunk.map(\.cadence).reduce(0, +) / count)
            h.append(chunk.map(\.hr).reduce(0, +) / count)
            t.append(chunk.map(\.target).reduce(0, +) / count)
            i += interval
        }
        return (interval, RideSamples(power: p, cadence: c, hr: h, targets: t))
    }
}
