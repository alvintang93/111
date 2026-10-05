# Margin — Device validation checklist (Apple Watch Ultra 2)

Run these steps on your own watch. Each step has the expected result and a
PASS/FAIL rule. Record the results in the sheet at the end. Nothing in this
repository has been run on a physical watch yet: everything below is
**unverified until you complete it**.

Where to look:
- **Developer diagnostics**: the More page (scroll down on the watch) → *Developer diagnostics*. Everything it shows comes from the same state the score uses. It exists only in Debug builds (run from Xcode); Release and TestFlight builds hide it.
- **Events**: the bottom of Developer diagnostics (newest first; the last 300 are kept on the watch).
- **Xcode console**: while the app runs from Xcode, every event is also logged through `os.Logger` with category `pipeline`.

Privacy: diagnostics screenshots contain health-derived values. Share them privately.

---

## 1. INSTALL

**Requirements**
- A Mac with Xcode 16.4 or later. CI builds with Xcode 16.4 and the watchOS 11.5 SDK; other versions are untested.
- Homebrew and XcodeGen: `brew install xcodegen`.
- Your iPhone, paired with the Ultra 2, both unlocked and on the same Wi-Fi as the Mac (or the iPhone connected by cable).
- An Apple ID added in Xcode → Settings → Accounts. Apps signed with a free personal team expire after 7 days. If Xcode reports that HealthKit or App Groups is unavailable for your team, you need the paid Apple Developer Program.

**Exact `CHANGE ME` values in `project.yml`**

| Key | Set to | Rule |
|---|---|---|
| `BUNDLE_ID_PREFIX` | e.g. `com.yourname.margin` | A reverse-DNS string not used by anyone else. The app becomes `<prefix>.watchkitapp` and the complication `<prefix>.watchkitapp.widgets` |
| `APP_GROUP_ID` | e.g. `group.com.yourname.margin` | Must start with `group.`; the same value is used by both targets automatically |
| `DEVELOPMENT_TEAM` | your 10-character Team ID | Xcode → Settings → Accounts → select team; or developer.apple.com → Membership |

**Build and deploy**
1. `cd` to the repo, then `xcodegen generate && open Margin.xcodeproj`.
2. Select target **Margin** → *Signing & Capabilities*. Check:
   - *Automatically manage signing* is on.
   - Team = yours.
   - **HealthKit** and **App Groups** (with your `APP_GROUP_ID` ticked) are listed.
3. Select target **MarginWidgets** → *Signing & Capabilities*. Check that **App Groups** shows the same group, ticked.
4. Scheme **Margin**, destination: your Apple Watch Ultra 2 (listed under the iPhone).
5. If prompted, enable **Developer Mode** on the iPhone and the watch (Settings → Privacy & Security → Developer Mode), then restart them. The first deployment can take several minutes ("Preparing … for development").
6. Press Run (⌘R). Keep the Xcode console open.

PASS: the app launches on the watch and the console shows `[lifecycle] app launched (engine 2.0.0)`.

---

## 2. FIRST LAUNCH

**Expected prompts**
1. A Health access sheet on the watch, listing roughly: Heart Rate, Heart Rate Variability, Resting Heart Rate, Respiratory Rate, Sleeping Wrist Temperature, Sleep, Workouts, Date of Birth, Sex. Exact wording is set by watchOS.
   **Grant all.** Margin only reads; it writes nothing to Health.
2. A notification permission prompt. Allow it; it is used only for the "overnight readings above usual" alert.

**Expected initial UI**
- The Today page shows "Reading Health history… N%" while up to 120 days are built.
- When it finishes, Today shows one of:
  - a score; or
  - **CALIBRATING x/14** (fewer than 14 nights with HRV in the last 60 days); or
  - a status explaining why there is no score.

**Confirm the historical backfill happened** (Developer diagnostics):

| Where | Expected |
|---|---|
| Health access → Request status | `unnecessary (prompt answered)` |
| Data → Last successful sync | within the last few minutes |
| Data → Cached days | about 120 (oldest ... today) |
| Data → Earliest sample (window) | about 60 days ago, if you wore the watch then |
| Health access → each input | `data seen` with days N/60. Wrist temperature and respiration need sleep tracking |
| Events | `foreground plan: 120 day(s) [missing 120, …]`, `queried … day(s): sleep N, HRV N, …`, `built 120 new day(s), K with no Health data`, `foreground sync complete` |

FAIL if:
- Cached days is 0;
- the events show `sync skipped: Health authorization not resolved` after you answered the sheet; or
- every input shows NO DATA although the Health app on your iPhone has data.

---

## 3. CALIBRATION

- **Valid calibration day (HRV night):** at least one HRV sample inside the main sleep bout. If no sleep was recorded, the 20:00–10:00 window is used instead.
- **Sleeping-HR night:** at least 10 heart-rate samples during the main sleep bout.
- **Minimum for a score:** 14 HRV nights in the previous 60 days.
- **Full calibration:** 20 previous days with a composite. Until then the status is **Provisional scale** and Push is disabled.

**Diagnostics → Score status shows**
- Status
- Calibration (`insufficientHRV` / `provisionalScale` / `calibrated`)
- HRV nights x/14
- Sleeping-HR nights
- Score-scale days x/20
- Missing tonight

**With insufficient data**
- No score anywhere.
- Today shows CALIBRATING with "Calibrating: x of 14 nights with HRV."
- Complications show `CALIBRATING x/14` / `CAL`.

PASS: the counts match your history: Health app → Browse → Heart → Heart Rate Variability shows roughly one or more readings on the nights counted.

---

## 4. WORKOUT TEST

1. Note Diagnostics → Data → Workouts 7d and Latest workout end.
2. Start a Workout (e.g. Outdoor Walk) for at least 15 minutes at moderate effort, then end and save it.
3. Open Margin and wait for "sync complete" in Events.
4. Check:
   - Data → Workouts 7d increased by exactly 1, and Latest workout end matches the end time.
   - Data → Workout HR coverage 7d: expect ≥ 90% (Workout mode samples HR densely). Below 50% means load is undercounted. Record it.
   - Recent days → today: `Workouts: 1 started, HR coverage NN%`.
   - Load page: *Load today* increased and zone minutes appear.
5. **Score input:** the recovery score must not change because of a workout (it uses overnight data). Today's load, tomorrow's sleep need and ATL/CTL (from tomorrow) do change.
6. **No duplicate ingestion:** tap *Sync now* three times. Workouts 7d must stay the same. Events show `day … [recent] replaced (source unchanged)`.

FAIL if:
- the workout count increases by more than 1;
- the workout is missing after a sync; or
- Load today does not change.

---

## 5. OVERNIGHT TEST

1. Wear the Ultra 2 overnight with sleep tracking on (Sleep schedule set in the Sleep app; battery above 30% at bedtime).
2. On waking, *before* opening Margin, note the complication. Expected:
   - **PENDING** until 30 minutes after the end of your main sleep (or 10:00 if no sleep was recorded);
   - afterwards the last saved state.
3. At least 30 minutes after waking, open Margin. In Diagnostics → Recent days → today, check:
   - `HRV: n sample(s) during sleep` (n ≥ 1);
   - `Sleeping HR: N samples` (N ≥ 10);
   - `Sleep: detected`;
   - `main sleep hh:mm–hh:mm` matches the Health app's Sleep chart within a few minutes;
   - `night` window = 18:00 yesterday → 18:00 today, and `tz` = your time zone.
4. Score status = `Scored` (or `Provisional scale` during calibration). If you see `Partial data`, record which input is missing.

PASS: the night is attributed to the wake day; the times match the Health app; the counts are non-zero.

---

## 6. BACKGROUND TEST

watchOS decides whether and when background work runs. Margin can only *request* it. The app records requests and executions separately.

1. Put a Margin complication on your **active** watch face. watchOS generally gives such apps more background opportunities; this is not guaranteed.
2. Open Margin, let it sync, then press the Digital Crown to leave it. Do not reopen it for at least 4 hours (ideally overnight).
3. Reopen it → Diagnostics → Background & complication. Record:
   - **Last background request** and **Requested for**: what Margin asked for (every 45 min).
   - **Last background run (executed)** and the list of runs: when watchOS actually ran the task.
   - Events: `background refresh requested for hh:mm`, `background refresh task executed`, `background plan: …`.
4. Fill in the sheet: number of requests vs executions, and the delay between requested and executed times.

Interpretation:
- Requests with no executions mean watchOS did not grant background time. That is not an app error, but the complication then only updates when you open the app.
- An execution followed by `sync aborted … Health database locked` means the watch was locked at that moment; the previous data is kept.

---

## 7. COMPLICATION TEST

Add each family to a face: long-press face → Edit → Complications → choose a slot → **Margin → Readiness**.
- Circular: Infograph-style slot
- Corner
- Rectangular, and also via the Smart Stack
- Inline: the top text slot on faces that have one

Expected appearance, generated by `ComplicationState`:

| State | Circular | Corner | Rectangular (3 lines) | Inline |
|---|---|---|---|---|
| Calibrating | gauge x/14, `CAL` | `CAL` + gauge | `CALIBRATING x/14` · `HRV nights collected` · `No score yet` | `Calibrating x/14` |
| Push | score, green/yellow gauge | score | `REC nn` + `PUSH` · `Load a / lo-hi` · `Synced hh:mm` | `nn · PUSH` |
| Maintain | score | score | `REC nn` + `MAINTAIN` · load line · footnote | `nn · MAINTAIN` |
| Recover | score, red/yellow | score | `REC nn` + `RECOVER` · load line · footnote | `nn · RECOVER` |
| Partial data / provisional | score | score | footnote `Partial data` / `Scale calibrating` (orange) | `nn · …` |
| Night in progress | `…` | `…` | `PENDING` · `Ready after you wake` | `Margin · pending` |
| Unavailable | `–` | `–` | `NO SCORE` · `No overnight data` or `HRV unavailable` | `No score · …` |
| Stale (previous day) | `–` | `–` | `Margin` · `Open to update` · `Last result: yyyy-mm-dd` | `Margin · open to update` |

How to observe each state:
- **Stale:** after midnight, without opening Margin. The complication must not show yesterday's number.
- **Pending:** look right after waking (within 30 minutes).
- **Unavailable:** a night without the watch on, or the permission test below.
- **Calibrating:** a fresh install with fewer than 14 HRV nights. If you have more history, rely on the unit tests (`testWidgetStateWhileCalibrating`).
- **Push / Maintain / Recover:** observe over days. Each time, compare the complication with the Today page.
- **Update after a score change:** open Margin and let it sync. In Diagnostics compare *Widget reload requested* with *Widget timeline generated*. The complication should change shortly after; WidgetKit decides exactly when.

PASS:
- every family shows the same state and score as Today;
- the stale state never shows a number;
- "Widget timeline generated" advances after syncs;
- App Group = `available`.

FAIL: App Group `UNAVAILABLE`, or "Widget state / saw brief" = `no` after a successful sync.

---

## 8. PERMISSION FAILURE TEST

Goal: confirm that losing a permission produces an explicit degraded state, not a normal-looking score.

1. On the iPhone: Health app → your profile picture → Privacy → **Apps** → **Margin** → turn off **Heart Rate Variability** only. If Margin is not listed there, check the watch's Settings → Health. The exact menu path depends on the OS version.
2. On the watch, open Margin and tap *Sync now*.
3. Expected:
   - Events: many `day … [sourceChanged] replaced (source data changed); HRV now missing` warnings. HealthKit now hides all HRV, so every day changes.
   - Status = **HRV unavailable**, detail "No HRV readings in the last 60 days although heart rate is recorded…".
   - No score on Today or on the complications (`NO SCORE` / `HRV unavailable`).
   - Health access → Heart Rate Variability = `NO DATA`.
4. Turn the permission back on and sync. HRV returns, the days are rebuilt again, and the score returns.

Note: HealthKit never tells an app that read access was denied. Margin can only report "no data", which is why the HRV status is phrased that way.

PASS: no score is shown while HRV is off, and the score returns after re-enabling.

---

## 9. RESTART TEST

1. Note Diagnostics: score, status, Cached days, Last successful sync.
2. Restart the watch (hold the side button → power off → on). Unlock it.
3. Before opening Margin, the complication should show the same same-day result. After midnight it should show the stale state.
4. Open Margin. Events, in order:
   - `cache loaded: N day(s)`
   - `foreground plan: 3 day(s) [missing 0, recent 3, sourceChanged 0, retryEmpty 0]` (sourceChanged > 0 only if Health data changed meanwhile)
   - `sync complete`
5. With no new Health data, the score and recommendation must be identical to step 1 (scoring is deterministic and tested byte-for-byte).

FAIL if:
- Cached days drops to 0 after the restart (look for `cache discarded: …` in Events); or
- the score changes without any new data.

---

## 10. TIME-ZONE TEST (safe procedure)

The day-bucketing logic is covered by deterministic tests, which are the primary evidence:
- `testTimeZoneChangeLeavesNoOverlapOrGap`
- `testWestwardTimeZoneChangeClosesGap`
- `testDSTBoundariesKeepContinuousCoverage`
- `testDayCrossingMidnight`

A device check is optional.

Margin only reads Health data and never modifies it. A time-zone change only affects how Margin's own cache splits days.

1. Pick a day without training plans. Note Diagnostics → Recent days (today's `night` and `day` windows and `tz`).
2. On the iPhone: Settings → General → Date & Time → turn off *Set Automatically* → choose a city 5+ hours away. The watch follows the iPhone.
3. Open Margin and sync. Expected:
   - Data → Time zones (14d) lists two zones.
   - The newest day's `day` window starts exactly where the previous day's ended (no gap or overlap).
4. Restore *Set Automatically* and sync again.
5. To return every cached day to your home zone's boundaries: Settings → **Rebuild from Health**. This re-reads up to 120 days and rebuilds them in the current zone.

---

## 11. DAILY SCORES AND LIFESTYLE (engine 2.1)

After updating from engine 2.0, the cache is rebuilt once (schema 2 → 3), and Health asks again for the new types: Steps, Heart Rate Recovery and Body Mass. Grant them.

| Check | Where | Expected |
|---|---|---|
| Cache rebuilt | Events | `cache discarded: schema 2 != 3; full rebuild from Health`, then a 120-day foreground plan |
| Steps read | Diagnostics → Health access → Steps | `data seen` on days you wore the watch |
| Strain | Load page | A number 0–100 after some heart-rate data today. "Provisional" until 28 days of load history |
| Stress | Energy page | Hourly bars appear for hours you sat still for ≥ 10 min. No bars during a workout or while walking |
| Energy | Energy page | Starts at wake. Drops after a workout, and rises slightly after calm rest |
| HR recovery | Load page, bottom | After a workout with the Workout app, a 1-minute drop. Keep the watch on for 2 minutes after ending it |
| Caffeine | Today → coffee button, then More → Caffeine & water | "In your body now" rises over 45 min. A cut-off time appears before bedtime |
| Status | More → Status → Unwell | Today shows "Marked unwell · baselines paused". The directive is never Push |
| Timeline | Today → list button | Sleep, wake, workouts, drinks and journal in time order |
| Complications | Watch face → Edit | Strain, Energy, Stress and Sleep are listed alongside Readiness |
| Check-ins | Settings → Check-ins | Morning summary arrives once after waking. The journal reminder fires at the set time unless today is already journaled |

PASS: every row behaves as described. FAIL: any tile shows a value with yesterday's date after midnight, or the app crashes on any page.

## 12. BODY, RUNNING, CYCLE, SMART ALARM (engine 2.2)

The cache is rebuilt once again (schema 3 → 4). Health asks for VO2 max, blood pressure, body composition, glucose, nutrition, running metrics and cycle tracking. Grant what you use.

| Check | Where | Expected |
|---|---|---|
| Biomarkers read | Events | `biomarkers: vo2Max N, ... runs N` after a foreground sync |
| VO2 max / resting HR | Body page | The latest value matches Health → Heart. A trend appears once there are 4 readings over 14 days |
| Biological age | Body page, top | Components add up to the estimate. Needs your date of birth in Health |
| Body composition | Body page | Appears only if a scale or app writes body mass or body fat to Health |
| Running form | More → Running form | After a Workout-app run: cadence, stride, vertical oscillation, ground contact, power |
| Zones | Settings → Heart-rate zones | Changing a bound changes Load → zone minutes today, without a re-sync |
| Cardio focus | Load page | Each recent workout labelled low aerobic, high aerobic or anaerobic |
| Cycle | More → Cycle | With periods logged in Health: cycle day, predicted next start, HRV and temperature by phase |
| Compare | More → Compare | Lines for two metrics and Spearman ρ once 3 days have both values |
| Smart alarm | Settings → Smart alarm | "Armed for …" after enabling. At the window you get a haptic alarm on movement, or at the wake time. Keep a backup alarm for the first nights |

## Results sheet

| Date | Test | Status / score / recommendation | HRV nights x/14 | Bg requests / executions | Complication state seen | PASS/FAIL | Notes |
|---|---|---|---|---|---|---|---|
| | | | | | | | |

Also record **what the wrist temperature value looks like** (Diagnostics → Scoring → Wrist temp baseline): roughly 33–37 °C (absolute) or around 0 (deviation). This confirms which form HealthKit stores, which is currently an assumption.
