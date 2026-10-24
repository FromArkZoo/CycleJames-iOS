import Foundation
import Combine
import QuartzCore

/// One shift as the gear badge flashes it.
struct GearShift: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Up the range: more resistance at the same cadence.
        case harder
        /// Down the range.
        case easier
        /// A press past the hardest gear, which stayed put.
        case top
        /// A press past the easiest gear.
        case bottom
    }

    let kind: Kind
    /// Gears moved in this run of same-way shifts, each within
    /// `GearTracker.runWindow` of the last ("+3"); 0 for a press past an end.
    let steps: Int
    /// The gear after it; nil on a bike that reports presses but no gear.
    let gear: Int?
    /// When it arrived (`CACurrentMediaTime()` in the app).
    let at: Double
    /// Different for every shift, so a view can tell two alike apart.
    let serial: Int
}

/// What the trainer's shifters have done, for the gear badge.
///
/// A Wattbike reports the gear itself (1 = easiest … 22) after every press,
/// and (on the firmware QZ and the ftms_emu emulator describe) the press
/// first. The gear drives the badge; a press only shows when no gear change
/// follows it: past either end of the range, or on a bike that reports
/// presses but not the gear. A value type, so tests drive it with their own
/// clock.
struct GearTracker: Equatable, Sendable {
    /// Shifts the same way closer together than this add up.
    static let runWindow: Double = 1.2
    /// How long the badge flashes a shift.
    static let flashSeconds: Double = 1.2
    /// A press with no gear change this long after it was past an end.
    static let pressSettle: Double = 0.6
    /// A press this soon after a gear change was reported after the gear it made.
    static let lateReport: Double = 0.3
    static let defaultCount = 22

    /// The trainer reports gears (it has Wattbike's service).
    private(set) var available = false
    /// The current gear, 1 = easiest; nil until the bike reports one.
    private(set) var gear: Int?
    /// The top gear, for "/22" and the ladder: the configured count, raised
    /// for the session if a higher gear arrives.
    private(set) var count: Int
    /// The latest shift, for the badge's flash.
    private(set) var lastShift: GearShift?
    /// The bike has reported a press; if it never reports the gear, the badge
    /// stops asking the rider to shift.
    private(set) var sawPresses = false

    private var configuredCount: Int
    /// Highest gear reported since the link came up.
    private var highest = 0
    private var serial = 0
    private var lastChangeAt = -Double.infinity
    private var pending: Press?

    private struct Press: Equatable, Sendable {
        let up: Bool
        let at: Double
    }

    init(count: Int = GearTracker.defaultCount) {
        configuredCount = max(1, count)
        self.count = configuredCount
    }

    /// The trainer has (true) or has lost (false) gear reports; `count` is
    /// the configured number of gears. Losing them forgets the gear.
    mutating func setAvailable(_ value: Bool, count newCount: Int? = nil) {
        available = value
        if !value { forget() }
        if let newCount { setCount(newCount) }
    }

    /// The rider changed the number of gears in Settings.
    mutating func setCount(_ newCount: Int) {
        let n = max(1, newCount)
        guard n != configuredCount else { return }
        configuredCount = n
        count = max(n, highest)
    }

    /// A gear report; nil (the link dropped) forgets the gear quietly. The
    /// first gear after connecting shows without a flash.
    mutating func receive(gear new: Int?, now: Double) {
        guard let new else {
            forget()
            return
        }
        settle(now: now)
        let old = gear
        gear = new
        highest = max(highest, new)
        count = max(configuredCount, highest)
        guard let old, old != new else { return }
        pending = nil
        lastChangeAt = now
        emit(new > old ? .harder : .easier, steps: abs(new - old), now: now)
    }

    /// A shifter press (`up` = harder).
    mutating func press(up: Bool, now: Double) {
        settle(now: now)
        sawPresses = true
        guard gear != nil else {
            // No gear to follow: the direction is all there is.
            emit(up ? .harder : .easier, steps: 1, now: now)
            return
        }
        // Reported after the gear it made.
        guard now - lastChangeAt >= Self.lateReport else { return }
        pending = Press(up: up, at: now)
    }

    /// Turns a press no gear change followed into a bump at the end of the
    /// range. Run by every report and by the feed a moment after a press.
    mutating func settle(now: Double) {
        guard let p = pending, now - p.at >= Self.pressSettle else { return }
        pending = nil
        // Long gone (nothing ran settle in time): too late to flash.
        guard now - p.at < Self.pressSettle + 1, let g = gear, lastChangeAt < p.at else { return }
        if p.up, g >= count {
            emit(.top, steps: 0, now: now)
        } else if !p.up, g <= 1 {
            emit(.bottom, steps: 0, now: now)
        }
    }

    private mutating func emit(_ kind: GearShift.Kind, steps: Int, now: Double) {
        var total = steps
        if steps > 0, let last = lastShift, last.kind == kind, now - last.at <= Self.runWindow {
            total += last.steps
        }
        serial += 1
        lastShift = GearShift(kind: kind, steps: total, gear: gear, at: now, serial: serial)
    }

    private mutating func forget() {
        gear = nil
        lastShift = nil
        pending = nil
        sawPresses = false
        lastChangeAt = -.infinity
        highest = 0
        count = configuredCount
    }
}

/// Feeds a `GearTracker` from the trainer for one ride screen. Its own
/// ObservableObject, so a shift redraws the gear badge and not the whole HUD.
@MainActor
final class GearFeed: ObservableObject {
    @Published private(set) var state: GearTracker
    private var cancellables = Set<AnyCancellable>()
    private var settingsChange: AnyCancellable?
    private var settleTask: Task<Void, Never>?

    init(count: Int = AppSettings.wattbikeGearCount) {
        state = GearTracker(count: count)
        // The gear count can change in Settings while the trainer is connected.
        settingsChange = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.handleCount(AppSettings.wattbikeGearCount) }
            }
    }

    /// Follows the trainer's gear reports. Never touches its `onData`.
    func bind(_ trainer: FTMSManager) {
        cancellables.removeAll()
        trainer.$reportsGears
            .sink { [weak self] reports in MainActor.assumeIsolated { self?.handleSupport(reports) } }
            .store(in: &cancellables)
        trainer.$gear
            .sink { [weak self] gear in
                MainActor.assumeIsolated { self?.handleGear(gear, now: CACurrentMediaTime()) }
            }
            .store(in: &cancellables)
        trainer.shifterPresses
            .sink { [weak self] up in
                MainActor.assumeIsolated { self?.handlePress(up: up, now: CACurrentMediaTime()) }
            }
            .store(in: &cancellables)
    }

    // Internal so tests and the Simulator demo drive them with their own clock.

    func handleSupport(_ reports: Bool) {
        update { $0.setAvailable(reports, count: AppSettings.wattbikeGearCount) }
    }

    func handleGear(_ gear: Int?, now: Double) {
        update { $0.receive(gear: gear, now: now) }
    }

    func handlePress(up: Bool, now: Double) {
        update { $0.press(up: up, now: now) }
        // A press past an end gets no gear report to settle it.
        settleTask?.cancel()
        settleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((GearTracker.pressSettle + 0.05) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.settle(now: CACurrentMediaTime())
        }
    }

    func handleCount(_ count: Int) {
        update { $0.setCount(count) }
    }

    func settle(now: Double) {
        update { $0.settle(now: now) }
    }

    private func update(_ change: (inout GearTracker) -> Void) {
        var next = state
        change(&next)
        if next != state { state = next }
    }
}
