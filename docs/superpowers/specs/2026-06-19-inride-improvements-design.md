# CycleJames — In-Ride Improvements (Design)

**Date:** 2026-06-19
**Status:** Design approved; spec under review
**Branch:** `inride-improvements`
**Related:** [`2026-06-19-pricing-and-gtm-strategy.md`](2026-06-19-pricing-and-gtm-strategy.md) (the in-app review prompt below is the code half of GTM action #3)

## Overview

Five changes to the in-ride experience, all testable on the owner's Wattbike (FTMS):

1. **ELAPSED overflow fix** — long durations (`h:mm:ss`) wrap and overflow the metric tile in landscape.
2. **In-ride settings panel** — a compact overlay opened by a gear button; the shared home for the two new controls.
3. **Free Ride mode** — toggle ERG ⇄ Free Ride mid-ride; in Free Ride the trainer is put into simulation mode at 0% grade so the rider's own gears/effort drive resistance and the app simply reflects actual power.
4. **Whole-ride intensity** — a single ± watts control that adjusts every interval at once (the existing per-interval ± is fiddly on short intervals).
5. **Review prompt** — request an App Store review after a completed ride, gated.

### Goals
- Fix the landscape ELAPSED layout bug for all long-duration rides.
- Let the rider ride freely (gears/effort) inside a structured session without ending it.
- Let the rider rescale the whole workout in one action.
- Begin the traction-first reviews loop (GTM strategy).

### Non-goals (deferred to a later spec)
- **Power-meter-only support** (Cycling Power Service, `0x1818`) — connecting a road bike + power meter with no controllable trainer. Net-new BLE subsystem; cannot be verified on the Wattbike.
- **On-screen +/- "gears"** for controllable trainers that lack physical shifters. The sim-mode plumbing built here makes this a cheap later addition; the owner's gears are on the Wattbike handlebars, so it is not testable now.

## Current state (relevant code)

- **Ride screen:** `Views/Ride/RideView.swift` — `portraitContent` (~L143) renders `MetricsGrid` + `WorkoutGraphView`; `landscapeContent` (~L186) renders `LandscapeRideLayout`.
- **Metric tiles:** `Views/Ride/MetricCard.swift` — the value `Text` uses `valueFont` (~L52–57) inside a flexible-width frame (~L41) with **no `lineLimit` and no `minimumScaleFactor`** → the wrap bug. Portrait grid: `Views/Ride/MetricsGrid.swift`; landscape row: `Views/Ride/LandscapeRideLayout.swift` (`pillsRow`, ~L42–76).
- **Time formatting:** `Domain/PowerMetrics.swift` `TimeFormat.mmss` (~L44–54) → `m:ss` under an hour, `h:mm:ss` at/over an hour.
- **Per-interval ± control:** `Views/Ride/IntervalEditBar.swift` (±5 W buttons) → `RideController.adjustCurrentInterval(byWatts:)` (~L141–148) → `Workout.adjustingInterval(at:byWatts:ftp:)` (~L125–130).
- **Whole-ride scaffolding (already present):** `Workout.adjustingAllIntervals(byWatts:ftp:)` (~L132–134) maps `adjustedByWatts` over every interval. Currently unused by any UI.
- **Target power loop:** `RideController.handleTick` (~L339–346) computes `currentTarget` from the interval's `powerPercent × ftp` and calls `trainer?.setTargetPower(...)` when connected.
- **Trainer control (FTMS):** `Bluetooth/FTMSManager.swift` — service `1826`, Indoor Bike Data `2AD2`, Control Point `2AD9`; only opcode implemented is `opSetTargetPower = 0x05` (`setTargetPower`, ~L136–143). Indoor Bike Data parse (~L171–221) currently **skips** the resistance field. `RideController` holds a weak `trainer` ref (~L53) bound in `bind(trainer:hr:)` (~L63).
- **Settings/profile:** `Models/Settings.swift` (`AppSettings`, FTP in `UserDefaults` via `SettingsKeys`), `Views/Settings/SettingsView.swift`. **No rider weight is stored** anywhere.
- **Graph:** `Views/Graph/WorkoutGraphView.swift` (target profile + live trace).
- **Session model:** `Models/RideSessionModel.swift` (`ftp` default 200).

## Feature 1 — ELAPSED overflow fix

**Problem:** When elapsed crosses one hour, the value string grows from `m:ss` to `h:mm:ss`. `MetricCard`'s value `Text` has no single-line constraint, so SwiftUI wraps it onto a second line, overflowing the tile (seen as "1:17:4 / 4" in landscape).

**Fix:** On the value `Text` in `MetricCard`, add `.lineLimit(1)` + `.minimumScaleFactor(0.6)` (plus `.allowsTightening(true)`). Apply to **all** metric values, not just Elapsed, so a 4-digit power reading or any long value shrinks-to-fit rather than wrapping. The `.monospacedDigit()` already in `valueFont` keeps the shrunk digits aligned.

**Acceptance:** In landscape, a ride past 1:00:00 shows the full `h:mm:ss` on one line inside the tile at every duration up to `9:59:59`; nothing is truncated or wrapped; portrait is visually unchanged for short values.

## Feature 2 — In-ride settings panel

**What:** A gear (`gearshape`) button on the ride screen in **both** orientations opens a compact overlay card anchored near the button; tap-away or a close affordance dismisses it. It does **not** pause the ride. It hosts two controls: the **Mode** toggle (Feature 3) and the **Whole-ride intensity** control (Feature 4).

**Why an overlay, not a `.sheet`:** A medium sheet covers most of the screen in landscape (the primary riding orientation) and reads as "leaving the ride." A small card overlay keeps the ride visible and works identically in both orientations.

**New view:** `Views/Ride/RideSettingsPanel.swift`. Trigger button + presentation state (`@State private var showSettings`) added to `RideView` and surfaced in `LandscapeRideLayout`. The panel takes bindings/closures into `RideController` (mode, intensity offset, and their mutators) — it owns no ride state itself.

**Acceptance:** Gear button visible and tappable in portrait and landscape; opening/closing never interrupts the timer, trainer control, or recording; panel is legible over the ride background.

## Feature 3 — Free Ride mode

**Model:** add `enum RideMode { case erg, freeRide }` to `RideController`, default `.erg`. Expose `mode` (published) and `setMode(_:)`.

**Behaviour:**
- **ERG (unchanged default):** `handleTick` keeps sending `setTargetPower(currentTarget)`.
- **Switch to Free Ride:** `RideController` stops sending target power and instead commands the trainer into **simulation mode at 0% grade** (see FTMS change). This is the same mechanism Zwift uses, under which the Wattbike's handlebar gears modulate resistance and power rises/falls with effort.
  - The **workout clock and graph keep running**. The target line in `WorkoutGraphView` is rendered **ghosted** (reduced opacity / dashed) to signal "not being enforced."
  - The rider's **actual** power continues to be read and recorded against the workout exactly as in ERG.
- **Switch back to ERG:** resume enforcing the current interval's target (re-issue control + next `handleTick` sends target power).

**Safe-first construction (per the agreed risk plan):**
1. **Guaranteed core (no hardware uncertainty):** stop ERG, ghost the target, keep recording actual power, restore ERG on toggle-back. This is entirely our own code and always works.
2. **Sim-mode gears layer:** send sim @ 0% so the bar-gears go live. Standard Zwift mechanism; validated on the bike during implementation.

**Fallback:** if sim @ 0% does not make the Wattbike gears live as expected, exit ERG via an FTMS reset/stop so the bike reverts to its standalone resistance/gear behaviour. Either way the rider gets a working "ERG off, ride freely, watch your power" mode.

**Rider weight:** sim resistance at 0% grade is dominated by rolling/wind terms, not gravity, so rider weight has negligible effect. Use a fixed default (75 kg) in the sim parameters; **no new weight setting** in this round.

**Acceptance:** Toggling to Free Ride mid-ride stops target-power commands within one tick, ghosts the target, and (on the Wattbike) makes the bar-gears change resistance with power tracking effort; toggling back resumes ERG enforcement at the correct current target; recorded power is continuous across both.

## Feature 4 — Whole-ride intensity (watts offset)

**Model:** `RideController` gains `wholeRideOffsetWatts: Int` (published, starts at 0 each ride) and `adjustWholeRide(byWatts delta: Int)`:
- calls `selectedWorkout = workout.adjustingAllIntervals(byWatts: delta, ftp: ftp)` (reusing the existing model method),
- updates the player (`player.updateWorkout(...)`, mirroring `adjustCurrentInterval`),
- accumulates `wholeRideOffsetWatts += delta`.

**Control:** in the settings panel, a ± control at **±5 W** per step (matching the per-interval control) with a label showing the cumulative offset, e.g. `Whole ride: +15 W`. The existing per-interval `IntervalEditBar` is **unchanged** and composes naturally (both ultimately mutate stored interval targets; clamping via the existing `adjustedByWatts` bounds of 5–600 % FTP).

**Acceptance:** A ±5 W tap shifts every interval's target by ≈5 W (FTP-scaled), the cumulative offset label updates, the current target sent to the trainer reflects it within one tick, and per-interval adjustments still work on top.

## Feature 5 — Review prompt (GTM)

**What:** after a ride is **completed** (reaches the end naturally — not on quit/abort), request an App Store review via `SKStoreReviewController.requestReview(in:)` (or SwiftUI `@Environment(\.requestReview)`).

**Gating:** persist a completed-ride counter in `UserDefaults` (new `SettingsKeys` entry). Fire only from the **3rd** completed ride onward, and never more than the system already allows (~3×/year). Never on the first two completed rides (too early) or on an aborted ride (negative moment).

**Touch point:** the ride-completion path in `RideController`; the actual request is invoked from the view layer (needs a `UIWindowScene`).

**Acceptance:** completing an early ride does not prompt; completing a later ride may prompt once; aborting never prompts.

## Data flow summary

```
Settings panel ──(mode)──────────► RideController.mode ──► handleTick:
                                                              erg      → trainer.setTargetPower(currentTarget)
                                                              freeRide → trainer.setSimulationGrade(0)  [once on switch]
Settings panel ──(±5 W whole)────► RideController.adjustWholeRide ─► Workout.adjustingAllIntervals ─► player + trainer
IntervalEditBar ──(±5 W current)─► RideController.adjustCurrentInterval (unchanged)
Ride completes ─────────────────► completed-ride counter ─► (gated) requestReview
```

## FTMS change (Bluetooth)

Add to `FTMSManager`:
- `opSetSimulationParameters: UInt8 = 0x11` and a `setSimulationGrade(_ grade: Double)` that writes the **Set Indoor Bike Simulation Parameters** payload to the Control Point (`2AD9`): wind speed = 0, grade = `grade` (sint16, 0.01 % units → 0 for 0%), Crr and Cw at standard defaults, using the fixed 75 kg assumption where needed. Ensure control is requested (`0x00`) before the first sim write, mirroring the existing ERG path.
- (Optional, low cost) start storing the resistance field already parsed-and-skipped at ~L207 for display/diagnostics — only if trivial; not required.

## Testing strategy

- **Unit (logic, no hardware):**
  - `TimeFormat.mmss` already covered; add a view-layer check that long values do not wrap (snapshot or `lineLimit` assertion if feasible).
  - `adjustWholeRide` accumulation + that `adjustingAllIntervals` scales every interval and respects clamps.
  - Mode state machine: ERG↔FreeRide transitions set the expected control intent; `handleTick` sends target power only in `.erg`.
  - Review-prompt gate: counter increments on completion only, threshold logic, no-fire on abort.
- **FTMS encoding:** unit-test the `0x11` payload bytes (grade 0 and a sample non-zero grade) against the FTMS spec byte layout.
- **On-bike (manual, during implementation):** connect Wattbike → start an ERG workout → open panel → switch to Free Ride → confirm bar-gears change resistance and power tracks effort, target ghosts, recording continues → switch back → ERG re-enforces. Validate the landscape ELAPSED fix past 1:00:00 on-device.

## Touch-point summary

| Area | Files |
|------|-------|
| ELAPSED fix | `Views/Ride/MetricCard.swift` |
| Settings panel | new `Views/Ride/RideSettingsPanel.swift`; `Views/Ride/RideView.swift`; `Views/Ride/LandscapeRideLayout.swift` |
| Free Ride mode | `Domain/RideController.swift`; `Bluetooth/FTMSManager.swift`; `Views/Graph/WorkoutGraphView.swift` (ghost target) |
| Whole-ride intensity | `Domain/RideController.swift`; `RideSettingsPanel`; (reuses `Models/Workout.swift`) |
| Review prompt | `Domain/RideController.swift` (completion + counter); view layer for `requestReview`; `Models/Settings.swift` (new key) |

## Risks

- **Free Ride / Wattbike (low, mitigated):** sim @ 0% is the standard Zwift free-ride mechanism, but the exact Wattbike response must be confirmed on-bike. Mitigated by safe-first construction + the FTMS-reset fallback, both of which still yield a usable Free Ride.
- **Review-prompt timing:** prompting too eagerly annoys; the gate (3rd completed ride, completion-only) keeps it to genuine positive moments.
