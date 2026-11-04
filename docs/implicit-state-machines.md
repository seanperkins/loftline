# Implicit state machines in LoftLine

Audit of 2026-11-02. The raw scanner and verifier output (162 candidates, with file:line traces) is in
`.tmp/implicit-state-machines/findings.json` (git-ignored).

## Status (2026-11-03)

Fixes are on branch `fix/implicit-state`, one commit per item. Each has a test unless noted, and a `docs/DECISIONS.md`
entry where the choice is not obvious.

- **Fixed:** #1, #2, #6 (a toolpath-level and an export-level test, both red before the fix), #9, #12, #15, #19,
  #21 (red run-to-run before the fix), #22, #24, #25, #27.
- **Partly fixed:**
  - #4: tiling no longer posts stale results and the job sheet waits for fresh ones. Stop still restarts the
    calculation, and the four copies of the sheet lifecycle remain. No unit test, since this is sheet `@State`.
  - #11: a stopgap. Tab editing, envelope and kerning end each other, and another tool ends envelope and kerning.
    Deleting the envelope's shapes ends it, arrows don't nudge during an envelope, and Space resets when the window
    stops being key. A single `CanvasSession` type is still the full fix.
  - #17: every document window now refreshes its stored times when the settings change. This is view wiring, so it
    has no unit test.
- **Fixed after Sean's decisions of 2026-11-03** (branch `fix/implicit-state-decisions`, plans in
  `docs/superpowers/plans/2026-11-03-implicit-state-gcode.md` and `docs/superpowers/plans/2026-11-03-implicit-state-app.md`):
  - #3: through cuts store their overcut.
  - #5: pauses are worked out once.
  - #7: a mid-program units change, or motion in G91, is an error.
  - #8: rest passes name their source, and a relief's split is its model's. This is project format 3 and template
    format 2.
  - #10: expressions link within their form.
  - #13: layers keep their sheet and side.
  - #14: one sheet at a time, and alerts queue.
  - #16: one-file order follows the preference.
  - #18: a missing machine is reported.
  - #20: one show-vectors owner.
  - #26: one window attach step.
  - #28: export states its expected steps.
- **Left as is:** #23 is reachable only from tests and the harness.
- **Deferred within decided items:** #13's nest-sheet offset after a width change (the mixed-sheets warning covers it)
  and #14's app-wide gadget panel blocking other windows.
- **Not checked in the running app:** #15 (typing in the post editor) and #11 (the Space reset).

## What counts

An **implicit state machine** is a component whose behaviour depends on a mode, phase or lifecycle stage that is
not modelled as one explicit state type with its transitions in one place. The state is spread across loose
variables and the transitions across scattered code, so wrong combinations can be represented and nothing stops
them. Signals:

1. **Flag clusters**: several Bool / Optional / Set vars that are really one mode.
2. **Async lifecycles**: task handles, busy flags, generation counters, "pending" values that coalesce requests.
3. **Queues** drained on an unrelated event.
4. **Ordering protocols**: X must happen before Y, begin/end pairs, "starting A must clear B".
5. **Modal interpreters**: line readers that keep modal state in loose vars.
6. **Shadow state**: an explicit enum exists, but extra vars carry part of the state and can disagree with it.
7. **Multi-step UI flows** whose step is implied by which optionals are set.

## Method

- **Scan:** 12 Sonnet scanners at max effort, one per slice of `Sources/` plus `scripts/` and
  `packaging/updater/macos.sh`. Each read every file in its slice.
- **Verify:** one Sonnet verifier per slice re-traced each finding in the code and tried to refute it. It set
  `needsThought` only for items that need a fix or a design decision.
- **Spot-check:** I re-read the code for the items marked "checked" below. Everything else rests on the verifier's
  static trace. **Nothing was run.**

Totals: 162 candidates. The verifiers judged 67 as confirmed implicit machines, 54 as confirmed but explicit enough,
and 41 as not state machines. Verifiers raised 46 "needs thought" flags across slices, many of them the same machine
seen from different slices, and found 10 items the scanners had missed. Together these deduplicate to the 28 items
below.

---

## Tier 1: affects what reaches the machine

### 1. Merging toolpaths erases the inlay-part and relief-side markers (checked)
- **State:** `Toolpath.metadata["part"]` (`female`/`male`) and `["side"]`: untyped markers layered on top of
  `Toolpath.kind`.
- **Problem:** `MergeOperation.generate` rebuilds each piece's metadata, keeping only `"warning"`, and turns its
  `kind` into `.merge`. As a result, the validator's `inlay-mixed-parts` and `relief-mixed-sides` errors stop
  firing.
- **Path:** Inlay wizard → enable the plug → Merge With Next. Pocket and plug can then post into one program with no
  error.
- **Files:** `Sources/CAMCore/Ops2D/MergeOperation.swift:36-47`, `Sources/PostCore/Validation/GCodeValidator.swift:102-113`,
  `Sources/LoftLineApp/Model/MergeCommands.swift:25-39`, `Sources/LoftLineApp/Model/InlayWizardModel.swift:70-76`.
- **Decision:** carry part/side as typed fields (or keep them through the merge), or refuse to merge across parts
  and sides.

### 2. Tab mode is a Bool plus an optional list; the loose-part check reads only the Bool (checked)
- **State:** `TabSettings.isEnabled` + `manualTabs` (nil = automatic, `[]` = manual with none, list = manual)
  + spacing/count. The four modes are off / automatic / manual / manual-empty.
- **Problem:** in the manual-empty state, a through-cut profile gets **zero tabs**. `PreflightChecks.looseParts` is
  guarded on `!tabs.isEnabled`, so it stays silent. The generator's short-loop warning compares 0 < 0, so it is
  silent too. The same gap applies to a closed vector added after manual anchors were seeded: that vector has no
  anchor, so it gets no tab.
- **Path:** Profile at full thickness → Tabs on → Placement Manual → Clear (or option-click every tab away).
- **Files:** `Sources/LoftLineApp/Model/PreflightChecks.swift:43-58`, `Sources/CAMCore/Ops2D/ProfileOperation.swift:204-303`,
  `Sources/LoftLineApp/Model/TabEditor.swift:26-76`, `Sources/LoftLineApp/Model/OperationWarnings.swift:54-60,185-195`,
  `Sources/LoftLineApp/Panels/OperationForms.swift:236`.
- **Decision:** a `TabPlacement` enum (off | automatic(count/spacing) | manual([anchors])) and one "placed tab count
  per closed loop" predicate shared by preflight, warnings and the generator. "Empty manual = no tabs" is pinned by a
  test (`Ops2DManualTabTests.swift:38`), so the generator's behaviour is intended. The gap is the preflight.

### 3. "Follow the material thickness" is a mode flag that nothing invalidates (checked)
- **State:** `DepthSettings.followsThickness` + `cutDepth` + `customPasses` (+ `exactStep`, `passDepth`: the
  pass mode even / exact / custom is itself an implicit union where `customPasses == []` means different things to
  the form and to the generator).
- **Problems:**
  - Every new Profile is created following, and editing Cut depth by hand never clears the flag. The next thickness
    change in Job Setup moves the hand-set depth by the difference. The caption says "Stays at the material bottom"
    even when the cut stops short of it.
  - Thickness changed through a variable link (Document Variables, or a gadget's `setVariable`) skips `DepthFollow`
    entirely. A "through" profile then stops short of the bottom, and nothing warns.
- **Files:** `Sources/LoftLineApp/Model/OperationFactory.swift:167-171,240-265`,
  `Sources/LoftLineApp/Panels/OperationForms.swift:17-34`, `Sources/LoftLineApp/Model/JobSetupForm.swift:114`,
  `Sources/LoftLineApp/Model/VariableLinks.swift:116-135,239-247`, `Sources/CAMCore/Model/Parameters/CommonParameters.swift:44-101`,
  `Sources/LoftLineApp/Panels/Toolpaths2DForms.swift:129-195`.
- **Decision:** store "overcut past the bottom" instead of an absolute depth plus a flag, or clear the flag on a hand
  edit. Run the follow for every thickness writer, not only `JobSetupForm.apply`.

### 4. Tiled export can post stale toolpaths after Stop (checked)
- **State:** each export sheet infers its phase from `calcTask`, `result`/`files`, `postedFrom`, `failure`,
  `confirmErrors` and `replaceRequest`. The same pattern is copy-pasted into four sheets.
- **Problem:** `TilingSheet` treats `calcTask == nil` as "results are fresh":
  `.onChange(of: settings) { if calcTask == nil { post() } }`. Stop also sets `calcTask = nil` while stale results
  remain. Stop → change a tile size → `post()` stamps `postedFrom` and tiles the old toolpaths.
- **Related:** in all four sheets, Stop does not stay stopped. The in-flight operation still stores its result,
  `currentInputs` changes, and `onChange` runs `run()` again. Separately, Export Job Sheet runs one
  `calculateAndWait`, discards its Bool and prints whatever is in `results`, with no `isStale` re-check.
- **Files:** `Sources/LoftLineApp/Panels/TilingSheet.swift:54-55,82,117-140`,
  `Sources/LoftLineApp/Panels/ExportGCodeSheet.swift:14-26,77-90,135-158`, `Sources/LoftLineApp/Panels/SaveAllToolpathsSheet.swift`,
  `Sources/LoftLineApp/Panels/ValidationSheet.swift`, `Sources/LoftLineApp/App/LoftLineDocument+Layout.swift:18-27`,
  `Sources/LoftLineApp/App/LoftLineDocument.swift:814-912`.
- **Decision:** one shared `ExportPipeline` state type (idle / calculating / stopped / posted(inputs) / failed),
  where "posted" requires that no target is stale.

### 5. The operator pause (M0/M1) is re-derived in about seven places, over two different lists
- **Problem:** the pause is attached to an operation's last non-empty toolpath and written only when a following
  *active* toolpath exists.
  - If the next operation's toolpaths are all empty, no stop is written. The job sheet and job summary still list
    it.
  - Tiling attaches the pause **before** clipping. A tile where the pause-carrying toolpath has no cuts loses the
    stop.
  - Merge/split and templates also drop or misplace it (see #22).
  - Tiling copies other whole-toolpath attributes onto clipped pieces too. With `clearedDepth`, a tile that does not
    contain the deepest point can miss the export's flute-length *error*. The flute *warning* still shows, so this
    is a weaker safety net, not a wrong Z.
- **Files:** `Sources/PostCore/Processor/ProgramBuilder.swift:31,82,164`, `Sources/LoftLineApp/Model/GCodeExporter.swift:38-60`,
  `Sources/CAMCore/Layout/ToolpathTiling.swift:213-217`, `Sources/LoftLineApp/Model/JobSheet.swift:133`,
  `Sources/LoftLineApp/Model/JobSummary.swift:84-85`, `Sources/LoftLineApp/Model/TiledExport.swift:26-28`.
- **Decision:** decide where a pause lives (between two emitted toolpaths), and compute it once from the final
  emitted list.

### 6. Keep-out lift-over router: "lifted" exists only as `cur != prev`
- **State:** two `Vec3?` registers in a Router driven by three entry points (`apply`, `link`, `linkTravel`), with
  an apply-oriented tail fix-up.
- **Problem (traced, no test covers it):** when a toolpath's opening rapid lands inside a lift-over zone (grown by
  radius + margin), the first move is copied unrouted, and the next lift happens *inside* the zone as a vertical
  rapid.
- **Files:** `Sources/CAMCore/Ops2D/Support/KeepOutAvoidance.swift:79,151-244,286-289`; tests
  `Ops2DKeepOutLiftTests`, `Ops2DKeepOutLinkTests`.
- **Decision:** add a test that starts a toolpath inside a zone first. If it fails, give the router an explicit
  `atSafe / lifted(clearZ) / cutting` state.

### 7. ProgramBuilder assumes controller modal state that template text can change
- **State:** the controller's modal groups (units, G90/G91, plane, arc mode, work offset), assumed after a single
  setup line.
- **Problem:** a units or distance word inside a post's toolChange, preamble or pause template (for example `G21`
  in an inch post) is never scanned on the non-editor paths: posts-folder JSON and a project's embedded post copy.
  `PostDraftReport` runs only in the editor.
- **Files:** `Sources/PostCore/Processor/ProgramBuilder.swift:41,52,176,185`, `Sources/PostCore/Model/PostProfile.swift:303`,
  `Sources/LoftLineApp/Model/GCodeExporter.swift:204`, `Sources/LoftLineApp/Model/ProjectPost.swift:47`,
  `Sources/PostCore/Profiles/PostProfileStore.swift:55`.
- **Decision:** run the template word scan at load or export, or validate the written program's modal state
  (GCodeValidator already tracks units).

### 8. Ordering dependencies between 3D operations that nothing checks
- **Rest machining:** `restToolID` points to an earlier operation by tool id, with only a caption as the contract.
  Disable, delete or reorder that operation, and the rest pass still cuts its patches into the bare stock.
- **Two-sided relief:** there are two unrelated models, per-relief `TwoSidedSettings` and the job-level
  `TwoSidedSetup`. The top and bottom ops can drift (flip, web, split depth edited on one side only), and "which
  side" is derived three different ways.
- **Files:** `Sources/CAMCore/Model/Parameters/Parameters3D.swift:17,60-108`, `Sources/CAMCore/Ops3D/Relief3DOperation.swift:30-78,101-129`,
  `Sources/CAMCore/Ops3D/ReliefRest.swift:16-41`, `Sources/CAMCore/Ops3D/ReliefTwoSided.swift:9-44`,
  `Sources/LoftLineApp/Model/OperationWarnings.swift:88-100` (the existing hole-mill "what ran earlier" check to copy).

### 9. Machine editor: probe toggle off/on resets calibrated values
- **Problem:** `toolChangeProbe == nil` means "off". Turning it back on rebuilds the probe from defaults: park X/Y 0,
  plate thickness 0.5 in, zero macro 199. The defaults pass validation, so Save overwrites the calibrated plate
  thickness and Z-zero macro. The editor also has no dirty tracking.
- **Files:** `Sources/LoftLineApp/Panels/PreferencesView.swift:105-107,159-250,265-268`,
  `Sources/PostCore/Model/ToolChangeProbe.swift:48-63`.

### 10. Typed `=expressions` become variable links by value coincidence
- **State:** `ExpressionRecorder.pending` / `unwritten`. They are filled as a side effect of a field's *parse* and
  drained by the next `perform` of any kind. `reconcile` then links every changed numeric leaf whose value equals
  the expression's result.
- **Problems:**
  - An expression typed into a non-project field (a drawing option, a transform dialog) waits, then links a default
    of the next new operation that happens to have the same value.
  - Two leaves changed in one edit to the same value both get linked.
  - `apply` runs 3 passes, so a dependency chain of depth 4 created in the worst order is left stale until the next
    edit.
  - The effect: a machining parameter (depth, Z) that later moves without the user editing it.
- **Files:** `Sources/LoftLineApp/Model/VariableLinks.swift:8-135`, `Sources/LoftLineApp/Panels/VariablesPanels.swift:62-97`,
  `Sources/LoftLineApp/Panels/FormControls.swift:35,77`, `Sources/LoftLineApp/App/LoftLineDocument.swift:385,689,1032`,
  `Sources/CADCore/Expressions/VariableLink.swift`.
- **Decision:** record the field (key path) the expression came from, and link only that field.

---

## Tier 2: user-visible bugs and design debt (design time only, undoable)

### 11. Canvas interaction mode spread over about ten variables
- **State:** `activeTool`, `tabEditingOperationID`, `envelopeEdit`, `kerningShapeID` and `nodeSelection` on the
  document. On the view: `DragState` (explicit), `CanvasDrawingState` (five optional drags), `clickPoints`, `pen`,
  `transientStateTool` and `spaceHeld`.
- **Reachable bugs:**
  - Tab editing and kerning (or envelope) can be on together. Their banners stack in one spot and tab editing
    stops responding.
  - Arrow keys nudge shapes during an envelope edit, while the frozen `box` still drives the preview. Apply then
    distorts differently from what was shown.
  - Delete or undo leaves the envelope session pointing at shapes that are gone.
  - A palette or tool key changes the tool while the session keeps swallowing clicks.
  - Hold Space, Cmd-Tab away, release: `spaceHeld` stays true and the canvas only pans (it looks frozen).
  - Shift/Option are read live for the preview but from the event at commit.
- **Files:** `Sources/LoftLineApp/App/LoftLineDocument.swift:111-139,436-445`, `Sources/LoftLineApp/Canvas/CanvasEvents.swift:23-37,249-299`,
  `Sources/LoftLineApp/Model/EnvelopeEdit.swift:47-65`, `Sources/LoftLineApp/Model/KerningEdit.swift:15-27`,
  `Sources/LoftLineApp/Canvas/CanvasDrawingTools.swift:6-22`, `Sources/LoftLineApp/App/ContentView.swift:97-113`.
- **Decision:** one `CanvasSession` enum (none / tabEdit / envelope / kerning) with a single enter/exit. Keys and
  palette consult it. Stopgap: an `endOtherSessions()` in every `begin*`, plus a `spaceHeld` reset on resign-key.

### 12. Node selection is a second selection that nothing keeps in sync
- **Problem:** `nodeSelection` is checked only for existence. Cmd-D, Tab, or a sheet switch changes `selection`
  while the node refs stay. Arrow or Delete then edits nodes of a shape that is no longer selected (or not on the
  visible sheet or side).
- **Files:** `Sources/LoftLineApp/Canvas/CanvasEvents.swift:253-266`, `Sources/LoftLineApp/Canvas/CanvasNodeEvents.swift:12-61`,
  `Sources/LoftLineApp/App/LoftLineDocument.swift:136,439-440,520-523`, `Sources/LoftLineApp/Canvas/CanvasEditMenu.swift:16-23`.

### 13. Sheets, sides and layer roles
- **State:** a layer's role (ordinary / nest-sheet slot / clamp) and its placement (side, material sheet) live in
  four optionals: `sheet`, `keepOut`, `side` and `sheetID`. "Ordinary" is re-derived at 6+ sites. Nest sheets and
  material sheets are two independent "sheet" machines on one document. The current material sheet is swapped into
  `Document.job`, and `nil` means "primary" on both `activeSheetID` and `Layer.sheetID`.
- **Reachable problems:**
  - A layer added with + while on Sheet 2, or anything imported there, gets `sheetID == nil` and is hidden on
    Sheet 2.
  - `deleteLayer` falls back to any ordinary layer, so a two-sided job's top vectors can move to the bottom side.
  - Nest sheet 1's offset is recomputed from the current job size, while sheets 2+ keep a stored offset, so a Job
    Setup width change desynchronises them.
  - Using nest sheets and material sheets together corrupts placement.
- **Files:** `Sources/CADCore/Model/Shape.swift:78-100`, `Sources/CADCore/Layout/NestSheets.swift:19-119`,
  `Sources/CADCore/Model/MaterialSheet.swift:57-92`, `Sources/LoftLineApp/Model/ProjectEditing.swift:73-98`,
  `Sources/LoftLineApp/Model/NestingCommands.swift:72-152`, `Sources/LoftLineApp/App/LoftLineDocument+Sheets.swift:11-33`.

### 14. Sheet and alert presentation
- **State:** one `sheet` slot written from about 30 sites, plus `alert`, `deferredAlert`, `pendingPlacements`,
  `pendingScales`, `platformSheetOpen` and an app-wide static `GadgetRunner.panel`.
- **Problems:**
  - Menu shortcuts replace an open sheet and drop its draft (Post Processors, Variables, Job Setup).
  - A gadget dialog open in one window silently blocks gadgets in another.
  - `report()` overwrites an alert that is already showing.
- **Files:** `Sources/LoftLineApp/App/LoftLineDocument.swift:743-752,1006-1042`, `Sources/LoftLineApp/App/ContentView.swift:49`,
  `Sources/LoftLineApp/Panels/GadgetPanels.swift:55-83`, `Sources/LoftLineApp/App/LoftLineCommands.swift`.

### 15. Post editor template areas eat trailing spaces and Return (checked)
- **Problem:** the binding's getter re-joins the normalised lines (trimmed, blanks dropped), and
  `updateNSView` overwrites the text view whenever its text differs. Typing `G0 Z5` left to right gives `G0Z5`, and
  Return at the end of a line collapses. This is deterministic.
- **Files:** `Sources/LoftLineApp/Panels/PostProcessorsSheet.swift:83-84,150-153,305-315`,
  `Sources/LoftLineApp/Model/PostEditorModel.swift:148-155`.
- **Fix:** keep the raw text in the view (or a draft string) and normalise on save.

### 16. Program order has three owners
- **Problem:** "group by tool" is decided by a shared preference, by `SaveAllMode` and by a CLI flag. Save All can
  write a file in an order that differs from what the 3D preview, the tool-change summary and the printed job sheet
  show. That breaks the promise at `GCodeExporter.swift:27-30`.
- **Files:** `Sources/LoftLineApp/Model/GCodeBatchExport.swift:7-54`, `Sources/LoftLineApp/Model/GCodeExporter.swift:27-41`,
  `Sources/LoftLineApp/App/LoftLineDocument+Layout.swift:34-36`, `Sources/LoftLineApp/Model/JobSheet.swift:112-121`.

### 17. Cached time estimates go stale
- **Problem:** `results[].estimatedSeconds` is refreshed only by an `onChange` inside the 3D host, so only while a
  window shows 3D. Change the time settings in one window and another window's sidebar row times keep the old
  numbers, while its job total uses the new ones.
- **Files:** `Sources/LoftLineApp/Preview/TimeEstimateSettings.swift:94-131`, `Sources/LoftLineApp/App/Preview3DHost.swift:70`,
  `Sources/LoftLineApp/Panels/SidebarView.swift:372-391`.

### 18. Project post, machine and tool copies vs the installed selection
- **Problem:** five optionals on `LoftLineProject` (`postProfileID`, `machineID`, `postSnapshot`, `machineSnapshot`,
  `machineInferredFor`). A chosen machine that is not installed and has no copy is silently replaced by the first
  installed machine that lists the post. Job Setup shows the substitute and saves its id, with no issue reported.
- **Files:** `Sources/LoftLineApp/Model/ProjectPost.swift:41-192`, `Sources/LoftLineApp/Model/MachineStore.swift:70-74`,
  `Sources/LoftLineApp/Model/JobSetupForm.swift:39-41,118`.

### 19. Update helper failure paths
- **Problems:**
  - With `--relaunch 1`, every failure after the app quit exits without reopening the intact old app. To the user,
    Install and Restart just quits.
  - The recovery hint names `$ME --recover`, but `$ME` is the temporary copy that the EXIT trap deletes.
  - The "rolled back" message prints even when there was no previous app.
- `UpdateController` itself is explicit and fine. Its `pending` field sits outside `State` but did not produce a
  practical bug.
- **Files:** `packaging/updater/macos.sh:42-48,111-189`, `Sources/LoftLineApp/Updates/UpdateController.swift:226-256`.

### 20. 3D preview tool mode and the "show vectors" flag
- **Problems:**
  - `showVectors` has two owners: the model's copy read once at init, and the host's `@AppStorage`. Two windows in
    3D disagree.
  - Entering Select or Draw rewrites the persisted preference.
  - Measure can stay on while its toggle is disabled.
  - An in-flight frame from the old engine is applied after `configure()` swaps engines (a brief flash, then
    corrected).
- **Files:** `Sources/LoftLineApp/Preview/SimulationPreviewModel.swift:112-125,193-225,239-270,357-380`,
  `Sources/LoftLineApp/App/Preview3DHost.swift:14-27`.

---

## Tier 3: small holes worth one line each

| # | Item | Files |
|---|------|-------|
| 21 | Nearest-neighbour ordering iterates a `Set<Int>`, so exactly equidistant chains (a regular hole grid) are picked in per-process hash order. Output can differ between runs (checked; not a state machine). | `Sources/CAMCore/Ops2D/Support/ChainOrdering.swift:12-32` |
| 22 | Merged op's setup shadows its children's: splitting a disabled merge re-enables every part, and a template made from a merge loses its stop. | `Sources/CAMCore/Ops2D/MergeOperation.swift:74`, `Sources/LoftLineApp/Model/MergeCommands.swift:25-58`, `Sources/CAMCore/Templates/ToolpathTemplate.swift:76-79` |
| 23 | Live-edit undo window can be armed with no undo step, so the next edit is neither undoable nor dirty. Reachable only from tests and the harness today. | `Sources/LoftLineApp/App/LoftLineDocument.swift:684-698` |
| 24 | Nesting's copy branch remaps `groupID` but not `innerGroupIDs`, so copies share inner groups. `duplicateShapes` (dead code) does not remap either. | `Sources/LoftLineApp/Model/NestingCommands.swift:131-136`, `Sources/LoftLineApp/Model/ProjectEditing.swift:47-57` |
| 25 | Crafted-file blowups: DXF INSERT has a depth cap but no work cap (k^16), and `^` chains in a stored expression bypass the parser's depth guard. | `Sources/CADCore/IO/DXF/DXFImporter.swift:34`, `Sources/CADCore/Expressions/ExpressionEvaluator.swift:100-122` |
| 26 | Document window attachment (undoManager, fileURL, recovery registration) is set by three `onAppear`s. An edit before attach is silently not undoable. | `Sources/LoftLineApp/App/ContentView.swift:34-48` |
| 27 | `bundle.sh` deletes and rebuilds `dist/LoftLine.app` in place, so a failure leaves a half-built, unsigned app. | `scripts/bundle.sh:35-107` |
| 28 | Export gate: the "operation missing from the program" check is opt-in per caller (all 4 writers add it today), while the probing check fails closed. A fifth export path that forgets it would fail open. No live bug. | `Sources/LoftLineApp/Model/GCodeExporter.swift:63-74,165-239`, `Sources/LoftLineApp/Model/LoftLineCLI.swift:284-313` |

## Implicit but healthy (no action; candidates for extraction only)

- **Save confirmation / dirty tracking.** About 10 fields, 2 locks, polled by `RecoveryCoordinator`. The best-tested
  machine in the app (`SaveConfirmationTests`, about 18 orderings) and it fails safe. Worth extracting into a
  `SaveTracker` only to enforce the "confirm before reading `needsRecovery`, on main" contract.
  `LoftLineDocument.swift:185-353`.
- **Toolpath calculation lifecycle.** `calculating`, `pendingRecalculation`, generation counters and
  `calculateUntilFresh`. Correct thanks to the generation guard in `store()`, and tested. The job-sheet gap is under
  #4. `LoftLineDocument.swift:814-912`.
- **Simulation render coalescing and playback**, `SimulationTimeline`, `SimulationPlayer` seek cache.
- **G-code validator / reader modal interpreters**, `ProbeSequenceChecker` (explicit `State`), `MotionChecker`
  (accumulate → `finish()` once, both callers comply), `GCodeWriter` modal mirror, `FooterTravel`.
- **UpdateController `State`**, kerf migration coordinator, `GCodeFileSet.write` rollback, `check-samples.sh`
  staged swap, `PostEditorModel` (apart from #15), Tool Database autosave, crash-recovery copies.
