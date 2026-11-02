# Unique Ids in a Project: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The app never writes two operations with one id. A file that has them opens repaired. A file with
clashing layers, shapes, models, keep-out zones or tools is refused, with a message that names the clash.

**Spec:** `docs/specs/2026-11-01-duplicate-ids-design.md` (revision 3, approved)

**Ruling:** The operation repair lives in LoftLineApp (`MergeCommands.swift`), not CAMCore, because it needs
`editableSetup`, which LoftLineApp defines. Cost if wrong: one function moves.

**Review Focus:**
- A legacy merge-then-split file keeps its top-level ids.
- The message names positions.

### Task 1: Operation ids stay unique

- [ ] **Step 1: Write the tests in `Tests/LoftLineAppTests/DuplicateIDTests.swift`:**
  - the repair over `[A, B, A′]`, a merge child versus a top-level id, and three items on one id;
  - duplicate a merge, then split both: all ids are unique;
  - merge a toolpath with its own duplicate, then split: all ids are unique.
- [ ] **Step 2:** Run `scripts/test.sh --filter DuplicateID`. Expected: FAIL.
- [ ] **Step 3: Implement it.**
  - `[AnyOperation].givingRepeatedIDsNewOnes()` and `AnyOperation.withNewIDs()`.
  - `duplicateOperation` uses `withNewIDs()`.
  - `splitMerged` and `mergeWithNext` repair afterwards.
- [ ] **Step 4:** Run `scripts/test.sh --filter "DuplicateID|Merge"`. Expected: PASS.

### Task 2: Refuse other clashes; repair operations on open

- [ ] **Step 1: Write the tests.**
  - `Bad` cases `duplicateLayers`, `duplicateShapes`, `duplicateModels`, `duplicateZones` and `duplicateTools`.
  - Message details, in `DuplicateIDTests`.
  - Repair on open.
  - The CLI cases.
- [ ] **Step 2:** Run `scripts/test.sh --filter "ProjectOpening|DuplicateID|LoftLineCLI"`. Expected: FAIL.
- [ ] **Step 3: Implement it.**
  - `ProjectPost.rejectDuplicateIDs(in:)`.
  - In `opening(from:)`, call it, then the repair.
- [ ] **Step 4:** Run the same filter. Expected: PASS. Add the DECISIONS entry, then run `scripts/build.sh` and
  `scripts/test.sh`. Commit.
