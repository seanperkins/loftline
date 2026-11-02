# Ramps Keep Their Maximum Angle: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No ramp is steeper than its maximum angle without a warning. The spiral ramp gets as much
length as the angle needs.

**Architecture:** `PassShaping.pass` computes each ramp's length and sets
`ChainPass.isSteeperThanMaxAngle` from the slope it actually has. `ProfileOperation` and `PocketOperation`
turn the flag into one warning sentence.

**Tech Stack:** Swift 6, SwiftPM, swift-testing. Run everything through `scripts/build.sh` and `scripts/test.sh`.

**Spec:** `docs/specs/2026-11-01-ramp-angle-design.md` (revision 4, approved)

## Global Constraints

- The warning text is fixed by the spec:
  `"ramps go down steeper than the <a>° maximum angle on some passes (the vector is too short, or the angle is under 0.5°); use a plunge, a steeper maximum angle, or a shallower pass depth"`,
  with `<a>` = `String(format: "%g", ramp.maxAngle)`.
- The flag rule: `slope > requested · (1 + 1e-9)`, where `requested = maxAngle ≤ 0 ? 0 : tan(min(maxAngle, 89.5)°)`.
- On a loop with `drop / tanA ≤ L`, the spiral's points must be identical to today's.
- Never write a source file and run tests in the same shell command.

## Review Focus

- **Spiral on a loop exactly one lap long.** `length = L` exactly, so the output is unchanged. Covered by
  the long-loop equality test.
- **Pocket multi-pass on a short loop.** It now retracts between passes. The final review checks that the
  pocket ramp tests still pass, and that `conventionViolations` stays empty.
- **`maxAngle` 0 or negative.** `requested = 0`, so any ramp that runs warns. A test pins this in Task 1.
- **The last-pass loops of a profile.** They go through the same `cut`, so they are covered by the
  profile tiny-loop test.
- **A warning added by `AnyOperation` after the steep sentence.** Tests call `op.generate`, where the steep
  sentence is last.

---

### Task 1: PassShaping computes ramp length and flags steep ramps

**Files:**
- Modify: `Sources/CAMCore/Ops2D/Support/PassShaping.swift`
- Create: `Tests/CAMCoreTests/Ops2DRampAngleTests.swift`
- Modify: `Tests/CAMCoreTests/Ops2DSmoothRampAngleTests.swift`. Move its `circle(radius:sides:)` and its
  steepest-slope loop into a file-level helper `steepestSlope(_ pass: ChainPass) -> Double` in the new
  file. Make `circle` internal there, and have the smooth test use both.

**Interfaces:**
- Produces:
  - `ChainPass.isSteeperThanMaxAngle: Bool` (default `false`);
  - `PassShaping.steepRampWarning(_ ramp: RampSettings) -> String`;
  - `PassShaping.maxRampLaps`, the renamed `maxSmoothLaps`.

- [ ] **Step 1: Write the failing tests** in `Ops2DRampAngleTests.swift`:
  - `spiralRampNeverGoesDownSteeperThanTheMaximumAngle(radius:drop:)`
    - Arguments: `[0.125, 0.5, 4.0] × [0.25, 0.6]`.
    - `steepestSlope ≤ tan 10° + 1e-9`.
    - The last depth equals the drop.
    - With `spiralFinish` (the default), the length cut at depth is `≥ L − 1e-9`.
  - `spiralRampOnALongLoopIsUnchanged(s0:finish:)`
    - Arguments: `[0, 0.37] × [false, true]`, on radius 4, drop 0.25, overcut 0.1.
    - Build the expected pieces with the old formulas: `chain.samples(from: s0, to: s0+L) { fromDepth + drop*(s-s0)/L }`,
      then the flat lap `s0+L … s0+2L+0.1` when `finish`.
    - Every station matches in `xy`, `s` and `depth` (`< 1e-9`).
    - `endS` is `s0+L`, or `s0+2L+0.1` with `finish`.
  - `spiralRampEndsWhereItsLengthSays()`
    - Radius 0.125, drop 0.25, 10°, so `length = 0.25/tan 10°`.
    - Without finish: `endS ≈ length` and the last depth is 0.25.
    - With finish and overcut 0.1: `endS ≈ length + L + 0.1`.
  - `aRampTooShortEvenAtTheCapIsFlagged(type:)`
    - Arguments: `[.spiral, .smooth, .zigzag]`.
    - A 0.0015 in square, drop 0.25, 10°: the flag is true.
  - `aRampUnderTheFloorIsFlagged(type:)`
    - Radius 1, drop 0.25, `maxAngle: 0.2`: the flag is true.
  - `aGentleRampIsNotFlagged(type:)`
    - At 10° on radius 1, drop 0.25: false.
    - At `maxAngle: 0.2` on radius 4, drop 0.05, length 25: false.
  - `aZeroAngleRampIsFlagged()`
    - Smooth, `maxAngle: 0`, radius 1, drop 0.1: true.
  - `tabsKeepTheFlag()`
    - Take the flagged smooth pass on a radius 1 loop, `maxAngle: 0.2`, drop 0.25.
    - Apply `TabLayout(loopLength: L, centers: [L/2], settings: TabSettings(isEnabled: true, thickness: 0.1), toolDiameter: 0.25, cutDepth: 0.25)`.
    - The result is still flagged.
  - `steepRampWarningFormatsTheAngle()`
    - `steepRampWarning(RampSettings(maxAngle: 7.5))` contains `"the 7.5° maximum"`.
    - For 10 it contains `"the 10° maximum"`.
    - The whole string equals the spec sentence for 10.
- [ ] **Step 2: Run** `scripts/test.sh --filter RampAngle`. Expected: a build failure (no `isSteeperThanMaxAngle`
  or `steepRampWarning`).
- [ ] **Step 3: Implement it in `PassShaping.swift`**:
  - Move the `pass(...)` parameter doc block above `pass`.
  - Rename `maxSmoothLaps` to `maxRampLaps`, and update its doc comment.
  - Add `descentLength(asked:L:drop:tanA:)` for spiral and smooth.
  - Change the zig-zag to `wanted` as a `Double`, capped before `Int`.
  - Set `isSteeperThanMaxAngle` from the slope in each ramp branch, using the spec's rule.
  - Add `steepRampWarning`.
  - Update the `maxAngle` doc comment at `CommonParameters.swift:25`.
- [ ] **Step 4: Run** `scripts/test.sh --filter "RampAngle|SmoothRamp|Ops2DProfile|Ops2DPocket|CutDirection"`.
  Expected: all pass.
- [ ] **Step 5: Commit** `fix(cam): spiral ramps keep their maximum angle, and a ramp that can't is flagged (#124)`.

### Task 2: Profile and pocket warn about steep ramps

**Files:**
- Modify: `Sources/CAMCore/Ops2D/ProfileOperation.swift`. Rename `TabNotes` to `CutNotes` and `tabNotes`
  to `cutNotes`, add `steepRamp`, set it at both `PassShaping.pass` call sites, append the warning last,
  and rewrite the doc comment.
- Modify: `Sources/CAMCore/Ops2D/PocketOperation.swift`. `emit` returns `(toolpath:, steepRamp:)`. OR the
  flags from every call, and append the warning last before the assignment.
- Test: `Tests/CAMCoreTests/Ops2DProfileTests.swift`, `Tests/CAMCoreTests/Ops2DPocketTests.swift`

**Interfaces:**
- Consumes: `ChainPass.isSteeperThanMaxAngle` and `PassShaping.steepRampWarning(_:)` from Task 1.

- [ ] **Step 1: Write the failing tests:**
  - `ops2DProfileWarnsWhenATinyLoopCannotKeepTheRampAngle`
    - Profile `.on` a closed circle 0.02 in across. Build it from 64 points, or from `Path` circle if
      the fixture has one.
    - Depth 0.5, a spiral ramp at `maxAngle: 0.5`.
    - `metadata["warning"]` has the suffix `steepRampWarning(ramp)`.
  - `ops2DProfileWarnsWhenAShortOpenVectorCannotKeepTheRampAngle`
    - An open line 0.05 in long, `side: .on`, a zig-zag ramp at `maxAngle: 0.5`.
    - The warning contains the sentence.
  - `ops2DProfileWithoutASteepRampHasNoRampWarning`
    - A 4 in square with a spiral at 10°: no warning.
  - `ops2DProfileSpiralRampKeepsItsAngleOnASmallHole(mode:)`
    - Arguments: both Z modes.
    - An inside profile of a 3/8 in circle, depth 0.5, a spiral at 10°.
    - Every descending feed with horizontal run `> 1e-9` is at most 10° + 1e-6.
    - It reaches depth 0.5. Model it on `ops2DProfileSmoothRampAvoidsVerticalPlunges`.
  - `ops2DPocketWarnsOnceWhenARampCannotKeepItsAngle`
    - Pocket `F.rect(0,0,3,3)` and `F.rect(6,0,0.2,3)`, with `clearanceToolID: F.bigEndMill.id`.
    - A smooth ramp at `maxAngle: 0.2`.
    - The result is 2 toolpaths.
    - The last one's warning contains "1 region(s) too small for the tool" and has the suffix of the sentence.
    - The first has `metadata["warning"] == nil`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "Ops2DProfile|Ops2DPocket"`. Expected: the new tests fail.
  The Z-mode test fails on today's code only if Task 1 is reverted, and it passes after Task 1, so it is a
  regression guard. Ruling: it already passes at this point, because Task 1 is in.
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** `scripts/test.sh --filter "Ops2D|RampAngle|SmoothRamp"`. Expected: all pass.
- [ ] **Step 5: Commit** `fix(cam): profiles and pockets warn when a ramp is steeper than its maximum angle (#124)`.

### Task 3: Docs, then the full suite

**Files:** `docs/DECISIONS.md` (new entry `ramp-angle-laps`, as the spec's Docs section says), and
`Sources/LoftLineApp/Model/HelpTopics.swift` (lines :460 and :497).

- [ ] **Step 1:** Write the DECISIONS entry and the two help strings exactly as the spec gives them.
- [ ] **Step 2:** Run `scripts/build.sh`, then `scripts/test.sh` in a separate command. Expected: every
  "Test run with N tests" line passes, apart from the known #130 flake
  (`SaveConfirmationTests.aPipeInTheFilesPlaceIsNotWaitedOn`), which is rerun alone.
- [ ] **Step 3:** Run `scripts/check-samples.sh`. Expected: unchanged, since no sample enables a ramp.
- [ ] **Step 4: Commit** `docs: ramps keep their maximum angle (#124)`.
