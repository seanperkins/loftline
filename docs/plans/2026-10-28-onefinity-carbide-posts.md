# Onefinity and Carbide Motion posts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Built-in Onefinity Buildbotics and Carbide Motion posts, four machines, and the export checks those controllers need (#104, #105, #100).

**Architecture:** Data-only posts and machines; two id sets in `BuiltInPosts` (`secondsNoOptionalStopIDs`, `noCoolantIDs`) read by
`honoursOptionalStop`, `dwellProblem`, `PostSampleJob` and a new PostCore `DialectChecks` called beside `ToolChangeZ` in the exporter.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** docs/specs/2026-10-28-onefinity-carbide-posts-design.md (revision 4)

## Global Constraints

- Existing goldens and `samples/expected/<existing post>/` stay byte-identical; `GCodeValidator` is not weakened.
- `BuiltInMachines.genericGRBL` is unchanged.
- Build and test only through `scripts/build.sh` and `scripts/test.sh`; never write a source file and run tests in one command.

## Review Focus

1. A tool named `1/4" End Mill (2 flute)` on a Carbide Motion post: no `(` anywhere in the program (Task 1 test).
2. An edited Carbide Motion or BB post keeping its id: still M0 for an optional stop and no `{MILLISECONDS}` (Task 1 test).
3. A saved Generic GRBL project: no "copy differs" warning (Task 2: `genericGRBL` unchanged, test).
4. Two cutters numbered 1 that differ only in tip diameter or shape: a validator error on every post (Task 3 test).
5. Coolant on Othermill and Carbide Motion: one error each, with its own reason (Task 3 test).

---

### Task 1: The posts and their rules

**Files:** `Sources/PostCore/Profiles/BuiltInPosts.swift` (four posts, `bbPreamble`, `carbidePreamble`, `carbideToolChange`,
`secondsNoOptionalStopIDs`, `noCoolantIDs`), `Sources/PostCore/Model/PostProfile.swift` (`honoursOptionalStop`, `dwellProblem`,
`comment` for semicolons, docs), `Tests/PostCoreTests/PostGoldenTests.swift`, `PostPauseTests.swift`, `PostProcessorTests.swift`,
`Tests/LoftLineAppTests/MachineConfigTests.swift` (the `other` list); `samples/expected/` via `scripts/check-samples.sh --update`.

- [ ] **Step 1: Failing tests:** `newPosts` and `newPostNumbers` rows per spec Decisions 1–2; forbidden-codes loop for the four
  posts in both Z-zero modes (BB: `G40`, `G80`, `M30`, `M1`; CM: `G94`, `G80`, `G91.1`, `M30`, `M1`, and no `(` on any line,
  the fixture tool being `1/4" End Mill (2 flute)`); `G4 P3` present; optional stop writes `M0` for BB and CM as built,
  Avid-applied and edited with the same id; `dwellProblem` refuses `{MILLISECONDS}` on edited BB, CM and GRBL copies keeping
  their ids; a semicolon comment of `a (b)` is `; a [b]`.
- [ ] **Step 2:** `scripts/test.sh --filter "PostGoldenTests|PostPauseTests|PostProcessorTests|golden|newPosts"` → FAIL.
- [ ] **Step 3:** Implement per the spec.
- [ ] **Step 4:** Filter → PASS; `scripts/check-samples.sh --update` adds only the four new folders; read one by eye;
  `scripts/test.sh` green. Commit `feat(post): built-in Onefinity Buildbotics and Carbide Motion posts (#104, #105)`.

### Task 2: Machines

**Files:** `Sources/PostCore/Model/MachineDefinition.swift` (`BuiltInMachines`: four machines appended, doc comment); tests in
`Tests/PostCoreTests/PostGoldenTests.swift` (machine table) and `Tests/LoftLineAppTests/MachineConfigTests.swift` (inference).

- [ ] **Step 1: Failing tests:** a table of the four machines with every number in spec Decisions 6–7 and their post lists;
  `genericGRBL == ` its current value (postIDs `["generic-grbl-mm"]`); inference: `generic-grbl-mm` → `generic-grbl`, an unmarked
  `generic-grbl-inch` project → no machine; park-and-probe on the Woodworker and the Shapeoko refuses.
- [ ] **Step 2:** `scripts/test.sh --filter "othermillMachines|newMachines|MachineConfigTests"` → FAIL.
- [ ] **Step 3:** Implement. **Step 4:** PASS; `scripts/test.sh` green. Commit `feat(post): Onefinity, Shapeoko, Genmitsu and LongMill machines`.

### Task 3: `DialectChecks` and the tool geometry test

**Files:** create `Sources/PostCore/Validation/DialectChecks.swift`; `Sources/CADCore/Model/Tool.swift` (`hasSameGeometry(as:)`),
`Sources/PostCore/Validation/GCodeValidator.swift` and `Sources/LoftLineApp/Model/PreflightChecks.swift` (use it); modify `OthermillSetup.swift` (coolant out),
`Sources/PostCore/Editor/PostSampleJob.swift` (`noCoolantIDs`), `Sources/LoftLineApp/Model/GCodeExporter.swift` (one line);
tests: create `Tests/PostCoreTests/DialectChecksTests.swift`, move the coolant test out of `OthermillSetupTests`, loop
`noCoolantIDs` in `PostDraftReportTests`.

**Interface:** `public static func issues(toolpaths: [Toolpath], profile: PostProfile) -> [GCodeIssue]`.

- [ ] **Step 1: Failing tests:** Mist and Air on a CM post give one error with "Carbide Motion ignores M7 and does not support M8";
  coolant on an Othermill post gives one with "its G-code reference lists M7, M8 and M9 as unsupported"; BB and GRBL give none;
  two tools numbered 1 differing only in tip diameter, or only in shape, give the validator's error; identical geometry gives
  its warning; the editor sample has no coolant for each `noCoolantIDs` id.
- [ ] **Step 2:** `scripts/test.sh --filter "DialectChecksTests|OthermillSetupTests|PostDraftReportTests"` → FAIL.
- [ ] **Step 3:** Implement. **Step 4:** PASS; `scripts/test.sh` green. Commit `feat(post): coolant checked per controller; tools of different tip or shape may not share a number`.

### Task 4: Docs

**Files:** `docs/DECISIONS.md`, `Sources/LoftLineApp/Model/HelpTopics.swift`, `TESTING.md`, `README.md`, `docs/PARITY.md`, doc comments
listed in the spec's Docs section.

- [ ] **Step 1:** Write per the spec's Docs; `scripts/build.sh`, `scripts/test.sh` green. Commit `docs: Onefinity and Carbide Motion posts`.
