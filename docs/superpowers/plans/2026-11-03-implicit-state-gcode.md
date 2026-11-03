# Implicit State Machines, Part A (G-code and model) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix audit items #3, #5, #7, #8 and #28 as Sean decided on 2026-11-03.

**Architecture:** Each item replaces loosely synced state with one owner: through depths derive from a stored
overcut (#3), pauses are computed once from the written toolpath list (#5), the validator owns modal state (#7), a rest
pass names its operation and a relief's split is stored once per model (#8), and `export` owns the missing-step check
(#28).

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** `docs/implicit-state-machines.md` (items #3, #5, #7, #8, #28) and the decisions in its Status section.

## Global Constraints

- Branch `fix/implicit-state-decisions` off `fix/implicit-state`; one conventional commit per task; build and tests green
  (`scripts/build.sh`, `scripts/test.sh`, judged by `Test run with N tests ... passed`).
- Z-related tests run in both `ZZeroMode.materialTop` and `.spoilboard`.
- No validator check is weakened. Samples and goldens do not move unless a task says so; run `scripts/check-samples.sh`
  without `--update` after #5 and #7.
- `LoftLineProject.currentFormatVersion` goes from 2 to 3 in Task 4 only (older apps then refuse the file, never misread it).
- A `docs/DECISIONS.md` entry per task.

## Review Focus

1. A multi-sheet job: each through cut follows its own sheet's thickness (Task 1 test `throughDepthsFollowTheirOwnSheet`).
2. Units switched inch↔mm: the overcut scales with every other length (Task 1 test `overcutScalesWithUnits`).
3. A merged operation whose part is a through cut resolves like a plain one (Task 1 test `mergedThroughCutResolves`).
4. Group by tool moves a pause-carrying toolpath last: no stop is listed or written (Task 2 test `noPauseAfterTheLastToolpath`).
5. A version 2 file whose rest tool matches no earlier operation opens with the rest pass in error, never machining the
   whole area with the small tool (Task 4 test `unmatchedRestToolIsAnError`).

---

### Task 1: #3 Through depths derive from a stored overcut

**Files:** `Sources/CAMCore/Model/Parameters/CommonParameters.swift`, create `Sources/CAMCore/Model/ThroughDepths.swift`,
`Sources/CAMCore/Model/LoftLineProject.swift` (`decode`), `Sources/LoftLineApp/App/LoftLineDocument.swift` (`perform`),
`Sources/LoftLineApp/Model/OperationFactory.swift` (remove `DepthFollow`; Profile default), `Sources/LoftLineApp/Model/JobSetupForm.swift:114`,
`Sources/LoftLineApp/Panels/OperationForms.swift:17-34`, `Sources/LoftLineApp/Model/UnitScaling.swift`,
`Sources/LoftLineApp/Model/TwoSidedSupport.swift:18-22` (`sheetID(of:)` moves to CAMCore);
Test: create `Tests/CAMCoreTests/ThroughDepthsTests.swift`, update `DepthFollow` tests in `Tests/LoftLineAppTests`.

**Produces:**
- `DepthSettings.overcut: Double?` (past the material bottom; nil = fixed `cutDepth`).
- `followsThickness` is decoded only. `DepthSettings` gets explicit `CodingKeys` and an `encode(to:)` that never writes
  it, so no encoded project carries it.
- `extension LoftLineProject { public func sheetID(of op: AnyOperation) -> UUID? }`, moved unchanged from
  `TwoSidedSupport.swift:18-22`: an operation with no vectors on a multi-sheet job is on the primary sheet, as
  calculation already assumes.
- `extension LoftLineProject { public func resolvingThroughDepths() -> LoftLineProject }`: for every operation (merge
  children one by one) with `overcut != nil`, `cutDepth = thickness + overcut`. The thickness is
  `document.job(ofSheet: sheetID(of: op))?.thickness`. An operation whose shapes span sheets (nil) keeps its `cutDepth`.
  Custom passes at or past the new depth are dropped, as `DepthFollow` did.
- One commit point: `LoftLineDocument.perform` and the live-edit fast path (`LoftLineDocument.swift:705-710`,
  `p.upsertOperation(op)` then `project = p`) both resolve through depths before storing.

- [ ] Tests: `overcutGivesThicknessPlusOvercut` (overcut 0.02, thickness 0.75 → 0.77; thickness to 0.5 → 0.52),
  `throughDepthsFollowTheirOwnSheet`, `mergedThroughCutResolves`, `overcutScalesWithUnits`,
  `legacyFollowsThicknessMigrates` (`followsThickness: true`, cutDepth 0.8, thickness 0.75 → overcut 0.05; cutDepth
  0.7 < thickness → a fixed depth, overcut nil, the hand edit the old flag ignored), `variableThicknessMovesThroughCuts`
  (a thickness set through `VariableLinks.apply` inside `perform` moves a through cut), `liveEditOfOvercutMovesCutDepth`,
  `facingWithoutVectorsUsesThePrimarySheet` (on Sheet 2 of a two-sheet job), `encodedProjectHasNoFollowsThickness`.
  Run, see them fail.
- [ ] Implement: migration in `resolvingThroughDepths()` (legacy flag → overcut, flag cleared); call it last in
  `LoftLineProject.decode`, in `LoftLineDocument.perform` after `ToolSync.carrying`, and in the live-edit path; delete `DepthFollow` and its call
  in `JobSetupForm.apply`; new Profiles get `overcut = 0`.
- [ ] Form: the toggle reads "Cut through the material"; when on, a "Past the bottom" `LengthField` edits `overcut` and
  Cut depth shows the derived value read-only.
- [ ] `scripts/test.sh --filter 'ThroughDepths|DepthFollow|JobSetup|VariableLinks'` passes; full suite passes; commit
  `fix(cam): a through cut stores its overcut, so every thickness change moves it (#3)`.

### Task 2: #5 Operator pauses computed once from the written list

**Files:** create `Sources/PostCore/Processor/ProgramPauses.swift`; `Sources/PostCore/Processor/ProgramBuilder.swift:31,86,168`,
`Sources/LoftLineApp/Model/JobSheet.swift:133`, `Sources/LoftLineApp/Model/JobSummary.swift:84-85`,
`Sources/CAMCore/Layout/ToolpathTiling.swift:93-112`; Test: create `Tests/PostCoreTests/ProgramPausesTests.swift`,
add to `Tests/CAMCoreTests/LayoutTilingTests.swift` and `Tests/LoftLineAppTests/PauseStepTests.swift`.

**Produces:** `public enum ProgramPauses { public static func effective(_ toolpaths: [Toolpath]) -> [Toolpath] }`: the
same list with `pauseAfter` kept only on a toolpath that has moves and is followed by another that has moves.
`ProgramBuilder.build`, its header list, `JobSheet.make` and `JobSummary.make` read pauses only from `effective(_:)`.

- [ ] Tests: `noPauseAfterTheLastToolpath` (also when the only toolpaths after it are empty), `pauseSurvivesEmptyNeighbours`,
  `jobSheetListsExactlyTheProgramsStops` (job sheet `pauses` count equals the `M0` count in the posted text),
  `aTileKeepsTheStopWhenItsCarrierIsClippedAway` (the stop moves to the last surviving toolpath of the same
  `operationID` before it in the tile). Run, see them fail.
- [ ] Implement `effective(_:)`; replace the three inline rules; in `ToolpathTiling.tile`, after clipping, a dropped
  carrier's `pauseAfter` moves to the last surviving earlier toolpath with its `operationID`.
- [ ] Full suite passes; `scripts/check-samples.sh` reports no change; commit
  `fix(post): operator pauses are worked out once, from the toolpaths the program writes (#5)`.

### Task 3: #7 The validator tracks units and distance mode

**Files:** `Sources/PostCore/Validation/GCodeValidator.swift:190-240`; Test: add to `Tests/PostCoreTests/PostValidatorTests.swift`.

**Produces:** error `units-mismatch` (was a warning): a G20/G21 (G70/G71 on a `.g70g71` post) naming units other than
`profile.units`, anywhere in the program. New error `incremental-motion`: a G0/G1/G2/G3 block with X, Y or Z while G91
is in force (a G28/G30 line is not motion here, so `G91 G28 Z0` stays legal). The existing `incremental` warning stays
for a G91 that moves nothing.

- [ ] Tests: an inch post whose tool-change template adds `G21` → `units-mismatch` error;
  a footer `G91 G28 Z0` → no error; a preamble `G91` then a cut → `incremental-motion` error; every built-in post's
  sample program has neither. Run, see them fail.
- [ ] Implement in the `case 20, 21` and `case 91` branches and the motion handling.
- [ ] Full suite and `scripts/check-samples.sh` pass; commit `fix(post): a program that switches units or moves in G91 is refused (#7)`.

### Task 4: #8 A rest pass names its operation; a relief's split is stored once per model

**Files:** `Sources/CAMCore/Model/Parameters/Parameters3D.swift:60-108`, `Sources/CADCore/Model/Mesh.swift:39-55`
(`PlacedModel`), `Sources/CAMCore/Ops3D/Relief3DOperation.swift:30-78`, `Sources/CAMCore/Ops3D/ReliefTwoSided.swift`,
`Sources/CAMCore/Model/LoftLineProject.swift:7`, `Sources/CADCore/Persistence/LoftLineFile.swift` (migration 2→3),
`Sources/LoftLineApp/Model/ToolpathCalculator.swift`, `Sources/LoftLineApp/Panels/OperationForms.swift:522-625`,
`Sources/LoftLineApp/Panels/OperationEditor.swift:185`, `Sources/LoftLineApp/Model/UnitScaling.swift:112-113,219`,
`Sources/CAMCore/Templates/ToolpathTemplate.swift:44,125,167`, `Sources/LoftLineApp/Model/TemplateService.swift:24-60`, create `Sources/LoftLineApp/Model/RestDependency.swift`,
`Sources/PostCore/Processor/PostProcessor.swift:75-110` (`ToolpathOrdering`), `Sources/LoftLineApp/Model/OperationFactory.swift:67-80`
(`referencedToolIDs`); existing tests that set `restToolID`: `Tests/CAMCoreTests/ReliefRestTests.swift:61,74`,
`Tests/LoftLineAppTests/OperationWarningsTests.swift:273`;
Test: add to `Tests/CAMCoreTests/ReliefRestTests.swift`, `ReliefTwoSidedTests.swift`, `Tests/CADCoreTests/IOLoftLineFileTests.swift`.

**Produces:**
- `public enum RestSource: Codable, Hashable, Sendable { case operation(UUID); case unresolved(toolID: UUID) }` as
  `FinishingSettings.rest: RestSource?`, which replaces `restToolID`. nil means no rest machining (the whole area).
  `.unresolved` comes only from older files. It always fails generation with
  `Rest after: choose the toolpath this rests after`, so it can never fall through to a whole-area cut.
- Decoding older files (projects and templates alike), done in the types:
  - `FinishingSettings.init(from:)` reads a legacy `restToolID` as `rest = .unresolved(toolID:)`.
  - `TwoSidedSettings.init(from:)` reads legacy `flip`/`splitDepth`/`web` into a decode-only `legacySplit: ReliefSplit?`.
  - Neither legacy field is ever encoded. A file from an older version can therefore never decode to "no rest", nor
    lose its split, whichever path reads it.
- `CAMContext.operations: [AnyOperation]` (default `[]`) is the project's ordered list.
  `ToolpathCalculator.calculate` (`ToolpathCalculator.swift:51`) fills it in; the CLI calculates through it.
- `Relief3DOperation.generate` resolves its rest source there and uses that operation's finishing tool. It throws
  `CAMError.invalidParameter` when the source is gone, off, after it in the list, not a 3D finish, or machines another
  model or side (`Rest after "<name>": that toolpath is off` / `…is after this one` / `…was deleted` /
  `…cuts another model or side`). Whether the source's area covers the rest pass's is left to the user, as today.
- The rest pass's finishing toolpath carries `metadata["restAfter"] = <source operation id>`.
  `ToolpathOrdering.canMove(_:aheadOf:)` refuses to move it ahead of any toolpath with that `operationID`, whatever the
  footprints. Group by tool therefore never posts a rest pass before its source.
- `RestDependency.problem(_ op: AnyOperation, results: [UUID: ToolpathResult]) -> String?` (LoftLineApp): non-nil when
  the source's result is missing or failed, or has no toolpath with `metadata["pass"] == "finishing"` and moves
  (`Rest after "<name>": it has no finishing toolpath`). Task 4 builds and unit-tests it; Task 5 wires it into `export`.
- `public struct ReliefSplit: Codable, Hashable, Sendable { var flip: FlipAxis; var splitDepth: Double?; var web: Double }`
  in CADCore. `FlipAxis` already exists in `CADCore/Model/TwoSided.swift` with the same cases and raw values;
  `TwoSidedSettings.Flip` is removed and CAMCore uses `FlipAxis`.
  as `PlacedModel.reliefSplit: ReliefSplit?`. `TwoSidedSettings` keeps only `side`. `Relief3DOperation` reads the split
  from its primary model.
- `UnitScaling` scales `reliefSplit.splitDepth` and `.web` with the model (`UnitScaling.swift:219`).
- `Relief3DForm` takes `split: Binding<ReliefSplit?>`. `OperationEditor` builds it over the document: its setter runs
  `document.perform("Two-Sided Split") { $0.document.models[i].reliefSplit = $1 }`.
- Project format version 3 (an identity JSON migration from 2, so version 2 apps refuse version 3 files). After decode,
  `LoftLineProject.decode` upgrades older state:
  - Each `.unresolved(toolID:)` becomes `.operation(id)` of the nearest earlier 3D operation whose finishing tool is
    that tool. Without one it stays unresolved.
  - Each model gets its two-sided reliefs' `legacySplit`. When they agree, that is all. When they differ, the model
    takes the top side's values, and every relief of that model gets `TwoSidedSettings.splitNeedsReview = true`.
    Generation throws `Two-sided settings differed between the sides in the saved file: check flip, split depth and web,
    then press Use These Settings` while it is set. The form shows the shared values with a "Use These Settings" button
    that clears the flag on every relief of the model in one `perform`. No side's cut changes silently.
- References to the rest source:
  - `referencedToolIDs` no longer lists a rest tool; the source operation lists its own.
  - `ToolpathTemplate` stores `.operation(id)` and remaps it to the source's new id when `resolve(in:)` gives fresh
    ids. A source that is not in the template becomes `.unresolved(toolID:)` with the source's finishing tool, and the
    template's tool list includes that tool.
- Templates (`ToolpathTemplate.swift:44,125`):
  - `currentFormatVersion` goes from 1 to 2, so version 1 readers refuse new templates; `decode` already refuses a
    newer version.
  - `Entry.reliefSplit: ReliefSplit?` is captured from the source model by `make(from:)`.
  - `decode` upgrades a version 1 template: its `.unresolved` rest passes resolve within the template, by the same
    nearest-earlier rule as projects, and its reliefs' `legacySplit` moves to `Entry.reliefSplit`.
  - `resolve(in:)` also returns each resolved relief's `(modelID, ReliefSplit)` in the template's units.
    `TemplateService.apply` (`TemplateService.swift:24-26`) works on the `inout` project, so it can write models. It
    scales each split by `f = template.units.factor(to: project.document.units)`, as it already does each operation,
    before comparing or installing it.
  - A target model with no `reliefSplit` takes the converted split. An equal one (within 1e-9 × max(1, |value|))
    changes nothing. A different one is kept, and the added relief gets `splitNeedsReview = true`.

- [ ] Characterization first: pin the current toolpaths of the two-sided relief tests for both flips. They must not
  change.
- [ ] Tests: `restPassFollowsItsOperation`, `disabledOrLaterRestSourceIsAnError`, `unmatchedRestToolIsAnError`
  (migrated `.unresolved` throws; it never generates a whole-area pass), `restDependencyNeedsAFinishingResult`
  (failed source, roughing-only source, empty source → a problem; finished source → nil),
  `restSourceOnAnotherModelOrSideIsAnError`, `groupByToolKeepsTheRestPassAfterItsSource` (list `[Y, source, rest]`: Y uses
  the rest pass's tool; source uses another; all three footprints are apart, so without the guard the rest pass joins
  Y's group ahead of the source. With it the order stays `[Y, source, rest]`. First assert the old `canMove` would move
  it), `conflictingSidesMigrateToReview` (version 2 file, top and bottom webs differ: both reliefs fail with the review
  message; Use These Settings clears it), `templateRemapsTheRestSource`, `legacyRestToolIDNeverDecodesToNoRest`
  (a bare `FinishingSettings` JSON with `restToolID` → `.unresolved`), `version1TemplateMigrates` (rest source and split
  carried), `version2TemplateIsRefusedByVersion1Reader`, `templateSplitConflictNeedsReview`, `templateSplitConvertsUnits` (an inch
  template on a mm project and a mm template on an inch project, each with an absent, an equivalent and a conflicting
  target split, and the same for a migrated version 1 template: web 0.04 in installs as 1.016 mm; an equivalent split
  raises no review), `bothSidesShareTheModelsSplit`,
  `splitScalesWithUnits`, `editingTheSplitOnOneSideChangesBoth`, `version2FileMigrates` (rest id and split moved), `version3FileIsRefusedByVersion2Reader`
  (`LoftLineFile.decode` with `currentVersion: 2`). Run, see them fail.
- [ ] Implement in the order of the files list; move the existing `restToolID` tests to `rest:`; characterization tests
  still pass.
- [ ] Full suite passes; commit `feat(cam): a rest pass names the toolpath it follows, and a relief's two sides share one split (#8)`.

### Task 5: #28 `export` owns the missing-step check

**Files:** `Sources/LoftLineApp/Model/GCodeExporter.swift:63-74,170-239`; callers `Panels/ExportGCodeSheet.swift:160-170`,
`Panels/SaveAllToolpathsSheet.swift:148-156`, `Model/GCodeBatchExport.swift:100-104`, `Model/LoftLineCLI.swift:284-296`,
`Model/TiledExport.swift:32-56`, `Model/ValidationReport.swift:39,53`; Test: add to `Tests/LoftLineAppTests/PreflightChecksTests.swift`.

**Produces:**
- `enum ExpectedSteps { case operations([AnyOperation], results: [UUID: ToolpathResult]); case notChecked(because: String) }`.
- `GCodeExporter.export(project:toolpaths:profile:jobName:expected:sheetToolpaths:)` with `expected` required (no
  default). For `.operations`, the result's issues start with `missingOperationIssues`, refusals included. The same
  issues are also kept in a new field, `GCodeExportResult.missingSteps: [GCodeIssue]`.
- The CLI keeps its hard gate: it refuses when `result.missingSteps` is non-empty, whatever `--force` says, as
  `LoftLineCLI.swift:305` does today.
- For `.operations`, `export` also refuses the program (no text, so Save Anyway cannot write it) when a rest pass whose
  toolpaths are in `toolpaths` has a `RestDependency.problem` (from Task 4). The refusal message is the problem's text.
- Callers keep inserting their own notices at index 0, so the final order is unchanged: notices, missing steps, the rest.

- [ ] Tests: `everyExportResultCarriesMissingSteps` (an enabled, uncalculated operation gives the error through
  `export` alone, and through a refusal path), `cliRefusesAPartialProgramEvenWithForce` (one operation calculated, one
  failed, `--force`: exit non-zero, no file), `failedSourceBlocksTheRestPassAtExport` (the rest pass generated
  normally, the source's entry in `results` set by hand to a failed `ToolpathResult`, then `export` returns no text). Run, see them fail.
- [ ] Implement; each caller passes what it computed before and drops its own `missingOperationIssues` call;
  `ValidationReport`'s per-operation check passes `.notChecked(because: "one operation's own program")`.
- [ ] Full suite passes; commit `refactor(export): every export states which steps it expects (#28)`.
