# Share a Post Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task.

**Goal:** Export a custom post as a `.loftlinepost` file, import one as an unsaved draft, and add the post the open project
carries, with every part 3 check and no overwrite.

**Architecture:** One `PostProfile.normalized` rule on every read path; `PostProfileStore.read`, `importID` and
`saveNew(keepingID:)`; `PostEditorModel.beginImport` and `addState`; three buttons in the Post Processors sheet.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, SwiftUI. **Spec:** `docs/specs/2026-10-28-post-share-design.md` (revision 3).

## Global Constraints

- Built-in posts, goldens, `samples/expected/` byte-identical. An imported post posts only after Save; never overwrites.

## Review Focus

1. A project carrying `pause: []` posts `M0` at its pause (Task 1, `carriedEmptyPauseStops`).
2. Add keeps the project's id even when another window saved it meanwhile (Task 1, `keepingIDRefusesAnExistingFile`).

---

### Task 1: One empty-pause rule, and safe new saves

**Files:** `Sources/PostCore/Model/PostProfile.swift` (`var normalized: PostProfile`), `Sources/LoftLineApp/Model/PostProfileStore.swift`
(`load()` uses it; `saveNew(_:keepingID: Bool = false)`; cleanup on a failed write via an injectable `write: (FileHandle, Data) throws -> Void`),
`Sources/LoftLineApp/Model/ProjectPost.swift` (`postCopy(of:)` returns `.normalized`). Tests: `Tests/LoftLineAppTests/PostShareTests.swift`.

- [ ] Tests: `normalizedReadsEmptyPauseAsNil`; `carriedEmptyPauseStops` (a project whose post snapshot has `pause: []` posts `M0`
  after its pause and, once that post is installed, resolves with no copy-differs warning); `keepingIDRefusesAnExistingFile`;
  `failedNewSaveLeavesNoFile`. Run `scripts/test.sh --filter PostShareTests` → FAIL; implement; → PASS.
- [ ] Commit `fix(post): an empty pause list reads as the default pause everywhere; a failed new save leaves no file`.

### Task 2: Reading, ids, the import draft and the Add state

**Files:** `PostProfileStore.swift` (`read(_ url:) throws -> PostProfile`, 1 MB checked with `fileSizeKey` before reading;
`importID(for:) -> String`), `PostEditorModel.swift` (`beginImport(_:)`, private `beginDraft(_:)` shared with `duplicate()`,
`enum AddState { case hidden, enabled, disabled(String) }`, `addState(for:)`, `addCarried(_:)` which drafts with the id kept and
saves with `keepingID`), `LoftLineDocument.swift` (`carriedPostNotInstalled` returns `ProjectPost.postCopy(of:)`). Tests in
`PostShareTests`.

- [ ] Tests: `importIDKeepsAFreeIDAndRenamesTakenOnes` (built-in id, loaded id, case-only clash, skipped file's name, unsafe id →
  `imported-post`); `importDraftIsUnsavedAndChecked`; `importedBuiltInKeepsItsController`; `importedProbeKeyIsDropped`;
  `readRefusesABigFileBeforeReading` (sparse 2 MB file) and `readRefusesMalformed`; `addStateCases` (hidden, dirty, unsafe id,
  taken id, enabled); `carriedPostIsTheRawCopy` (limits differ from the project's machine; after Add and Save the project resolves
  it installed, equal, no warning). FAIL → implement → PASS.
- [ ] Commit `feat(app): import a post file as a draft; add the project's post`.

### Task 3: Buttons, notice, docs

**Files:** `PostProcessorsSheet.swift` (`carried:` parameter; Import…, Export…, Add This Project's Post; disabled while dirty),
`ContentView.swift` (passes `document.carriedPostNotInstalled`), `ProjectPost.swift` (the "not installed here" notice adds "Add it in
Toolpaths ▸ Post Processors"), `docs/DECISIONS.md` (`post-share`), `docs/PARITY.md`, `TESTING.md`, Help.

- [ ] Test `exportWritesTheSavedPostsBytes` (model `exportData()` equals `toJSON()` of the saved custom post; nil for a built-in).
  FAIL → implement → PASS. `scripts/build.sh`, `scripts/check-samples.sh`, `scripts/test.sh` green.
- [ ] Commit `feat(ui): export, import and add a project's post in Post Processors` and `docs: share a post`.
