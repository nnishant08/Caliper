# Caliper

**Caliper — Macros & Lifting.** A nutrition-first cut/recomp app for iOS: honest
numbers, stated with their real uncertainty, for people who already know what
they're doing.

No streaks. No badges. No confetti. When the expenditure estimate hasn't earned
confidence yet, the app says so rather than showing a number it can't support.

---

## Status

**M0 — scaffold.** Repo, packages, CI, and the architectural boundaries that
later milestones build inside. No product features yet.

| Milestone | | |
|---|---|---|
| M0 | Repo scaffold, NutritionKit, CI | **current** |
| M1 | Data pipeline; snapshot generated locally | |
| M2 | Snapshot download, FTS5 search, barcode lookup, attribution UI | |
| M3 | Logging loop against the §5 speed budgets | |
| M4 | Weight trend, adaptive TDEE, weekly targets | |
| M5 | HealthKit read/write, idempotent sync, CloudKit boundary | |
| M6 | Lift log | |
| M7 | Widgets, App Intents, Lock Screen | |
| M8 | Paywall, onboarding, privacy policy, TestFlight | |

---

## Getting set up

Requires Xcode 26 with an iOS simulator runtime, and Homebrew.

```bash
brew install xcodegen swiftlint
Scripts/bootstrap.sh
```

If `xcodebuild` reports that it "requires Xcode, but the active developer
directory is a command line tools instance":

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

The scripts set `DEVELOPER_DIR` themselves and work either way; the global switch
is for your own terminal and for Xcode's own tooling.

If no simulator runtime is installed, `xcodebuild -downloadPlatform iOS` fetches
one (~8.5 GB).

## Running the tests

```bash
Scripts/test.sh
```

Boundaries, both Swift packages, SwiftLint, then the iOS app tests.
`Scripts/test.sh packages` runs just the package suites — no simulator needed.

---

## Layout

```
App/                  the iOS app
  Persistence/        SwiftData stack, day-boundary resolution
  Health/             the HealthKit boundary
Packages/
  NutritionKit/       trend, expenditure, targets — Foundation only, no calendars
  LiftKit/            lift log — stub until M6
Tests/CaliperAppTests/
tools/snapshot/       offline food-database pipeline (M1)
Docs/
  DECISIONS.md        architecture decision records — read this first
  LICENSING.md        ODbL, attribution, and the separation that keeps it clean
  SPEED_BUDGET.md     §5 logging-speed criteria and how actions are counted
Scripts/
```

---

## Three rules that are not up for quiet revision

Each is enforced mechanically, because a comment does not survive six months.

**Active energy never enters the calorie budget.** Expenditure is inferred from
intake versus weight trend, which already contains activity. Reading a wearable's
active-energy figure back in double-counts every workout.
→ `HealthKitTypeBoundaryTests`, a SwiftLint custom rule, ADR-0011.

**Open Food Facts data is never merged with anything else.** Separate stores,
read-only handle, corrections as deltas. This is what keeps ODbL share-alike from
reaching user data.
→ `Docs/LICENSING.md`, ADR-0004, ADR-0005.

**HealthKit-derived data never reaches iCloud.** Guideline 5.1.3. Two SwiftData
configurations with disjoint schemas; the local one is never CloudKit-backed.
→ `ModelSeparationTests`, `Scripts/check-boundaries.sh`, ADR-0002.
