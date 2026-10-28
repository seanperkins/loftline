# ShopBot G-code, Syntec and Haas posts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Built-in ShopBot G-code (inch), Syntec and Haas posts (#106, #110, #111) and the engine options they need: a
program wrapper (`prelude`), G70/G71 units words, `{DECIMAL_SECONDS}`, `{APPROACH_Z}`, schema version 3.

**Architecture:** Two optional `PostProfile` fields and two placeholders, written by `ProgramBuilder`/`GCodeWriter`, read by
the validator, reader and draft report; family rules in `BuiltInPosts` sets, `dwellProblem`/`postProblem` and
`DialectChecks`; five data-only posts.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** docs/specs/2026-10-28-shopbot-syntec-haas-posts-design.md (revision 4; its Rulings override the body)

## Global Constraints

- Existing goldens and `samples/expected/<existing post>/` stay byte-identical (`scripts/check-samples.sh` with no `--update`
  until Task 6); `GCodeValidator` is not weakened.
- Build and test only through the scripts; never write a source file and run tests in one command.
- Placeholder and field names exactly as the spec: `prelude`, `unitsCodes`/`UnitsCodes.g70g71`, `{DECIMAL_SECONDS}`,
  `{APPROACH_Z}`, `writesDwell(seconds:)`, `postProblem`, `noSpindleSpeedIDs`, `oneGWordIDs`.

## Review Focus

1. A Syntec copy read with `fromJSON` whose dwell is `G4 P{DECIMAL_SECONDS}` or whose G43 line is `Z{SAFE_Z}`: refused at
   post (Task 3).
2. An inch Syntec program shown on a mm job: the Export sheet's deepest cut is right (Task 4).
3. A ShopBot copy that declares a controller and is used on a probing machine: refused, never a multi-G line (Task 6).
4. A user post with line numbers and a `%` footer line: `%` unnumbered, nothing else moves (Task 2).
5. A 0.0004 s peck dwell on Haas: no `G4` line, and the validator does not warn about the hole (Tasks 2, 4).

---

### Task 1: Fields and schema version 3

**Files:** `Sources/PostCore/Model/PostProfile.swift`; `Tests/PostCoreTests/SnapshotTests.swift`.

**Produces:** `public var prelude: [String]?`, `public enum UnitsCodes: String, Codable, Sendable { case g70g71 }`,
`public var unitsCodes: UnitsCodes?`; `unitsCode` → `G70`/`G71` when set; `normalized` maps an empty prelude to nil;
`currentSchemaVersion = 3`; `requiredSchemaVersion` 3 when prelude non-empty, `unitsCodes != nil`, or any template (prelude,
preamble, toolChange, toolLengthOffset, spindleOn, dwell, footer, pause) contains `{DECIMAL_SECONDS}` or `{APPROACH_Z}`.
Both fields are `var` with nil defaults, not init parameters (built-ins set them in a closure, as other posts' extras).

- [ ] Step 1: tests in SnapshotTests: pinned version 3; `requiredSchemaVersion` 3 for each trigger (one test each), 2 for a
  `{MILLISECONDS}` dwell, 1 for Avid; a JSON with `schemaVersion: 4` refused; `normalized` of `prelude: []` is nil; a post with
  `unitsCodes = .g70g71` round-trips through `toJSON`/`fromJSON` equal; `unitsCode` is `G71` for a mm `.g70g71` post.
- [ ] Step 2: `scripts/test.sh --filter Snapshot` → FAIL (no member `prelude`).
- [ ] Step 3: implement. Step 4: PASS; full suite green. Commit `feat(post): post fields for a program wrapper and G70/G71 units; schema version 3`.

### Task 2: Writing them

**Files:** `Sources/PostCore/Processor/{ProgramBuilder,GCodeWriter}.swift`, `Sources/PostCore/Model/PostProfile.swift`;
test `Tests/PostCoreTests/PostEngineOptions2Tests.swift` (new).

**Produces:** `GCodeWriter.raw(_:)` (unnumbered append); `append` never numbers a trimmed `%`; prelude rendered with
`baseValues()` and written first through `raw`; `baseValues()["APPROACH_Z"] = fmt(approachZ)`;
`dwellValues(seconds:)["DECIMAL_SECONDS"] = NumberFormat.fixed(seconds, decimals: 3)`;
`public func writesDwell(seconds: Double) -> Bool` = the dwell template renders with a non-zero number (seconds > 0 and the
template's placeholder value parses to a value ≠ 0); `GCodeWriter.dwell` uses it.

- [ ] Step 1: tests: prelude `["%", "O1000", "(X)"]` with `lineNumbers` on → first three lines exactly those; footer `%`
  unnumbered with numbers on, other footer lines numbered; `G4 X{DECIMAL_SECONDS}` with 3 s → `G4 X3.000`, 0.25 → `X0.250`;
  `{APPROACH_Z}` in a tool length line → approach height (job approach 1.5, safe Z 0.5, material-top and spoilboard) and safe
  Z with no approach height; 0.0004 s toolpath dwell writes no G4 for `{SECONDS}`, `{MILLISECONDS}`, `{DECIMAL_SECONDS}`, 0.001
  s writes one for each; Avid golden unchanged.
- [ ] Step 2: `scripts/test.sh --filter PostEngineOptions2` → FAIL. Step 3: implement. Step 4: PASS; full suite and
  `scripts/check-samples.sh` green. Commit `feat(post): program wrapper, {APPROACH_Z} and {DECIMAL_SECONDS}; skip a dwell that prints as zero`.

### Task 3: Dwell form rules

**Files:** `Sources/PostCore/Model/PostProfile.swift`, `Sources/PostCore/Processor/ProgramBuilder.swift`; test
`PostEngineOptions2Tests.swift`.

**Produces:** `dwellForm(_ template: String) -> (letter: Character, placeholder: String)?` (spaces and leading zeros ignored,
either order); `dwellProblem` compares a family's form with its built-in's (message from the spec for X); refuses
`{DECIMAL_SECONDS}` after a letter other than X and X with any other placeholder, for every post; the "`{SECONDS}` elsewhere"
rule applies when the dwell is not `P{SECONDS}` and walks `prelude`. (`postProblem`, the G43 form, needs the Syntec and Haas
ids: Task 6.)

- [ ] Step 1: tests: Avid copy with `G4 X{DECIMAL_SECONDS}` refused; any post with `G4 P{DECIMAL_SECONDS}` or `G4 X{SECONDS}`
  refused; MASSO copy with `{SECONDS}` in its prelude refused; `fromJSON` of such a post then `post` throws `invalidPost`;
  every built-in has nil `dwellProblem` and `postProblem`.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS; full suite green. Commit `feat(post): dwell form and tool length rules by family`.

### Task 4: Readers (validator, reader, probe checker, deepest cut)

**Files:** `Sources/PostCore/Validation/{GCodeValidator,ProbeSequenceChecker}.swift`, `Sources/PostCore/Support/GCodeReader.swift`,
`Sources/LoftLineApp/Model/DeepestCut.swift` and its caller in `GCodeExporter.swift`; tests in
`PostEngineOptions2Tests.swift` and `Tests/LoftLineAppTests` (DeepestCut).

**Produces:** validator: for a `.g70g71` profile, 70/71 are units (inch/mm) and not `unknown-g`; `no-units` message names
the post's words; the toolpath check forgets a hole only when `profile.writesDwell(seconds:)`. Reader: a G4 with X dwells X
seconds unscaled; one warning on the first G70/G71 (text from spec E2). ProbeSequenceChecker: a G4 block skips every move
rule. `DeepestCut.find(in:job:units:postUnits:)` passes `assumedUnits: postUnits`.

- [ ] Step 1: tests: `.g70g71` inch program with `G70` → no `no-units`/`unknown-g`, `G71` in it → `units-mismatch`; Avid
  profile on `G70` → `unknown-g`; `G4 X3.000` → reader dwell 3 s in a mm program, no segment move to X3, validator no bounds
  issue; reader warns on G70; a 0.0004 s peck dwell on a Haas-like `{MILLISECONDS}` profile → no re-entry warning beyond what
  the same program without the dwell gives; `spot-descent` after a `G4 X` block at the spot; DeepestCut of an inch G70
  program on a mm job = 25.4 × inch depth in mm, equal to the same program with G20.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS; full suite green. Commit `feat(post): read G70/G71 for posts that write them, G4 X dwells`.

### Task 5: Draft report and editor

**Files:** `Sources/PostCore/Editor/PostDraftReport.swift`, `Sources/PostCore/Editor/PostSampleJob.swift` (only if coolant
needs it), `Sources/PostCore/Profiles/BuiltInPosts.swift` (`noSpindleSpeedIDs` declared empty here),
`Sources/LoftLineApp/Panels/PostProcessorsSheet.swift`; test `Tests/PostCoreTests/PostDraftReportTests.swift`.

**Produces:** `Template.prelude` ("Program start", placeholders = `base`); `base` gains `APPROACH_Z`; dwell placeholders gain
`DECIMAL_SECONDS`; dwell regex accepts `G4 X{DECIMAL_SECONDS}` (either order); spindle rule accepts `M3` alone when
`BuiltInPosts.family(of:)` is in `noSpindleSpeedIDs`; sample report allows `spindle-no-speed` for that family; prelude in the
ASCII and placeholder walks. Editor: `TemplateArea(label: "Program start", …)` above Preamble, bound through a setter that
stores nil for empty.

- [ ] Step 1: tests: prelude `{JOB_NAME}` outside a comment refused, inside accepted; non-ASCII prelude refused;
  `G4 X{DECIMAL_SECONDS}` accepted; plain `M3` refused for Avid.
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS; `scripts/build.sh`; `scripts/ui.sh` scenario showing the post editor
  (existing one) to see the new field. Commit `feat(post): the editor's program start lines and the new placeholders`.

### Task 6: The five posts and their rules

**Files:** `Sources/PostCore/Profiles/BuiltInPosts.swift`, `Sources/PostCore/Processor/ProgramBuilder.swift`
(`probeForBuild`), `Sources/PostCore/Validation/DialectChecks.swift`, `Sources/PostCore/Model/PostProfile.swift`
(`public var postProblem: String?`: Syntec or Haas family with the offset on and no `Z{APPROACH_Z}` word in
`toolLengthOffset`, message from spec E1b; `build()` throws `.invalidPost` for it as for `dwellProblem`); tests `PostGoldenTests.swift` (rows; `goldenProgramsPassTheValidator` at `min(18000, maxRPM)` with
the ShopBot allowance), `PostDraftReportTests.swift`, `PostEngineOptions2Tests.swift`,
`Tests/LoftLineAppTests/LoftLineCLITests.swift` (stderr allowance), `SnapshotTests.swift` (versions), `MachineConfigTests`
if it lists posts; `samples/expected` via `scripts/check-samples.sh --update`.

**Produces:** `shopbotGCodeInch`, `syntecInch`, `syntecMM`, `haasInch`, `haasMM` with every value in the spec's tables,
appended to `all` in that order; `noSpindleSpeedIDs = [shopbot]`, `oneGWordIDs = [shopbot]`, `noCoolantReasons[shopbot]`
(spec text); `probeForBuild` throws for `oneGWordIDs` families ("ShopBot runs only the first G word on a line: touch-plate
tool changes cannot be written for it."); DialectChecks error on T0 for Syntec and Haas families.

- [ ] Step 1: tests: dwell line per post (`G4 P3`, `G4 X3.000`, `G4 P3000`); first lines `%`/`O1000`, `%`/`O01000`; Syntec
  writes `G70`/`G71`, never `G20`/`G21`; last line `%`; ShopBot every line ≤ 1 G word, numbered, no S; both Z-zero modes per
  post; Syntec copy `G4 P{MILLISECONDS}` and Haas copy `Z{SAFE_Z}` G43 refused (also `fromJSON`); ShopBot copy with controller
  on a probing machine throws; ShopBot coolant error; T0 error on Syntec and Haas; every built-in's `requiredSchemaVersion`
  (ShopBot 1, Syntec 3, Haas 3).
- [ ] Step 2: FAIL. Step 3: implement. Step 4: PASS; `scripts/check-samples.sh --update` adds five folders only (`git status`
  shows no change under existing ones); read one program per post by eye; full suite green. Commit
  `feat(post): built-in ShopBot G-code, Syntec and Haas posts (#106, #110, #111)`.

### Task 7: Docs and issues

**Files:** `docs/DECISIONS.md`, `docs/PARITY.md`, Help (the post list source under `Sources/LoftLineApp`), `TESTING.md`,
`README.md`.

- [ ] Step 1: DECISIONS `engine-prelude-units` and `shopbot-syntec-haas-posts` (sources, assumptions, rulings, the `%`
  numbering change for user posts, "adds a reading, weakens no check"); PARITY, Help (posts, Air/Mist note), TESTING owner
  checks, README. `scripts/test.sh` green (docs tests). Commit `docs: ShopBot, Syntec and Haas posts`.
- [ ] Step 2 (after merge): comments on #106, #110, #111 (nine safety facts, what is assumed, owner checks) and #99 (E5).
