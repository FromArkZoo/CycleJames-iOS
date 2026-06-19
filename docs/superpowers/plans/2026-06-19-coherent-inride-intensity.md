# Coherent In-Ride Intensity Controls Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Swap the two in-ride power controls so the most-used one (whole-ride) is the inline edit-bar stepper and the rarer per-interval tweak lives in the ⚙ panel, both reading as identical ±5 W steppers.

**Architecture:** Pure view-layer change. A new pure formatter (`IntensityReadout`) produces both readout strings and is unit-tested. `IntervalEditBar` swaps its inline stepper from per-interval to whole-ride (instant accumulated offset readout). `RideSettingsPanel` swaps its section from whole-ride to per-interval (live absolute target from `currentTarget`, disabled when no active interval). No changes to `RideController`, `Workout`, `RideView`, or `LandscapeRideLayout` — landscape inherits the swap because it embeds `IntervalEditBar`.

**Tech Stack:** SwiftUI, XcodeGen (`project.yml`), XCTest via `xcodebuild`.

## Global Constraints

- **No domain edits.** `RideController.adjustWholeRide(byWatts:)`, `adjustCurrentInterval(byWatts:)`, and `Workout.adjustingAllIntervals(byWatts:ftp:)` are unchanged. `WholeRideIntensityTests` must stay green.
- **Branch:** work on `inride-improvements` (continues PR #2). Do not branch.
- **Step size:** ±5 W for both controls (unchanged from today).
- **Negative readout uses a typographic minus** `−` (U+2212), not an ASCII hyphen `-`.
- **Test command:** `xcodebuild test -project CycleJames.xcodeproj -scheme CycleJames -destination 'platform=iOS Simulator,name=iPhone 17'`
- **Build command:** `xcodebuild build -project CycleJames.xcodeproj -scheme CycleJames -destination 'platform=iOS Simulator,name=iPhone 17'`
- **New source files require** `xcodegen generate` **and committing the regenerated** `CycleJames.xcodeproj` **alongside them** (XcodeGen globs `CycleJames/` and `CycleJamesTests/` by directory).

## File Structure

- `CycleJames/Views/Ride/IntensityReadout.swift` (**create**) — pure, stateless formatter for both readout strings. One responsibility: turn watts values into display text.
- `CycleJamesTests/IntensityReadoutTests.swift` (**create**) — unit tests for the formatter.
- `CycleJames/Views/Ride/IntervalEditBar.swift` (**modify**) — inline stepper becomes whole-ride.
- `CycleJames/Views/Ride/RideSettingsPanel.swift` (**modify**) — panel section becomes per-interval.
- `CycleJames.xcodeproj` (**regenerate + commit** in Task 1 only).

---

### Task 1: `IntensityReadout` formatter (pure, TDD)

**Files:**
- Create: `CycleJames/Views/Ride/IntensityReadout.swift`
- Test: `CycleJamesTests/IntensityReadoutTests.swift`
- Regenerate + commit: `CycleJames.xcodeproj`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `IntensityReadout.wholeRide(offsetWatts: Int) -> String` — `"0 W"`, `"+10 W"`, `"−5 W"` (typographic minus).
  - `IntensityReadout.intervalTarget(watts: Int, hasActiveInterval: Bool) -> String` — `"This interval · 210 W"` when active, `"This interval · —"` when not.

- [ ] **Step 1: Write the failing test**

Create `CycleJamesTests/IntensityReadoutTests.swift`:

```swift
import XCTest
@testable import CycleJames

final class IntensityReadoutTests: XCTestCase {
    func test_wholeRide_zero_showsPlainWatts() {
        XCTAssertEqual(IntensityReadout.wholeRide(offsetWatts: 0), "0 W")
    }

    func test_wholeRide_positive_showsPlusSign() {
        XCTAssertEqual(IntensityReadout.wholeRide(offsetWatts: 10), "+10 W")
    }

    func test_wholeRide_negative_usesTypographicMinus() {
        // U+2212 minus, not ASCII hyphen.
        XCTAssertEqual(IntensityReadout.wholeRide(offsetWatts: -5), "\u{2212}5 W")
    }

    func test_intervalTarget_active_showsAbsoluteWatts() {
        XCTAssertEqual(
            IntensityReadout.intervalTarget(watts: 210, hasActiveInterval: true),
            "This interval · 210 W"
        )
    }

    func test_intervalTarget_inactive_showsDash() {
        XCTAssertEqual(
            IntensityReadout.intervalTarget(watts: 0, hasActiveInterval: false),
            "This interval · —"
        )
    }
}
```

- [ ] **Step 2: Create the source file**

Create `CycleJames/Views/Ride/IntensityReadout.swift`:

```swift
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
```

- [ ] **Step 3: Regenerate the Xcode project so the new files are in the target**

Run: `xcodegen generate`
Expected: `Created project at .../CycleJames.xcodeproj`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `xcodebuild test -project CycleJames.xcodeproj -scheme CycleJames -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:CycleJamesTests/IntensityReadoutTests`
Expected: `** TEST SUCCEEDED **`, 5 tests passing.

(If `-only-testing` filtering misbehaves, run the full suite from the Global Constraints test command; all tests including `IntensityReadoutTests` must pass.)

- [ ] **Step 5: Commit (include the regenerated project)**

```bash
git add CycleJames/Views/Ride/IntensityReadout.swift CycleJamesTests/IntensityReadoutTests.swift CycleJames.xcodeproj
git commit -m "feat: pure IntensityReadout formatter for in-ride readouts"
```

---

### Task 2: `IntervalEditBar` — inline stepper becomes whole-ride

**Files:**
- Modify: `CycleJames/Views/Ride/IntervalEditBar.swift` (full replacement below)

**Interfaces:**
- Consumes: `IntensityReadout.wholeRide(offsetWatts:)` (Task 1); `ride.adjustWholeRide(byWatts:)` and `ride.wholeRideOffsetWatts` (existing on `RideController`).
- Produces: unchanged public surface — `IntervalEditBar(onShowUpcoming:onShowAddInterval:onShowSettings:)`. Callers in `RideView` and `LandscapeRideLayout` are untouched.

**Why no new unit test:** this is declarative SwiftUI wiring; the only non-trivial logic (the readout string) is already covered by Task 1. Verification is build + visual.

- [ ] **Step 1: Replace the file contents**

Overwrite `CycleJames/Views/Ride/IntervalEditBar.swift` with:

```swift
import SwiftUI

struct IntervalEditBar: View {
    @EnvironmentObject private var ride: RideController
    var onShowUpcoming: () -> Void
    var onShowAddInterval: () -> Void
    var onShowSettings: () -> Void

    var body: some View {
        HStack(spacing: CJSpacing.s) {
            HStack(spacing: 6) {
                adjustButton(systemName: "minus", label: "Decrease whole-ride power by 5 watts") {
                    ride.adjustWholeRide(byWatts: -5)
                }
                VStack(spacing: 0) {
                    Text("Whole ride")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(CJColors.textSecondary)
                    Text(IntensityReadout.wholeRide(offsetWatts: ride.wholeRideOffsetWatts))
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .foregroundStyle(CJColors.textPrimary)
                }
                adjustButton(systemName: "plus", label: "Increase whole-ride power by 5 watts") {
                    ride.adjustWholeRide(byWatts: 5)
                }
            }
            Spacer(minLength: CJSpacing.s)
            Button(action: onShowUpcoming) {
                HStack(spacing: 4) {
                    Image(systemName: "list.bullet.rectangle")
                    Text("Queue")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, CJSpacing.m)
                .frame(height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CJColors.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Button(action: onShowAddInterval) {
                HStack(spacing: 4) {
                    Image(systemName: "plus.rectangle.on.rectangle")
                    Text("Add")
                }
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, CJSpacing.m)
                .frame(height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(CJColors.border, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            Button(action: onShowSettings) {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.white)
                    .background(CJColors.card)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(CJColors.border, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Ride settings")
        }
        .padding(.horizontal, CJSpacing.s)
        .padding(.vertical, 6)
        .background(CJColors.bgSecondary.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
    }

    private func adjustButton(systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .bold))
                .frame(width: 32, height: 32)
                .foregroundStyle(.white)
                .background(CJColors.card)
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

#Preview {
    IntervalEditBar(onShowUpcoming: {}, onShowAddInterval: {}, onShowSettings: {})
        .environmentObject(RideController())
        .padding()
        .background(CJColors.bgPrimary)
}
```

Notes on what changed: the left stepper now calls `adjustWholeRide` and shows the `Whole ride` caption + accumulated offset; the `let ctx = ...` line and the `enabled:` parameter on `adjustButton` are removed (whole-ride needs no active-interval gate); a `#Preview` is added for canvas verification.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project CycleJames.xcodeproj -scheme CycleJames -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Visual check**

Open `IntervalEditBar.swift` in Xcode and resume the Preview canvas (or run the app in the iPhone 17 simulator). Confirm the inline control reads `[−]  Whole ride / 0 W  [+]` and that Queue / Add / ⚙ still sit to the right without clipping at narrow widths.

- [ ] **Step 4: Commit**

```bash
git add CycleJames/Views/Ride/IntervalEditBar.swift
git commit -m "feat: inline edit-bar stepper controls whole-ride intensity"
```

---

### Task 3: `RideSettingsPanel` — panel section becomes per-interval

**Files:**
- Modify: `CycleJames/Views/Ride/RideSettingsPanel.swift` (full replacement below)

**Interfaces:**
- Consumes: `IntensityReadout.intervalTarget(watts:hasActiveInterval:)` (Task 1); `ride.adjustCurrentInterval(byWatts:)`, `ride.currentTarget`, `ride.currentIntervalContext` (existing on `RideController`); `ride.mode` / `ride.setMode(_:)` (unchanged).
- Produces: unchanged public surface — `RideSettingsPanel(onClose:)`.

- [ ] **Step 1: Replace the file contents**

Overwrite `CycleJames/Views/Ride/RideSettingsPanel.swift` with:

```swift
import SwiftUI

/// Compact in-ride settings overlay: ride mode + per-interval intensity.
/// Presented over the ride; never pauses it.
struct RideSettingsPanel: View {
    @EnvironmentObject private var ride: RideController
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: CJSpacing.m) {
            HStack {
                Text("Ride Settings").font(.system(size: 16, weight: .bold))
                    .foregroundStyle(CJColors.textPrimary)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(CJColors.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close settings")
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("MODE").font(CJFont.labelUpper).foregroundStyle(CJColors.textSecondary)
                Picker("Mode", selection: Binding(
                    get: { ride.mode },
                    set: { ride.setMode($0) }
                )) {
                    Text("ERG").tag(RideMode.erg)
                    Text("Free Ride").tag(RideMode.freeRide)
                }
                .pickerStyle(.segmented)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("THIS INTERVAL").font(CJFont.labelUpper)
                    .foregroundStyle(CJColors.textSecondary)
                let hasInterval = ride.currentIntervalContext != nil
                HStack(spacing: CJSpacing.m) {
                    stepButton(systemName: "minus", label: "Decrease current interval power by 5 watts", enabled: hasInterval) {
                        ride.adjustCurrentInterval(byWatts: -5)
                    }
                    Text(IntensityReadout.intervalTarget(watts: ride.currentTarget, hasActiveInterval: hasInterval))
                        .font(.system(size: 15, weight: .semibold).monospacedDigit())
                        .foregroundStyle(CJColors.textPrimary)
                        .frame(minWidth: 120)
                    stepButton(systemName: "plus", label: "Increase current interval power by 5 watts", enabled: hasInterval) {
                        ride.adjustCurrentInterval(byWatts: 5)
                    }
                }
            }
        }
        .padding(CJSpacing.l)
        .background(CJColors.card)
        .clipShape(RoundedRectangle(cornerRadius: CJRadius.medium))
        .overlay(RoundedRectangle(cornerRadius: CJRadius.medium).stroke(CJColors.border, lineWidth: 1))
        .frame(maxWidth: 360)
        .shadow(radius: 12)
    }

    private func stepButton(systemName: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 40, height: 40)
                .foregroundStyle(.white)
                .background(CJColors.bgSecondary)
                .clipShape(Circle())
                .opacity(enabled ? 1.0 : 0.4)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

#Preview {
    RideSettingsPanel(onClose: {})
        .environmentObject(RideController())
        .padding()
        .background(CJColors.bgPrimary)
}
```

Notes on what changed: the `WHOLE-RIDE INTENSITY` section is replaced by `THIS INTERVAL` (wired to `adjustCurrentInterval`, reading `currentTarget`, disabled when there's no active interval); the `offsetLabel` computed property is removed; `stepButton` gains an `enabled:` parameter; the doc comment is updated. The MODE section is unchanged.

- [ ] **Step 2: Build to verify it compiles**

Run: `xcodebuild build -project CycleJames.xcodeproj -scheme CycleJames -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Run the full test suite (confirm nothing regressed)**

Run: `xcodebuild test -project CycleJames.xcodeproj -scheme CycleJames -destination 'platform=iOS Simulator,name=iPhone 17'`
Expected: `** TEST SUCCEEDED **` — `WholeRideIntensityTests`, `IntensityReadoutTests`, and all existing tests pass.

- [ ] **Step 4: Visual check**

Resume the `RideSettingsPanel` Preview canvas (or open the ⚙ panel in the simulator). In the preview's fresh-controller state there is no active interval, so confirm the per-interval row renders **disabled** and reads `This interval · —` beneath the MODE picker. (Enabled state with a live target is verified during the on-bike gate below.)

- [ ] **Step 5: Commit**

```bash
git add CycleJames/Views/Ride/RideSettingsPanel.swift
git commit -m "feat: move per-interval intensity into the ride settings panel"
```

---

## Post-implementation verification (PR #2 gate, not a code task)

On the bike, in a live ride: confirm the inline `Whole ride` stepper adjusts every interval and its readout updates instantly; open ⚙ and confirm `This interval` adjusts only the current block with the absolute target updating within ~1 s; confirm both behave in ERG and Free Ride and in landscape. This folds into PR #2's existing Free Ride pre-merge verification.

## Self-Review

**Spec coverage:**
- Inline → whole-ride with live accumulated offset → Task 2. ✓
- Panel → per-interval with live absolute target, disabled when no interval → Task 3. ✓
- Typographic-minus formatter, both readouts pure-tested → Task 1. ✓
- No domain edits; `WholeRideIntensityTests` green → Global Constraints + Task 3 Step 3. ✓
- Landscape inherits via `IntervalEditBar` → noted in Architecture; no task needed. ✓
- Reset-to-zero deferred; watts (not %) → respected (not implemented). ✓

**Placeholder scan:** none — all code blocks are complete and final.

**Type consistency:** `IntensityReadout.wholeRide(offsetWatts:)` and `IntensityReadout.intervalTarget(watts:hasActiveInterval:)` are defined in Task 1 and consumed with identical signatures in Tasks 2 and 3. `adjustWholeRide(byWatts:)`, `adjustCurrentInterval(byWatts:)`, `wholeRideOffsetWatts`, `currentTarget`, `currentIntervalContext` all match `RideController`'s existing surface. ✓
