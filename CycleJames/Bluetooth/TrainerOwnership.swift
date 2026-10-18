import Foundation

/// Which ride is driving the trainer. The ERG workout (`RideController`)
/// and the 3D course ride (`CourseRideController`) both send it control
/// commands, so only one may hold it at a time: each claims it while its
/// ride counts down, runs or is paused, and the other won't start then.
///
/// The holder is kept weakly, so a controller that goes away without
/// releasing can't lock the trainer for good.
@MainActor
enum TrainerOwnership {
    private static weak var holder: AnyObject?

    /// True when nothing, or `claimant` itself, holds the trainer.
    static func isAvailable(to claimant: AnyObject) -> Bool {
        holder == nil || holder === claimant
    }

    /// Takes the trainer for `claimant`; false if another ride holds it.
    @discardableResult
    static func claim(_ claimant: AnyObject) -> Bool {
        guard isAvailable(to: claimant) else { return false }
        holder = claimant
        return true
    }

    /// Gives the trainer up, if `claimant` holds it.
    static func release(_ claimant: AnyObject) {
        if holder === claimant { holder = nil }
    }
}
