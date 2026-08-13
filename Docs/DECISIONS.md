# Decisions

Architecture decision records for Caliper. Each entry states what was decided,
why, and what it costs. Records are appended, not rewritten — if a decision is
reversed, a later record supersedes it and says so.

Two of these are load-bearing beyond the usual sense and are called out in the
brief as things not to quietly relax: **ADR-0004/0005** (licence separation) and
**ADR-0011** (no active energy in the budget). Both are enforced by tests or
lint rules rather than by comments alone.

---

## ADR-0001 — iOS 18.0 minimum

**Status:** accepted (M0). Supersedes the brief's iOS 17 floor.

**Context.** The brief specified iOS 17 to buy interactive widgets and modern
App Intents. Those arrive at 17, but the load-bearing concern is elsewhere:
SwiftData shipped in iOS 17 in a state that made `#Predicate` expressiveness,
migrations and index declaration genuinely painful. iOS 18 added `#Index`,
`#Unique` and history tracking, and all three are directly used here — indexed
day keys for the home screen's daily query, `#Unique` for HealthKit anchor
dedupe, history tracking as the honest basis for sync bookkeeping.

**Decision.** Deployment target 18.0.

**Consequences.** We lose the residual iOS 17 population. In August 2026 that is
a small share, skewed to old hardware, and unlikely to buy a paid cutting app.
In exchange the riskiest dependency in the stack lands on its second-generation
API rather than its first.

---

## ADR-0002 — SwiftData retained, with a two-configuration container

**Status:** accepted (M0).

**Context.** The brief allowed a fallback to Core Data on sync or migration
friction, and asked to be told early. The specific friction, found before any
model was written:

- SwiftData backed by CloudKit **forbids `#Unique` and `@Attribute(.unique)`**,
  because uniqueness cannot be enforced across devices.
- Every synced attribute must be optional or carry a default; relationships must
  be optional and cannot use `.deny` delete rules.
- Violations fail at container initialisation, not at compile time.

Separately, Guideline 5.1.3 forbids storing HealthKit-derived data in iCloud.

**Decision.** Stay on SwiftData at iOS 18, and split the store in two:

| Configuration | `cloudKitDatabase` | Holds |
|---|---|---|
| `Synced` | `.automatic` (once entitled) | App-owned records: logged foods, user foods, recipes, saved meals, lift sets, routines, settings |
| `Local`  | `.none` | HealthKit-derived records: import anchors, imported samples |

**Consequences.** The compliance requirement and the technical constraint point
the same way, which is the reason to trust this shape: HealthKit records need
real uniqueness for dedupe and must not sync; app-owned records must sync and
therefore cannot have uniqueness constraints, so they use explicit
fetch-before-insert instead. `ModelSeparationTests` fails the build if a
`LocalOnlyModel` reaches the synced schema, and `Scripts/check-boundaries.sh`
catches the coarser edit of removing `.none` altogether.

Reassess at M5. If the HealthKit sync surfaces migration friction that Core Data
would not have, that is the trigger to switch, and it is cheaper at M5 than at
M8.

---

## ADR-0003 — NutritionKit is Foundation-only and calendar-free

**Status:** accepted (M0).

**Context.** The brief requires NutritionKit to have no UIKit, SwiftUI or
HealthKit imports so the maths is unit-testable against synthetic data. Testing
it on a free Linux CI runner requires a further step: no dependency on Darwin at
all. And swift-corelibs-foundation diverges from Darwin Foundation precisely on
`Calendar` and `TimeZone` — which is the entire subject matter of a rolling
14-day expenditure window.

**Decision.** NutritionKit imports Foundation and nothing else, and may not
reference `Calendar`, `TimeZone`, `DateComponents` or any date formatter. All
day arithmetic happens in `DayIndex` space — an `Int` count of days. Resolution
from instant to `DayIndex` happens exactly once, in
`App/Persistence/DayBoundary.swift`, on Darwin.

**Consequences.** The expenditure engine structurally cannot be green on Linux
and wrong on device, because it never performs calendar arithmetic. The whole
calendar risk of the product is concentrated in one file with its own test suite.
Enforced by `Scripts/check-boundaries.sh`.

`Date` itself remains permitted in the package; the divergence risk is calendar
arithmetic, not the instant type.

---

## ADR-0004 — Food data lives in three physically separate stores

**Status:** accepted (M0). Refines §3 of the brief.

**Context.** §3 specified three tables — `off_products`, `usda_foods`,
`user_foods` — never merged, joined only at query time. But §2 opens the food
database **read-only**, and user foods must be writable and must sync via
CloudKit. Those cannot all be true of one SQLite file.

**Decision.** Separate by store, not merely by table:

| Store | Contents | Licence | Writable | Syncs |
|---|---|---|---|---|
| `caliper-foods.sqlite` (GRDB, read-only) | `off_products`, `usda_foods`, `off_corrections` | ODbL / CC0 / ours | No | No — re-downloadable |
| SwiftData `Synced` configuration | `UserFood`, `Recipe`, `LoggedFood`, `SavedMeal` | User's | Yes | Yes |

Search unions FTS5 results from the snapshot with a SwiftData query over user
foods, ranked in Swift.

**Consequences.** This is a stronger form of the property §3 wanted, not a
weaker one. OFF data and user data are not merely in different tables — they are
in different files, with different lifecycles, and the read-only handle makes
accidental merge impossible at runtime rather than merely forbidden by
convention. See `Docs/LICENSING.md` for why that separation is what keeps ODbL
share-alike from reaching our data.

Cost: search is a two-source merge rather than one SQL query. User food counts
are in the hundreds, so this is not a performance concern.

---

## ADR-0005 — `off_corrections` is pipeline-authored; user edits fork

**Status:** accepted (M0).

**Context.** §3 requires corrections to OFF rows to be stored as deltas keyed to
the barcode, never applied destructively. With a read-only snapshot, the app
cannot write to that table at all, so "who writes corrections" needs an answer.

**Decision.** Two distinct mechanisms:

- **`off_corrections`** is authored by the offline pipeline in `/tools`, ships
  inside the snapshot as its own table, and is applied at query time. If we ever
  publish a derivative database, publishing means exporting this one table and
  nothing else.
- **A user editing an OFF food creates a `UserFood` fork.** The original row is
  untouched. The UI labels the result as an edited copy based on Open Food
  Facts, and attribution survives the edit.

**Consequences.** The only path by which user data could contaminate the OFF
database is closed, because the app has no write handle to it. Users get
editability without us acquiring a share-alike obligation over their data.

---

## ADR-0006 — The package test suite runs on both Linux and Darwin

**Status:** accepted (M0).

**Context.** ADR-0003 makes the packages Foundation-only so they can run on free
Linux CI runners. But "Foundation-only" is not "identical on both platforms":
corelibs and Darwin still differ, and the engine is date-windowed arithmetic.

**Decision.** `packages.yml` runs `swift test` on Linux on every push.
`app.yml` re-runs the same suites on macOS on every pull request, alongside the
iOS app tests. The pair is the check — neither replaces the other.

**Consequences.** Push-time feedback stays fast and free; a Darwin-only
divergence is caught before merge rather than after ship. Costs one macOS runner
job per PR.

---

## ADR-0007 — Excluded days are shown, never silently dropped

**Status:** accepted (M0), implemented M4.

**Context.** §4 requires days with obviously incomplete logging to be excluded
from the intake mean, since a day logged at 40% of actual looks identical to a
day of genuine restriction and will drag the expenditure estimate down.

**Decision.** A day whose logged intake falls below
`PhysiologyConstants.incompleteDayIntakeFractionThreshold` of its issued target
is marked incomplete and excluded from the intake mean. The set of excluded days
is surfaced in the UI wherever the estimate is shown.

**Consequences.** A day dropped without the user being told is worse than a day
counted wrong, because only one of the two is something they can correct.

**Known bias, and why it is accepted.** Excluding a day from the intake mean
while the weight delta still spans that day implicitly assumes the excluded day's
intake equalled the mean of the complete ones. That is the right default, but it
fails in one specific case: a user who both under-logs *and* genuinely
under-eats for the same stretch. We assume they ate at their average, observe
real weight loss, and read the difference as a metabolic drop — then raise their
targets. `UnderLoggedRestriction` in the M4 synthetic-user suite exists solely to
measure the size and duration of that error.

---

## ADR-0008 — Day boundary semantics, fixed before the log model

**Status:** accepted (M0), consumed from M3.

**Context.** Lifters log at 1am; users travel. Both change which day an entry
belongs to, and retrofitting either after real log data exists is a migration.

**Decision.** Every log entry persists three things:

1. `timestamp` — the UTC instant.
2. `dayIndex` — the resolved logging day, per `DayKeyResolver`.
3. The `timeZoneIdentifier` and `dayStartHour` in force at write time.

`dayStartHour` is user-configurable in 0...11. Day keys are resolved **once, at
write time, and never recomputed**.

**Consequences.** Changing the day-start hour affects future entries only.
History does not silently re-bucket underneath targets that were already issued
against it, and the intake means behind past estimates stay reproducible.
Because (3) is persisted, an explicit, auditable "re-bucket history" action
remains possible in Settings; it is deliberately not automatic.

Travel produces genuinely skipped and genuinely doubled local days, and freezing
the key means the day the rule changed is longer or shorter than 24 hours. Any
code assuming `14 indices == 14 × 86400 seconds` is therefore wrong.
**ADR-0014 is the resolution of that**, and is required reading alongside this
record.

---

## ADR-0009 — Body mass carries provenance, and provenance decides lifecycle

**Status:** accepted (M0), implemented M4–M5.

**Context.** The entire TDEE engine rests on the weigh-in series. That series has
two sources with opposite storage requirements: weigh-ins typed into Caliper are
app-owned and must survive a device change; weigh-ins read from HealthKit are
HealthKit-derived and must not reach iCloud (Guideline 5.1.3).

**Decision.** Same measurement, two models:

| | `BodyMassEntry` | `ImportedBodyMass` |
|---|---|---|
| Source | Entered in Caliper | Read from HealthKit |
| Store | `Synced` | `Local` (`LocalOnlyModel`) |
| Key | App UUID | HealthKit sample UUID (`#Unique`) |
| New device | Restored from CloudKit | Re-read from HealthKit |
| Also written to HealthKit | Yes | n/a |

The trend engine consumes the union, deduped.

**Consequences.** Weigh-ins typed into Caliper survive a device change even if
the user revokes HealthKit access. Weigh-ins from a smart scale come back from
HealthKit on the new device. Neither path loses the series.

Two failure modes this creates, both of which get explicit M5 tests:

- **Self-import loop.** We write body mass to HealthKit, so an anchored query
  will hand our own writes straight back and duplicate the series. Every read
  must filter out samples whose source bundle identifier is Caliper's.
- **Same-day duplicates.** Multiple weigh-ins on one `DayIndex` are averaged
  before entering the trend, with Caliper-entered values taking precedence over
  an imported sample at the same instant.

---

## ADR-0010 — Least-squares slope, not endpoint differencing

**Status:** accepted (M0), implemented M4.

**Context.** §4 defines
`TDEE ≈ mean_intake − (Δtrend_weight_kg × 7700 / window_days)`. The formula is
correct — a loss makes `Δtrend` negative and correctly raises the estimate above
intake. The question is how `Δtrend` is measured.

**Decision.** `Δtrend` is the least-squares slope of the trend series across the
window, multiplied by the window length. Endpoint differencing is implemented
alongside it and retained as a comparison in the test suite only.

**Consequences.** Endpoint differencing discards every observation between the
two ends, so a single anomalous day at either boundary moves the estimate by the
full amount of the anomaly. That jitter is the visible failure of several
competitors. The regression uses the whole window and degrades gracefully when
one day is odd.

The M4 report must show the divergence between the two methods across all
synthetic users, so the choice is evidenced rather than asserted.

---

## ADR-0011 — Active energy never enters the calorie budget

**Status:** accepted (M0), permanent.

**Context.** §4's critical negative requirement.

**Decision.** `HKQuantityTypeIdentifier.activeEnergyBurned`,
`appleExerciseTime` and `appleMoveTime` are never requested for reading.
Workouts are read for context only and are labelled in the UI as not adjusting
the target.

**Consequences.** Caliper infers expenditure from intake versus weight trend.
Activity is already inside that relationship: a user who trains hard loses more
at a given intake, and the estimate rises to meet it. Adding a wearable's
active-energy figure on top credits the same session twice — the mechanism by
which MyFitnessPal reports ~520 kcal for a workout worth ~260.

Enforced three ways, because a comment alone will not survive six months:

1. `HealthKitTypeBoundaryTests` fails if the identifier enters the read set.
2. A SwiftLint custom rule (`active_energy_in_budget`) makes the identifier an
   error anywhere except the file that lists it as forbidden.
3. The rationale is written at the boundary in `App/Health/HealthKitTypes.swift`.

Users will ask why their workout did not increase their target. That answer
belongs in the UI, not in a support document.

---

## ADR-0012 — XcodeGen and SwiftLint as build tooling

**Status:** accepted (M0).

**Decision.** `Caliper.xcodeproj` is generated from `project.yml` and gitignored.
SwiftLint runs in CI with `--strict`.

**Consequences.** The project structure changes repeatedly across M0–M8, and a
hand-edited `project.pbxproj` is where silent corruption comes from. SwiftLint is
what turns §10's "no force unwraps outside tests, no `try?` swallowing errors"
into a red build rather than an aspiration; both are configured as errors, and
tests are excluded from the force-unwrap rule as §10 permits.

Neither ships in the app. Neither is an app dependency.

---

## ADR-0013 — CloudKit stays off until the entitlement exists

**Status:** accepted (M0).

**Context.** A `ModelConfiguration` requesting `.automatic` without a
provisioned iCloud entitlement fails at container initialisation, which would
make the app unlaunchable on any machine without a signing team.

**Decision.** `CaliperModelContainer.make(cloudKitEnabled:)` defaults to
`false`. The two-store split is fully in place regardless — only the attachment
to CloudKit is gated.

**Consequences.** The repo builds and tests on a fresh clone with no Apple
Developer Program membership, which is what keeps CI simple. Enabling sync is a
one-line change plus an entitlement. The separation guarantee does not depend on
the flag, so nothing about 5.1.3 compliance is deferred.

---

## ADR-0014 — Expenditure divides by elapsed time, not by a count of day keys

**Status:** accepted (M0), consumed at M4. Extends ADR-0008.

**Context.** Day keys resolve once and never recompute, which is right for
target integrity but means any change to the resolution rule produces a logging
day of anomalous length:

| Event | Day length |
|---|---|
| Day-start hour 00:00 → 04:00 | 28 hours |
| Day-start hour 04:00 → 00:00 | 20 hours |
| Sydney → London (August) | 33 hours |
| London → Sydney (August) | 15 hours |
| Daylight-saving transition | 23 or 25 hours |

A long day's intake is genuinely larger, which inflates the window's intake mean,
which inflates the expenditure estimate, which raises targets. The short return
leg does the reverse.

**Rejected: treat a seam day like an under-logged one** — drop it from the
intake mean, keep it in the weight-delta window. Two problems.

It under-counts. A 33-hour day's food was really eaten, and the weight change
across the window contains it. Excluding the day and imputing the mean
understates total intake while the weight delta still reflects it, so the
estimate is pulled down from both directions at once.

And the natural detection rule — flag when the resolved UTC offset changes —
fires on every daylight-saving transition. Every user in a DST country would lose
two days a year from the intake mean, to correct a one-hour distortion that is
4% of a day and well inside the noise the EWMA already absorbs.

**Decision.** The expenditure identity is

```
mean_intake − TDEE = Δweight × 7700 / elapsed
```

and `elapsed` is *time*, not a count of day keys. A 14-day window containing a
Sydney → London leg spans 14 days and 9 hours, and the user genuinely expended
14.375 days' worth of energy across it. So:

1. **The denominator is real elapsed time**, computed as
   `start(lastDay + 1) − start(firstDay)` from persisted boundary records. One
   subtraction, no special cases, no detection, exact for seams and DST alike.
2. **`DayBoundaryRecord`** persists the zone and day-start hour in force from a
   given day, written only when the policy changes. Day length is not derivable
   from log entries alone — a day with no entries still has a duration — and this
   is app-owned data, so it syncs.
3. **Seam detection serves the UI, not the maths.** Days departing from 24 hours
   by ≥ 2 hours are surfaced and explained. The threshold sits above every
   daylight-saving shift in use (one hour almost everywhere, thirty minutes on
   Lord Howe Island) and far below any timezone seam.

**Consequences.** Ignoring the correction on a single-leg window overstates the
per-day figures by about 2.7% — roughly 70 kcal a day on a 2,600 kcal
expenditure, sustained for a fortnight, in the direction that quietly stalls a
cut.

A round trip inside one window cancels exactly, which is the common case for a
short trip and produces no distortion at all. The error is real when only one leg
falls inside the window.

The short return leg matters more for copy than for maths. A 15-hour day looks
exactly like a day of under-logging, and reporting it as such would have the app
telling the user something untrue about their own behaviour — the precise thing
§1 rules out. Seam days are labelled with their cause, not with a scolding.

**Rejected: scaling a seam day's intake to a 24-hour equivalent.** Eating is not
uniform in time, and a 33-hour day containing a long-haul flight has thoroughly
atypical intake. Scaling would manufacture precision we have not earned.

**M4 owes evidence for this.** `SydneyLondonRoundTrip` joins the synthetic-user
suite — a mid-cut trip with both seams — reported under both the elapsed-time
denominator and the naive day-count one, so the choice is evidenced rather than
asserted. Same treatment as ADR-0010's endpoint-versus-regression comparison.

---

## ADR-0015 — Boundary observations are written per active day, and uncertainty is surfaced

**Status:** accepted (M0). Extends ADR-0014.

**Context.** ADR-0014 divides by real elapsed time, which requires knowing which
zone and day-start hour applied on each day. The first implementation wrote a
record only when the policy changed — and that fails on the case the mechanism
exists for. **The seam day is precisely the day the user is least likely to open
the app: they are on a plane.** With change-triggered writes, a missing record is
ambiguous between "nothing changed" and "nobody was looking", so an unobserved
33-hour day is indistinguishable from an ordinary one.

**Decision.**

1. **One observation per day the app is active**, upserted on scene phase
   `.active` and on `NSSystemTimeZoneDidChangeNotification` while running. Not on
   first log entry — a day the user opens without logging is still a day we
   watched. A few hundred bytes a year buys an unambiguous signal: **absence of a
   record means nobody was looking.**
2. **A policy change bracketed by a gap yields `Attribution.somewhereIn`**, not a
   guess. The seam carries its true total deviation, attributed to the range of
   days one of which absorbed it. `DaySeam.duration` is `nil` in that case,
   because no single day can honestly be named.
3. **`uncertainDays(given:)`** reports the runs whose boundaries cannot be pinned.
4. **`elapsed(across:)` refuses** when an endpoint falls inside such a run, rather
   than mis-dividing. **`anchor(_:given:)`** widens the window backwards to the
   last observed day, which restores exactness.

**Consequences.** The property that makes this tractable is that **total elapsed
time depends only on the window's two endpoints**, not on where inside it the
change fell. A window ending today always has a known later endpoint — the app is
open, or nothing would be asking. So an unobserved flight day costs the
*attribution*, not the estimate: a test asserts that sparse and dense observation
sets produce an identical denominator across the same seam.

Uncertainty therefore bites in exactly one place — a window whose *start* falls
inside an unobserved gap — and anchoring widens rather than narrows, because a
shorter window is a noisier estimate and the added days are real days with real
data. Only the record of which zone they were in was missing.

**Rejected: inferring the change time from other signals.** Location would need
a permission we deliberately do not request. HealthKit workout metadata carries a
time zone, but depends on the user wearing a watch and is not available until M5.
Neither is worth a dependency to recover an attribution that does not affect the
estimate.

---

## ADR-0016 — A seam day's targets scale with the day's real length

**Status:** accepted (M0), implemented at M4.

**Context.** ADR-0014 made the expenditure estimate correct across a 33-hour day.
The user-facing daily target is still 24 hours wide, so the adherence line reports
"400 over" on a day the user was not over. That is the same untruth ADR-0014
removed from the seam copy, one surface up — and on the surface people actually
look at.

**Decision.** Scale the day's energy and macronutrient targets by
`duration / 24h`, and annotate with the cause. Not one or the other: an
unexplained target of 3,438 kcal is its own kind of dishonesty.

Applies only above `DayDurations.seamThreshold`, the same two hours that governs
seam disclosure, so the target moves exactly when the app is willing to say why.
Daylight-saving days are left alone.

**Why this is not the intake scaling ADR-0014 rejected.** Scaling a day's
*intake* to a 24-hour equivalent invents a number — it asserts what the user would
have eaten in a day they did not live. Scaling the *target* is arithmetic on our
own output: expenditure is a rate, and a 33-hour day genuinely contains 1.375
days of it. Nothing is imputed.

**The interaction that would otherwise ship as a bug.** §4's safety clamps —
deficit never above 25% of expenditure, intake never below 1.1 × BMR — are
statements about a *daily rate*, not a day's total. A 15-hour return leg scales a
2,400 kcal target to 1,500, which trips the BMR floor even though the user is not
under-eating; the next day simply starts sooner. **Clamps are therefore applied to
the normalised 24-hour figure and the result is scaled, never the reverse.**
Clamping after scaling would silently inflate every short seam day's target and
make the app tell a traveller to eat more on the one day that needed it least.

**Uncertain seams are not scaled.** When attribution is `somewhereIn`, no
particular day's target can be adjusted. The adherence line is annotated with the
range instead. Scaling the wrong day is worse than scaling none.

**M4 owes:** the scaled target on both legs of `SydneyLondonRoundTrip`, shown
against the unscaled one, and the clamp ordering exercised on the short leg.
