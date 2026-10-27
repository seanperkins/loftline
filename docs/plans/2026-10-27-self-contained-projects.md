# Self-Contained Projects Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `.loftline` file carries a full copy of its post, machine and tools, posts from them on any Mac, and tells the user when the installed ones differ.

**Architecture:** CAMCore cannot name PostCore types, so the file stores the post and machine as plain `JSONValue` and an app-layer `ProjectPost` resolver interprets them. Copies are attached at `LoftLineDocument.init`, kept in step in `perform`, and refreshed by one undoable "Update This Project". Tools use the same rule through `ToolSync` and a flipped `mergedTools`.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, targets CADCore, CAMCore, PostCore, LoftLineApp.

**Spec:** `docs/specs/2026-10-27-self-contained-projects-design.md` (reviewed; the spec wins over this plan).

## Global Constraints

- Run every command from the worktree: `cd /Users/sean/sites/loftline/.worktrees/loftline-posts && scripts/...`. Build and test only through `scripts/build.sh` and `scripts/test.sh [--filter X]`; judge a run by its `Test run with N tests ... passed` line, not the exit code.
- Never write a source file and run tests in the same shell command; if a run sits at 0% CPU, kill `swift-test` / `swiftpm-testing-helper` and retry once.
- File format version **2**; `schemaVersion` **1** on `PostProfile` and `MachineDefinition`; version 1 files open unchanged and nothing is rewritten without a save.
- `samples/expected/`, `samples/*.tap` and every golden must not change by one byte. Never weaken a `GCodeValidator` check. Hand-built test projects stay copy-less on purpose.
- Nil `postProfileID` / `machineID` are never written by attaching. Effective post id = `postProfileID ?? PostProfileStore.defaultID(for: units)`.
- Conventional commits, one logical change each, no attribution lines. Done = `scripts/build.sh` and `scripts/test.sh` green (>= 1638 tests plus the new ones).

## Review Focus

- An old project (nil ids) that switches post or machine, or converts units, resolves exactly as before: Task 4.
- A copy with a mismatched id, a `null` copy, a malformed copy or a newer schema never posts: Tasks 3 and 5.
- A tool changed while an export's calculation runs never posts the old cutter: Task 11.
- Tool Database edit with the project open (follows) and closed (warns, file's tool posts): Task 8.
- Saving on a Mac whose library tool differs does not rewrite the file's tool: Task 8.

---

### Task 1: JSONValue, schema versions, snapshot conversions

**Files:**
- Create: `Sources/CADCore/Persistence/JSONValue.swift`, `Sources/PostCore/Model/SnapshotError.swift`
- Modify: `Sources/PostCore/Model/PostProfile.swift` (`toJSON`/`fromJSON` ~l.131), `Sources/PostCore/Model/MachineDefinition.swift` (~l.71)
- Test: `Tests/CADCoreTests/JSONValueTests.swift`, `Tests/PostCoreTests/SnapshotTests.swift`

**Interfaces:**
- Produces: `public enum JSONValue: Codable, Hashable, Sendable` (`null, bool, number(Double), string, array, object`) with `init<T: Encodable>(encoding: T) throws` and `func decoded<T: Decodable>(_: T.Type) throws -> T`; `public enum SnapshotError: Error, Equatable { case newerSchema(found: Int, supported: Int); case malformed(String) }`; on both `PostProfile` and `MachineDefinition`: `public var schemaVersion: Int`, `public static let currentSchemaVersion = 1`, `init(snapshot: JSONValue) throws`, `func snapshot() throws -> JSONValue`; `fromJSON` also throws `newerSchema`.

- [ ] **Step 1: Write the failing tests.** `jsonValueRoundTripsEveryBuiltInPostAndMachine` (`PostProfile(snapshot: p.snapshot()) == p` for `BuiltInPosts.all`, `BuiltInMachines.all`); `jsonValueKeepsExtremes` (1e300, 1e-300, a 3000-character string, nested arrays/objects, empty array and string); `schemaVersionAbsentDecodesAsOne` (JSON without the key loads, `schemaVersion == 1`, both types); `newerSchemaThrows` (`schemaVersion: 2` -> `SnapshotError.newerSchema(found: 2, supported: 1)` from `init(snapshot:)` and from `fromJSON`, both types); `undecodableSnapshotIsMalformed`; `everyFieldSurvivesTheDecoder` (a post with every optional set round-trips `==`, guarding a forgotten key).
- [ ] **Step 2: Run** `scripts/test.sh --filter JSONValue` then `--filter Snapshot`. Expected: build error `cannot find 'JSONValue'`.
- [ ] **Step 3: Implement** the types above. `schemaVersion` always encodes; decoding defaults to 1, which needs a hand-written `init(from:)` with `CodingKeys` on both structs (synthesized Codable throws on a missing key). `fromJSON` and `init(snapshot:)` share one checked decode that reads `schemaVersion` first.
- [ ] **Step 4: Run** `scripts/test.sh --filter PostCore` and the two filters. Expected: all pass, `PostGoldenTests` unchanged.
- [ ] **Step 5: Commit** `feat(post): schema versions and JSON snapshots for posts and machines`.

### Task 2: File format 2 and the project fields

**Files:**
- Modify: `Sources/CAMCore/Model/LoftLineProject.swift` (`currentFormatVersion`, fields, init), `Sources/CADCore/Persistence/LoftLineFile.swift` (`currentVersion`, `migrations`, `DocumentFile`)
- Test: `Tests/CAMCoreTests/LoftLineProjectFormatTests.swift` (new), `Tests/CADCoreTests/IOLoftLineFileTests.swift`

**Interfaces:**
- Produces: `LoftLineProject.postSnapshot: JSONValue?`, `machineSnapshot: JSONValue?`, `machineInferredFor: String?` (nil by default, omitted from JSON when nil); `LoftLineProject.currentFormatVersion == 2 == LoftLineFile.currentVersion`; `migrations[1]` is a no-op closure.

- [ ] **Step 1: Write the failing tests.** `versionOneFixtureDecodesWithNoCopies`; `projectWithCopiesEncodesVersionTwoAndRoundTrips` (nested JSON, not base64); `versionThreeIsRefused`; `migrationOneToTwoOnlyChangesTheNumber` (compare the objects minus `formatVersion`); `documentFileReadsOneWritesTwo`. Update the existing `IOLoftLineFileTests` expectation that pins version 1.
- [ ] **Step 2: Run** `scripts/test.sh --filter LoftLineProjectFormat`. Expected: FAIL (`formatVersion` 1, no fields).
- [ ] **Step 3: Implement** the version bumps, the three fields, the no-op migration `1 -> 2`, and `DocumentFile` writing 2.
- [ ] **Step 4: Run** `scripts/test.sh --filter CADCore` and `--filter CAMCore`. Expected: pass; goldens untouched.
- [ ] **Step 5: Commit** `feat(format): version 2 files carry post, machine and tool copies`.

### Task 3: ProjectPost resolver, validation, and `opening(from:)`

**Files:**
- Create: `Sources/LoftLineApp/Model/ProjectPost.swift`
- Test: `Tests/LoftLineAppTests/ProjectPostResolveTests.swift`

**Interfaces:**
- Consumes: Task 1 and 2 types; `MachineResolver.machine(for:machines:)`, `MachineResolver.effectiveProfile`.
- Produces: `enum ProjectPost { enum Source: Equatable { case projectCopy, installed, fallback(missingID: String) }; struct Resolved { var post: PostProfile; var machine: MachineDefinition?; var postSource: Source; var machineSource: Source?; var postCopyDiffers: (copy: PostProfile, installed: PostProfile)?; var machineCopyDiffers: (copy: MachineDefinition, installed: MachineDefinition)? }; static func validate(_ p: LoftLineProject) throws; static func resolve(_ p: LoftLineProject, profiles: [PostProfile], machines: [MachineDefinition]) -> Resolved }`; `extension LoftLineProject { static func opening(from data: Data) throws -> LoftLineProject }` (decode, then `validate`, and refuse a `postSnapshot` / `machineSnapshot` key whose raw value is `null`, read as `[String: JSONValue]`).

- [ ] **Step 1: Write the failing tests** (arrays passed explicitly, no catalogs). `copyPostsWhenInstalledChanged` (G-code from the copy, byte for byte, via `GCodeExporter`); `uninstalledPostWithCopyPostsWithoutError`; `noCopyNoInstalledKeepsFallback`; `machineLimitsComeFromCopy`; `copyWithOtherIDIsIgnored`; `nilMachineIDCopyValidOnlyWhileMachineInferredForEqualsEffectivePost` (two installed machines supporting the new post: result is `MachineResolver`'s first); `machineIDNamingUninstalledMachineHasNoCopyAndResolvesAsToday`; `openingRefusesNewerMalformedAndNullCopies` (each key, each case, message "made with a newer LoftLine. Update LoftLine to open it." for newer).
- [ ] **Step 2: Run** `scripts/test.sh --filter ProjectPostResolve`. Expected: build error `cannot find 'ProjectPost'`.
- [ ] **Step 3: Implement** per spec section 4: post copy used while its id equals the effective post id; machine copy while its id equals `machineID`, or (nil `machineID`) `machineInferredFor == effective post id`; machine limits applied with `MachineResolver.effectiveProfile`; `Resolved` reports sources and `Hashable ==` differences against the installed definition of the same id.
- [ ] **Step 4: Run** the filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(app): resolve a project's post and machine from its own copies`.

### Task 4: Attach, sync, notices, document wiring, Update This Project

**Files:**
- Modify: `Sources/LoftLineApp/Model/ProjectPost.swift`, `Sources/LoftLineApp/App/LoftLineDocument.swift` (`init(project:toolLibrary:)` ~l.212, `perform` ~l.360, `postProfile`/`machine`/`postProfileIssues` ~l.398-411, `setPostProfile` ~l.821)
- Test: `Tests/LoftLineAppTests/ProjectPostDocumentTests.swift`

**Interfaces:**
- Consumes: Task 3.
- Produces: `ProjectPost.attaching(_:profiles:machines:) -> LoftLineProject`, `syncing(_:profiles:machines:) -> LoftLineProject`, `updated(_:profiles:machines:) -> LoftLineProject` (each copy replaced by the installed definition of the copy's own id when installed, else kept), `issues(for:profiles:machines:) -> [GCodeIssue]`; `LoftLineDocument.init(project:toolLibrary:postCatalog:machineCatalog:)` (both default `.shared`); `func updateProjectFromInstalled()` (`perform("Update Post")`); `var hasCopyDifferences: Bool`.

- [ ] **Step 1: Write the failing tests** with explicit `PostProfileCatalog(store:)` / `MachineCatalog(store:)` on temp dirs. `openingVersionOneAttachesCopiesKeepsNilIdsAndDocumentUnedited`; `attachSnapshotsWhatTheSelectionNames` (nil machine: inferred machine + `machineInferredFor`; named-but-uninstalled machine: no copy); `pickingPostPickingMachineApplyTemplateAndNewProjectLeaveMatchingCopy`; `nilMachineProjectSwitchingAvidToGRBLGetsGRBLMachine` (equals `MachineResolver` today); `convertingNilPostProjectToMMMovesToMMDefaultPostAndCopy` (`converted(to:)` through `perform`); `syncLeavesAMatchingCopyAlone`; `updateReplacesEachCopyWithInstalledOfSameIDAndUndoes` and `updateKeepsACopyWithNoInstalledCounterpart`; `warningExactlyWhenCopyDiffers` (post names both versions, equal versions drop them, machine names both bed sizes) and appears in the issues `ExportGCodeSheet` and `SaveAllToolpathsSheet` merge; `missingPostWithoutCopyKeepsTheError`; `reloadingPostCatalogRefreshesNotice`; `attachingTreatsAnUnreadableCopyAsAbsent`; `storesSkipUserPostAndMachineFilesWithANewerSchema` (the built-in of that id shows).
- [ ] **Step 2: Run** `scripts/test.sh --filter ProjectPostDocument`. Expected: FAIL / build error.
- [ ] **Step 3: Implement.** `init` attaches in memory only (not dirty). `perform` runs `syncing` after the change closure and before the `p != project` comparison; a nil-`machineID` machine copy is re-inferred whenever `machineInferredFor` no longer equals the effective post id. `postProfile`, `machine`, `postProfileIssues` go through `resolve`/`issues` (error only with no copy and the post not installed; warning when a copy differs). `ToolDatabaseView` (~l.145-158) resolves through `ProjectPost`.
- [ ] **Step 4: Run** `scripts/test.sh --filter LoftLineDocument` and the new filter. Expected: pass.
- [ ] **Step 5: Commit** `feat(app): attach, sync and update a project's post and machine copies`.

### Task 5: Every file-to-project caller refuses bad copies; the CLI posts from the copy

**Files:**
- Modify: `Sources/LoftLineApp/App/LoftLineDocument.swift` (`init(configuration:)` ~l.227), `Sources/LoftLineApp/Model/LoftLineCLI.swift` (~l.197-230), `Sources/LoftLineApp/Model/RecoveryStore.swift:52`, `Sources/LoftLineApp/Model/JobTemplateStore.swift:42`, `Sources/LoftLineApp/Harness/UIHarness.swift:260,270`
- Test: `Tests/LoftLineAppTests/ProjectOpeningTests.swift`, `Tests/LoftLineAppTests/LoftLineCLITests.swift`

**Interfaces:** Consumes `LoftLineProject.opening(from:)`, `ProjectPost.resolve`. `ClipartLibrary` keeps `decode`.

- [ ] **Step 1: Write the failing tests.** For document open, `RecoveryStore`, `JobTemplateStore` and the CLI: a newer-schema copy, a malformed copy and a `null` copy are each refused with the message and never opened with the installed post (CLI exit code 2). CLI: `postsFromTheCopy`; `postOverrideUsesInstalledEvenWhenIDsEqual` and installed id must exist; `overrideKeepsMachineInferredFromTheProjectAsOpened` (nil `machineID`, Avid overridden to GRBL still posts with Avid limits); `overrideStillSuppressesMissingPostErrorAndRapidRateComesFromProjectsOwnPost`; `builtinOnlyKeepsTheCopy`.
- [ ] **Step 2: Run** `scripts/test.sh --filter ProjectOpening` and `--filter LoftLineCLI`. Expected: FAIL.
- [ ] **Step 3: Implement.** Replace `decode` with `opening(from:)` at the five callers. In the CLI: resolve the machine first from the project as opened, then replace only the post with the installed one for `--post`; do not write `postProfileID` into the project.
- [ ] **Step 4: Run** both filters. Expected: pass.
- [ ] **Step 5: Commit** `feat(cli): refuse unreadable copies everywhere a project opens; post from the copy`.

### Task 6: Job Setup uses the copies

**Files:**
- Modify: `Sources/LoftLineApp/Model/JobSetupForm.swift` (`init(project:machines:)` ~l.35), `Sources/LoftLineApp/Panels/JobSetupSheet.swift` (~l.9-47)
- Test: `Tests/LoftLineAppTests/JobSetupMachineTests.swift`

**Interfaces:** Consumes `ProjectPost.resolve`. Produces `JobSetupForm.machine: MachineDefinition?` (the project's copy when valid, else installed, else nil) and `init(project:machines:profiles:)`.

- [ ] **Step 1: Write the failing tests.** `formStartsOnProjectsOwnMachineWhenNotInstalled`; `applyingMaterialSizeOnlyWritesTheSameResolvedIDsAsToday` (nil-id project and uninstalled-machine project: copies stay attached); `unitsChangeInsideJobSetupKeepsTheOpenedPost`; `sheetBedFitAndPostGroupingUseTheCopy`; `pickerListsUninstalledCopyAsNotInstalledHere`; `updateButtonShownForPostOrMachineDifference` (the tool case is tested in Task 8).
- [ ] **Step 2: Run** `scripts/test.sh --filter JobSetupMachine`. Expected: FAIL.
- [ ] **Step 3: Implement.** The form resolves through `ProjectPost` and keeps `form.machine`; `JobSetupSheet` uses it for `MachineResolver.fitProblems` and the compatible-post grouping instead of `machines.machine(id:)`; add the "Using this project's copy of «name» vX" line, "(not installed here)", the warning, and an **Update This Project** button calling `updateProjectFromInstalled()`. `apply(to:)` keeps writing ids only when the form holds one.
- [ ] **Step 4: Run** the filter plus `scripts/ui.sh main --light`. Expected: tests pass; the screenshot shows the copy line.
- [ ] **Step 5: Commit** `feat(app): Job Setup shows and updates the project's copies`.

### Task 7: ToolSync core and the flipped merge

**Files:**
- Create: `Sources/LoftLineApp/Model/ToolSync.swift`
- Modify: `Sources/CAMCore/Model/LoftLineProject.swift` (`mergedTools` l.42), `Sources/LoftLineApp/Model/ProjectEditing.swift` (`refreshToolSnapshot` l.123), `Sources/CADCore/Model/Tool.swift` (extension)
- Test: `Tests/LoftLineAppTests/ToolSyncTests.swift`, `Tests/CAMCoreTests/` (merge precedence)

**Interfaces:**
- Produces: `extension Tool { func samePostingFields(as other: Tool) -> Bool }` (equal except `notes` and `group`); `enum ToolSync { static func carrying(_ p: LoftLineProject, library: ToolLibrary) -> LoftLineProject; static func applyingLibraryChange(old: ToolLibrary, new: ToolLibrary, to p: LoftLineProject) -> LoftLineProject; static func differences(_ p: LoftLineProject, library: ToolLibrary) -> [(carried: Tool, library: Tool)]; static func issues(for p: LoftLineProject, library: ToolLibrary) -> [GCodeIssue]; static func updated(_ p: LoftLineProject, library: ToolLibrary) -> LoftLineProject }`; `mergedTools(with:)` now lets the project's tools win.

- [ ] **Step 1: Write the failing tests.** `projectToolWinsOverDifferingLibraryTool`; `carryingAddsReferencedAndDropsUnreferenced`; `refreshToolSnapshotNoLongerOverwrites`; `followsLibraryEditOnlyWhenCarriedEqualsOldLibraryEntry` (label-only edit of a library tool whose diameter differs from the carried copy leaves the carried diameter); `followKeepsCarriedNotesAndGroup`; `differenceIgnoresNotesAndGroupButNotName`; `issuesNameToolAndDiameters`; `updatedReplacesToolsWithCounterpartAndKeepsOthers`.
- [ ] **Step 2: Run** `scripts/test.sh --filter ToolSync`. Expected: build error.
- [ ] **Step 3: Implement** per spec section 9. `refreshToolSnapshot(from:)` calls `ToolSync.carrying` only.
- [ ] **Step 4: Run** `scripts/test.sh --filter ToolSync` then `--filter Ops2D`. Expected: pass; toolpath tests unchanged.
- [ ] **Step 5: Commit** `feat(tools): the project's tool copy wins over the library`.

### Task 8: Document wiring for tools

**Files:**
- Modify: `Sources/LoftLineApp/App/LoftLineDocument.swift` (`init` sinks ~l.212-218, `perform`, `updateOperationLive` ~l.596, `replaceProject` ~l.368, `store` ~l.802, `showToolNames` ~l.810, `postProfileIssues`, `updateProjectFromInstalled`), `Sources/LoftLineApp/Panels/OperationEditor.swift` (~l.35), `Sources/LoftLineApp/Model/OperationWarnings.swift` (~l.14)
- Test: `Tests/LoftLineAppTests/ToolSyncDocumentTests.swift`

**Interfaces:** Consumes Task 7. Library reads in these files change to `mergedLibrary`.

- [ ] **Step 1: Write the failing tests.** `toolAddedToAnOperationIsCarriedAtOnce` (also via `updateOperationLive`; save, edit library, calculate, no reopen); `savingWithDifferingLibraryToolLeavesFilesToolUnchanged`; `appAndCLIGCodeMatchWithDifferentLibraryToolName` (tool-change comment); `warningsAndEditorDescribeTheToolThatCuts`; `libraryEditFollowsIntoOpenProjectMarksUnsavedAndUndoesAsOneStep`; `editOfAnotherToolChangesNothing`; `undoingAnEarlierEditDoesNotRollTheLibraryBack`; `toolChangeBumpsDesignRevisionIncludingUndoRedo`; `closedProjectWithEditedLibraryToolWarnsAndPostsTheFilesTool`; `toolDifferenceAddsWarningAndUpdateButtonState`; `updateThisProjectReplacesToolsWithPostAndMachineInOneUndo`.
- [ ] **Step 2: Run** `scripts/test.sh --filter ToolSyncDocument`. Expected: FAIL.
- [ ] **Step 3: Implement.** `ToolSync.carrying` after `perform`, after `updateOperationLive`, and in `init`. Keep `lastLibrary`; on `toolLibrary.$library` change apply `applyingLibraryChange` as one undoable "Update Tool from Library" step. `replaceProject` bumps `designRevision` when `tools` changed as well as `document`. `store`/`showToolNames`/editor/warnings read the merged library. `postProfileIssues` appends `ToolSync.issues`; Update This Project also runs `ToolSync.updated`.
- [ ] **Step 4: Run** the filter and `--filter LoftLineDocument`. Expected: pass.
- [ ] **Step 5: Commit** `feat(tools): live edits follow into open projects; saves keep the file's tools`.

### Task 9: Template apply carries the template's tool

**Files:**
- Modify: `Sources/LoftLineApp/Model/TemplateService.swift` (`apply` l.20-40), `Sources/LoftLineApp/Model/OperationFactory.swift` (next to `referencedToolIDs` l.67)
- Test: `Tests/LoftLineAppTests/ToolpathTemplateTests.swift`

**Interfaces:** Produces `extension AnyOperation { func remappingTool(_ from: UUID, to: UUID) -> AnyOperation }` covering every id in `referencedToolIDs`.

- [ ] **Step 1: Write the failing tests.** `templateToolIsCarriedEvenWhenLibraryHasTheID`; `identicalCarriedToolIsReused`; `differingCarriedToolGetsAFreshIDAndRemappedOperationsWhileExistingOperationsKeepTheirTool`; `sharedTNumberRaisesTheValidatorErrorWithoutRenumbering`.
- [ ] **Step 2: Run** `scripts/test.sh --filter ToolpathTemplate`. Expected: FAIL.
- [ ] **Step 3: Implement** the rule in spec section 9 (template copy wins; clash with a different carried tool -> fresh id + remap; number kept).
- [ ] **Step 4: Run** the filter. Expected: pass.
- [ ] **Step 5: Commit** `fix(templates): applying a template keeps the template's own tool`.

### Task 10: Tiled export carries the notices

**Files:**
- Modify: `Sources/LoftLineApp/Model/TiledExport.swift` (`files(project:results:profile:groupByTool:settings:)` l.22), `Sources/LoftLineApp/Panels/TilingSheet.swift`
- Test: `Tests/LoftLineAppTests/TiledExportTests.swift` (find or create)

**Interfaces:** Produces an added parameter `extraIssues: [GCodeIssue] = []` on `TiledExport.files`, inserted at index 0 of each tile result's issues like `missing`.

- [ ] **Step 1: Write the failing test** `tileFilesCarryCopyDifferenceAndMissingPostIssues`.
- [ ] **Step 2: Run** `scripts/test.sh --filter TiledExport`. Expected: FAIL.
- [ ] **Step 3: Implement**; `TilingSheet` passes `document.postProfileIssues`.
- [ ] **Step 4: Run** the filter. Expected: pass.
- [ ] **Step 5: Commit** `fix(export): tiled export shows the same post, machine and tool notices`.

### Task 11: Calculate until fresh before any export or validation

**Files:**
- Modify: `Sources/LoftLineApp/App/LoftLineDocument.swift` (next to `calculateAndWait` ~l.770), `ExportGCodeSheet.swift:~134`, `SaveAllToolpathsSheet.swift:~124`, `TilingSheet.swift:~117`, `ValidationSheet.swift:~100` (all in `Sources/LoftLineApp/Panels/`)
- Test: `Tests/LoftLineAppTests/CalculateUntilFreshTests.swift`

**Interfaces:** Produces `@MainActor func calculateUntilFresh(targets: [UUID]) async -> Bool` (re-evaluates which targets are stale before each of at most five `calculateAndWait` passes; true only when none is stale). Sheets act only on true, otherwise show "The project changed while it was being calculated. Export again."

- [ ] **Step 1: Write the failing tests.** `changingACarriedToolDuringCalculationPostsTheNewTool`; `returnsFalseAfterFivePassesOfConstantChange`; `recheckCoversTargetsThatBecameStaleLater`.
- [ ] **Step 2: Run** `scripts/test.sh --filter CalculateUntilFresh`. Expected: FAIL.
- [ ] **Step 3: Implement** and switch the four sheets' `run()` to it. Leave `LoftLineDocument+Layout.swift:20` (it ignores the result).
- [ ] **Step 4: Run** the filter and `--filter GCodeFileSet`. Expected: pass.
- [ ] **Step 5: Commit** `fix(export): never post a result computed before a change`.

### Task 12: Regenerate samples and harness projects; prove the goldens

**Files:**
- Modify: `Tests/LoftLineAppTests/SampleFilesTests.swift`, `Tests/LoftLineAppTests/HarnessProjectsTests.swift` (generators attach copies via `ProjectPost.attaching` + `ToolSync.carrying` before encoding), regenerated `samples/*.loftline` and harness projects

- [ ] **Step 1: Write the failing test** `samplesCarryCopiesAndSampleToolsEqualTheSeededLibrary` (each sample is version 2 with a post copy, a machine copy and tools equal to `ToolLibrary.seeded`).
- [ ] **Step 2: Run** `scripts/test.sh --filter SampleFiles`. Expected: FAIL (samples are version 1).
- [ ] **Step 3: Regenerate** in two separate runs: `LOFTLINE_WRITE_SAMPLES=1 scripts/test.sh --filter SampleFiles`, then `LOFTLINE_WRITE_SAMPLES=1 scripts/test.sh --filter HarnessProjects`.
- [ ] **Step 4: Run** `scripts/check-samples.sh` (no `--update`) and `git status --short samples/expected samples/*.tap Tests/Fixtures/golden`. Expected: check passes; no change under `samples/expected`, `*.tap` or golden fixtures.
- [ ] **Step 5: Commit** `chore(samples): regenerate samples and harness projects as format 2`.

### Task 13: Docs, manual check, final suite

**Files:**
- Modify: `docs/DECISIONS.md` (`project-carries-post`, `snapshot-schema`, `tool-copy-wins`), `docs/PARITY.md` (self-contained projects row), `TESTING.md` (manual check from the spec, including Reload Post Profiles and the tools drill), `Sources/LoftLineApp/Model/HelpTopics.swift` (Job Setup and Machines topics), `README.md` ("Command line" note)

- [ ] **Step 1: Write the docs** from the spec's "Docs to update" and "Manual check" sections.
- [ ] **Step 2: Run** `scripts/test.sh --filter HelpTopics`. Expected: pass.
- [ ] **Step 3: Run** `scripts/build.sh` then, separately, `scripts/test.sh`. Expected: build succeeds; `Test run with N tests ... passed`, N >= 1638 plus the new tests.
- [ ] **Step 4: Commit** `docs: self-contained projects (decisions, parity, testing, help)`.
