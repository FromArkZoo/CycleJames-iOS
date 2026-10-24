import SwiftUI
import QuartzCore
import UIKit

/// The gear the trainer's shifters are in, out of its range, with a ladder
/// of every gear and a flash on each shift: an arrow and "Harder"/"Easier",
/// the outline and the current rung in the shift's colour (orange harder,
/// cyan easier) and the number rolling, so the rider sees which way the
/// shift went before the resistance changes. A press past either end of the
/// range shows "Top gear"/"Lowest" with a shake.
///
/// `.badge` hangs under the grade badge in the portrait 3D HUD (the same
/// 112 pt width), with the ladder under the number. `.tile` sits in the
/// landscape metrics column and `.card` is a metric card on the workout ride
/// screen in Free Ride; both keep the ladder beside the number so they are
/// as tall as the tiles and cards around them.
struct GearBadge: View {
    enum Style { case badge, tile, card }

    let gear: Int?
    let count: Int
    var flash: GearShift? = nil
    var style: Style = .badge
    /// "Shift to show" for an unknown gear.
    var showsHint = true
    /// Where a shift's pop grows from: the corner the badge hangs from.
    var anchor: UnitPoint = .topTrailing

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    static let harderColor = CJColors.warning
    static let easierColor = CJColors.accent

    private var compact: Bool { verticalSizeClass == .compact }
    private var onCard: Bool { style == .card }
    private var primary: Color { onCard ? CJColors.textPrimary : .white }
    private var secondary: Color { onCard ? CJColors.textSecondary : Color.white.opacity(0.72) }

    /// The flash colour, nil when nothing is flashing.
    private var tint: Color? {
        switch flash?.kind {
        case .harder?: Self.harderColor
        case .easier?: Self.easierColor
        case .top?, .bottom?: Color.white
        case nil: nil
        }
    }

    private var isLimit: Bool { flash?.kind == .top || flash?.kind == .bottom }

    var body: some View {
        let shakes = isLimit && !reduceMotion
        VStack(alignment: .leading, spacing: style == .tile ? 0 : 2) {
            header
            if style == .badge {
                reading
                footer.frame(height: 10)
            } else {
                HStack(alignment: .lastTextBaseline, spacing: CJSpacing.s) {
                    reading.fixedSize()
                    footer.frame(height: onCard && compact ? 16 : 13)
                }
            }
        }
        .frame(width: style == .badge ? 96 : nil, alignment: .leading)
        .frame(maxWidth: style == .badge ? nil : .infinity, minHeight: onCard && !compact ? 54 : 0,
               alignment: .leading)
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, onCard ? (compact ? 4 : 8) : CJSpacing.xs)
        .modifier(GearBadgeBacking(style: style, tint: tint))
        .scaleEffect(tint != nil && !isLimit && !reduceMotion ? 1.06 : 1,
                     anchor: style == .badge ? anchor : .center)
        // Keyed on every flash, so the trigger never steps back as a limit
        // flash clears (which would shake a second time); only a limit
        // flash moves.
        .keyframeAnimator(initialValue: 0.0, trigger: flash?.serial ?? 0) { content, x in
            content.offset(x: shakes ? x : 0)
        } keyframes: { _ in
            KeyframeTrack {
                LinearKeyframe(-5, duration: 0.05)
                LinearKeyframe(5, duration: 0.08)
                LinearKeyframe(-3, duration: 0.07)
                LinearKeyframe(0, duration: 0.06)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.spoken(gear: gear, count: count, shift: flash))
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var header: some View {
        HStack(spacing: 3) {
            Text("GEAR")
                .font(style == .badge ? .system(size: 9, weight: .heavy) : CJFont.labelUpper)
                .foregroundStyle(secondary)
            Spacer(minLength: 2)
            if let flash {
                Image(systemName: Self.symbol(flash.kind))
                    .font(.system(size: 8, weight: .heavy))
                Text(Self.word(flash))
                    .font(.system(size: 9, weight: .heavy))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(tint ?? secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private var reading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(gear.map(String.init) ?? "–")
                .font(numberFont)
                .foregroundStyle(primary)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(gear ?? 0)))
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: gear)
            Text("/\(count)")
                .font(style == .badge ? .system(size: 14, weight: .heavy, design: .rounded) : CJFont.caption)
                .foregroundStyle(secondary)
        }
        .lineLimit(1)
    }

    private var numberFont: Font {
        switch style {
        case .badge: .system(size: 30, weight: .heavy, design: .rounded)
        case .tile: CJFont.metricSmall
        case .card: compact ? .system(size: 28, weight: .heavy, design: .rounded) : CJFont.metricSmall
        }
    }

    @ViewBuilder
    private var footer: some View {
        if gear == nil {
            Text(showsHint && flash == nil ? "Shift to show" : " ")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        } else {
            GearLadder(gear: gear, count: count, current: tint ?? primary,
                       lit: primary.opacity(0.7), unlit: primary.opacity(0.18))
        }
    }

    static func symbol(_ kind: GearShift.Kind) -> String {
        switch kind {
        case .harder: "arrowtriangle.up.fill"
        case .easier: "arrowtriangle.down.fill"
        case .top: "arrow.up.to.line"
        case .bottom: "arrow.down.to.line"
        }
    }

    static func word(_ shift: GearShift) -> String {
        switch shift.kind {
        case .harder: shift.steps > 1 ? "HARDER +\(shift.steps)" : "HARDER"
        case .easier: shift.steps > 1 ? "EASIER −\(shift.steps)" : "EASIER"
        case .top: "TOP GEAR"
        case .bottom: "LOWEST"
        }
    }

    /// VoiceOver: "Gear 14 of 22, harder".
    static func spoken(gear: Int?, count: Int, shift: GearShift?) -> String {
        var text = gear.map { "Gear \($0) of \(count)" } ?? "Gear not known yet. Shift once to show it"
        switch shift?.kind {
        case .harder?: text += ", harder"
        case .easier?: text += ", easier"
        case .top?: text += ", already the hardest gear"
        case .bottom?: text += ", already the easiest gear"
        case nil: break
        }
        return text
    }
}

/// HUD panel (3D ride) or metric-card (workout ride) backing, washed and
/// outlined in the flash colour while a shift shows. The wash stays light
/// (12 % on the HUD) so the grade badge above remains the strongest warm
/// colour on screen; the outline and the arrow carry the direction.
private struct GearBadgeBacking: ViewModifier {
    let style: GearBadge.Style
    let tint: Color?

    func body(content: Content) -> some View {
        switch style {
        case .badge, .tile:
            let shape = RoundedRectangle(cornerRadius: style == .badge ? CJRadius.overlay : CJRadius.card,
                                         style: .continuous)
            content
                .background(tint?.opacity(0.12) ?? .clear)
                .hudPanel(cornerRadius: style == .badge ? CJRadius.overlay : CJRadius.card)
                .overlay(shape.strokeBorder(tint ?? .clear, lineWidth: 2))
        case .card:
            // As `MetricCard`, with its tinted look while a shift shows.
            let shape = RoundedRectangle(cornerRadius: CJRadius.medium)
            content
                .background(tint?.opacity(0.18) ?? CJColors.card.opacity(0.85))
                .overlay(shape.strokeBorder(tint ?? CJColors.border, lineWidth: tint == nil ? 1 : 2))
                .clipShape(shape)
        }
    }
}

/// One rung per gear, rising left to right with the effort: gears below the
/// current one lit, the current one in `current`, the rest dim.
struct GearLadder: View {
    let gear: Int?
    let count: Int
    var current: Color = .white
    var lit: Color = Color.white.opacity(0.7)
    var unlit: Color = Color.white.opacity(0.18)

    var body: some View {
        Canvas { context, size in
            let n = max(count, 1)
            // Narrow ladders (a landscape tile) give the rungs the room.
            let gap = n > 16 ? min(1.5, size.width / CGFloat(n) * 0.35) : 2.5
            let w = max(1, (size.width - gap * CGFloat(n - 1)) / CGFloat(n))
            for i in 1...n {
                let h = size.height * (0.35 + 0.65 * CGFloat(i) / CGFloat(n))
                let rect = CGRect(x: CGFloat(i - 1) * (w + gap), y: size.height - h, width: w, height: h)
                let color: Color = switch gear {
                case .some(let g) where i == g: current
                case .some(let g) where i < g: lit
                default: unlit
                }
                context.fill(Path(roundedRect: rect, cornerRadius: min(w / 2, 1.5)), with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A `GearBadge` fed live from a ride's `GearFeed`: nothing unless the
/// trainer reports gears, and each shift flashes for
/// `GearTracker.flashSeconds`.
struct GearIndicator: View {
    @ObservedObject var feed: GearFeed
    var style: GearBadge.Style = .badge
    var anchor: UnitPoint = .topTrailing
    /// False draws nothing, for a HUD that moves the badge between two spots.
    var shown = true
    @State private var flash: GearShift?

    var body: some View {
        let state = feed.state
        if state.available, shown {
            GearBadge(gear: state.gear, count: state.count, flash: flash, style: style,
                      showsHint: !state.sawPresses, anchor: anchor)
                .task(id: state.lastShift?.serial) { await play(state.lastShift) }
        }
    }

    private func play(_ shift: GearShift?) async {
        // A stale shift also clears: a camera change can hide the badge
        // (cancelling this task) part-way through a flash.
        guard let shift, Self.isFresh(shift) else {
            flash = nil
            return
        }
        withAnimation(.spring(duration: 0.25, bounce: 0.35)) { flash = shift }
        if UIAccessibility.isVoiceOverRunning {
            AccessibilityNotification.Announcement(
                GearBadge.spoken(gear: shift.gear, count: feed.state.count, shift: shift)
            ).post()
        }
        #if DEBUG
        if CourseLaunchArgs.rideGearFlash != nil { return }     // held for screenshots
        #endif
        try? await Task.sleep(nanoseconds: UInt64(GearTracker.flashSeconds * 1_000_000_000))
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.3)) { flash = nil }
    }

    /// A shift from before this view appeared (e.g. a rotation rebuilt the
    /// HUD) doesn't flash again.
    private static func isFresh(_ shift: GearShift) -> Bool {
        #if DEBUG
        if CourseLaunchArgs.rideGearFlash != nil { return true }
        #endif
        return CACurrentMediaTime() - shift.at < GearTracker.flashSeconds
    }
}

/// A workout-ride slot the Wattbike's gear takes over in Free Ride, where
/// the shifters set the resistance; otherwise `fallback`.
struct GearSlot<Fallback: View>: View {
    @ObservedObject var feed: GearFeed
    let mode: RideMode
    @ViewBuilder var fallback: () -> Fallback

    var body: some View {
        if RideController.showsGear(mode: mode, gearsAvailable: feed.state.available) {
            GearIndicator(feed: feed, style: .card)
        } else {
            fallback()
        }
    }
}

#if DEBUG
/// Every `GearBadge` state, for screenshots (`-screenshotGearBadges`): the
/// Simulator has no Wattbike to shift.
struct GearBadgeGallery: View {
    private static func shift(_ kind: GearShift.Kind, steps: Int = 1, gear: Int?) -> GearShift {
        GearShift(kind: kind, steps: steps, gear: gear, at: 0, serial: 1)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: CJSpacing.s) {
            HStack(spacing: CJSpacing.s) {
                GearBadge(gear: nil, count: 22)
                GearBadge(gear: 1, count: 22)
                GearBadge(gear: 22, count: 22)
            }
            HStack(spacing: CJSpacing.s) {
                GearBadge(gear: 14, count: 22, flash: Self.shift(.harder, gear: 14))
                GearBadge(gear: 9, count: 22, flash: Self.shift(.easier, steps: 3, gear: 9))
                GearBadge(gear: 22, count: 22, flash: Self.shift(.top, steps: 0, gear: 22))
            }
            HStack(spacing: CJSpacing.s) {
                GearBadge(gear: 1, count: 22, flash: Self.shift(.bottom, steps: 0, gear: 1))
                GearBadge(gear: 7, count: 11)
                GearBadge(gear: nil, count: 22, flash: Self.shift(.harder, steps: 2, gear: nil), showsHint: false)
            }
            HStack(alignment: .top, spacing: CJSpacing.s) {
                VStack(spacing: CJSpacing.xs) {
                    GearBadge(gear: 14, count: 22, flash: Self.shift(.harder, steps: 2, gear: 14), style: .tile)
                    GearBadge(gear: nil, count: 22, style: .tile)
                }
                .frame(width: 128)
                VStack(spacing: CJSpacing.xs) {
                    GearBadge(gear: 14, count: 22, style: .card)
                    GearBadge(gear: 13, count: 22, flash: Self.shift(.easier, gear: 13), style: .card)
                        .environment(\.verticalSizeClass, .compact)
                }
                .frame(width: 170)
                .padding(CJSpacing.xxs)
                .background(CJColors.bgPrimary, in: RoundedRectangle(cornerRadius: CJRadius.medium))
            }
        }
        .padding(CJSpacing.m)
        .foregroundStyle(.white)
    }
}

/// Development aid: the Simulator has no Wattbike, so `-courseRideGears`
/// (3D ride) and `-rideGearDemo` (workout ride) feed a ride's `GearFeed` a
/// scripted run of shifts through the same entry points the trainer uses,
/// looping until the view goes. `-courseRideGear 14` holds a single gear
/// instead (0 = connected, gear not known yet), and
/// `-courseRideGearFlash harder|easier|top|bottom` pins that flash.
@MainActor
enum GearDemo {
    private enum Event { case gear(Int), press(Bool), wait(Double) }

    /// One shift up, a run of three, back one, a run of four down, then each
    /// end of the range with a press past it.
    private static let script: [Event] = [
        .gear(8), .wait(2),
        .press(true), .gear(9), .wait(2),
        .press(true), .gear(10), .wait(0.35), .press(true), .gear(11), .wait(0.35),
        .press(true), .gear(12), .wait(2.5),
        .press(false), .gear(11), .wait(2),
        .press(false), .gear(10), .wait(0.3), .press(false), .gear(9), .wait(0.3),
        .press(false), .gear(8), .wait(0.3), .press(false), .gear(7), .wait(2.5),
        .gear(22), .wait(1.6), .press(true), .wait(2.5),
        .gear(1), .wait(1.6), .press(false), .wait(2.5),
    ]

    static func run(_ feed: GearFeed) async {
        feed.handleSupport(true)
        while !Task.isCancelled {
            for event in script {
                guard !Task.isCancelled else { return }
                switch event {
                case .gear(let g): feed.handleGear(g, now: CACurrentMediaTime())
                case .press(let up): feed.handlePress(up: up, now: CACurrentMediaTime())
                case .wait(let s): try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000))
                }
            }
        }
    }

    static func hold(_ feed: GearFeed, gear: Int, flash: String?) {
        feed.handleSupport(true)
        guard gear > 0 else { return }
        let now = CACurrentMediaTime()
        switch flash {
        case "harder":
            feed.handleGear(max(1, gear - 1), now: now - 0.1)
            feed.handleGear(gear, now: now)
        case "easier":
            feed.handleGear(gear + 1, now: now - 0.1)
            feed.handleGear(gear, now: now)
        case "top", "bottom":
            feed.handleGear(gear, now: now - 2)
            feed.handlePress(up: flash == "top", now: now - GearTracker.pressSettle - 0.05)
            feed.settle(now: now)
        default:
            feed.handleGear(gear, now: now)
        }
    }

    /// Only a Wattbike reports gears, so the 3D ride sees one connected (in
    /// control, pedalling at `watts`) for as long as the demo runs: the HUD
    /// then shows what it shows on the bike, the trainer chip in place of
    /// the virtual power control.
    static func connectTrainer(_ controller: CourseRideController, watts: Int) async {
        let now = CACurrentMediaTime()
        controller.handleTrainerLink(true, now: now)
        controller.handleTrainerControl(true, now: now)
        while !Task.isCancelled {
            controller.handleTrainerData(TrainerData(power: watts, cadence: 85), now: CACurrentMediaTime())
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
    }
}
#endif
