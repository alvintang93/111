# Margin — Pipeline audit (Phase 2)

This document traces where data enters, how it is transformed, and every point
where it could be silently dropped, duplicated, stale or misclassified. It
covers the code as of commit f0800f9, and how each issue is handled after
Phase 2. "Test" names refer to `MarginCore/Tests/MarginCoreTests`.

## 1. Data flow

```
HealthKit (on watch)
  │  HealthService.swift: HKSampleQueryDescriptor per type, sorted by start date
  │  types: heart rate, HRV SDNN, resting HR, respiratory rate,
  │         sleeping wrist temperature, sleep analysis, workouts
  ▼
Raw samples  (RawDayInput: TimedValue / HRSample / SleepSegment / WorkoutSample)
  │  AppModel.sync → SyncPlanner.plan decides which days to (re)build:
  │     missing · recent (last 3 days) · sourceChanged (fingerprint) · retryEmpty
  │  windows per day: DayWindows (stored, chained across time zones)
  ▼
Daily aggregation  (DayRecordBuilder → DayRecord, cached in day-records.json)
  │  Sanitizer: range check, duplicate removal, future filter → IngestionStats
  │  sleep sweep + source priority → main bout
  │  ln-HRV mean in bout, sleeping-HR p10, resp/temperature means,
  │  time-at-HR histogram, workout summary, source fingerprint
  ▼
Baseline / calibration  (Engine.rawRecovery)
  │  60-day median/MAD per input (≥14 nights), HRV baseline required
  │  composite calibrated against own 60-day composites (≥20 days)
  ▼
Score inputs  (Components: value, baseline, z, weight)
  ▼
Score + status  (Recovery: score, ScoreStatus, CalibrationStatus, flags)
  ▼
Recommendation  (Engine.directive → Plan with RuleCheck trace, load targets)
  ▼
Persisted state
  │  App Group defaults: DailyBrief (+ audit)        → complications
  │  App files: day-records.json, event-log.json, decision-log.json
  │  Standard defaults: settings, journal, AppRuntimeStatus
  ▼
Complication / UI
     MarginWidgets: ComplicationState.make(brief, now) → timeline (+ heartbeat)
     Watch UI: Today / Drivers / Sleep / Load / Trends / Developer diagnostics
```

## 2. Failure points

| # | Stage | Failure (as of f0800f9) | Kind | Phase 2 handling | Evidence |
|---|---|---|---|---|---|
| 1 | Authorization | A one-shot "requested" flag meant types added later were never requested on existing installs | dropped | Uses HealthKit request status; `.shouldRequest` prompts again (workouts were added this phase) | Code review (device-only) |
| 2 | Authorization / sync | First launch: the scene-phase refresh could run before the permission sheet was answered. It would build up to 120 empty days and cache them forever | dropped, stale | No sync until request status is `unnecessary`. Empty days are retried every 24 h. Fingerprint changes trigger rebuilds | `testNoHealthKitData`, `testLongPeriodWithoutOpeningTheApp` |
| 3 | Authorization | Read denial is invisible in HealthKit (denied = no samples) | misclassified | Per-input "days with data" in diagnostics. With no HRV in 60 days but heart rate present, the status is `hrvUnavailable` and the score is withheld | `testPartialPermissionsHRVDeniedWithholdsScore` |
| 4 | Query | Any failed query aborted the refresh, but the in-memory records were already half-updated | stale | A failed query aborts the sync. Prior records stay authoritative and the error is logged by input name. A failure is never treated as "no data" | Code review (device-only) |
| 5 | Query | Unknown sleep enum values were dropped silently | dropped | Counted and logged | Code review |
| 6 | Cache | Only today and yesterday were re-read. Late, corrected or deleted data for older days was ignored, and a revoked permission was masked by the cache | stale | Foreground sync re-queries all non-heart-rate inputs over 120 days and compares per-day FNV-1a fingerprints. Changed days are rebuilt (`sourceChanged`). The last 3 days are always rebuilt | `testLateArrivingSamplesAreReconciled`, `testCorrectedAndDeletedSamplesTriggerRebuild` |
| 7 | Cache | Heart-rate corrections older than 3 days are not detected (heart rate is not fingerprinted; re-reading 120 days of it is too costly) | stale | Residual. "Rebuild from Health" in Settings forces a full re-read | Documented limitation |
| 8 | Cache | Load and save errors were swallowed (`try?`); a corrupt or old-schema file silently became an empty cache | dropped | `RecordCacheFile.decode` returns ok / schemaMismatch / corrupt. Every outcome is logged and save errors surface in diagnostics | `testRebootReconstructsPersistedStateAndRejectsBadCaches` |
| 9 | Backfill | Records were saved only after all days were built, so an interrupted first sync lost everything | dropped | Saved every 10 built days and again on abort | Code review (device-only) |
| 10 | Background | Background refresh could run a full 120-day backfill, exceeding the task budget | dropped | Background mode builds at most 2 days (newest first) and defers the rest to the foreground | `testLongPeriodWithoutOpeningTheApp` |
| 11 | Ingestion | Out-of-range values were accepted (heart rate was clamped into the 250 bin) | misclassified | Plausibility limits; rejections are counted, never clamped | `testImplausibleValuesAreRejectedNotClamped` |
| 12 | Ingestion | Exact duplicates (two sources) double-weighted the HRV mean | duplicated | Exact duplicates removed and counted | `testDuplicateSamplesAreRemovedAndCounted` |
| 13 | Ingestion | Future-dated samples (clock skew, manual entry) were accepted | misclassified | Samples starting after build time + 60 s are rejected and counted | `testFutureDatedSamplesAreExcluded` |
| 14 | Sleep | Only the highest-priority source in the window is used. If the Watch recorded part of a night and the iPhone the rest, the iPhone part is ignored | dropped | Residual by design (avoids double counting); visible via sleep-sample counts | `testPrefersWatchSourceOverPhone` |
| 15 | Day boundary | Day windows were recomputed in the current time zone. After travel, windows overlapped (double-counted load) or left gaps (lost data) | duplicated / dropped | Windows are stored per record. New days chain from the previous day's end and are clipped to the next existing day | `testTimeZoneChangeLeavesNoOverlapOrGap`, `testWestwardTimeZoneChangeClosesGap`, `testDSTBoundariesKeepContinuousCoverage` |
| 16 | Day boundary | Sleep regularity used current-zone windows for old nights | misclassified | Uses stored windows | `testTimeZoneChangeLeavesNoOverlapOrGap` |
| 17 | Scoring | A refresh at 03:00 scored a partial night and showed it as today's score | stale | `nightInProgress`: withheld until 30 min after the main sleep bout ends, or the end of the fallback window | `testNightInProgressWithholdsScoreUntilWake` |
| 18 | Scoring | With HRV absent (permission off) a score was still produced from sleeping HR and sleep: a normal-looking number missing its main input | misclassified | An HRV baseline is required. Status is `hrvUnavailable` or `calibrating`, with no score | `testPartialPermissionsHRVDeniedWithholdsScore`, `testOneDayBelowCalibration` |
| 19 | Scoring | Early-history scale fallback was not labelled | misclassified | Status `provisional`; Push blocked | `testExactlyEnoughCalibrationDays` |
| 20 | Scoring | One core input missing gave only a "low/medium confidence" label | misclassified | Status `degraded` with `missingInputs`; Push blocked | `testMissingHRVButSleepingHRPresentIsDegradedAndBlocksPush`, `testMissingSleepingHRButHRVPresentIsDegradedAndBlocksPush` |
| 21 | Scoring | HRmax or HRrest defaults were applied silently | misclassified | Source strings shown in diagnostics | `testAuditReportsCalibrationCountsAndSources` |
| 22 | Brief | `generatedAt` looked like data freshness, but the brief was recomputed even when the sync failed | stale | `dataSyncedAt` carries the last successful sync. Complications flag syncs older than 12 h | `testStalePersistedScoreVersusNewerHealthKitData` |
| 23 | Complication | A misconfigured App Group made the widget show "Open the app" forever, with no hint | stale | App Group availability check, logged at launch. The widget writes a heartbeat that diagnostics show | Code review (device-only) |
| 24 | Complication | No record of whether or when WidgetKit asked for a timeline | — | `WidgetHeartbeat`: last timeline, requested next refresh, state, brief decoded | Code review (device-only) |
| 25 | Background | Requested refreshes and executed refreshes were indistinguishable | — | Both are recorded separately in `AppRuntimeStatus` (last 20 executions) | `testRuntimeStatusKeepsRecentBackgroundRuns` |
| 26 | Determinism | Persisted hashes must not use Swift `Hasher` (seeded per process) | — | FNV-1a with reference vectors | `testFNV1aMatchesReferenceVectors` |
| 27 | Language | The "Illness watch" flag and notification implied detection of illness | misclassified | Renamed to "overnight vitals above usual". The About text states what the app is not | `testUserFacingCoreTextAvoidsMedicalClaims`, `scripts/check_product_language.py` |

## 3. What is still trusted without verification

- HealthKit returns all samples matching a date predicate, in order, on every query.
- `sourceRevision.productType` begins with "Watch" for Apple Watch data.
- The stored value of `appleSleepingWristTemperature`. The plausibility range accepts both absolute and deviation-style values until a device confirms which one is stored.
- watchOS delivers background refresh tasks at all. Only the request is under the app's control.
