import Foundation

/// The part of the world a course is drawn as: its sun, sky and haze, the
/// sea, and the styles of its buildings, plants, walls and road markings.
/// Every Flemish climb is `.flanders` and keeps exactly the look it had;
/// the Poggio is `.riviera` (Liguria on a clear spring afternoon).
///
/// The struct carries only the region. Each subsystem reads its own
/// settings from an extension in its own file, keyed on `region`
/// (`WorldLook+Sky.swift`, `BuildingBuilder+Riviera.swift`, …), so no
/// builder needs another's details.
struct WorldLook: Sendable, Equatable {
    enum Region: String, Sendable {
        case flanders
        case riviera
    }

    var region: Region

    static let flanders = WorldLook(region: .flanders)
    static let riviera = WorldLook(region: .riviera)

    var isRiviera: Bool { region == .riviera }

    #if DEBUG
    /// `-courseLook riviera`: draws any course as the Riviera (or
    /// `flanders`), to judge a style on a familiar road. Nil without it.
    static var launchOverride: WorldLook? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-courseLook"), i + 1 < args.count,
              let region = Region(rawValue: args[i + 1]) else { return nil }
        return WorldLook(region: region)
    }
    #endif
}
