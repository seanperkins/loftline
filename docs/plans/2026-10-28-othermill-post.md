# Othermill Pro posts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Built-in Othermill posts and machines, with export checks for the setup the Bantam software assumes (#114).

**Architecture:** Two data-only `PostProfile`s and two `MachineDefinition`s; one PostCore check, `OthermillSetup`, called
from `GCodeExporter.export` beside `ToolChangeZ.warning`; the optional-stop rule from #115 extended by id.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** docs/specs/2026-10-28-othermill-post-design.md (revision 4)

## Global Constraints

- Existing goldens and `samples/expected/<existing post>/` stay byte-identical; `GCodeValidator` is not weakened.
- Ids `othermill-inch`, `othermill-mm`, `othermill-pro`, `othermill`; extension `gcode`.
- Build and test only through `scripts/build.sh` and `scripts/test.sh`; never write a source file and run tests in one command.
- Tolerances: lengths 0.0005 in / 0.01 mm, feeds the same per minute, RPM exact.

## Review Focus

1. A job with Z zero, origin and datum right but a clamp raising the approach above Home Z: the Z-envelope warning fires (Task 3 test).
2. An mm document with the inch post at exactly 5.5 × 4.5 in: no XY error from rounding (Task 3 test).
3. A tiled Othermill export (datum offset nil, cell-sized job): no setup error (Task 3 test).
4. A user post file reusing `othermill-inch` with bigger limits and no machine: the limits warning fires (Task 3 test).
5. The samples corpus: Othermill pairs print only `OthermillSetup` warnings; any other message on any post still fails (Task 3 test).

---

### Task 1: Posts, machines and their goldens

**Files:** Modify `Sources/PostCore/Profiles/BuiltInPosts.swift`, `Sources/PostCore/Model/MachineDefinition.swift`
(`BuiltInMachines` and its doc comment), `Tests/PostCoreTests/PostGoldenTests.swift`, `Tests/PostCoreTests/MachineConfigTests.swift`
(machine lists); create `samples/expected/othermill-inch/`, `othermill-mm/` via `scripts/check-samples.sh --update`.

**Produces:** `BuiltInPosts.othermillInch`, `.othermillMM` (in `all`, after the LinuxCNC posts); `BuiltInMachines.othermillPro`,
`.othermill` (in `all`, Pro first).

- [ ] **Step 1: Failing tests.** In `PostGoldenTests`:
  - `newPosts` rows `othermill-inch` (`G20`, `G0 Z0.2000`, preamble `["G90","G94","G17","G55"]`, tool change
    `["M5", "(\(endMillChange))", "T1 M6"]`, footer tail `["G0 Z0.8000","M5","G0 X0.0000 Y0.0000","M30"]`) and `othermill-mm`
    (`G21`, `G0 Z5.080`, same lines, footer `G0 Z20.320` … `G0 X0.000 Y0.000`, `M30`).
  - `newPostNumbers` rows: inch 5.5/4.5/1.35/0.01, rapid and feed 100, RPM 7000–26000, arcTolerance 0.0005, decimals 4/1;
    mm 139.7/114.3/34.29/0.254, 2540, 7000–26000, 0.01, 3/0; name "Othermill (inch)"/"Othermill (mm)", ext `gcode`.
  - `othermillWritesNoForbiddenCode`: for both posts, no line's words include `G40`, `G49`, `G91.1`, `G43`, `G53`, `G28`, `M7`,
    `M8`, `M9`, `M4` (parse with `GCodeParser`); the program contains `G4 P4`.
  - `othermillLinearisesHelices`: a `PostJob` with one helical `.arcCW` (start Z 0, end Z −0.1) posts no `G2`/`G3`.
  - `othermillArcsSweepAtMost180`: every `G2`/`G3` in the two posts' `samples/expected` programs has sweep ≤ π + 1e-9
    (`ArcGeometry.sweep`).
  - `goldenProgramsPassTheValidator`: for ids in `["othermill-inch","othermill-mm"]` validate against
    `BuiltInMachines.avidPRO6096.applied(to: p)` (bytes unchanged); add `othermillOwnLimitsPassTheValidator` with a
    4 × 3 × 0.25 in job (one profile inside it, home (0,0), Home Z 0.5) validated against the post's own limits: no issues.
  - `MachineConfigTests`: `othermill-pro` (5.5/4.5/1.35/0.01 in, 8500–26000, 100/100) and `othermill` (5.5/4.5/1.25/0.01 in,
    7000–16500, 60/60) both list both posts; `BuiltInMachines.all` order puts the Pro before the original.
- [ ] **Step 2:** `scripts/test.sh --filter "PostGoldenTests|MachineConfigTests"` → FAIL (`profile(id:)` nil, machines missing).
- [ ] **Step 3:** Add the posts (spec Decision 1: `helicalArcs: false`, `spindleDwellSeconds: 4`, `arcOutput: .incrementalIJ`,
  `footer` the standard one with `M30`) and the machines (Decision 6); fix the `BuiltInMachines` doc comment.
- [ ] **Step 4:** Same filter → PASS. `scripts/check-samples.sh --update`; `git status samples/` shows only the two new
  folders (four files). Read one by eye.
- [ ] **Step 5:** `scripts/test.sh` green except the CLI samples test, which Task 3 settles (expected: it fails on the
  Othermill pairs only when Task 3's warnings exist, so it passes here). Commit `feat(post): built-in Othermill posts and machines (#114)`.

### Task 2: Optional stop by id, neutral wording

**Files:** Create `Sources/PostCore/Validation/OthermillSetup.swift` (just `public static let postIDs`); modify
`Sources/PostCore/Model/PostProfile.swift` (`honoursOptionalStop` and its doc), `Sources/LoftLineApp/Panels/Toolpaths2DForms.swift`,
`Sources/LoftLineApp/Model/JobSheet.swift`, `Sources/LoftLineApp/Model/HelpTopics.swift`; tests `PostPauseTests`, `PauseStepTests`.

**Produces:** `OthermillSetup.postIDs: Set<String>`; `honoursOptionalStop` false for those ids before the GRBL rule.

- [ ] **Step 1: Failing tests.** `PostPauseTests.optionalStopOnAnOthermillPostWritesM0`: both posts as built, Pro-applied, and
  an edited copy keeping the id (footer appended) write `M0`, never `M1`, header `[M0]`. `PauseStepTests`: the GRBL job-sheet
  expectation becomes "(always stops, M0: no Optional Stop on this controller)", and an Othermill post gives the same text.
- [ ] **Step 2:** `scripts/test.sh --filter "PostPauseTests|PauseStepTests"` → FAIL.
- [ ] **Step 3:** Implement; the toggle label "Optional stop (always stops here, M0)" and help "This controller has no
  Optional Stop, so this post writes M0: the machine always stops here" when `!honoursOptionalStop`; Help's pause paragraph
  says the same without naming GRBL or "ignores M1". Doc comments in the three files follow.
- [ ] **Step 4:** Same filter → PASS; `scripts/test.sh` green. Commit `feat(post): an Othermill optional stop writes M0; neutral wording`.

### Task 3: `OthermillSetup.issues` at export

**Files:** Modify `Sources/PostCore/Validation/OthermillSetup.swift`, `Sources/LoftLineApp/Model/GCodeExporter.swift` (one line
beside `ToolChangeZ.warning`, passing `doc.job`, `doc.units`, `checked`, `toolpaths`, `profile`),
`Tests/LoftLineAppTests/LoftLineCLITests.swift` (the samples filter); create `Tests/PostCoreTests/OthermillSetupTests.swift`,
and one export test in `Tests/LoftLineAppTests/` (existing exporter test file).

**Interfaces:** `public static func issues(job: JobSetup, units: LengthUnit, moves: [Toolpath], toolpaths: [Toolpath],
profile: PostProfile) -> [GCodeIssue]`; `public static let warningPrefixes: [String]` (the two warnings' opening words).

- [ ] **Step 1: Failing tests** (`OthermillSetupTests`, inch and mm documents; spec Tests list): errors for spoilboard Z zero,
  each of the four non-lower-left origins, datum (0.5, 0); none for nil or zero datum; an XY error for a move at X 6 on the
  Pro-applied post and for a home move at X 6 with 5 in stock; none at exactly 5.5 × 4.5 (inch doc + mm post, mm doc + inch
  post); one coolant error naming two toolpaths; no issues for `genericGRBLMM`; checked for Pro-applied, a project-copy-equal
  and an edited same-id post; the limits warning for the Avid-applied post, a user file reusing the id with xTravel 24 and no
  machine, a Pro-sized machine with maxRPM 30000, with maxFeed 600, with rapid 200 alone, with minRPM 6000 alone; none for
  the Pro and the original machines applied, both units; Z envelope: 0.75 stock + move at Z 0.8 warns, 0.25 + 0.5 quiet,
  0.75 + 0.6 quiet, 0.75 stock with a move at Z 0.7 and Home Z 0.5 warns, and the mm equivalents. Export test: a
  spoilboard Othermill job through `GCodeExporter.export` returns text and an error issue. A two-sided job's bottom side with
  spoilboard zero errors (through `TwoSidedSupport.sideProject`).
- [ ] **Step 2:** `scripts/test.sh --filter "OthermillSetupTests"` → FAIL (no `issues`).
- [ ] **Step 3:** Implement per spec Decision 2; built-in numbers from `BuiltInPosts.profile(id:)` converted to `units`; the
  XY check uses max X/Y over every move's points (arcs by their end points and centres' extents via `ArcGeometry`), Z from the
  highest move Z.
- [ ] **Step 4:** Filter → PASS. Change the CLI samples filter to accept `warningPrefixes` only when `post.id` is in
  `OthermillSetup.postIDs`; `scripts/test.sh` green. Commit `feat(post): Othermill setup checks at export`.

### Task 4: Docs

**Files:** `docs/DECISIONS.md` (`othermill-post`), `Sources/LoftLineApp/Model/HelpTopics.swift` (Machines, Coolant),
`TESTING.md` (Othermill owner check: the spec's owner list, a two-tool file first), `docs/PARITY.md` (`io-post-processors`),
`README.md` (post list), and a #114 comment answering the nine facts (after merge).

- [ ] **Step 1:** Write them per the spec's Docs section. `scripts/build.sh` and `scripts/test.sh` green.
- [ ] **Step 2:** Commit `docs: Othermill posts (decisions, help, testing, parity, readme)`.
