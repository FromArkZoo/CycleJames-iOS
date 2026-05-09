# App Store screenshots

Five 6.9" iPhone screenshots (1320×2868) ready for App Store Connect →
iPhone 6.9" Display. Drag in upload order:

| Order | File | Story |
|---|---|---|
| 1 | `01_onboarding.png` | First-launch FTP entry — sets the hook. |
| 2 | `02_workouts.png` | Workout library with brand wordmark + zone bars, hearts on cards, and the new tab bar including Favourites. |
| 3 | `03_workout_detail.png` | Kitchen Sink chart with all five training zones + the +/- adjuster + Schedule-for-later button. Hero shot. |
| 4 | `04_calendar.png` | Calendar with three scheduled rides on the grid, today highlighted, day-detail card showing Kitchen Sink scheduled for May 10. |
| 5 | `05_favourites.png` | Favourites tab with three heart-curated workouts. |

## How they were captured

Two debug-only launch arguments make it possible to land on any tab or
push a workout detail without tapping. They're plain `ProcessInfo`
reads, no behaviour change in production.

```bash
# Boot the 6.9" sim and clean the status bar
xcrun simctl boot 7A61C462-2E83-4C1D-A9D0-66B03FF47CCA   # iPhone 17 Pro Max
xcrun simctl status_bar booted override --time "9:41" \
  --batteryState charged --batteryLevel 100 \
  --cellularBars 4 --wifiBars 3
xcrun simctl spawn booted defaults write com.jamesbrowne.cyclejames \
  cyclejames_hasOnboarded -bool YES
xcrun simctl spawn booted defaults write com.jamesbrowne.cyclejames \
  cyclejames_ftp -int 240

# Build + install the latest debug build
APP_PATH=$(find ~/Library/Developer/Xcode/DerivedData/CycleJames-*/Build/Products/Debug-iphonesimulator \
  -maxdepth 2 -name "CycleJames.app" -type d | head -1)
xcrun simctl install booted "$APP_PATH"

# Capture each shot
xcrun simctl launch booted com.jamesbrowne.cyclejames \
  -screenshotWorkout "Kitchen Sink"
sleep 4
xcrun simctl io booted screenshot 02_workout_detail.png

xcrun simctl terminate booted com.jamesbrowne.cyclejames
xcrun simctl launch booted com.jamesbrowne.cyclejames -screenshotTab settings
sleep 3
xcrun simctl io booted screenshot 04_settings.png
# … etc for history, calendar, builder
```

Supported `-screenshotTab` values: `workouts` (default), `calendar`,
`history`, `builder`, `settings`. `-screenshotWorkout` takes a substring
of either workout id or workout name.

## To re-capture for a future build

Re-run the install + launch lines above. Status-bar override survives
across launches but is cleared on reboot — re-run `status_bar override`
if needed. To remove: `xcrun simctl status_bar booted clear`.

## Uploading

App Store Connect → My Apps → CycleJames → 1.0 Prepare for Submission →
Screenshots → iPhone 6.9" Display → drag in the five files in order.
