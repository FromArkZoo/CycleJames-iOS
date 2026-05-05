# Reply to App Review (Submission 4714779b-594f-4b86-9463-5147005cd62e)

Paste-ready reply for App Store Connect → Resolution Center.

---

Hello App Review team,

Thank you for the detailed feedback. Replies to each point below.

## Guideline 2.5.4 — Background audio

We have removed `audio` from the `UIBackgroundModes` array in Info.plist. The
app no longer declares the audio background mode. Audio cues (countdown and
interval beeps) now play only while the app is in the foreground. The new
build (1.0 build 2) reflects this change.

## Guideline 1.4.1 — Medical disclaimer

We have added the following disclaimer to the end of the app's description in
App Store Connect:

> DISCLAIMER
> CycleJames is a fitness app, not a medical device. It does not diagnose,
> treat, cure or prevent any condition. Consult a qualified physician before
> starting any new training programme, and seek a doctor's advice before
> making any decisions related to your health. Stop exercising and seek
> medical attention if you experience pain, dizziness or other symptoms
> during a workout.

## Guideline 2.1 — Hardware brand and authorisation

CycleJames does **not** use any brand-specific Bluetooth protocols. It speaks
two open, standardised Bluetooth GATT profiles published by the Bluetooth SIG:

- **FTMS** (Fitness Machine Service, UUID `0x1826`) — used for smart trainers.
- **Heart Rate Service** (UUID `0x180D`) — used for heart-rate monitors.

Both profiles are vendor-neutral public standards. The app works with any
hardware that implements these profiles correctly, regardless of manufacturer.
We are not affiliated with, sponsored by, or distributing on behalf of any
specific brand. No brand names, logos, or trademarks belonging to hardware
manufacturers are used in the app's UI, marketing, or App Store listing in a
way that implies endorsement — references such as "Wahoo, Tacx, Wattbike"
appear only as factual examples of trainers that implement the open FTMS
standard, in the same way a generic Bluetooth keyboard app might mention that
it is compatible with keyboards from various vendors.

Because the app is not distributed on behalf of any brand, no authorisation
documentation applies.

## Guideline 2.1 — Demo video

A demo video has been uploaded; the link is in the App Review Information
section. The video is filmed on a physical iPhone (not a simulator) and shows:

1. The app launched on the iPhone.
2. The initial Bluetooth pairing flow with a Wattbike Atom smart trainer
   (FTMS) and a Polar H10 heart-rate strap.
3. Selecting a built-in workout from the library.
4. Starting the workout — live target power streaming to the trainer,
   resistance changing automatically as the workout steps through intervals,
   live heart-rate and power readouts on screen.
5. Mid-ride controls — adjusting target watts, skipping an interval.
6. Finishing the workout — saved ride summary with average power, normalised
   power, IF, TSS.
7. Exporting the ride via the iOS share sheet.

Both the iPhone screen and the trainer/HR hardware are visible throughout.

Please let us know if anything further is needed.

Thanks,
James Browne

---

# Demo video shotlist (~3–4 minutes total)

Film with a second phone or a tripod-mounted camera so both the iPhone screen
and the hardware are visible in frame. Keep the iPhone screen un-mirrored —
Apple specifically wants the physical device shown.

## Equipment to have visible on camera

- iPhone running 1.0 build 2 (the resubmitted build).
- Wattbike Atom (or whichever FTMS trainer you'll demo).
- Polar H10 (or any standard HR strap) worn on the body, or held to camera
  briefly so it's clearly a separate piece of HR hardware.

## Shot list

1. **Open with the hardware** (5s) — pan from the trainer to the HR strap,
   then to the iPhone, so the reviewer sees all three pieces in the same room.
2. **Launch app on iPhone** (5s) — show the home screen, tap the CycleJames
   icon. Brief flash of the launch screen counts.
3. **Bluetooth pairing — trainer** (20–30s)
   - Go to the Connect / Settings screen.
   - Show "Searching" or equivalent.
   - Wattbike appears in the list. Tap it. Show "Connected" status.
   - Pan the camera to the trainer briefly.
4. **Bluetooth pairing — HR strap** (15–20s)
   - Same screen. Polar H10 appears. Tap it. Show heart-rate readout
     starting to populate (e.g. 65 bpm).
   - Lift the strap to camera or tap your chest so the reviewer sees the
     hardware that's producing the BPM number on screen.
5. **Pick a workout** (10s) — go to Library, scroll, pick a short one
   (e.g. a 15-minute Z2 spin or a quick interval workout).
6. **Start workout** (45–60s)
   - Hit Start. Sit on the trainer.
   - Show the live screen: target watts, current watts, HR, interval timer.
   - Start pedalling. Show that current watts approach target watts as the
     trainer's resistance changes — this is the core "FTMS write" feature.
   - When the workout steps to a new interval, show resistance change again
     (you can hear the Wattbike adjust; pedal harder/easier accordingly).
7. **Mid-ride controls** (15s)
   - Tap +5W or -5W, show target updating.
   - Skip the current interval, show the next one starting.
8. **Finish** (15s)
   - End the workout (or wait for it to complete on a short one).
   - Show the ride summary: avg power, NP, IF, TSS.
9. **Export** (10s)
   - Tap share, show the iOS share sheet, point at "Strava" / "Files" /
     "Mail" so the reviewer sees the TCX export path. You don't have to
     actually upload.
10. **Close** (3s) — back to home screen.

## Tips

- Narrate over the top, or add captions in the Photos / iMovie app —
  reviewers appreciate "Here I'm tapping the Wattbike to pair…"
- Upload to a private YouTube or Vimeo link. Paste the URL into App Review
  Information → "App review notes" or → "Demo video URL" if a dedicated
  field exists.
- Keep the link active until the app is approved.
