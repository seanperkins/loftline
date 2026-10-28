# Post Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Edit, check and preview custom posts in a Toolpaths ▸ Post Processors… sheet, list post files that did not load, and
let a custom post declare its controller for touch-plate tool changes.

**Architecture:** The store gains a one-scan `load()` with skipped files and safe-id rules. PostCore gains the `controller`
field, a fixed sample job and one synchronous `PostDraftReport` (static rules first, then the sample posted and validated). The
app gets a sheet with the list, the form and the preview.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, SwiftUI. `scripts/build.sh`, `scripts/test.sh [--filter X]`.

**Spec:** `docs/specs/2026-10-27-post-editor-design.md` (revision 4, approved). Read it for every rule this plan names.

## Global Constraints

- Built-in posts, goldens, `samples/expected/` stay byte-identical; `scripts/check-samples.sh` unchanged.
- `PostProfile.currentSchemaVersion` stays 1; `controller` is coded only when set.
- Every blocking rule and its message is the spec's; the report never posts a draft whose static rules fail.
- Don't write a source file and run tests in one shell command. Judge runs by `Test run with N tests ... passed`.

## Review Focus

1. A user post file that loads today but is misnamed (`Avid.json` holding id `avid-x`): listed under Did not load with the reason
   (Task 1, test `misnamedFileIsSkippedWithItsReason`).
2. An unedited Duplicate of each built-in is clean, probe sample included (Task 3, test `unchangedDuplicatesAreClean`).
3. An inch post declaring GRBL at 4 decimals posts and validates the probe sequence (Task 2, test
   `g53ValuesWrittenTowardZeroPass`).
4. A post with `controller` set read by a decoder that drops the key cannot probe (Task 2, test `droppedControllerCannotProbe`).
5. Two windows saving new posts with the same id: the second gets the next id (Task 1, test `exclusiveCreateTakesTheNextID`).

---

### Task 1: Store, skipped files, safe ids, Trash

**Files:** Modify `Sources/LoftLineApp/Model/PostProfileStore.swift`, `Sources/LoftLineApp/App/LoftLineDocument.swift`
(`PostProfileCatalog`), `Sources/LoftLineApp/Model/LoftLineCLI.swift`. Test `Tests/LoftLineAppTests/PostProfileStoreTests.swift`.

**Interfaces — produces:** `struct SkippedPost: Hashable { var fileName: String; var reason: String }`;
`PostProfileStore.load() -> (profiles: [PostProfile], skipped: [SkippedPost])` (`allProfiles()` = `load().profiles`,
`userProfiles()` removed); `static func isSafeID(_ id: String) -> Bool`; `func newID(from base: String) -> String`;
`func saveNew(_ p: PostProfile) throws -> PostProfile` (exclusive create, retrying with `newID` on EEXIST, returns the profile
with the id it was saved under); `func save(_ p: PostProfile) throws` (replaces its own file; refuses an unsafe id);
`var trash: (URL) throws -> Void` (default `FileManager.default.trashItem`); `func delete(id: String) throws`;
`func isUserPost(_ id: String) -> Bool`; `PostProfileCatalog.skipped: [SkippedPost]` (published).

- [ ] **Step 1: Write the failing tests:** `malformedAndNewerFilesAreSkipped`, `unsafeIDIsSkipped` (`../x`),
  `misnamedFileIsSkippedWithItsReason` (also case only: `Shop.json` holding `shop`), `finderCopyDoesNotHideTheOriginal`
  (`x copy.json` and `x.json` both holding `x`: the first skipped, `x.json` loads), `emptyPauseLoadsAsNil`,
  `newIDAvoidsSkippedAndCaseClashes` (and `a-custom-1` → `a-custom-2`, never `a-custom-1-custom-1`),
  `exclusiveCreateTakesTheNextID`, `saveRefusesUnsafeID`, `deleteCallsTheInjectedTrash`, and in `LoftLineCLITests`
  `postsPrintsSkippedFiles`.
- [ ] **Step 2: Run** `scripts/test.sh --filter PostProfileStoreTests` — Expected: build fails.
- [ ] **Step 3: Implement** per spec "The store": name check first (exactly `<id>.json`), then decode, then the safe-id rule, then
  only a loaded file claims an id; reasons from `SnapshotError.errorDescription`. Exclusive create with
  `open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)`; the CLI writes each skipped file to stderr for `posts` and `export`.
- [ ] **Step 4: Run** `scripts/test.sh --filter "PostProfileStoreTests|LoftLineCLITests|ProjectPost|Document"` — Expected: pass.
- [ ] **Step 5: Commit** `feat(app): list post files that did not load; safe post ids and Trash delete`

### Task 2: Controller declaration, part 2's fixes

**Files:** Modify `Sources/PostCore/Model/PostProfile.swift`, `Profiles/BuiltInPosts.swift`, `Model/MachineDefinition.swift`,
`Model/ToolChangeProbe.swift`, `Processor/ProgramBuilder.swift` (`POST_VERSION`), `Validation/ProbeSequenceChecker.swift`.
Test `Tests/PostCoreTests/PostControllerTests.swift`, additions in `ProbeValidatorTests.swift`,
`Tests/LoftLineAppTests/ProjectPostProbeTests.swift`.

**Interfaces — produces:** `PostProfile.controller: ToolChangeProbe.Controller?`; `BuiltInPosts.probeController(for:)` (built-in
by value, else `raw.controller`); `ToolChangeProbe.defaults(controller:units:limits:) -> ToolChangeProbe` (`defaults(for:)`
calls it); refusal messages "The post \"<name>\" declares no controller…" and "…declares GRBL; this machine probes with Mach4…".

- [ ] **Step 1: Write the failing tests:** `controllerRoundTrips`, `noKeyWithoutController` (every built-in's encoded bytes equal
  to before), `droppedControllerCannotProbe`, `declaredMach4Probes`, `undeclaredAndWrongControllerAreRefusedWithMessages`,
  `builtInByValueUnchanged`, `postVersionIsCommentSafe` (`1.0) M3` renders `1.0] M3` inside the header comment),
  `defaultsByControllerMatchDefaultsForMachine`; in `ProbeValidatorTests` `g53ValuesWrittenTowardZeroPass` (inch post at 4
  decimals, GRBL probe with top Z −1 mm: no error) and `unrepresentableParkValuePasses`; in `ProjectPostProbeTests`
  `projectCopyDeclaringMach4Probes`.
- [ ] **Step 2: Run** `scripts/test.sh --filter "PostControllerTests|ProbeValidatorTests|ProjectPostProbeTests"` — Expected: FAIL.
- [ ] **Step 3: Implement**; the checker compares a `G53` value `v` with `Double(NumberFormat.towardZero(expected, decimals))`
  within 1e-9. Update the stale comments the spec lists.
- [ ] **Step 4: Run** the filter, then `scripts/test.sh --filter PostCoreTests` — Expected: pass, goldens unchanged.
- [ ] **Step 5: Commit** `feat(post): a post can declare its controller; probe checks match the written G53 values`

### Task 3: Sample job and the draft report

**Files:** Create `Sources/PostCore/Editor/PostSampleJob.swift`, `Sources/PostCore/Editor/PostDraftReport.swift`. Test
`Tests/PostCoreTests/PostDraftReportTests.swift`.

**Interfaces — produces:** `enum PostSampleJob { static func job(for draft: PostProfile) -> PostJob }` (spec "The sample");
`struct PostDraftReport { var problems: [String]; var program: String?; var issues: [GCodeIssue]; static func make(_ draft:
PostProfile) -> PostDraftReport; var canSave: Bool { problems.isEmpty } }`; `static let placeholders: [Template: Set<String>]`
with `enum Template: CaseIterable { case preamble, footer, toolChange, toolLengthOffset, spindleOn, pause, dwell }` (the table
also drives the editor's captions).

- [ ] **Step 1: Write the failing tests**, one per spec test-3 item (the list in the spec, each a draft from
  `BuiltInPosts.avidMach4Inch` with one field changed, asserting `!canSave` or `canSave`), plus `everyBuiltInIsClean`
  (no problem, no issue) and `unchangedDuplicatesAreClean` (each built-in with `controller` set as Duplicate sets it).
- [ ] **Step 2: Run** `scripts/test.sh --filter PostDraftReportTests` — Expected: build fails.
- [ ] **Step 3: Implement**: static rules in the spec's order; the fixed-code patterns as regular expressions; the comment rule
  scans each template line left to right for an unclosed `(` or a `;` before the placeholder; the sample posted with
  `TemplatePostProcessor`, validated with `validate(toolpaths:)` and `validate(gcode:)`; the parsed stop rules over
  `GCodeParser.parse(program).blocks`; the probe pass with `.on(defaults(controller:units:limits:))` and the spot at the centre.
- [ ] **Step 4: Run** the filter — Expected: pass.
- [ ] **Step 5: Commit** `feat(post): check and preview a post draft against a fixed sample job`

### Task 4: The Post Processors sheet

**Files:** Create `Sources/LoftLineApp/Panels/PostProcessorsSheet.swift`, `Sources/LoftLineApp/Model/PostEditorModel.swift`,
`harness/scenarios/post-processors.json`. Modify `LoftLineDocument.swift` (`DocumentSheet.postProcessors`), `ContentView.swift`,
`LoftLineCommands.swift` (menu item), `Harness/UIHarness.swift` and `HarnessScenario.swift` (`"postProcessors"`). Test
`Tests/LoftLineAppTests/PostEditorModelTests.swift`.

**Interfaces — produces:** `final class PostEditorModel: ObservableObject` with `selection: String?`, `draft: PostProfile?`,
`isNew: Bool`, `isDirty: Bool`, `report: PostDraftReport` (recomputed on each draft change),
`func duplicate()`, `func save() throws`, `func cancel()`, `func delete() throws`, init taking a `PostProfileStore`.

- [ ] **Step 1: Write the failing tests:** `duplicateIsAnUnsavedDraftWithTheBuiltInsController` (no file written),
  `saveWritesANewFileAndReloads`, `listIsLockedWhileDirty` (`selection` change refused while `isDirty`), `cancelDiscards`,
  `emptyPauseTextIsNil`, `deleteTrashesACustomPost`.
- [ ] **Step 2: Run** `scripts/test.sh --filter PostEditorModelTests` — Expected: build fails.
- [ ] **Step 3: Implement** the model, then the sheet (about 960 × 680): list (Built in, Custom, Did not load), the form grouped as
  the spec says with template text areas (`NSTextView` with automatic quote and dash substitution off), placeholder captions
  from `PostDraftReport.placeholders`, the problems list, the read-only monospaced preview; Duplicate, Folder, Delete, Save,
  Cancel. Menu: Toolpaths ▸ Post Processors… beside Open Post Profiles Folder.
- [ ] **Step 4: Run** the filter, then `scripts/ui.sh post-processors --light` and look at the PNG and `.ax.txt`.
- [ ] **Step 5: Commit** `feat(ui): Toolpaths ▸ Post Processors, a sheet to edit, check and preview posts`

### Task 5: Docs

**Files:** `docs/DECISIONS.md` (`post-editor`), `docs/PARITY.md` (`io-post-processors` row), `TESTING.md` (editing a post, the real
Trash, the custom-post air-probe step), Help (Machines and Post Processors).

- [ ] **Step 1: Write** the docs; run `scripts/check-samples.sh` — Expected: no differences.
- [ ] **Step 2: Run** `scripts/build.sh` and `scripts/test.sh` — Expected: green.
- [ ] **Step 3: Commit** `docs: the post editor (decisions, parity, testing, help)`
