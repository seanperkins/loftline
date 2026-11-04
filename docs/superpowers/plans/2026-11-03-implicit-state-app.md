# Implicit State Machines, Part B (app and UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fix audit items #10, #13, #14, #16, #18, #20 and #26 as Sean decided on 2026-11-03.

**Architecture:** Each item gives one piece of app state a single owner or a single entry point: expression links are
scoped to the form they were typed in (#10), new layers know their sheet (#13), the document's sheet slot refuses a
second sheet (#14), the shared preference orders every one-file export (#16), Job Setup keeps the project's machine id
(#18), the stored preference owns "show vectors" (#20), and a window attaches in one step (#26).

**Tech Stack:** Swift 6, SwiftPM, swift-testing, SwiftUI/AppKit.

**Spec:** `docs/implicit-state-machines.md` (items #10, #13, #14, #16, #18, #20, #26) and the decisions in its Status section.

## Global Constraints

- Same branch as Part A (`fix/implicit-state-decisions`), after it; one conventional commit per task; build and tests green.
- UI tasks (#14, #20) are checked with `scripts/ui.sh` outside the agent sandbox (docs/UI-HARNESS.md). Add a scenario
  when no existing one shows the state.
- No file format change in this part.
- Deferred by Sean's choices (no task here): #13's nest-sheet offset going out of step after a material width change
  (`NestSheets.swift:55`; the mixed-sheets warning covers the risk), and #14's app-wide gadget panel blocking another
  window (`GadgetPanels.swift:56`). The audit doc's Status section lists both.
- A `docs/DECISIONS.md` entry per task.

## Review Focus

1. A thickness typed as `=…` in Job Setup still feeds toolpath links that use `thickness` (Task 1 test `jobLinkFeedsOperationLinks`).
2. Sheets that chain on purpose (model placement queue, SVG scale queue, a sheet's own button) still open (Task 3 test `queuedSheetsStillOpen`).
3. An alert raised while one shows appears after it, not instead of it (Task 3 test `secondAlertWaits`).
4. A Save All mode stored by an earlier version (`oneFileInOrder`) opens as the one-file mode (Task 4 test `oldStoredModesDecode`).
5. Two windows in 3D agree on "Vectors" after either toggles it (Task 6 test `bothWindowsReadOneFlag`).

---

### Task 1: #10 Expressions link to the form they were typed in

**Files:** `Sources/LoftLineApp/Model/VariableLinks.swift:8-135`, `Sources/LoftLineApp/Panels/FormControls.swift:35,77`,
`Sources/LoftLineApp/Panels/OperationEditor.swift`, `Sources/LoftLineApp/Panels/JobSetupSheet.swift`; Test: add to the
`VariableLinks` tests in `Tests/LoftLineAppTests`.

**Produces:**
- `ExpressionRecorder.Entry.target: VariableLink.Target`.
- `EnvironmentValues.expressionTarget: VariableLink.Target?` (nil = record nothing). `OperationEditor` sets
  `.operation(draft.id)`; `JobSetupSheet` sets `.job(sheetID: currentSheetID)`.
- `reconcile` links an entry only inside its own target, and only when exactly one changed leaf there took its value.
  An ambiguous edit links nothing and keeps the value.
- `apply` repeats until nothing changes, at most `linkedValues.count + 1` passes (cycles are already excluded).

Deviation to flag in review: links follow the field's form and require a unique match; the exact field key path is not
recorded, because the fields are bound to drafts, not to project paths.

- [ ] Tests: `expressionOutsideAProjectFormLinksNothing` (a drawing-option field, then a new Profile with that value:
  no link), `twoLeavesWithTheSameValueLinkNeither`, `linkChainOfFourSettlesInOneEdit`, `jobLinkFeedsOperationLinks`.
  Run, see them fail.
- [ ] Implement; full suite passes; commit `fix(app): a typed expression links only within the form it was typed in (#10)`.

### Task 2: #13 New layers know their sheet; deleting a layer keeps its vectors' side and sheet

**Files:** `Sources/LoftLineApp/Model/ProjectEditing.swift:60-84`, `Sources/LoftLineApp/Model/ImportService.swift:117`,
`Sources/LoftLineApp/Model/PreflightChecks.swift`; Test: add to `Tests/LoftLineAppTests/LayoutMultiSheetTests.swift`
and `PreflightChecksTests.swift`.

**Produces:**
- `addLayer(named:)` and imported layers get `sheetID` = the current sheet (nil when it is the primary). When import
  reuses an existing layer by name (`ImportService.swift:114`, and the bitmap layer at `:143`), it reuses only a layer on
  the current sheet.
- `deleteLayer` moves the vectors to an ordinary layer of the same side and sheet. If there is none, it creates one
  ("Layer N", same side and sheet) rather than fall back to another side.
- `PreflightChecks.mixedSheets(_ doc: Document) -> GCodeIssue?`, added to the export checks: a warning when
  `doc.isMultiSheet` and a nest-sheet layer (`sheet != nil`) exist: `Nest sheets and material sheets are both used: nesting
  places parts by the first sheet's size and does not know the other material sheets. Check every part's position before cutting.`

- [ ] Tests: `aLayerAddedOnSheet2ShowsOnSheet2`, `importOnSheet2LandsOnSheet2` (including an SVG layer named like a
  Sheet 1 layer), `deletingTheOnlyTopLayerKeepsVectorsOnTop`,
  `nestAndMaterialSheetsTogetherWarn`. Run, see them fail.
- [ ] Implement; full suite passes; commit `fix(app): layers stay on their sheet and side, and mixing nest and material sheets warns (#13)`.

### Task 3: #14 An open sheet is never replaced; a second alert waits

**Files:** `Sources/LoftLineApp/App/LoftLineDocument.swift:1006-1060` (`sheet`, `report`, `sheetDismissed`); Test:
create `Tests/LoftLineAppTests/SheetPresentationTests.swift`.

**Produces:**
- `@Published private(set) var presentedSheet: DocumentSheet?`, with `var sheet: DocumentSheet?` as a computed wrapper.
  Setting nil, or setting while nothing is shown, presents; setting another sheet while one is shown beeps
  (`NSSound.beep()`) and changes nothing.
- `func replaceSheet(_ s: DocumentSheet)` for the few deliberate swaps: grep `sheet = ` for writes made from inside a
  sheet and route those through it.
- `report(_:)` holds the message when an alert is already up (`alert != nil`). `alert`'s didSet shows the held one
  once it is dismissed, deferred to the next run-loop turn as `sheetDismissed()` does. The deferred closure re-checks:
  if an alert or sheet appeared in the meantime, it holds the message again instead of replacing what is showing.

- [ ] Tests: `aMenuCommandDoesNotReplaceAnOpenSheet` (Job Setup open, then `sheet = .postProcessors` → still Job Setup),
  `queuedSheetsStillOpen`, `secondAlertWaits`, `anAlertReportedBeforeTheDeferredOneIsNotReplaced`. Run, see them fail.
- [ ] Implement; full suite passes; `scripts/ui.sh main` still opens; commit
  `fix(ui): a menu command never replaces an open sheet, and alerts queue (#14)`.

### Task 4: #16 The group-by-tool preference orders every one-file export

**Files:** `Sources/LoftLineApp/Model/GCodeBatchExport.swift:7-54`, `Sources/LoftLineApp/Panels/SaveAllToolpathsSheet.swift`;
Test: add to the `GCodeBatchExport` tests.

**Produces:** `SaveAllMode` cases `oneFile`, `filePerToolpath`, `filePerTool`. `init(rawValue:)` maps the stored
`oneFileGroupedByTool` and `oneFileInOrder` to `.oneFile`. `plan(mode:operations:results:jobName:profile:groupByTool:)`:
`.oneFile` orders by `groupByTool`. The sheet shows the shared "Group by tool" toggle (key `GCodeExporter.groupByToolKey`)
when `.oneFile` is chosen. The CLI's `--group-by-tool` is unchanged.

- [ ] Tests: `oneFileFollowsThePreference` (same order as `GCodeExporter.toolpaths(scope: .all, …)` for both values),
  `oldStoredModesDecode`. Run, see them fail.
- [ ] Implement; full suite passes; commit `fix(app): Save All writes one file in the order the preview shows (#16)`.

### Task 5: #18 A missing machine is reported, and the project keeps its id

**Files:** `Sources/LoftLineApp/Model/ProjectPost.swift:173-193`, `Sources/LoftLineApp/Model/JobSetupForm.swift:39-41,118`;
Test: add to `Tests/LoftLineAppTests/ProjectPostProbeTests.swift` or the `ProjectPost` tests.

**Produces:**
- `ProjectPost.issues` adds a warning when `p.machineID` is set, no machine with that id is installed, and the file has
  no copy: `The project's machine "<id>" is not installed and the file has no copy of it; "<name>" is used instead. Pick your machine in Job Setup.`
- `JobSetupForm.machinePicked: Bool`, set by the picker binding. `apply` writes `p.machineID` only when it is true.
- When the project's machine is missing, the form's `machineID` stays the project's id, and the picker lists it as
  `<id> (not installed, using <fallback name>)`. The selection shown is then what Apply keeps.

- [ ] Tests: `aMissingChosenMachineWarns`, `jobSetupApplyKeepsTheProjectsMachineID`, `jobSetupShowsTheMissingMachineSelected`. Run, see them fail.
- [ ] Implement; full suite passes; commit `fix(app): say when the project's machine is missing, and keep its id (#18)`.

### Task 6: #20 The stored preference owns "show vectors"

**Files:** `Sources/LoftLineApp/Preview/SimulationPreviewModel.swift:112-125,193-225`, `Sources/LoftLineApp/Preview/SimulationPreviewView.swift:270-305`,
`Sources/LoftLineApp/App/Preview3DHost.swift:14-27`; Test: add to the preview model tests.

**Produces:**
- The model drops its stored `showVectors`. It gets `var vectorsPreferred: Bool` from the view's
  `@AppStorage(SimulationPreviewModel.showVectorsKey)`, and draws vectors when `vectorsPreferred || tool == .draw || tool == .select`.
  The tool's didSet no longer writes the preference.
- The host passes vectors whenever the preference is on or the view asks for them (`needsVectors` callback), not only
  when the preference is on.
- `.onChange(of: toolpaths.isEmpty)`: when the toolbar is disabled, `model.tool = .none`.

- [ ] Tests: `drawModeShowsVectorsWithoutChangingThePreference`, `bothWindowsReadOneFlag` (two models with one
  `UserDefaults` suite), `measureEndsWhenTheToolbarIsDisabled`. Run, see them fail.
- [ ] Implement; full suite passes; `scripts/ui.sh` 3D scenario shows vectors in Draw mode; commit
  `fix(ui): one owner for "show vectors" in 3D, and Measure ends when it cannot be used (#20)`.

### Task 7: #26 A document window attaches in one step

**Files:** `Sources/LoftLineApp/App/ContentView.swift:34-48`, `Sources/LoftLineApp/App/LoftLineDocument.swift`; Test:
add to `Tests/LoftLineAppTests/SaveConfirmationTests.swift` or a new `WindowAttachTests.swift`.

**Produces:** `func attachWindow(undoManager: UndoManager?, fileURL: URL?)` on `LoftLineDocument`. It sets the undo
manager and file URL, registers with `RecoveryCoordinator.shared`, and notes the harness in DEBUG builds. ContentView
calls it from one `onAppear`; the existing `onChange` handlers for the undo manager and URL stay.

- [ ] Test: `attachSetsUndoURLAndRecoveryTogether`. Run, see it fail.
- [ ] Implement; full suite passes; commit `refactor(app): a document window attaches in one step (#26)`.
