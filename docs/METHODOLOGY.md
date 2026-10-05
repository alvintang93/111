# Margin — Methodology

Every number on the watch traces back to this document and to one constant in
`MarginCore/Sources/MarginCore/Parameters.swift`. Nothing is proprietary or hidden.

## 1. Data and windows

| Signal | HealthKit type | Window for day *D* (local time) | Aggregate |
|---|---|---|---|
| Sleep stages | `sleepAnalysis` | 18:00 *D-1* → 18:00 *D* | Interval sweep (below) |
| HRV | `heartRateVariabilitySDNN` | Main sleep bout; fallback 20:00 *D-1* → 10:00 *D* | Mean of ln(SDNN ms) |
| Sleeping HR | `heartRate` | Main sleep bout | 10th percentile (needs ≥10 samples) |
| Respiratory rate | `respiratoryRate` | Same as HRV | Mean |
| Wrist temperature | `appleSleepingWristTemperature` | Sample *ends* in sleep window | Mean |
| Apple resting HR | `restingHeartRate` | Calendar day *D* | Mean (used only for TRIMP HRrest) |
| Training load | `heartRate` | 00:00 → 24:00 *D* | Time-at-HR histogram |
| Workouts | `HKWorkout` | 00:00 → 24:00 *D* | Count by start day, minutes split across midnight, HR coverage. **Diagnostics only**; load still comes from heart rate |

**Windows are stored with each day.** A day's windows are computed in the
current time zone when it is first built and are then kept, including when the
day is rebuilt. A new day starts exactly where the previous stored day ended,
and a backfilled day is clipped to the next stored day. Days therefore tile time
with no overlap and no gap across time-zone changes and DST.

**Sample hygiene** happens before any aggregation; every rejection is counted per input:
- Range limits: HR 25–250 bpm, SDNN 1–400 ms, resting HR 25–200, respiration 4–60 /min, wrist temperature −10–45 °C. The temperature range is wide because it must accept both absolute and deviation-style values until a device confirms which form HealthKit stores.
- Durations must be positive (sleep, workouts) or non-negative (point samples), and at most 24 h.
- Exact duplicates are removed.
- Samples starting more than 60 s after the build time are rejected as future-dated.

**Sleep aggregation.** Only the highest-priority source in the window is used
(Apple Watch = 2, anything else = 1), so iPhone and Watch sleep data are never
added together. Overlaps within that source are resolved per elementary interval
by stage specificity: deep > REM > core > awake > asleep(unspecified) > in-bed.
Sleep pieces closer than 90 min form a *bout*; the bout with the most sleep is the
*main bout* (onset, wake, efficiency, midpoint). Naps count toward total sleep.

**Heart-rate histogram.** Each HR sample holds until the next sample, capped at
300 s. Duplicate timestamps from two sources therefore add zero time.
Bins are 1 bpm wide, so the error is at most 0.5 bpm. Because the cache stores
time-at-HR rather than load, changing HRmax, sex or HRrest re-scores all history
exactly, with no new HealthKit query.

## 2. Personal baselines

For each metric: median and MAD of the **previous** 60 days (today is
excluded, so there is no look-ahead). At least 14 valid days are required.
Scale = max(1.4826 × MAD, floor), with floors of 0.05 ln-ms (HRV), 1 bpm (HR),
0.3 /min (respiration) and 0.1 °C (temperature). The floor stops a flat history
from turning a tiny change into a huge z-score.

## 3. Recovery

Oriented z-scores (positive = better), clamped to ±3:

| Component | z | Weight |
|---|---|---|
| HRV | (lnHRV − median) / scale | 0.45 |
| Sleeping HR | −(HR − median) / scale | 0.25 |
| Sleep | (asleep/need − 1) / 0.15, capped at +1 | 0.15 |
| Respiration | −max(0, z − 1) (penalises only beyond +1 SD) | 0.075 |
| Wrist temperature | −max(0, z − 1) | 0.075 |

Weights are renormalised over the components present.
Composite *c* = Σ wᵢzᵢ.

**Calibration.** *c* is standardised against the median/MAD of the
person's own composites over the previous 60 days, using at least 20 of them.
Until 20 exist, it is divided by √Σwᵢ² instead, which assumes independent
components. Score = 100 × Φ(standardised *c*), clamped to 1–99. **50 = a typical
day for you.** Without this step, structural offsets (for example habitually
sleeping under the stated need) put 29% of stationary days in the red band.

**Bands** (display only): ≥67 primed, ≤33 depleted, otherwise steady.

**Score status** is always explicit. Only the last three statuses show a number, and only `Scored` allows Push:

| Status | Score? | Condition |
|---|---|---|
| Night in progress | no | Today, before 30 min after the main sleep bout ends; if no sleep is recorded, before the fallback window ends (10:00) |
| HRV unavailable | no | No HRV at all in the 60-day window although a sleeping-HR baseline exists (permission off, or HRV not recorded) |
| Calibrating | no | Fewer than 14 HRV nights in the 60-day window. **An HRV baseline is required for any score** |
| No overnight data | no | Neither HRV nor sleeping HR for the night |
| Partial data (degraded) | yes | HRV or sleeping HR missing for the night (or its baseline missing). Push is disabled |
| Provisional | yes | Full inputs, but fewer than 20 prior composite days, so the scale uses the √Σw² fallback. Push is disabled |
| Scored | yes | Full inputs and a calibrated scale |

**Confidence** (retained as a secondary label):
- *Calibrating*: no HRV baseline.
- *No data*: neither core input.
- *High*: HRV during sleep, sleeping HR and sleep present, with an HRV baseline of at least 30 days.
- *Medium*: HRV plus sleeping HR or sleep.
- *Low*: otherwise.

## 4. Flags

| Flag | Rule |
|---|---|
| Elevated overnight vitals | Sleeping HR z ≥ +2 **and** (temperature z ≥ +2 **or** respiration z ≥ +2). A measurement pattern, not an assessment of any health condition |
| HRV trend low | Mean lnHRV of the last 7 days (≥4 present) < baseline − 0.5 × scale (smallest-worthwhile-change convention) |
| Load spike | ATL/CTL through yesterday > 1.5 |
| Sleep debt | 7-night accumulated shortfall vs base need ≥ 5 h (missing nights are not counted as debt) |

The elevated-vitals rule is a conjunction on purpose. A single elevated signal,
such as a hot room or a late meal, does not fire it.

## 5. Directive (decision rule)

0. No score → no recommendation: *Pending* (night in progress), *Calibrating*, or *No data*.
1. Elevated overnight vitals → **Rest**.
2. Score ≤ 15 → **Recover**.
3. Score ≤ 33 **and** (HRV trend low **or** sleep debt) → **Recover**. Score ≤ 33 alone → **Maintain**, with "cap intensity".
4. Score ≥ 67 → **Push**, demoted to **Maintain** unless all of these hold:
   - status is *Scored*;
   - confidence is above low;
   - the HRV trend is not low;
   - there is no load spike;
   - there is no sleep debt.
5. Otherwise → **Maintain**.

Every evaluation is recorded as an ordered rule trace (rule, passed, detail),
shown in Developer diagnostics. A recomputed distribution of recommendations,
scores and component z over the 60-day window is shown too, together with an
on-device log of what was actually issued each day. None of this feeds back into
thresholds.

A recommendation describes how today's sensor readings compare with your own
history. Push does not mean exercise is medically appropriate. Recover or Rest
does not mean you are unwell.

The rules are deliberately asymmetric. Pushing while fatigued costs more than an
easy day while fresh, so "Push" needs clean evidence and "Recover" needs either a
strong signal or two agreeing weaker ones.

## 6. Training load

**TRIMP (Banister).** Σ minutes × HRr × a × e^(b × HRr), where
HRr = (HR − HRrest)/(HRmax − HRrest), clipped to ≤1.
- Male / unspecified: a = 0.64, b = 1.92. Female: a = 0.86, b = 1.67.
- HRr < 0.30 contributes nothing. Without this floor, 14 h of daily living at HRr ≈ 0.14 adds roughly as much TRIMP as a one-hour hard run.
- HRmax is the measured override if set; otherwise Tanaka (208 − 0.7 × age); otherwise 190.
- HRrest is the median of Apple resting HR over the last 30 days (needs ≥7 values). The fallback is sleeping-HR median, then 60.

**ATL / CTL.** Exponentially weighted averages with k = 1 − e^(−1/N), N = 7 and 42.
They are seeded with the mean of the first 14 observed days. A day with <2 h of
HR coverage is *unobserved*: it counts as zero load and is reported.
ACWR = ATL/CTL is shown only after 28 days of history and when CTL ≥ 10. The
same 28-day/CTL ≥ 10 rule applies to load targets.

**Targets.** A multiple of CTL by directive:
- Push: 1.0–1.5×
- Maintain: 0.6–1.0×
- Recover: 0–0.5×
- Rest: 0–0.3×

**Ceiling (load-change limit).** The largest load *L* today such that ATL/CTL after
today ≤ *r* (default 1.3):

  L ≤ [r·CTL·(1−k₄₂) − ATL·(1−k₇)] / (k₇ − r·k₄₂)

The upper target is capped at the ceiling. The unit test drives the model
forward with *L* = ceiling and checks that the ratio equals *r* to within 1e-9.

## 7. Sleep need

Need = base (default 8 h) + debt repayment + strain adjustment.
- Debt repayment = min(0.2 × 7-night debt, 1 h).
- Strain adjustment = clamp((yesterday's load / CTL − 1) × 30 min, 0, 45 min).

Sleep score = 70% performance (asleep/need, capped at 100%) + 15% efficiency
(70%→95% maps to 0→1) + 15% regularity (midpoint SD 15→90 min maps to 1→0),
renormalised over what is available.

## 8. Journal insights

For each tag, the app compares the **next night's** HRV deviation from baseline
on journaled days *with* the tag against journaled days *without* it.
- Days never journaled are excluded, so "not logged" is never read as "didn't happen".
- Each test needs ≥5 days per group.
- The test is Welch's t-test, two-sided, with Holm–Bonferroni across all tags at α = 0.05 (family-wise error control).
- The effect is shown as a percentage HRV change, e^Δ − 1.

These are associations, not causal effects.

## 9. Measured error rates (simulated data)

From `CalibrationTests`: 20 synthetic people, each with 150 days of
stationary physiology plus noise (HRV SD 0.10 ln, sleeping HR SD 1.5 bpm), 1,400
scored days:

| Metric | Result |
|---|---|
| Mean score | 50.4 |
| Days in red band | 32% (by construction ≈ terciles) |
| False "Recover" (type I) | 18.6% of days (test fails above 20%) |
| False "Rest" (elevated vitals) | 0.14% of days |
| Detection of a real 5-day drop (HRV −22%, sleeping HR +3 bpm) | 20/20 (test fails below 90%) |

Statistical routines are checked against SciPy 1.17 to 1e-12: the normal CDF,
the regularized incomplete beta, Student-t p-values and Welch's t.

## 10. Sync and reconciliation

- **Foreground (app open):** all non-heart-rate inputs are re-queried for the 120-day window. Each cached day's data is fingerprinted (FNV-1a over cleaned samples in its windows). Days whose fingerprint changed (added, corrected or deleted data, or a revoked permission) are rebuilt. The last 3 days are always rebuilt. Never-built days are built, and empty days are retried every 24 h.
- **Background (watchOS refresh):** at most 2 of the most recent days are built; everything else waits for the foreground.
- **Failures:** a failed query aborts the sync and keeps the previous data. It is never interpreted as "no data". Progress is saved every 10 built days.
- **Not detected:** heart-rate corrections older than 3 days (heart rate is not fingerprinted because re-reading 120 days of it is too costly). *Settings → Rebuild from Health* forces a full re-read.

Details and the failure-point inventory are in [`PIPELINE_AUDIT.md`](PIPELINE_AUDIT.md).

## 11. Where this can be wrong

- **No clinical validation.** Weights, the 0.30 HRR floor, the sleep-need rules and the band cut-offs are reasoned heuristics. Error rates are measured on simulated Gaussian data, and real physiology has autocorrelation, seasonality and artefacts.
- **SDNN, not RMSSD.** Apple exposes SDNN. Its overnight sampling is sparse (a few readings), so nightly HRV is noisy. Baselines and the 7-day trend partly absorb this.
- **The menstrual cycle raises wrist temperature** by a few tenths of a °C in the luteal phase. Temperature penalises only beyond +1 SD, carries 7.5% weight, and joins the elevated-vitals flag only together with elevated sleeping HR. Some cycle-driven shifts may still show up.
- **TRIMP without a workout** relies on background HR sampling, which is sparse, so unrecorded activity is under-counted. Start a workout for anything that matters.
- **Time zones.** Cached days keep the windows of the zone in which they were built (by design, see §1). *Rebuild from Health* re-splits all days in the current zone.
- **Wrist temperature form.** Whether HealthKit stores absolute or deviation values is unverified. Scoring is relative to your own baseline, so both work, but this should be confirmed on device.
- **Overnight-closed rule.** If you are still asleep at 10:00 and no sleep has been recorded yet, a score can be computed from a partial night.
- **ACWR** is a contested injury-risk predictor in the literature. Here it is used only as a load-change speed limit, not as an injury model.

## 12. Hourly slices (engine 2.1, cache schema 3)

Each day's activity window is split into hours from its stored start. For each hour the cache keeps:
- time at heart rate in 10-bpm bins (same holding rule as §1: each sample holds until the next, capped at 300 s, split at hour boundaries);
- **rest-state** heart-rate time and its seconds-weighted mean. A heart-rate piece is rest-state when its midpoint is not inside sleep or in-bed time (any source), a workout plus 10 min afterwards, or a moving step sample (cadence ≥ 30 steps/min) plus 3 min afterwards;
- asleep, workout and step totals.

The slices' heart-rate time adds up to the daily histogram's (unit-tested). Like the histogram, slices store time at HR rather than scores, so changing HRmax, HRrest or sex re-scores every hour without a new query.

## 13. Strain

Strain = 100 × (1 − 2^(−TRIMP / reference)). The reference is your current CTL
(42-day chronic load) once load targets are eligible (§6: 28 days and CTL ≥ 10),
so **50 = a typical day for you**, 75 = two typical days, 87.5 = three. Before
that, the reference is a fixed 50 TRIMP and the strain is labelled provisional.
Today's load target band (§6) is shown on the same scale. Strain per hour uses the
10-bpm slices and is rescaled so the hours add up to the exact daily TRIMP.

## 14. Stress and energy

**Stress** (0–100) uses rest-state heart rate only: level = clamp((HR − HRrest) /
(0.30 × (HRmax − HRrest)), 0, 1) × 100, computed per hour from the hour's rest-state
mean when it has ≥ 10 rest-state minutes. Bands: 0–25 rest, 26–50 low, 51–75
medium, 76–100 high. The daily score is the rest-time-weighted mean of hourly
levels and needs ≥ 60 rest-state minutes.

Limits: heart rate rises for reasons other than stress (heat, caffeine, digestion,
standing still). Daytime HRV is not used because Apple Watch records it only
occasionally. The level is relative to *your* HRrest and HRmax, not a population.

**Energy bank** (0–100) starts at wake:
- recovery and sleep available: 0.65 × recovery score + 0.35 × sleep score;
- recovery only: the recovery score;
- sleep only: 20 + 0.7 × sleep score (cannot reach the extremes without overnight physiology);
- neither: no energy value.

It then runs hour by hour until the last sync:
- −2 per waking hour;
- −30 × (hour's TRIMP / strain reference), so a typical day's load costs about 30;
- for rest-state time at stress > 50: −4 × (level − 50)/50 per hour;
- for rest-state time at stress ≤ 25: +2 per hour;
- naps: +12 per hour asleep.

The result is clamped to 0–100. The constants are heuristics: a typical day
(16 h awake, one typical day's load, about 6 h of calm rest) ends about 50 points
below the start. They are not fitted to data.

## 15. Heart-rate recovery

For each workout that started in the day: end HR = highest sample in the last
60 s of the workout. The one-minute drop = end HR − the sample nearest 60 s after
the end (within ±15 s). The two-minute drop uses 120 s (±20 s). When Health has
Apple's own one-minute recovery value for the workout (a sample starting up to
10 min after it ends), that value is used instead. The typical value is the median
over the last 60 days, excluding the newest workout, and needs ≥ 3 workouts.

## 16. Caffeine and hydration

Each dose is absorbed at a constant rate over 45 min and eliminated with first-order
kinetics (half-life 5 h by default, adjustable from 2 to 10 h, since individual
half-lives vary widely). Bedtime is the median sleep onset of the last 7 nights
(≥ 3 needed), otherwise 23:00. The **cut-off** is the latest time one usual dose
(95 mg by default) keeps caffeine at bedtime at or under the limit (50 mg by
default), solved in closed form:

  gap = 45 min − ln(ratio)/k, ratio = (limit − residual at bedtime) × k × 45 min / (dose × (1 − e^(−k × 45 min)))

If what you have already taken leaves the limit reached at bedtime, there is no cut-off.

Fluid target = 35 ml per kg of body mass (Health's latest, or 70 kg) + 10 ml per
workout minute, rounded to 50 ml. Caffeine and water logs stay on the watch.
Margin still writes nothing to Health.

## 17. Activity status

You can mark periods as *unwell*, *sore* or *travel*. Days inside any marked period:
- are left out of every personal baseline (HRV, sleeping HR, respiration, temperature), out of score calibration and out of the 7-day HRV trend (§2, §3, §4);
- for unwell and sore only: the load model is paused, so ATL and CTL carry over unchanged instead of decaying, and Push is off.

Today's score is still computed on a marked day, against the unmarked baseline.
