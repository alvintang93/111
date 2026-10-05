# Margin feature-gap audit (before this change)

Audited from the code on `feature/iphone-companion-coach` (7b959e3), not from ROADMAP.md.
The references are to the files that implement each item.

Legend:
- **Hidden**: computed internally but not shown to the user.
- **Data**: needs new HealthKit reads or writes.
- **UI** / **Logic**: needs new screens or new computation.

## Matrix

| Capability | Margin current state | Hidden? | Missing data? | Missing UI? | Missing logic? | Proposed implementation |
|---|---|---|---|---|---|---|
| HRV (overnight, used by score) | `DayRecord.lnHRV`: mean ln SDNN of samples in the main sleep bout, or 20:00–10:00 if no sleep. Baseline is the median/MAD of the previous 60 days (≥ 14). Shown only as a Drivers row (value, baseline, z) and in the 14-day Trends chart | **Yes**: sample count, timestamps, window used (bout vs fallback) and sources appear only in Diagnostics | Per-sample timestamps and sources are discarded after aggregation | Detail screen | 7/30/60-day trends, data state, reconciliation statement | Keep each overnight HRV reading (time, SDNN, source) in the day record (schema 5). Build a `MetricReport` whose current value and baseline are the recovery engine's own numbers |
| HRV (latest any-context reading) | Daytime readings (e.g. Breathe) are fetched for the fingerprint, then dropped | Yes | Daytime readings not kept | Yes | Label them as not used by the score | Keep daytime readings separately, flagged as not used by recovery |
| Resting HR | Two signals: sleeping HR (10th percentile during the main bout; the recovery input) and Apple resting HR (daily mean; HRrest for TRIMP, biological age, Body trend) | Partly: sleeping HR only in Drivers | – | Detail that explains both | Trends, data state | Two metric reports: "Sleeping HR (score input)" and "Resting HR (Apple)" |
| Respiratory rate | `DayRecord.respiratoryRate`, overnight mean; recovery input (weight 0.075, penalises only above +1 SD) | **Yes**: one Drivers row; no history, trend or timeline | – | Yes | Trends, data state, timeline event | Metric report and detail screen. Timeline "overnight respiration" event at wake |
| Wrist temperature | `DayRecord.wristTemperature`, recovery input | **Yes** (Drivers only) | – | Yes | Trends, state | Metric report. Shown as a deviation from baseline |
| SpO₂ | **Not read** | – | **Yes**: `oxygenSaturation` | Yes | Yes | New Health read (percent; fraction × 100, valid 50–100 %). Overnight readings use the stored night window. Display only, not a score input |
| VO₂ max | Batch 2 biomarker series. 365-day Theil–Sen trend on the Body page; biological age uses the latest value | Partly | Source not kept. **No range check or dedup on biomarker series** | Detail, history list | Change from previous reading, 30/60/90 trends, staleness | Biomarker sanitiser (range, dedup, future), provenance, metric report |
| Weight / body composition | Batch 2 body mass, body fat and lean mass trends with a 30-day projection | Partly | Same sanitiser gap, no source | 7/30/90-day changes, one body-composition detail | Change windows | Metric reports. Body fat and lean mass go in the same detail |
| Sleep | Today's sleep summary (stages, need, debt, score) | **Yes**: past nights aren't browsable | – | Sleep history | Trends | Metric report for time asleep and sleep score |
| HR recovery | Batch 1: per-workout 60/120 s drop, typical value | – | – | Detail and history | Trends | Metric report |
| Load / strain / CTL | Load page and strain card | – | – | – | – | Linked from Health metrics (no change) |
| Timeline | Batch 1 `DayTimeline`: sleep, wake, workouts, intake, journal, status. IDs are `kind-date-title` | – | Strength sessions, logged activities and body measurements missing | Partly | **No stable identity or dedup**: a saved strength session shows once as Margin's and again as Health's workout. No recovery, strain, vitals or measurements | Timeline v2: provenance IDs from Health UUIDs, reconciliation rules, new event kinds |
| Log activity | Only strength workouts (live) | – | Workout writes for other activity types | **Yes** | **Yes** | Live activity (any supported type) and past-activity entry. Saved to Health only when no overlapping Health workout exists. RPE and notes kept by Margin |
| Routines | **None**: strength sessions are free-form | – | – | **Yes** | **Yes** | `Routine` model: create, edit, reorder, duplicate, archive, delete. Start fills targets from the last session; completion is a `StrengthSession` tagged with the routine |
| Today hierarchy | Ring, directive, pinned tiles, quick log | – | – | Body deviations and a "what I've done today" summary | Notable-deviation selection | Sections: state → body → load → today → next |
| Metric detail UX | Tiles open existing pages | – | – | **Yes** | – | One detail layout for every metric report |
| Correlations | Journal tag → next-night HRV (Welch + Holm). 30-day Compare (Spearman, no multiplicity control) | – | – | Insights for metric pairs | Fixed pair set with minimum n, Holm control | Pre-registered metric pairs, Spearman with Holm, n and p shown |
| Data states | Recovery has explicit `ScoreStatus`. Other metrics show "–" | – | Query failures recorded only in the event log | Yes | Per-metric state | `MetricDataState`: available / stale / insufficient history / no measurement / query failed. Read permission can't be detected (HealthKit hides it) and is reported as such |
| Provenance | Sleep keeps a source priority only | – | Source names discarded | Yes | – | Optional `source` on samples; per-day HRV and biomarker sources |

## Integrity gaps found in existing code

1. Biomarker series (batch 2) skip the `Sanitizer`: no range check, no exact-duplicate removal, no future-date rejection. **Fixed in this change**: they become display inputs with the same rules as day records.
2. The timeline can show a saved strength workout twice. **Fixed**: a Margin session links to its Health workout by UUID, with a time-overlap rule for older sessions.
3. Health sources are dropped for every type except sleep. **Fixed for display**; fingerprints and scores are unchanged.

## Not changing

Recovery, strain, stress, energy and load formulas stay the same. No new metric becomes a score input. SpO₂, VO₂ max and weight are display-only.
