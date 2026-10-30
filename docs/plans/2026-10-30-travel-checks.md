# Travel checks on every machine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The written program's zero and moves fit the X/Y travel, and the stock plus the highest Z fits the Z travel, on every post.

**Architecture:** `MotionChecker` gains a `checksTravel` flag (the program pass only), folds X0 Y0 into the X/Y window in
`finish()`, counts the touch-plate positions with `include(x:y:z:)`, and adds the Z envelope warning. `OthermillSetup` loses its
XY and Z checks.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** `docs/specs/2026-10-30-travel-checks-design.md`

## Global Constraints

- Goldens and `samples/expected` byte-identical; the samples test accepts no new warning prefix.
- `GCodeValidator` not weakened: every travel check on an exported program still runs, on the program pass.
- Machine Z through `MachineCoordinates` only; test material-top and spoilboard for Z.
- American spelling; `scripts/build.sh` / `scripts/test.sh`; never write a source file and test in one command.

## Review Focus

- A program whose first motion names X and Y (no accidental X0 Y0 visit) is still checked from its zero.
- A two-sided job's bottom side: its own Z zero (the exporter passes the side's job).
- A mm document on an inch post: the window in post units, after `carryExtents`.
- The editor's sample (`PostSampleJob.widened`) stays clean for every built-in.
- The tile at exactly the travel is not an error (eps).

---

### Task 1: The window, the touch-plate positions and the Z envelope

**Files:** Modify `Sources/PostCore/Validation/MotionChecker.swift`, `Sources/PostCore/Validation/GCodeValidator.swift`.
Test `Tests/PostCoreTests/PostValidatorTests.swift` (new `@Suite struct TravelWindowTests` at the end).

**Interfaces — Produces:** `MotionChecker.init(profile:job:jobUnits:units:checksTravel: Bool)`;
`mutating func include(x: Double?, y: Double?, z: Double?)`; `static let zEnvelopePrefix = "The stock plus the highest Z"`
(on `GCodeValidator`, public, so the samples test and Othermill tests can name it).

- [ ] **Step 1: Write the failing tests** (spec table rows; each XY row's first motion names X and Y or is a touch-plate
  program): `aShortCutFarFromTheZeroIsAnError` (`G0 X5.8 Y1 Z0.2`, cut to X6, 5.5 in travel → error containing
  `X travel 6.0000 in exceeds the machine's X travel 5.5000 in (the program's zero and its moves span X0.0000 to X6.0000)`);
  `theEdgeIsInsideInBothUnits` (X5.5 and X5.5 + eps/2 clean, X5.5 + 2 eps error; inch and mm); `centreOriginWindow`;
  `upperRightOriginIsClean`; `lowerRightAndUpperLeftAreClean`; `aDatumOffsetMovesTheWindow` (−2 … 3 clean, −2 … 4 error);
  `aMoveHomePastTheBedIsAnError`; `noMovesNoTravelError`; `theToolpathPassLeavesTravelToTheProgram` (`validate(toolpaths:)`
  of the X6 cut → no `travel-` message); `aUnitsSwitchKeepsTheZeroInTheWindow` (G20 X4…5 then G21 X140…150 → error);
  `theTouchOffSpotCountsInTheWindow` (probing Avid post, spot X5 clean, X6 error); Z: `theStockPlusHomeZWarns` (0.75 + 0.8 on
  1.35, both Z modes, message starts with `zEnvelopePrefix`), `aThroughCutCountsInTheZWarning` (1.33 travel → warning),
  `thePlateClearanceCountsInTheZWarning`, `exactlyTheZTravelIsClean` (inch and mm), `aZSpanErrorIsNotAlsoWarned`;
  `aCoordinateShiftSaysTravelChecksNoLongerApply` (`G92 X0` → warning contains `depth and travel checks no longer apply`).

- [ ] **Step 2: Run** `scripts/test.sh --filter TravelWindowTests`. Expected: compile failure (`include`, `zEnvelopePrefix`), then
  after a stub, the XY and Z rows FAIL.

- [ ] **Step 3: Implement.** `finish()`: when `checksTravel`, X/Y window ends `lo = min(minP, 0)`, `hi = max(maxP, 0)`, error
  if `hi − lo > travel + eps` with the spec's message; Z span unchanged; Z envelope `maxP.z − min(minP.z,
  coords.materialBottomZ)` > `zTravel + eps` → warning key `z-envelope` unless `travel-Z` fired. `include` updates `minP`/`maxP`
  per known coordinate (an unknown axis keeps its extents; the first include of an axis seeds it). `validate(toolpaths:)`
  passes `checksTravel: false`; both checkers in `validate(gcode:)` pass `true`; after a consumed probe effect,
  `check.include(x: effect.xy?.x, y: effect.xy?.y, z: effect.z)`. The shift message (line 226) reads `…; depth and travel
  checks no longer apply`.

- [ ] **Step 4: Run** `scripts/test.sh --filter "TravelWindowTests|PostValidatorTests|PostRobustnessTests|ProbeValidatorTests"`.
  Expected: PASS.

- [ ] **Step 5: Commit** `feat(post): travel checks bound where the program goes, and the Z envelope, on every post (#119)`.

### Task 2: Othermill, the export and the docs

**Files:** Modify `Sources/PostCore/Validation/OthermillSetup.swift` (drop the XY bound, the Z envelope, `extents`,
`zEnvelopeWarningPrefix`, and the `moves`/`toolpaths`/`approachHeight` parameters), `Sources/LoftLineApp/Model/GCodeExporter.swift:185`,
`Tests/PostCoreTests/OthermillSetupTests.swift` (the #114 XY/Z tests move to `TravelWindowTests` as Othermill-post G-code cases),
`Tests/LoftLineAppTests/LoftLineCLITests.swift` (prefix list unchanged in meaning), `Tests/LoftLineAppTests/PreflightChecksTests.swift`
or a new export test, `docs/DECISIONS.md`, `TESTING.md`, `docs/PARITY.md`.

- [ ] **Step 1: Write the failing export tests:** `aCutPastTheBedIsOneErrorAndSaveAnywayWrites` (export of a 5.5 in machine
  job with a cut at X6: exactly one `travel-X` error, `text` non-nil); `tilesExactlyTheTravelWideAreClean` (11 × 4.5 job on a
  5.5 × 4.5 machine, pocket across the tile edge, `TiledExport` default tiles: no `travel-` issue on either tile);
  `theEditorSampleStaysClean` (`PostDraftReport.make` of Avid inch and Othermill inch: `canSave`). Run; the first fails on
  today's code only if the toolpath pass still reports (expected: two messages in mm-on-inch; use an mm document).
- [ ] **Step 2: Trim `OthermillSetup`** and its call; move the #114 tests; run `scripts/test.sh --filter
  "OthermillSetupTests|TravelWindowTests|LoftLineCLITests|PreflightChecksTests"`. Expected: PASS.
- [ ] **Step 3: Docs:** DECISIONS `travel-checks-all-machines` (the window, the zero not the stock, the per-origin table, the
  program pass, the touch-plate positions, the `?? 0` note, error vs warning); TESTING air-cut travel note; PARITY row. Commit
  `refactor(post): Othermill keeps only its own setup checks (#119)` and `docs: travel checks on every machine (#119)`.
- [ ] **Step 4:** `scripts/build.sh`, then `scripts/test.sh`. Expected: every `Test run with N tests` line passes; no sample diff.
