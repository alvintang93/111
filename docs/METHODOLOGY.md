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

**Confidence**:
- *Calibrating*: no HRV or sleeping-HR baseline yet. No score is shown.
- *No data*: neither HRV nor sleeping HR last night. No score is shown.
- *High*: HRV during sleep, sleeping HR and sleep all present, with an HRV baseline of at least 30 days.
- *Medium*: HRV plus sleeping HR or sleep.
- *Low*: anything else.

## 4. Flags

| Flag | Rule |
|---|---|
| Illness watch | Sleeping HR z ≥ +2 **and** (temperature z ≥ +2 **or** respiration z ≥ +2) |
| HRV trend low | Mean lnHRV of the last 7 days (≥4 present) < baseline − 0.5 × scale (smallest-worthwhile-change convention) |
| Load spike | ATL/CTL through yesterday > 1.5 |
| Sleep debt | 7-night accumulated shortfall vs base need ≥ 5 h (missing nights are not counted as debt) |

The illness rule is a conjunction on purpose. A single elevated signal, such as
a hot room or a late meal, does not fire it.

## 5. Directive (decision rule)

1. Illness watch → **Rest**.
2. Score ≤ 15 → **Recover**.
3. Score ≤ 33 **and** (HRV trend low **or** sleep debt) → **Recover**. Score ≤ 33 alone → **Maintain**, with "cap intensity".
4. Score ≥ 67 → **Push**, demoted to **Maintain** if confidence is low, HRV trend is low, there is a load spike, or there is sleep debt.
5. Otherwise → **Maintain**.

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

**Ceiling (risk limit).** The largest load *L* today such that ATL/CTL after
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
| False "Rest" / illness | 0.14% of days |
| Detection of a real 5-day drop (HRV −22%, sleeping HR +3 bpm) | 20/20 (test fails below 90%) |

Statistical routines are checked against SciPy 1.17 to 1e-12: the normal CDF,
the regularized incomplete beta, Student-t p-values and Welch's t.

## 10. Where this can be wrong

- **No clinical validation.** Weights, the 0.30 HRR floor, the sleep-need rules and the band cut-offs are reasoned heuristics. Error rates are measured on simulated Gaussian data, and real physiology has autocorrelation, seasonality and artefacts.
- **SDNN, not RMSSD.** Apple exposes SDNN. Its overnight sampling is sparse (a few readings), so nightly HRV is noisy. Baselines and the 7-day trend partly absorb this.
- **The menstrual cycle raises wrist temperature** by a few tenths of a °C in the luteal phase. Temperature penalises only beyond +1 SD, carries 7.5% weight, and joins the illness flag only together with elevated sleeping HR. Some cycle-driven shifts may still show up.
- **TRIMP without a workout** relies on background HR sampling, which is sparse, so unrecorded activity is under-counted. Start a workout for anything that matters.
- **Time zones.** Cached days keep the windows of the zone in which they were built.
- **ACWR** is a contested injury-risk predictor in the literature. Here it is used only as a load-change speed limit, not as an injury model.
