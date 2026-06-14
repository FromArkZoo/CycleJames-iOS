# Tabata Rides — Design Spec

**Date:** 2026-06-14
**Scope:** Add 10 new built-in workouts to `CycleJames/Library/BuiltInWorkouts.swift` — 5 Tabata rides at 30 minutes and 5 at 1 hour. Content-only; no model, UI, or filter changes.

## Background

The catalog (`BuiltInWorkouts.all`) holds ~80 workouts as flat literal `Workout` values built from the existing `S` / `Ssec` / `R` interval helpers. It already contains "Tabata-style" sessions (`vo2-30-30`, `vo2-40-20`, `microbursts-30`) but no rides explicitly named **Tabata**. This adds them.

The workout list view filters by duration bucket: **30min = 25–35 min total**, **1hr = 55–65 min total** (`WorkoutFiltering.durations`). Each ride's *total* duration (warm-up + work + recovery + cool-down) must land inside its bucket.

## Definitions

- **Tabata block** = the canonical protocol: **8 × (20s near-max effort / 10s easy rest) = 4:00 exactly.**
- Efforts are programmed as % of FTP (the model and ride UI already support power well above 100%).
- Off-efforts (the 10s rests) are at **45%**; recoveries between blocks are easy-spin **50%** steady.
- All rides are category `.vo2max` (where the existing high-intensity short work lives).

## Decisions (from brainstorming)

1. **Variety = progressive ladder.** All rides use genuine 20/10 blocks; the 5 at each duration form a difficulty ladder via escalating block count + peak intensity + tighter recovery.
2. **Intensity = classic maximal**, 150–170% FTP across the ladder.
3. **Implementation = flat inline interval literals**, matching the existing file style (no new `tabata()` helper). Efforts numbered continuously "On 1"/"Off 1"… per workout; the final effort of each workout ends on work (no trailing "Off"), per the existing `vo2-30-30` convention. Dropping that single trailing 10s shifts a total by at most 10s — well inside the bucket windows.

## 30-minute ladder

Warm-up `R` ramp; recoveries `S` at 50%; cool-down `R` ramp. Off-efforts at 45%.

| Name | ID | Warm-up | Blocks × peak | Recovery | Cool-down | Total |
|---|---|---|---|---|---|---|
| Tabata Starter | `tabata-starter-30` | 8 (45→75) + 2 opener @95 | 2 × 150% | 4 min | 6 (60→40) | ~28 min |
| Tabata Builder | `tabata-builder-30` | 8 (45→75) | 3 × 155% | 3 min | 5 (60→40) | ~31 min |
| Tabata Classic | `tabata-classic-30` | 8 (45→75) | 3 × 160% | 4 min | 4 (60→40) | ~32 min |
| Tabata Crusher | `tabata-crusher-30` | 7 (45→78) | 4 × 165% | 2 min | 4 (60→40) | ~33 min |
| Tabata Inferno | `tabata-inferno-30` | 7 (45→78) | 4 × 170% | 2 min | 4 (60→40) | ~33 min |

## 1-hour ladder

| Name | ID | Warm-up | Blocks × peak | Recovery | Cool-down | Total |
|---|---|---|---|---|---|---|
| Tabata Hour | `tabata-starter-60` | 10 (45→75) + 2 opener @95 | 5 × 150% | 4 min | 10 (60→40) | ~58 min |
| Tabata Hour Builder | `tabata-builder-60` | 10 (45→75) | 6 × 155% | 4 min | 8 (60→40) | ~62 min |
| Tabata Hour Classic | `tabata-classic-60` | 10 (45→75) | 7 × 160% | 3 min | 6 (60→40) | ~62 min |
| Tabata Hour Crusher | `tabata-crusher-60` | 10 (45→78) | 7 × 165% | 3 min | 6 (60→40) | ~62 min |
| Tabata Hour Inferno | `tabata-inferno-60` | 10 (45→78) | 8 × 170% | 2 min | 6 (60→40) | ~62 min |

## Descriptions

Each ride gets a one/two-sentence description in the catalog's house style, e.g. *"30-minute Tabata session. 3× classic Tabata blocks (20s on / 10s off) at 160% FTP. True high-intensity stimulus."*

## Verification

- IDs unique against the existing catalog (verified: no `tabata-` IDs exist today).
- Each total duration recomputed and asserted inside its bucket window.
- Project compiles (`xcodebuild` build of the CycleJames scheme).
- Single registration point is `BuiltInWorkouts.all`; appending suffices (consumed by WorkoutsView, FavouritesView, CalendarView, WorkoutPickerSheet).

## Out of scope

Marketing version / build-number bump and any App Store submission — separate finishing step, only if requested.
