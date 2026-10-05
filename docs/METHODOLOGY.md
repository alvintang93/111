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
Margin does not write them to Health. Since engine 2.3, the only thing Margin writes to Health is the strength workouts you log (§24).

## 17. Activity status

You can mark periods as *unwell*, *sore* or *travel*. Days inside any marked period:
- are left out of every personal baseline (HRV, sleeping HR, respiration, temperature), out of score calibration and out of the 7-day HRV trend (§2, §3, §4);
- for unwell and sore only: the load model is paused, so ATL and CTL carry over unchanged instead of decaying, and Push is off.

Today's score is still computed on a marked day, against the unmarked baseline.

## 18. Biomarker trends (engine 2.2)

Body mass, body fat, lean mass, VO2 max, resting HR, blood pressure and glucose are
read from Health (Margin does not write them). For each, over the last 90 days
(365 for VO2 max):
- **Slope:** Theil–Sen (median of all pairwise slopes), so one odd reading cannot swing it. Needs ≥ 4 readings spanning ≥ 14 days.
- **Projection:** the fitted line 30 days past today, with a band of ±1.96 × robust residual SD × √(1 + 30 / span in days). The band widens when you extrapolate further than the data covers. It describes "if the current trend holds", not a prediction of what you will do.

**Blood pressure** pairs systolic and diastolic readings with the same timestamp.
The latest reading is labelled with the American Heart Association category
(normal < 120/80; elevated 120–129 and < 80; high stage 1 130–139 or 80–89; high
stage 2 ≥ 140 or ≥ 90). One reading is not an assessment.

**Glucose:** latest, 24 h mean and share of readings in 70–140 mg/dL, plus daily means.
**Nutrition:** daily sums of energy, protein, carbohydrate and fat logged by other apps. The 7-day average skips days with nothing logged.

## 19. Biological age (estimate)

- **Start:** fitness age when VO2 max is available. That is the age at which your VO2 max would be typical, using a linear fit to published age norms: men 52 − 0.40 × (age − 20), women 44 − 0.35 × (age − 20), unspecified the midpoint. Without VO2 max, the start is your chronological age.
- **Resting HR:** +1.7 years per 10 bpm above 60 (median of the last 30 days, needs ≥ 7). This converts a hazard ratio of about 1.16 per 10 bpm at about 1.09 per year of age. It is halved when VO2 max is used, because the two overlap.
- **Sleep:** average over the last 14 nights (needs ≥ 7). Under 7 h adds 1.3 years per missing hour; over 9 h adds 1 year per extra hour; capped at 3.
- The total is clamped to chronological age ± 20 (and ≥ 18).

This is a heuristic that combines population associations. It is not a validated
biological-age model and not a clinical measure. Every component is shown on the watch.

## 20. Cycle

A recorded flow day starts a new period when the previous flow day is ≥ 10 days
earlier (spotting doesn't start a new cycle). Cycle length is the median of the
last 6 lengths between 18 and 45 days, otherwise 28. The next period is predicted
at last start + that length. Ovulation is placed 14 days before the next period:
- *menstrual* while flow continues from the start;
- *ovulatory* ovulation ± 1 day;
- *follicular* before that;
- *luteal* after it.

For each phase, Margin averages next-morning HRV vs your 60-day baseline and wrist
temperature vs your median, over the recorded cycles. Phase does not change the
recovery score; §11 explains how temperature is handled.

## 21. Running form and zones

Run form metrics (stride length, vertical oscillation, ground contact time, power,
speed) are Health's averages over each run recorded with the Workout app.
Cadence = steps ÷ minutes. Pace uses distance (or speed when distance is missing).
Typical values are medians over the other runs in 60 days.

**Custom zones:** five zone lower bounds, set as % of HR reserve (default
50/60/70/80/90), % of HRmax, or bpm. Time below zone 1 is zone 0. The default
reproduces the original zone split exactly (unit-tested). Zones drive today's zone
minutes, per-workout time in zone and cardio focus. Training load (TRIMP) is
unaffected.

**Cardio focus** per workout:
- *Anaerobic* if zone 5 holds ≥ 10% of in-zone time and ≥ 3 min.
- Otherwise *high aerobic* if zones 3–4 hold ≥ 40%.
- Otherwise *low aerobic*.
- None with under 5 min in zones 1–5.

The 28-day summary adds up workout minutes by zone group.

## 22. Compare two metrics

Daily values for the last 30 days: recovery, HRV, sleeping HR, sleep hours, sleep
score, load, stress, steps, caffeine and water. Caffeine and water count only on
days with something logged. Two metrics are paired by day, optionally with the
second one day later. The result is Spearman's ρ with a t-approximation p-value
(n − 2 df). Associations only, and with 30 days several pairs will look
"significant" by chance.

## 23. Smart alarm

A watchOS smart-alarm session is scheduled for the window before your wake time
(10–30 min). While it runs, wrist acceleration is sampled at 10 Hz and summarised
every 30 s as the mean |a − 1 g|. Two consecutive epochs at ≥ 0.015 g count as
sustained movement, a common sign of lighter sleep or a brief arousal, and trigger
the haptic alarm. The latest wake time always triggers it. watchOS lets apps
schedule the session only while they are open, so Margin re-arms it every time it
comes to the foreground. The movement threshold is a heuristic and has not been
validated against sleep staging.

## 24. Strength (engine 2.3)

**Logging.** A strength workout runs as a watchOS workout session (Traditional
Strength Training), so heart rate is sampled densely and counts toward training
load like any workout. Saving it writes the workout, plus the heart rate and
active energy the watch recorded, to Health. That is the only data Margin writes.
Sets (exercise, weight, reps, optional RPE, warm-up flag) stay in Margin's log on
the watch. The next set of an exercise is pre-filled from your last working set.

**Library.** 118 built-in movements, each with primary and secondary muscles from
16 groups, plus any you add. Bodyweight movements carry the share of body mass
moved (e.g. push-up 0.64, pull-up 1.0). Effective load = added weight + share ×
body mass (Health's latest, or 70 kg).

**Estimated 1RM.** Epley: weight × (1 + reps/30), reps capped at 12; 1 rep = the
weight. A record is the best estimate per exercise. A first attempt is not shown
as a record.

**Muscle stimulus.** Each working set counts 1 hard-set equivalent for each primary
muscle and ½ for each secondary one, times an effort factor: 1 without RPE, else
clamp((RPE − 5)/5, 0.2, 1). Warm-ups count nothing. Weekly sets = sum over 7 days.
For hypertrophy, 10–20 per muscle per week is a common evidence-based range.

**Freshness.** Fatigue(t) = Σ stimulus × e^(−Δt/τ), with τ = 30 h for large
groups (chest, back, glutes, quads, hamstrings, lower back) and 20 h for small ones.
Freshness = 100 × e^(−fatigue/6). Ready means ≥ 80. The ready time is solved in
closed form, assuming no more training: τ × ln(fatigue / 1.34). Six hard sets for
quads give freshness ≈ 37 and ready in about 45 h. The constants are heuristics
and have not been validated.

**Plate calculator.** Greedy from the heaviest plate (optimal for standard plate
sets): kg 25/20/15/10/5/2.5/1.25, lb 45/35/25/10/5/2.5. When the target can't be
loaded exactly, it shows the closest load below.

## 25. iPhone companion and coach (engine 2.3, batch 4)

**Where scores come from.** The watch is still the only place scores are
computed. After each rescore it sends a payload to the iPhone as a WatchConnectivity
file transfer: the brief, strength log, journal and settings, at most every
5 minutes and at once after a sync or a workout. The iPhone app and its home and
lock screen widgets only display that payload. Every tile uses the same
`DashboardTile` rules as the watch, so nothing from a previous day is shown as today's.

**Written by the iPhone.** Meals you log (energy, protein, carbohydrate, fat) are
written to Health. Calendar events are created only when you tap "Add to
Calendar" on a proposed session.

**Lab results** are entered by hand from your reports, with the report's own
reference range. Margin supplies no reference ranges and makes no interpretation.

**Coach.** Claude (`claude-opus-5-5`), called from the iPhone with your own
Anthropic API key, which is stored only in the iPhone Keychain. The coach reads data
only through tools that return numbers Margin already computed:
- today's brief;
- up to 30 days of a daily metric;
- body trends;
- strength;
- labs;
- calendar busy times (titles only if you turn that on).

Charts and plans are tool calls rendered by the app from Margin's own series, so
plotted values never come from the model. The modes map to effort: Fast = low,
Adaptive = medium, Thinking = high with a reasoning summary shown. Personalities
change only the voice. Ghost mode keeps a conversation out of the saved history.
Requests opt into server-side refusal fallback. When you chat, the data those tools
return is sent to Anthropic. Nothing is sent without a key and a question.
