# App Store screenshots

App Store Connect requires 3–10 screenshots at the **6.9" iPhone** resolution
(1320×2868). Screenshots taken on the iPhone 17 Pro Max simulator land at
exactly that size. Other sizes (6.5", 5.5") are now optional / deprecated.

## What's already here

| File | Captured | Notes |
|---|---|---|
| `01_onboarding.png` | ✓ | First-launch onboarding screen with FTP entry. |
| `02_workouts.png` | ✓ | Built-in workouts list with filter pills. |

## What's still needed (capture yourself)

Boot the iPhone 17 Pro Max simulator, run the app, then use **⌘S** in the
Simulator app to save each screenshot. Drop them into this folder.

| File | What to capture | How to get there |
|---|---|---|
| `03_workout_detail.png` | The chart + interval list for "2hr Threshold" | Tap the 2hr Threshold card from Workouts. |
| `04_ride_live.png` | Live ride view mid-interval, ideally with the disconnect banner *not* shown | Tap a workout → Start. The countdown will roll; let it run a few seconds in. (No trainer connected is fine — the simulator just shows zero metrics.) |
| `05_history_or_settings.png` | Either an empty History (clean look) or the Settings screen showing the FTP card | Tap History or Settings tab. |

Aim for **5 total** — that's enough for App Store Connect without padding.

## Pre-capture cleanup (already applied)

The simulator's status bar is currently overridden to a clean 09:41, full
battery, full signal via:

```bash
xcrun simctl status_bar booted override \
  --time "9:41" --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3
```

To clear the override later: `xcrun simctl status_bar booted clear`.

If you see an Apple Intelligence / system notification banner blocking the
top of the screen, swipe it away or run:

```bash
xcrun simctl terminate booted com.apple.springboard
sleep 2
xcrun simctl launch booted com.jamesbrowne.cyclejames
```

## Uploading to App Store Connect

App Store Connect → My Apps → CycleJames → 1.0 Prepare for Submission →
iPhone 6.9" Display → drag in the PNGs. They're auto-arranged in upload order.
