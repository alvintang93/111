# Margin — feature roadmap

This file maps the requested feature list onto Margin and splits it into batches. Each batch
ships as its own pull request, with unit tests in `MarginCore` and the product-language check
still passing. Margin stays a standalone watch app that computes everything on the watch.
Batch 4 is the exception: it needs an iPhone companion and, for the AI coach, a network service.

Status key: **Have** = already in Margin · **B1–B4** = batch · **Open** = needs a decision first. B1 shipped in PR #3, B2 in PR #4.

## Core metrics and readiness

| Feature | Status | Notes |
|---|---|---|
| Recovery score (HRV, resting HR, sleep) | Have | Also uses respiration and wrist temperature. 60-day personal baselines |
| Sleep score and stages | Have | Score from performance vs need, efficiency and regularity. Stages: deep, core, REM, awake |
| Smart alarm | B2 | watchOS smart-alarm session with a wake window. Light-sleep detection from motion and heart rate, because Health writes sleep stages only after you wake |
| Strain score | B1 | 0–100 score of today's TRIMP against your own 42-day chronic load |
| Stress score | B1 | Daytime heart rate above your resting level outside workouts and sleep, hour by hour, plus a daily summary |
| Energy bank | B1 | Morning level from sleep and recovery. Drains with strain and stress, recharges at low stress. Shown as a level and a curve |

## Fitness and training

| Feature | Status | Notes |
|---|---|---|
| Cardio and fitness load | Have | TRIMP, ATL/CTL, form, ACWR, load ceiling, heart-rate-reserve zones |
| Strength builder | B3 | Exercise library (starts at about 150 movements, not 700), set logging with weight autofill, plate calculator. Saves a strength workout to Health |
| Muscle maps and freshness | B3 | Per-muscle volume and recovery time from logged sets |
| HR recovery after workouts | B1 | Drop at 60 s and 120 s after each workout ends. Also reads Apple's 1-minute recovery when present |
| Running form metrics | B2 | Cadence, stride length, vertical oscillation, ground contact time and power per run, read from Health |
| Cardio focus and custom zones | B2 | User-defined zone boundaries, with time in zone per workout |

## Habits and lifestyle

| Feature | Status | Notes |
|---|---|---|
| Journal with correlations | Have | Tags tested against next-night HRV with a Welch t-test and Holm correction. B1 adds quantity habits (sunlight, screens, supplements) |
| Caffeine and hydration | B1 | Quick log on the watch. Caffeine still in the body (5 h half-life), a cut-off time before bed, and a daily fluid target |
| Unified daily timeline | B1 | One list per day: sleep, workouts, caffeine, water, journal and status changes |
| Activity status (unwell, sore, travel) | B1 | Marked days are left out of baselines and the load model, so they don't drag scores |
| Proactive check-ins | B1 | Local notifications: morning summary, evening journal reminder, caffeine cut-off |
| Pinned dashboard and complications | B1 | Choose which tiles Today shows. New complications for strain, energy, stress and sleep |
| Nutrition and glucose | B2 (read) / B4 (logging) | B2 reads calories, macros and glucose that other apps write to Health. Full food logging needs a food database and belongs on the phone |
| Cycle tracking | B2 | Reads cycle data from Health. Shows phase, prediction, and HRV and temperature by phase |

## Biomarkers

| Feature | Status | Notes |
|---|---|---|
| Biological age | B2 | Estimate from VO2 max, resting HR, HRV and sleep regularity, with every input shown. An estimate, not a clinical age |
| Blood pressure | B2 | Trends from Health. Manual logging needs write access to Health |
| Body fat and lean mass with a 30-day projection | B2 | Robust trend line with a projection band |
| Health records (labs, clinical) | B4 | Clinical-records access exists only on iPhone |

## AI coach and phone features

| Feature | Status | Notes |
|---|---|---|
| AI coach, coaching personalities, off-the-record chat, speed modes | Open → B4 | Needs a language model. The options are Claude via a key you provide, or a small backend. Either way, health summaries leave the watch, which changes Margin's privacy stance |
| Calendar-aware plans | B4 | Calendar access plus the coach |
| Visual charts across metrics | B2 (watch) / B4 (coach) | B2 adds a "compare two metrics" chart on the watch |
| iPhone home and lock screen widgets | B4 | Needs the iPhone companion app |

## Batch 1 scope (PR #3)

Strain score, stress score, energy bank, HR recovery, caffeine and hydration, unified timeline,
activity status, proactive check-ins, pinned Today tiles and new complications. The math lives in
`MarginCore` with deterministic tests. Formulas are documented in `docs/METHODOLOGY.md` §12–§17.

## Batch 2 scope (PR #4)

Body page with biological age, VO2 max, resting HR, body mass, body fat and lean mass trends with 30-day
projections, blood pressure, glucose and nutrition, all read from Health. Also running form, custom heart-rate
zones with cardio focus, cycle phase and prediction with HRV and temperature by phase, a compare-two-metrics
chart, and the smart alarm. Formulas are in `docs/METHODOLOGY.md` §18–§23. Still not done from B2: manual
blood-pressure logging (needs write access to Health).
