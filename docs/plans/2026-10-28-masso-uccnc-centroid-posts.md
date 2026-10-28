# MASSO, UCCNC and Centroid posts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Built-in MASSO G3, UCCNC and Centroid CNC12 posts with their controllers' rules (#107, #108, #103).

**Architecture:** Six data-only posts; the id-based rules move to built-in families (`BuiltInPosts.family(of:)`), an inverted
optional-stop list, a both-ways dwell rule, `toolChangeKeepsZIDs`, `noCoolantReasons`, and `DialectChecks` additions.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** docs/specs/2026-10-28-masso-uccnc-centroid-ncstudio-posts-design.md (revision 3; its rulings override the body)

## Global Constraints

- Existing goldens and `samples/expected/<existing post>/` stay byte-identical; `GCodeValidator` is not weakened.
- Build and test only through the scripts; never write a source file and run tests in one command.

## Review Focus

1. A duplicated MASSO post (`masso-g3-mm-custom-1`): still M0, still the dwell rule, the tool-number and TLO errors (Task 2).
2. An edited GRBL post: M0 now (Task 2; the existing test changes).
3. MASSO with `{SECONDS}`, Centroid with `{MILLISECONDS}`: refused (Task 2).
4. Inch UCCNC/Centroid programs: forbidden-code checks on parsed words (`G20` is not `G2`) (Task 1).
5. A Centroid toolpath dwell of 400 s or 0.005 s: an error (Task 2).

---

### Task 1: The six posts

**Files:** `Sources/PostCore/Profiles/BuiltInPosts.swift`; `Tests/PostCoreTests/PostGoldenTests.swift` (rows, forbidden codes);
`Tests/LoftLineAppTests/MachineConfigTests.swift` (the `other` list); `Tests/PostCoreTests/SnapshotTests.swift` (version 2 for
MASSO and UCCNC); `samples/expected` via `scripts/check-samples.sh --update`.

- [ ] Step 1: failing tests per spec Decisions 1–3 and ruling 8. Step 2: run, FAIL. Step 3: add the posts (appended to `all`
  after Carbide Motion: MASSO inch, mm, UCCNC inch, mm, Centroid inch, mm). Step 4: PASS; samples update adds six folders only;
  full suite green. Commit `feat(post): built-in MASSO G3, UCCNC and Centroid CNC12 posts`.

### Task 2: The rules

**Files:** `BuiltInPosts.swift` (`family(of:)`, `optionalStopIDs`, `toolChangeKeepsZIDs`, `noCoolantReasons`; remove
`secondsNoOptionalStopIDs`, `grblIDs`, `noCoolantIDs`), `PostProfile.swift` (`honoursOptionalStop`, `dwellProblem`),
`ToolChangeZ.swift`, `DialectChecks.swift`, `OthermillSetup.swift` (by family), `PostSampleJob.swift`; tests in `PostPauseTests`,
`PostProcessorTests`, `DialectChecksTests`, `ToolChangeZTests`, `OthermillSetupTests`, `PostDraftReportTests`, `LoftLineCLITests`
(the UCCNC warning prefix).

- [ ] Step 1: failing tests per spec Decision 4–5 and rulings 1–7. Step 2: run, FAIL. Step 3: implement. Step 4: PASS; full
  suite green. Commit `feat(post): controller rules by built-in family (optional stop, dwell unit, tool-change Z, MASSO, UCCNC, Centroid)`.

### Task 3: Docs

- [ ] DECISIONS, Help, TESTING, README, PARITY per the spec's Docs and ruling 9; green; commit `docs: MASSO, UCCNC and Centroid posts`.
