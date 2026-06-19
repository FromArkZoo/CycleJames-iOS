import Foundation

/// Pure formatters for the in-ride intensity readouts. No state, no SwiftUI —
/// kept separate so the (sign-sensitive) string logic is unit-testable.
enum IntensityReadout {
    /// Accumulated whole-ride offset, e.g. "0 W", "+10 W", "−5 W".
    /// Negative uses a typographic minus (U+2212), not an ASCII hyphen.
    static func wholeRide(offsetWatts w: Int) -> String {
        if w == 0 { return "0 W" }
        let sign = w > 0 ? "+" : "\u{2212}"
        return "\(sign)\(abs(w)) W"
    }

    /// Absolute current-interval target, e.g. "This interval · 210 W",
    /// or "This interval · —" when no interval is active.
    static func intervalTarget(watts: Int, hasActiveInterval: Bool) -> String {
        hasActiveInterval ? "This interval · \(watts) W" : "This interval · —"
    }
}
