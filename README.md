# Margin — recovery and training-load app for Apple Watch Ultra 2

A personal, standalone watchOS app. It turns the watch's own HealthKit data into
one daily decision: **how much training load to take on today, and what the
risk limit is**. Every score breaks down into its inputs, and the false-alarm
rate is measured, not assumed.

```
Today ─ Recovery ring · PUSH / MAINTAIN / RECOVER / REST · pinned tiles · quick log
Energy ─ Energy bank curve (wake → now) · hourly stress · stress bands
Drivers ─ HRV, sleeping HR, sleep, respiration, temp: value, baseline, z, weight
Sleep ─ asleep vs need, stages, efficiency, regularity, debt, tonight's need
Load ─ Strain 0–100, TRIMP today, ATL / CTL / form / ACWR, ceiling, custom zones, cardio focus, HR recovery
Body ─ Biological age estimate, VO2 max, resting HR, body composition with 30-day projection, BP, glucose, food
Trends ─ 14-day recovery and HRV
More ─ Timeline, Caffeine & water, Status, Running form, Cycle, Compare, Journal, Insights, Settings
Sleep ─ also smart alarm (wakes you in a 10–30 min window at the first sustained movement)
Complications ─ Readiness, Strain, Energy, Stress, Sleep (circular, corner, rectangular, inline)
Check-ins ─ morning summary, evening journal, caffeine cut-off, weekly review (local notifications)
```

## What it does that a typical recovery app does not

| | Margin |
|---|---|
| Transparency | Every input, baseline, z-score and weight is on the Drivers page. The full spec is in [`docs/METHODOLOGY.md`](docs/METHODOLOGY.md). |
| Error control | Type I and type II rates are measured in tests: 18.6% false "recover", 0.14% false "rest", 20/20 detection of a real drop. Without enough data the app shows an explicit status (*Calibrating*, *No overnight data*, *HRV unavailable*, *Night in progress*), never a number. |
| Load-change limit | A load **ceiling**, solved in closed form, keeps ATL/CTL under your chosen limit (default 1.3). |
| Evidence rules | "Recover" needs a strong signal or two that agree. "Push" needs full inputs and a calibrated scale. "Rest" needs elevated sleeping HR **and** elevated temperature or respiration. |
| Journal statistics | Welch's t-test with Holm–Bonferroni across tags. Days you didn't journal are excluded, not counted as "no". |
| Privacy | No account, no server, no subscription. Everything is computed on the watch. |
| Ultra 2 | Double tap triggers Refresh on watchOS 11+. Complications are tuned for the large display. |

I have not benchmarked against Bevel, whose algorithms are proprietary, so
"better" here means the properties above, not a head-to-head accuracy result.

## Repository layout

```
MarginCore/        Pure-Swift scoring engine (no Apple frameworks). 130 unit tests.
MarginWatch/App/   SwiftUI watch app: HealthKit adapter, cache, model, views
MarginWatch/Widgets/  WidgetKit complications
MarginWatch/Shared/   Code shared by app and complications
project.yml        XcodeGen spec (the .xcodeproj is generated, not committed)
docs/METHODOLOGY.md   Formulas, thresholds, measured error rates, limitations
docs/PIPELINE_AUDIT.md   Data flow and every silent-failure point, with its handling
docs/DEVICE_VALIDATION.md   Checklist to validate the app on an Apple Watch Ultra 2
docs/ROADMAP.md   Requested features mapped to batches
```

## Install on your watch

You need a Mac with Xcode 16 or later, and an Apple Watch Ultra 2 paired with
an iPhone.

1. `brew install xcodegen`
2. In `project.yml`, set the three `CHANGE ME` values:
   - `BUNDLE_ID_PREFIX`, e.g. `com.yourname.margin`
   - `APP_GROUP_ID`, e.g. `group.com.yourname.margin`
   - `DEVELOPMENT_TEAM`: your Team ID (Xcode → Settings → Accounts)
3. `xcodegen generate && open Margin.xcodeproj`
4. On the watch, enable **Settings → Privacy & Security → Developer Mode**.
5. In Xcode, select the **Margin** scheme and your watch as the destination, then press Run.
6. On first launch, grant Health access. The app reads up to 120 days of history; the first run takes a while.
7. Long-press the watch face → Edit → Complications → **Margin**.

**Free vs paid Apple ID:** apps signed with a free personal team expire after 7
days and have to be re-run from Xcode. If Xcode reports that HealthKit or App
Groups isn't available for your team, you need the paid Apple Developer Program.

## How to use it

- **Morning:** glance at the complication. If it says RECOVER or REST, open the app and read Drivers to see *why*.
- **Training:** start a Workout for every session so heart rate is sampled densely. Background HR undercounts load.
- **Evening:** log yesterday or today in Journal. After a few weeks, Insights shows which habits move your HRV, with p-values.
- **Settings:** set your measured HRmax if you know it. It changes every load number.

## Verify it yourself

```bash
swift test --package-path MarginCore    # 130 tests, macOS or Linux
python3 scripts/check_product_language.py
```

CI (`.github/workflows/ci.yml`) runs the core tests on Linux and macOS, then
compiles the watch app and complications for the watchOS simulator.

## Limitations

See [`docs/METHODOLOGY.md` §11](docs/METHODOLOGY.md#11-where-this-can-be-wrong).
Real-device behaviour (HealthKit permissions, background refresh, complication
updates) is **not yet validated**. Follow [`docs/DEVICE_VALIDATION.md`](docs/DEVICE_VALIDATION.md).
In short:
- The thresholds are heuristics, validated on simulated data only.
- Apple provides SDNN, not RMSSD.
- Load is undercounted outside workouts.
- This is a wellness tool, not a medical device.
