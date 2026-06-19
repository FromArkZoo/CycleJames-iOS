# Coherent in-ride intensity controls

**Date:** 2026-06-19
**Status:** Approved design, ready for implementation plan
**Branch:** `inride-improvements` (continues PR #2)

## Problem

The in-ride screen has two power-adjustment controls that are inconsistent with
each other:

- **Per-interval** (`adjustCurrentInterval`) lives **inline** in `IntervalEditBar`
  as `[−] 5W [+]` — one tap, always visible, but it displays only the *step size*
  ("5W").
- **Whole-ride** (`adjustWholeRide`) lives **two taps deep** behind the ⚙ gear,
  inside `RideSettingsPanel`, and displays the *accumulated offset* ("Whole ride: +10 W").

Two coherence gaps result: (1) placement — the controls sit at different depths;
(2) display — one shows a step size, the other an accumulated value, so they don't
read as the same kind of control.

Critically, the **whole-ride** control is the one the user most wants fast mid-ride
(the "today I'm cooked, back everything off" knob), yet it is the buried one. The
inline per-interval tweak is the rarer of the two.

## Approach (chosen: A — swap by hierarchy)

Promote the most-used control to the inline slot and demote the rarer one into the
panel. Make both read as identical ±5 W steppers, each showing the most meaningful
watts value for its scope.

Considered and rejected:
- **B — twins inline** (both ±W stacked): contradicts stated usage (per-interval is
  rarer), makes the bar taller/busier, risks mis-taps between adjacent ± pairs.
- **C — one stepper with a scope toggle**: forces a glance-and-switch before every
  adjustment — bad ergonomics when cooked; mis-scope risk.

## Design

This is a **pure view-layer change**. No domain or controller edits. The methods
`RideController.adjustWholeRide(byWatts:)`, `adjustCurrentInterval(byWatts:)`, and
`Workout.adjustingAllIntervals(byWatts:ftp:)` are unchanged, and
`WholeRideIntensityTests` stays green.

### 1. `IntervalEditBar.swift` — inline control becomes whole-ride

- Replace the inline `[−] 5W [+]` per-interval stepper with a whole-ride stepper:
  `[−] Whole ride <offset> [+]`.
- Wire `−`/`+` to `ride.adjustWholeRide(byWatts: ∓5)`.
- The readout reads `ride.wholeRideOffsetWatts` and updates live:
  `0 W` when zero, `+10 W` when positive, `−5 W` when negative. The negative sign is
  a typographic minus (`−`, U+2212), not an ASCII hyphen — so the formatter builds the
  string explicitly rather than via `%+d`, and its test asserts the same character.
  This readout is **instant**: `wholeRideOffsetWatts` is updated synchronously inside
  `adjustWholeRide`.
- Enabled whenever there is an active workout (the bar already only shows under
  `canEditLive`). No `currentIntervalContext` gate — whole-ride applies regardless
  of which interval is active.
- Queue / Add / ⚙ buttons are unchanged.
- Accessibility labels: "Increase/Decrease whole-ride power by 5 watts" (moved from
  the panel).

### 2. `RideSettingsPanel.swift` — panel section becomes per-interval

- Replace the `WHOLE-RIDE INTENSITY` section with a `THIS INTERVAL` section.
- Wire `−`/`+` to `ride.adjustCurrentInterval(byWatts: ∓5)`.
- The readout shows the **live absolute target** for the current interval, read from
  the already-published `ride.currentTarget` (absolute watts): `This interval · 210 W`.
  Note this value refreshes on the next 1 Hz tick after a tap (matching
  `adjustCurrentInterval`'s "takes effect on the next tick" behaviour), so it has up to
  ~1 s of lag — acceptable for the rarer control.
- Disabled when `ride.currentIntervalContext == nil` (mirrors the enabled-gate the
  inline per-interval control uses today).
- The MODE picker (ERG / Free Ride) stays unchanged at the top of the panel.
- Accessibility labels: "Increase/Decrease current interval power by 5 watts" (moved
  from the edit bar).

### Readout rationale

Each control shows what is most useful for its scope rather than forcing artificial
symmetry:
- Inline whole-ride shows the **accumulated offset** — it is sticky state you watch
  build up across the ride.
- Panel per-interval shows the **absolute target** — it is a momentary nudge, and the
  real target number is the meaningful thing while you tap. This reuses
  `ride.currentTarget` with no new controller state.

### Out of scope (deferred)

- **Reset whole-ride to 0**: not added in this pass (avoids a new controller method).
  Easy follow-up if it proves annoying on the bike.
- Percentage/intensity-bias representation: stays in watts, consistent with FTP-based
  targets and the per-interval control.

### Orientation

No layout change needed for landscape: `LandscapeRideLayout` embeds `IntervalEditBar`
and passes `onShowSettings` through to the same panel, so both orientations inherit
the swap automatically.

## Testing

- **Domain:** `WholeRideIntensityTests` untouched — still green (domain unchanged).
- **New unit:** extract the inline readout into a pure view-layer formatter (an
  `internal` free function or `static` helper, reachable from tests via
  `@testable import CycleJames`) and test it:
  - `wholeRideLabel(0)  == "0 W"`
  - `wholeRideLabel(10) == "+10 W"`
  - `wholeRideLabel(-5) == "−5 W"`
- **Visual:** simulator screenshot of the edit bar (whole-ride inline) and the opened
  ⚙ panel (per-interval + mode), verified by eye.
- **On-bike:** folds into PR #2's existing pre-merge gate (Free Ride verification on
  the trainer), confirming both steppers drive the trainer/profile as expected.

## Files touched

- `CycleJames/Views/Ride/IntervalEditBar.swift` (modified)
- `CycleJames/Views/Ride/RideSettingsPanel.swift` (modified)
- `CycleJamesTests/` — new formatter test (e.g. `IntensityReadoutTests.swift`)
- No changes to `RideController.swift`, `RideView.swift`, `LandscapeRideLayout.swift`,
  or `Workout.swift`.
