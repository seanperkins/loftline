# Coolant and Park-and-Probe Tool Changes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Per-toolpath coolant (Off / Mist / Air) and a park, manual swap, touch-plate re-zero sequence at every tool change, for the
Avid Mach4 posts and the GRBL post, checked independently by the validator.

**Architecture:** Coolant is an operation setting stamped onto toolpaths at export and turned on and off by a state machine in
`ProgramBuilder`. Probe settings live on `MachineDefinition`, always taken from the installed machine in `ProjectPost.resolve`, and reach
the builder and validator as a never-coded `ProbeSetting` on the effective `PostProfile`. The builder writes the sequence in code; the
validator walks a state table; export checks the touch-off spot against every toolpath of the posted sheet.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, SwiftUI. Build `scripts/build.sh`, test `scripts/test.sh [--filter X]`.

**Spec:** `docs/specs/2026-10-27-post-features-design.md` (revision 10). Its section numbers are cited as §N; read the spec for every
value this plan does not repeat.

## Global Constraints

- Nothing changes until switched on: coolant defaults to Off, every built-in machine has no probe, so goldens, `samples/expected/`,
  `samples/*.tap` and `scripts/check-samples.sh` stay byte-identical.
- All depth → machine-Z conversion goes through `MachineCoordinates.z(aboveTop:)` / `z(depth:)`; test both Z-zero modes.
- Never weaken an existing `GCodeValidator` rule; every new refusal returns an error message and no text (no Save Anyway).
- One `PostError.probe(String)` case carries every probe refusal; `GCodeExporter.export` catches it once.
- No machine or post schema bump: both stay at version 1.
- Don't write a source file and run tests in the same shell command. Judge runs by `Test run with N tests ... passed`.
- Conventional commits, one logical change per commit, build and tests green.

## Review Focus

1. A probe edit in Preferences while an export sheet is open: the sheet re-posts and Save refuses the old program (Task 3, test
   `probeEditChangesPostedInputs`).
2. A project copy of the machine in other units than the installed one: the same G-code as a same-unit copy (Task 4, test
   `installedProbeIsConvertedToTheCopysUnits`).
3. A program with line numbers on: validator recognises every sequence block (Task 6, test `lineNumbersAreIgnoredWhenMatching`).
4. The previous toolpath ending at the spot's X: the spot rapid still writes X and Y and no Z (Task 5, test
   `spotRapidAlwaysWritesXAndY`).
5. A single-toolpath export with a sibling that failed to calculate: no missing-from-the-program error for the sibling (Task 8, test
   `calculationTargetsAreKeptApartFromExportedTargets`).

---

### Task 1: Coolant on operations and toolpaths

**Files:**
- Create: `Sources/CAMCore/Model/Coolant.swift`
- Modify: `Sources/CAMCore/Model/ToolpathOperation.swift` (`OperationSetup`), `Sources/CAMCore/Model/Toolpath.swift`,
  `Sources/LoftLineApp/Model/GCodeExporter.swift` (`toolpaths(scope:…)`), `GCodeBatchExport.swift`, `ValidationReport.swift`,
  `TiledExport.swift`, `Sources/LoftLineApp/Model/OperationFactory.swift:58`, `Sources/LoftLineApp/App/LoftLineDocument.swift:815`,
  `Sources/LoftLineApp/Model/MergeCommands.swift`
- Test: `Tests/LoftLineAppTests/CoolantTests.swift`

**Interfaces:**
- Produces: `public enum Coolant: String, Codable, Hashable, Sendable { case mist, air; public var code: String }` (`"M7"`, `"M8"`);
  `OperationSetup.coolant: Coolant?`; `Toolpath.coolant: Coolant?`;
  `GCodeExporter.withCoolant(_ coolant: Coolant?, _ toolpaths: [Toolpath]) -> [Toolpath]` (stamps every toolpath);
  `AnyOperation.withoutPostSettings` (renamed from `withoutPause`; clears `pauseAfter` and `coolant`).

- [ ] **Step 1: Write the failing tests** in `CoolantTests`:
  `everyToolpathOfAnOperationGetsItsCoolant` (a two-toolpath operation with `.air`, `.all` and `.operation` scopes: both toolpaths
  `.air`); `batchAndValidationAndTiledCarryCoolant` (file per tool, file per toolpath, `ValidationReport`, a tile: `.mist` kept);
  `olderFilesDecodeWithCoolantOff` (an `OperationSetup` JSON without the key decodes with `coolant == nil`);
  `changingCoolantLeavesResultsFresh` (calculate, set `.mist`, `isStale` false); `mergeRefusesDifferentCoolant`
  (`mergeWithNextProblem` == `"The next toolpath uses a different coolant."`); `splitGivesCoolantBackToEveryChild`.
- [ ] **Step 2: Run** `scripts/test.sh --filter CoolantTests` — Expected: build fails (no `Coolant`).
- [ ] **Step 3: Implement** the type, the two fields, `withCoolant` called wherever `withPause` or a scope's toolpaths are collected
  (both scopes, batch, validation report, tiles), the rename at both call sites, the merge refusal beside the same-tool rule, and the
  merged operation keeping the shared coolant.
- [ ] **Step 4: Run** `scripts/test.sh --filter CoolantTests` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(cam): coolant setting on operations, stamped onto exported toolpaths`

### Task 2: Coolant codes in the program, and the toolpath form

**Files:**
- Modify: `Sources/PostCore/Processor/ProgramBuilder.swift`, `Sources/LoftLineApp/Panels/OperationEditor.swift`
- Test: `Tests/PostCoreTests/PostCoolantTests.swift`

**Interfaces:**
- Consumes: `Toolpath.coolant`, `Coolant.code` (Task 1).
- Produces: `ProgramBuilder` tracks `coolantOn: Coolant?`; private `writeCoolant(for tp:)` and `coolantOff()`.

- [ ] **Step 1: Write the failing tests** (`PostCoolantTests`, posting with the built-in Avid inch post): `codesOnlyWhereStateChanges`
  (Off, Mist, Mist, Air → exactly one `M7`, then `M9`, `M8`); `mistToAirTurnsMistOffFirst` (`M9` line precedes `M8`);
  `offBeforeToolChangePauseAndFooter` (an `M9` before each); `toolpathAfterPauseTurnsItBackOn`;
  `coolantAfterSpindleStartWithoutRPMChange` (same RPM, coolant changes → code written without a new `M3`); `allOffIsByteIdentical`
  (Off everywhere equals the existing golden `.tap`).
- [ ] **Step 2: Run** `scripts/test.sh --filter PostCoolantTests` — Expected: FAIL (no coolant codes).
- [ ] **Step 3: Implement** per §1 "State machine in the builder": after a toolpath's spindle start (or before its moves when there is
  none) write `M9` if something else is on, then its code; before every tool change, pause and the footer write `M9` if on and reset.
  Add a Coolant picker (Off / Mist / Air) to the operation form.
- [ ] **Step 4: Run** `scripts/test.sh --filter "PostCoolantTests|PostGoldenTests"` — Expected: all pass; goldens unchanged.
- [ ] **Step 5: Commit** `feat(post): write coolant codes per toolpath (M7 mist, M8 air, M9 off)`

### Task 3: `ToolChangeProbe`, `ProbeSetting` and the machine field

**Files:**
- Create: `Sources/PostCore/Model/ToolChangeProbe.swift`, `Sources/PostCore/Model/NeverCoded.swift`
- Modify: `Sources/PostCore/Model/MachineDefinition.swift`, `Sources/PostCore/Model/PostProfile.swift`,
  `Sources/PostCore/Processor/PostProcessor.swift` (`PostError`), `Sources/PostCore/Profiles/BuiltInPosts.swift`
- Test: `Tests/PostCoreTests/ToolChangeProbeTests.swift`, `Tests/LoftLineAppTests/ProbePostedInputsTests.swift`

**Interfaces:**
- Produces: `public struct ToolChangeProbe: Codable, Hashable, Sendable` with `parkX, parkY, parkZ, topZ, plateThickness, plateSize,
  probeFeed, probeTravel: Double`, `controller: Controller` (`enum Controller: String, Codable { case grbl, mach4 }`),
  `mach4ZeroMacro: Int?`, `workOffset: Int` (default 1); `func problems(limits: MachineLimits, units: LengthUnit) -> [String]`;
  `func scaled(by f: Double) -> ToolChangeProbe` (lengths and feed; not `workOffset`/macro);
  `public enum ProbeSetting: Hashable, Sendable { case on(ToolChangeProbe), refused(String) }`;
  `@propertyWrapper public struct NeverCoded<T: Hashable & Sendable>: Codable, Hashable` (value equality; decodes as nil, encodes
  nothing, with `KeyedDecodingContainer` and `KeyedEncodingContainer` overloads); `MachineDefinition.toolChangeProbe:
  ToolChangeProbe?`, `@NeverCoded MachineDefinition.probeRefusal: String?`; `@NeverCoded PostProfile.toolChangeProbe: ProbeSetting?`;
  `PostError.probe(String)`; `BuiltInPosts.probeController(for raw: PostProfile) -> ToolChangeProbe.Controller?` (non-nil only when
  `raw` equals by value a built-in post: the Avid Mach4 posts → `.mach4`, the GRBL post → `.grbl`).
- Ruling taken here: one wrapper with value equality for both fields; the copy-differs comparison (Task 4) clears both fields, which
  is all the spec's "compares equal" for `probeRefusal` was for.

- [ ] **Step 1: Write the failing tests.** `problemsCoverEveryBound` — one row per §2 bound with the spec's values: `topZ` 0.01 and
  `−zTravel/4 − 0.01`; `parkZ` above `topZ` and below `−zTravel/4`; `|parkX|` beyond `xTravel`; feed 10.01 in/min (and 254 mm/min passes,
  10 in/min passes on an mm machine after `scaled(by: 25.4)`); travel 1.01 in with a 2 in plate; travel over the plate thickness;
  `plateThickness`/`plateSize` 0; `workOffset` 0 and 7; `mach4ZeroMacro` 99 and 1000, nil on `.mach4`; GRBL `topZ` −0.5 mm (refused)
  and −1 mm (passes). `postBytesUnchangedByTheField` (encode a built-in post with and without `.on(probe)` set: equal bytes);
  `postJSONCarryingTheKeyDecodesWithoutIt`; `appliedSetsOnRefusedOrNil` (machine with probe + built-in Avid post → `.on` scaled to
  the post's units; machine with `probeRefusal` → `.refused`; no probe → nil, also clearing a value already on the profile); 
  `customOrEditedPostIsRefused` (a copy of the Avid post with one preamble line changed, and the GRBL post on a `.mach4` probe →
  `.refused`); `machineRoundTripsAtSchema1`. In `ProbePostedInputsTests`: `probeEditChangesPostedInputs` (two `PostedInputs` that
  differ only in plate thickness are unequal).
- [ ] **Step 2: Run** `scripts/test.sh --filter "ToolChangeProbeTests|ProbePostedInputsTests"` — Expected: build fails.
- [ ] **Step 3: Implement.** `applied(to:)` assigns `p.toolChangeProbe` unconditionally: nil when no probe and no refusal;
  `.refused(probeRefusal)`; `.refused("This post cannot probe tool changes: use the built-in post for this controller.")` when
  `BuiltInPosts.probeController(for: profile) != probe.controller`; else `.on(probe.scaled(by: units.factor(to: profile.units)))`.
- [ ] **Step 4: Run** the same filter — Expected: all pass. Then `scripts/test.sh --filter "MachineDefinitionTests|PostGoldenTests"`.
- [ ] **Step 5: Commit** `feat(post): park-and-probe settings on the machine, carried to the post never-coded`

### Task 4: Probe from the installed machine; the touch-off spot

**Files:**
- Modify: `Sources/LoftLineApp/Model/ProjectPost.swift` (`resolve`, copy-differs), `Sources/CADCore/Model/JobSetup.swift`,
  `Sources/LoftLineApp/Model/JobSetupForm.swift` (`setUnits`)
- Test: `Tests/LoftLineAppTests/ProjectPostProbeTests.swift`, `Tests/CADCoreTests/JobSetupTouchOffTests.swift`

**Interfaces:**
- Consumes: Task 3 types.
- Produces: `JobSetup.touchOffSpot: Vec2?` (material frame, document units, scaled in `JobSetup.scaled(by:)`); `resolve` returns a
  machine whose `toolChangeProbe` is the installed one's converted to the copy's units, or nil with `probeRefusal` set.

- [ ] **Step 1: Write the failing tests.** `installedProbeWinsOverTheCopy` (copy plate 0.75, installed 0.5 → resolved 0.5);
  `installedProbeIsConvertedToTheCopysUnits` (inch copy / mm installed and the reverse → same G-code from Task 5's builder once it
  exists; here: resolved values equal after conversion within 1e-9); `copyWithProbeAndMachineMissingIsRefused`;
  `copyWithProbeAndInstalledWithoutIsRefused` (also with built-in-only machines, as `--builtin-only` loads);
  `copyWithoutProbeGetsTheInstalledOne`; `copyDifferingOnlyInProbeGivesNoWarning`; `touchOffSpotScalesAndRoundTripsUnits`
  (`JobSetupForm.setUnits` mm → in → mm keeps the spot exact); `olderJobSetupDecodesWithNoSpot`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "ProjectPostProbeTests|JobSetupTouchOffTests"` — Expected: FAIL.
- [ ] **Step 3: Implement** in `resolve` after the copy is chosen: `machine.toolChangeProbe = installed?.toolChangeProbe?.scaled(by:
  installed!.units.factor(to: copy.units))`; refusal message (§2): `"This project was set up to probe tool changes on a machine that
  is not set up for it here."`. Compare copies with `toolChangeProbe` and `probeRefusal` cleared on both sides.
- [ ] **Step 4: Run** the same filter, then `scripts/test.sh --filter ProjectPost` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(app): probe settings come from the installed machine; touch-off spot on the job`

### Task 5: The sequence in the builder

**Files:**
- Modify: `Sources/PostCore/Processor/ProgramBuilder.swift`, `Sources/PostCore/Processor/GCodeWriter.swift`,
  `Sources/PostCore/Support/NumberFormat.swift`, `Sources/LoftLineApp/Model/GCodeExporter.swift` (one `catch PostError.probe`)
- Test: `Tests/PostCoreTests/ProbeSequenceBuilderTests.swift`

**Interfaces:**
- Consumes: `PostProfile.toolChangeProbe`, `JobSetup.touchOffSpot`, `PostError.probe`.
- Produces: `NumberFormat.floored(_ v: Double, decimals: Int) -> String` (floors `v·10^d + 1e-9`);
  `NumberFormat.towardZero(_ v: Double, decimals: Int) -> String`; `GCodeWriter.rapidXY(_ p: Vec2)` (always X and Y, never Z);
  `reenter(before:into:minHeight:)`.

- [ ] **Step 1: Write the failing tests** with exact expected lines (§4 steps 1–11): `oneToolMach4Inch`, `twoToolsGRBLmm`,
  `mmDocumentInchPost`, `centreOriginWithDatumOffset`, `bothZZeroModes` (`plateZ`, `clearZ`), `plateThickerThanSafeZ` (nothing below
  `clearZ` at the spot), `feedFloored` (4.99 in/min → `F4.9`; 126.746 mm/min → `F126`), `travelFlooredWithEpsilon` (0.57 in with a 0.57
  in plate → `Z-0.5700`; 25.4 mm travel and plate on an inch post → `Z-1.0000`), `g53ValuesTowardZero` (201 mm park on an inch post →
  `7.9133`), `noToolChangeLinesNoG43`, `step1WritesG90G921G5x` (`G55` with `workOffset` 2), `everyG53XYAfterTopZ` (`topZ` 0 Mach4,
  −1 mm GRBL), `mach4MacroThenRecoveryLine` (`M199 P0.5000` then `G17 G40 G49 G80 G90 G94 G91.1 G20 G54`; `G90.1` on an absolute-IJ
  post), `g0WrittenAfterProbe`, `feedRestatedAfterSequence`, `spotRapidAlwaysWritesXAndY` (previous toolpath ends at the spot's X),
  `placementCommentHasGapAndUnit`, `lineNumbersOn` (via a profile already set to `.on`). Refusals, each `PostError.probe`: no spot,
  `useToolLengthOffset`, a `problems` value, `plateThickness + safeZ` beyond Z travel, Mach4 without macro, feed or travel formatting
  to zero (mm post with zero feed decimals), `plateZ` 0.4 on 0 decimals, `clearZ` under 1 mm above `plateZ` (3 mm plate, safe Z
  0.0004 mm), `.refused`, two-sided job (and a single side of it), T300 on GRBL.
- [ ] **Step 2: Run** `scripts/test.sh --filter ProbeSequenceBuilderTests` — Expected: FAIL.
- [ ] **Step 3: Implement** `writeProbedToolChange(_:into:)` replacing `writeToolChange` when the profile is `.on`, writing §4's lines
  in order through `w.code`, `w.comment`, `w.rapidXY`; `w.resetModalState()` after the first `G53`; the stop comments exactly as §4
  step 6 and step 10; then `reenter(before:into:minHeight: clearZ)` (climb to `max(clearZ, approachZ)`, always cross X/Y, then the
  spindle start, dwell and coolant). Run the refusals before writing anything.
- [ ] **Step 4: Run** the filter, then `scripts/test.sh --filter "Post"` — Expected: all pass, goldens unchanged.
- [ ] **Step 5: Commit** `feat(post): park, swap and touch-plate re-zero at every tool change`

### Task 6: The validator's probe state table

**Files:**
- Create: `Sources/PostCore/Validation/ProbeSequenceChecker.swift`
- Modify: `Sources/PostCore/Validation/GCodeValidator.swift` (`validate(gcode:)` delegates when `.on`; `31`, `38.2`, `92.1` known)
- Test: `Tests/PostCoreTests/ProbeValidatorTests.swift`

**Interfaces:**
- Consumes: `ProbeSetting`, `JobSetup.touchOffSpot`, `MachineCoordinates`.
- Produces: `struct ProbeSequenceChecker { init(probe: ToolChangeProbe, profile: PostProfile, job: JobSetup, units: LengthUnit);
  mutating func check(blocks: [GCodeBlock]) -> [GCodeIssue] }` (block type as `GCodeParser` returns it); states `needsProbe, lifted,
  parked, swapReady, swapped, leaving, atSpot, placed, probed, zeroedAtSpot, cleared, ready` per §6's table.

- [ ] **Step 1: Write the failing tests.** Clean: the Task 5 programs (Mach4 `M199`, GRBL; line numbers on and off; a pause; a custom
  footer and pause starting `G53 G0 Z{topZ}`; a preamble writing `G54` with `workOffset` 2) give none of: coordinate-shift,
  incremental, unknown-G, unknown-M, garbage, unknown-Z, too-deep, spindle-off; a too-deep cut after tool 2 is still caught. One error
  test each (edit the builder's program): wrong `G10` value or `P`; macro `P` ≠ `plateZ`; `G10 L20` on Mach4; `G55` after the placement
  stop (`workOffset` 1); a cut or the spot rapid in the wrong offset; a `G53` X/Y move not after `topZ`; `T` outside `parked`;
  `T2`, `G53 G0 Z0`, spot with no park or swap stop; no placement stop; no clear move; no removal stop before `M3`; spindle on at the
  swap or probe; a probe on X, upward, with `M3`, with no `G91` before, no `G90` after, `G91`/`G90` swapped, outside `placed`;
  probe longer or faster than allowed (the limit at the rounding edge passes); Mach4 unit without macro or recovery line; recovery
  line with the other arc word; park or spot not the computed one; first sequence deleted; a later one with its `T` kept; descent at
  the spot after the removal stop (re-entry cross deleted); an axis block with no motion word after the probe; a zero outside
  `probed`. A GRBL footer with `G53 G0 Z0` keeps today's coordinate-shift warning. Without a probe on the profile: today's warnings.
- [ ] **Step 2: Run** `scripts/test.sh --filter ProbeValidatorTests` — Expected: FAIL.
- [ ] **Step 3: Implement** the table, the unlisted-block rule, the state-gated errors, modal work offset, the probe-unit lookahead
  and the zero check (`v` from the validator's own `MachineCoordinates(job:).z(aboveTop: plateThickness)` in program units), all
  comparisons ignoring `N` words; the expected recovery line built from the profile, not the builder.
- [ ] **Step 4: Run** the filter, then `scripts/test.sh --filter PostValidator` — Expected: all pass.
- [ ] **Step 5: Commit** `feat(post): validator checks the park-and-probe sequence state by state`

### Task 7: The preview reader

**Files:**
- Modify: `Sources/PostCore/Support/GCodeReader.swift`
- Test: `Tests/PostCoreTests/PostGCodeReaderTests.swift`

- [ ] **Step 1: Write the failing tests**: `probedTwoToolsGRBLAndMach4` (two segments, no phantom plunge, Z = `plateZ` after
  `G10 L20` and after `M199 P…` plus recovery line, no "not previewed" note for `G53`); `m6ProgramsKeepTodaysSegments` (Avid
  `T{T} M6`; `T1 M6` … `T2` pre-staged → today's segments).
- [ ] **Step 2: Run** `scripts/test.sh --filter PostGCodeReaderTests` — Expected: FAIL.
- [ ] **Step 3: Implement** per §6 last paragraph: `G31`/`G38.x` non-modal and not drawn; `G10 L20 Z` and an `M` block with `P` right
  after a probe unit set Z; `T`-word segments only in programs with no `M6`.
- [ ] **Step 4: Run** the filter — Expected: all pass.
- [ ] **Step 5: Commit** `feat(preview): read probed tool changes`

### Task 8: The whole-sheet spot check

**Files:**
- Create: `Sources/LoftLineApp/Model/TouchOffSpotCheck.swift`
- Modify: `Sources/LoftLineApp/Model/GCodeExporter.swift`, `TiledExport.swift`, `GCodeBatchExport.swift`, `ValidationReport.swift`,
  `LoftLineCLI.swift`, `Sources/LoftLineApp/Panels/ExportGCodeSheet.swift`, `SaveAllToolpathsSheet.swift`, `ValidationSheet.swift`
- Test: `Tests/LoftLineAppTests/TouchOffSpotCheckTests.swift`

**Interfaces:**
- Produces: `enum SheetToolpaths { case ready([Toolpath]), refused(String) }`;
  `GCodeExporter.sheetToolpaths(project: LoftLineProject, results: [UUID: ToolpathResult], sheetID: UUID?) -> SheetToolpaths` (every
  operation of the sheet, switched on or off, ungrouped; refused for a missing result or a switched-on failure);
  `export(…, sheetToolpaths: SheetToolpaths? = nil)`; `TouchOffSpotCheck.problem(project:, sheet: [Toolpath], probe:, units:) ->
  String?`; `TouchOffSpotCheck.footprint(spot: Vec2, radius: Double) -> [Vec2]` (a 32-gon circumscribing the disc: vertex radius
  `r / cos(π/32)`).

- [ ] **Step 1: Write the failing tests**, each refusing with no text: nil `sheetToolpaths` with probing; a list lacking the exported
  toolpaths; spot near an edge (3 × 3 in plate, `plateSize` 4.243, touched at a corner); in a keep-out zone; in a clamp; over a pocket
  in another file (file per tool, single operation, CLI); multi-sheet: pocket under sheet B's spot, a sheet-B toolpath exported while
  A is current (helper and CLI); a pocket cut then switched off; a switched-off pocket exported alone (helper and CLI); a switched-on
  sheet operation whose calculation failed; tiled with probing (every tile's result). Not refused: a switched-off operation that
  failed. `calculationTargetsAreKeptApartFromExportedTargets` (a sibling that failed: no missing-from-the-program error); each entry
  point refuses (export sheet with the project's post and a picked post, Save All, Check Toolpaths, tiled, CLI with `--force`).
- [ ] **Step 2: Run** `scripts/test.sh --filter TouchOffSpotCheckTests` — Expected: FAIL.
- [ ] **Step 3: Implement**: the sheet is `sheetID(of: op)` for `.operation`, the current sheet for `.all`; the plate zone at height 0
  through `LayoutChecks.keepOut` plus the material-bounds and keep-out/clamp checks over both stores; the calculation-target lists in
  the sheets and the CLI widen to every operation of the sheet when the profile is `.on`; `TiledExport.files` refuses before the loop.
- [ ] **Step 4: Run** the filter, then `scripts/test.sh` — Expected: full suite green.
- [ ] **Step 5: Commit** `feat(app): check the touch-off spot against every toolpath on the posted sheet`

### Task 9: Machines and Job Setup UI

**Files:**
- Modify: `Sources/LoftLineApp/Panels/PreferencesView.swift` (machine editor), `Sources/LoftLineApp/Panels/JobSetupSheet.swift`
- Create: `harness/scenarios/machine-probe.json`
- Test: `Tests/LoftLineAppTests/MachineConfigTests.swift`

- [ ] **Step 1: Write the failing test** `unitsSwitchScalesTheProbe` (editor's units switch on a machine with a probe uses
  `scaled(by:)`: 10 in/min ↔ 254 mm/min, 1 in ↔ 25.4 mm, `workOffset` and macro unchanged).
- [ ] **Step 2: Run** `scripts/test.sh --filter MachineConfigTests` — Expected: FAIL.
- [ ] **Step 3: Implement** a "Tool change: park and probe" switch with every §2 field, the controller picker, the Mach4 macro number,
  and `problems(limits:units:)` shown as the user types; Job Setup shows touch-off spot X/Y when the resolved machine probes.
- [ ] **Step 4: Run** the filter, then `scripts/ui.sh machine-probe --light` and look at the PNG and `.ax.txt`.
- [ ] **Step 5: Commit** `feat(ui): park-and-probe settings in Machines, touch-off spot in Job Setup`

### Task 10: Docs and the air-probe procedure

**Files:**
- Modify: `docs/DECISIONS.md` (`coolant`, `park-and-probe`, including the GRBL `topZ` ruling and built-in-posts-only), `docs/PARITY.md`
  (coolant and tool-change-probe rows), `TESTING.md` (§Risks procedure: held plate, no-contact run over scrap, probe already active,
  paper check of work Z 0 in both Z-zero modes with every post the machine lists, dry run of `topZ` over the longest bit, clamps and
  fixtures, the coolant check), Help (Toolpaths: coolant and GRBL `M7`; Machines: every field, the macro contract and a reference Lua
  macro; Job Setup: the spot, minimum stock width, where probing is switched off)

- [ ] **Step 1: Write the docs**; run `scripts/check-samples.sh` — Expected: no differences.
- [ ] **Step 2: Run** `scripts/build.sh` and `scripts/test.sh` — Expected: green.
- [ ] **Step 3: Commit** `docs: coolant and park-and-probe (decisions, parity, testing, help)`
