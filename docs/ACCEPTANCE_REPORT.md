# Acceptance report: health metrics, timeline, activity logging, routines

Branch `feature/health-metrics-timeline-routines` (PR #7, stacked on #6). Engine 2.4.0, day-cache schema 5.

## A. Before / after feature matrix

| Capability | Before | After |
|---|---|---|
| HRV | Drivers row, 14-day chart | Detail with current, baseline, % change, z, 7/30/60 trends, each night's readings marked used / not used, 90-day history, sources, state. Reconciles exactly with the recovery input (tested) |
| Resting HR | Sleeping HR in Drivers. Apple RHR only as a Body trend | Two reports: Sleeping HR (score input) and Apple resting HR, each with full detail |
| Respiratory rate | Drivers row only | Full report, timeline "overnight readings", compare series, insight pair |
| Wrist temperature | Drivers row only | Full report. The timeline shows the deviation from your usual |
| SpO₂ | Not read | Read, unit-checked, range-checked. Daily median, overnight / daytime tags, baseline, trends. Display only |
| VO₂ max | Body trend, no checks | Apple's values only: range-checked, change from previous, 30/60/90 trends, history with source, timeline event, no-data state |
| Weight / body composition | Trends, no checks | Same report structure with 7/30/90 changes, source, timeline events. Body fat and lean mass in the same area |
| Sleep, HR recovery, load | Separate pages | Also as metric reports with history and trends |
| Timeline | 2 days. Ad-hoc ids. Saved workouts could show twice | 7 days, stable ids, de-duplicated. Adds overnight readings, recovery, merged activities and strength, strain milestones, measurements, BP, status end, source per event |
| Log activity | Strength only | Live session of any HealthKit type (saved to Health), or a past entry that links to an existing Health workout instead of duplicating it. RPE, notes, history, delete |
| Routines | None | Create, edit, reorder, duplicate, archive, delete. Start with pre-filled weights, guided set by set, completion and history. Part of the strength builder |
| Today | Ring, tiles, quick log | State → body deviations (only ≥ 1 SD) → load → today so far → next. Tiles reorderable |
| Insights | Journal tags vs HRV. Compare without multiplicity control | Plus 8 pre-registered metric pairs, Spearman, n ≥ 14, Holm at 0.05 |
| Data states | Recovery only | Every metric: available / stale / insufficient history / no measurement / not authorized / read failed |

## B. Files changed

38 files, +3,251 / −72 against `feature/iphone-companion-coach`. Excludes `project.yml`, which has no structural change in this batch.

- **New core files:** `HealthMetrics.swift`, `EngineMetrics.swift`, `Activities.swift`, `Routines.swift`.
- **Changed core files:** `DayRecord.swift`, `Daytime.swift`, `Biomarkers.swift`, `Brief.swift`, `Companion.swift`, `Engine.swift`, `EngineBiomarkers.swift`, `EngineDaily.swift`, `Lifestyle.swift`, `Strength.swift`, `Training.swift`, `Runtime.swift`.
- **New tests:** `IntegrityTests`, `HealthMetricsTests`, `TimelineTests`, `RoutineTests`, `InsightTests`, `FixtureExportTests` (screenshot fixture only).
- **Updated test:** `DailyFeatureTests` (two expectations: 7-day timelines and the extra event kinds; the original order assertion is kept).
- **Watch:**
  - New views: `HealthMetricViews.swift`, `ActivityViews.swift`, `RoutineViews.swift`.
  - Changed: `AppModel.swift`, `HealthService.swift`, `StrengthWorkout.swift`, `TodayView.swift`, `DailyViews.swift`, `MoreView.swift`, `RootView.swift`, `StrengthViews.swift`.
  - Shared: `MetricDisplay.swift`, `Display.swift`.
- **iPhone:** `PhoneHealthViews.swift` (new), `PhoneViews.swift`.
- **Docs:** `FEATURE_GAP_AUDIT.md`, this report, `evidence/*.png`.

## C. HealthKit types

- **New read:** `oxygenSaturation` (percent unit → 0–1 fraction → × 100. An input outside 0–1 is rejected, not rescaled).
- **Newly used metadata:** `sourceRevision.source.name` on every quantity sample and workout. Workout `uuid` for identity.
- **New writes:** `HKWorkout` for past activities logged with "Save to Health" (`HKWorkoutBuilder`, `HKMetadataKeyWasUserEntered`, `MarginRPE`). Live activities save through `HKLiveWorkoutBuilder` for any `HKWorkoutActivityType`. Write types are unchanged from batch 3: workouts, heart rate and active energy.
- **Deletes:** only workouts Margin itself saved, only on explicit user request.

## D. New domain models

- **Metrics:** `HealthMetricKind`, `MetricDataState`, `MetricObservation`, `MetricBaseline`, `TrendWindow`, `MetricReport`, `MetricMath`, `HealthAccess`.
- **Day record:** `HRVReading` (stored in day records).
- **Activities:** `LoggedActivity`, `ActivityLog`, `ActivityCatalog`, `ActivityEntry`, `ActivityReconciler`.
- **Routines:** `Routine`, `RoutineItem`, `RoutineLibrary`, `RoutineTarget`, `RoutineProgress`, `RoutineRunner`.
- **Insights:** `MetricPairInsight`, `MetricPairs`.
- **Units:** `HealthUnits`.
- **Changed models:**
  - `StrengthSession`: `healthWorkoutID`, `routineID`, `routineName`, `rpe`, `notes`, `completedItems`.
  - `TimedValue` / `WorkoutSample` / `WorkoutDetail`: `source`, `healthID`.
  - `TimelineItem`: stored `id`, `source`, 6 new kinds.
  - `PhonePayload`: routines, activity log.

## E. New UI and screens

- **Watch:**
  - New screens: Health page (all reports), metric detail, Log activity (live / past / history), active activity, routines list / detail / editor / item editor, routine guide inside strength workouts.
  - Today: sections, body deviations, today so far.
  - 7-day timeline with sources, tile reorder, metric-pair insights.
- **iPhone:** health metrics section and detail, insights card, activities, routines (read-only).

## F. Timeline reconciliation design

- Timelines are derived, not stored. They are rebuilt from day records, biomarkers and Margin's logs on every rescore. So late, corrected and deleted Health data reconciles through the existing per-day fingerprint rebuild (day inputs) and full biomarker re-reads (tested: a deleted workout disappears, a late weight appears, a corrected weight keeps its id).
- Ids come from the source record:
  - `hk-<uuid>` for Health workouts;
  - `margin-<uuid>` for Margin logs;
  - `sleep-/wake-/vitals-/recovery-/journal-<day>`;
  - `strain-<day>-<threshold>`;
  - `intake-<uuid>`;
  - `m-<kind>-<timestamp>`;
  - `status-<uuid>-start|end`.
- `TimelineItem.ordered` sorts by (time, kind order, id) and drops repeated ids.
- Day assignment uses each record's stored windows. Biomarker timestamps go through `Engine.dayFor`, which checks stored activity windows first, so travel can't move events (tested with a Tokyo-built day).

## G. Activity logging design

- **Taxonomy:** HealthKit's own (`HKWorkoutActivityType` raw values). There is no parallel list.
- **Live:** `HKWorkoutSession` + `HKLiveWorkoutBuilder` record dense heart rate, so TRIMP counts it like any workout. The saved workout's UUID is stored on the log.
- **Past:** `ActivityReconciler.existingWorkout` first looks for a Health workout of the same type family covering at least 50 % of the interval.
  - If found, the log links to it and nothing is written.
  - Otherwise it saves (if chosen) and stores the UUID.
  - Past entries add no TRIMP (no heart rate). Session RPE × minutes is shown only.
- **Reconciliation rule (tested):** match by stored UUID first. Logs without a UUID fall back to: same type family, start within 2 min, overlap ≥ 50 %. Each Health workout matches at most one log. A log with a UUID never falls back to time matching.

## H. Routine architecture

- A routine is a template.
- **Starting:** starting one creates an ordinary `StrengthSession` with `routineID` / `routineName` and a live strength workout. Sets, Health workout, muscle freshness, weekly volume, records, load and timeline all come from the same session, so nothing is counted twice (tested with reconciliation).
- **Pre-fill:** each set's weight comes from the routine's own target, else the last time in this routine, else your last working set.
- **Progress:** working sets map to items in order. Activity items are checked off.
- **Copies and deletes:** duplicates get new ids, so each copy keeps its own history. Deleting a routine keeps its past sessions.

## I. Metric calculations and units

- **HRV:** geometric mean of SDNN readings in the main sleep bout (fallback 20:00–10:00) in ms. Baseline is the median / robust SD of ln values over the previous 60 days (≥ 14, marked days excluded). Change is reported as % and as z.
- **Nightly score inputs:** sleeping HR (bpm), respiration (/min) and wrist temperature (°C) use the same baselines as the recovery score.
- **Apple RHR and sleep hours:** the same method, display only.
- **SpO₂:** % (50–100). Daily median of readings, each tagged overnight if inside the main sleep bout. Baseline from previous days' medians.
- **VO₂ max (mL/kg/min, 10–90), weight and lean mass (kg), body fat (%):** latest valid reading, change from previous, window change vs the reading nearest the window start, Theil–Sen slope (≥ 3 readings).
- **Trend minimums:**
  - 7 days: 4 readings.
  - 30 days: 10 readings.
  - 60 / 90 days: 15 readings.
  - Sporadic metrics: 3 readings.
- **Stale after:**
  - Nightly metrics, sleep and load: 1 day.
  - SpO₂: 3 days.
  - Body measurements and HR recovery: 14 days.
  - VO₂ max: 60 days.

## J. Data-integrity protections

- Range rejection (never clamping) for every new type.
- Exact-duplicate removal across sources.
- Future-date rejection.
- Provenance kept but excluded from fingerprints and scores (tested).
- Per-input failed-read tracking (`readFailed` state, cached values flagged).
- `notAuthorized` before the permission sheet is answered.
- HealthKit read denial can't be detected, and the "no measurement" text says so instead of guessing.
- Missing data is never zero (tested).
- Scores unchanged by the new metrics (tested: identical recovery, plan and strain with and without them).

## K. Tests added

| Suite | Tests |
|---|---|
| IntegrityTests | 9 |
| HealthMetricsTests | 11 |
| TimelineTests | 10 |
| RoutineTests | 6 |
| InsightTests | 3 |
| FixtureExportTests (skipped unless exporting a screenshot fixture) | 1 |

- **Required cases covered:**
  - valid, missing, stale, duplicate, corrected, deleted and future-dated samples;
  - permission unavailable, query failure;
  - unit conversion, time zone / day boundary;
  - timeline ordering and de-duplication, workout and activity de-duplication;
  - routine persistence and completion;
  - trends, insufficient history.
- **Not changed:** existing expectations, except two in `DailyFeatureTests` updated for intended new behaviour (7 days, extra kinds).

## L. Full regression results

- `swift test --package-path MarginCore`: **184 tests: 183 passed, 1 skipped (FixtureExport, which runs only when its environment variable is set), 0 failures**.
- `xcodebuild` MarginPhone scheme (iOS + embedded watch app + both widget extensions), Debug: **succeeded, 0 warnings in project sources**.
- Product-language check: passed.

## M. Remaining Bevel/Athlytic gaps

**P0** (prevents Margin being a credible replacement)
- None found in the features built here. A real-device validation run (overnight, workouts, routines) is still pending. Until it's done, the claims rest on fixtures and unit tests.

**P1** (competitor materially better)
- Routine editing on iPhone (watch-only now; the phone is read-only).
- Workout analysis per session: HR curve, splits, zone timeline per workout.
- Sleep history browser and sleep-stage hypnogram (only totals per night are stored).
- Recovery explanation in natural language for why today changed; numbers exist but no narrative.
- Food database and barcode logging.

**P2** (useful enhancement)
- Exercise library depth: 118 vs ~700.
- Manual blood-pressure and weight entry.
- Health-records import, which needs a paid account.
- Configurable trend windows.
- Weekly / monthly reports.
- Complication for any metric (the watch has 5 fixed metrics).
- Data export.

**P3** (optional polish)
- Animated transitions.
- Per-metric colour themes.
- Onboarding tour.

No superiority claim is made. Where Margin is likely stronger (transparency of method, explicit data states, reconciliation with the score, multiplicity-controlled insights), that is by design and tested. It has not been benchmarked against competitors.

## N. Not validated

- **On-device behaviour of everything in this batch:**
  - live activity sessions of non-strength types;
  - saving and deleting past workouts in Health;
  - SpO₂ availability on this watch and region;
  - real source names.
- **Watch UI screenshots:** no watchOS simulator runtime is installed on this Mac.
- **Real-data correctness of SpO₂ overnight tagging:** depends on Apple's sleep-bout timing.
- **The low HRV data on the device (still open):** recovery can't calibrate until HRV readings arrive.

## O. Simulator evidence

iPhone 18 Pro simulator, Debug build. Payload generated by `FixtureExportTests` from the synthetic test pipeline, test data only.
- `evidence/01-today.png`: Today (glass header, tiles).
- `evidence/02-health-metrics.png`: health metrics list with values and change.
- `evidence/03-hrv-detail.png`: HRV trends, last night's readings marked used by recovery, history.
- `evidence/03-hrv-detail-before-fix.png`: the invisible-chart bug the screenshots exposed (fixed).
- `evidence/04-vo2-trend.png`, `evidence/05-vo2-history.png`: VO₂ max trends, dated history with source, method.
- `evidence/06-insights.png`: metric-pair insights with n and p.

Issues found through the screenshots and fixed:
- the chart line was invisible on light backgrounds;
- sleep showed "h" twice;
- insight text said "59 of 14 days" when a metric had no variation.

## P. Recommended next batch

1. Run the device validation for this batch: overnight, one live activity, one past activity, one routine.
2. Per-workout analysis (HR curve, zones over time, splits).
3. Sleep history and hypnogram (store stage segments per night).
4. Routine editing on iPhone through WatchConnectivity.
5. Plain-language "why today changed" generated deterministically from the component z-scores (no LLM).
