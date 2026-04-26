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
}
