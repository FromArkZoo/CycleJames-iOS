import SwiftUI

struct Zone: Identifiable, Hashable {
    let id: Int
    let name: String
    let minPercent: Double
    let maxPercent: Double
    let color: Color
}

enum Zones {
    static let all: [Zone] = [
        Zone(id: 1, name: "Recovery",      minPercent: 0,   maxPercent: 55,  color: Color(red: 0.533, green: 0.533, blue: 0.533)),
        Zone(id: 2, name: "Endurance",     minPercent: 55,  maxPercent: 75,  color: Color(red: 0.129, green: 0.588, blue: 0.953)),
        Zone(id: 3, name: "Tempo",         minPercent: 75,  maxPercent: 90,  color: Color(red: 0.298, green: 0.686, blue: 0.314)),
        Zone(id: 4, name: "Threshold",     minPercent: 90,  maxPercent: 105, color: Color(red: 1.000, green: 0.922, blue: 0.231)),
        Zone(id: 5, name: "VO2max",        minPercent: 105, maxPercent: 120, color: Color(red: 1.000, green: 0.596, blue: 0.000)),
        Zone(id: 6, name: "Anaerobic",     minPercent: 120, maxPercent: 150, color: Color(red: 0.957, green: 0.263, blue: 0.212)),
        Zone(id: 7, name: "Neuromuscular", minPercent: 150, maxPercent: 999, color: Color(red: 0.612, green: 0.153, blue: 0.690))
    ]

    static func zone(forWatts watts: Int, ftp: Int) -> Zone {
        guard ftp > 0 else { return all[0] }
        let pct = Double(watts) / Double(ftp) * 100
        return zone(forPercent: pct)
    }

    static func zone(forPercent pct: Double) -> Zone {
        for z in all.reversed() where pct >= z.minPercent {
            return z
        }
        return all[0]
    }
}
