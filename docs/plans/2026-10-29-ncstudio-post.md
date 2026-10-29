# NcStudio Post and Apostrophe Comments Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `'` comment style to the post engine (parser, validator, writer, reader, editor, schema) and a built-in
`ncstudio-mm` post with its family rules.

**Architecture:** A comment style gains a third case; the parser takes an explicit comment mode from every caller that knows the
post, so only an apostrophe post reads `'` as a comment and only there are `(`/`)`/`;` errors. NcStudio's controller limits are
family rules in `postProblem` (build) and `DialectChecks` (export), as for Syntec and Haas.

**Tech Stack:** Swift 6, SwiftPM, swift-testing. Build `scripts/build.sh`; test `scripts/test.sh [--filter X]`; samples
`scripts/check-samples.sh [--update]`; goldens `LOFTLINE_UPDATE_GOLDEN=1 scripts/test.sh --filter <name>`.

**Spec:** `docs/specs/2026-10-29-ncstudio-post-design.md` (revision 3, approved).

## Global Constraints

- Every existing golden and sample stays byte-identical; a post not using `.apostrophe` validates exactly as today.
- `GCodeValidator` is never weakened.
- Never write a source file and run tests in the same shell command. Judge runs by "Test run with N tests" lines.
  `SaveConfirmationTests.aPipeInTheFilesPlaceIsNotWaitedOn` is a known load flake: re-run it alone.
- Conventional commits, no attribution lines.
- Messages are copied verbatim from the spec.

## Review Focus

1. A `'` in a non-apostrophe post's template: must stay garbage (warning) for the validator, as today.
2. An imported (posts-folder) apostrophe post holding `(MSG, {MESSAGE})`: export refused by the validator error.
3. A parser caller left on the wrong mode: `parse` has no default, so the compiler lists them; check each passes the post's.
4. `requiredSchemaVersion` order: an apostrophe post with `{MILLISECONDS}` and `{APPROACH_Z}` must stamp 4, not 2 or 3.
5. Existing copies that switched between `( )` and `;` must still pass `postProblem`.

---

### Task 1: The comment style and its schema

**Files:** Modify `Sources/PostCore/Model/PostProfile.swift`, `Sources/PostCore/Processor/ProgramBuilder.swift`;
Test: create `Tests/PostCoreTests/ApostropheCommentTests.swift`; modify `Tests/PostCoreTests/SnapshotTests.swift`.

**Interfaces — Produces:** `PostProfile.CommentStyle.apostrophe`; `CommentStyle.message(_ text: String) -> String`;
`PostProfile.currentSchemaVersion == 4`.

- [ ] **Step 1: Tests** in `ApostropheCommentTests`:
  - `apostropheCommentRunsToTheEndOfTheLine`: a post with `.apostrophe`: `comment("Bob's (1/4) bit")` == `"' Bob's [1/4] bit"`;
    `comment("a\nb")` contains no `\n`.
  - `oneMessageFormPerStyle`: `.parentheses.message("x") == "(MSG, x)"`, `.semicolon.message("x") == "; x"`,
    `.apostrophe.message("x") == "' x"`; `PostProfile.defaultPause(for: .apostrophe) == ["M5", "' {MESSAGE}", "{STOP}"]`.
  - `anApostrophePostNeedsSchemaFour`: Avid fields with `.apostrophe` → `requiredSchemaVersion == 4`; the same with
    `dwell = "G4 P{MILLISECONDS}"` and `toolLengthOffset = "G0 G43 Z{APPROACH_Z} H{T}"` → still 4; `toJSON` writes
    `"schemaVersion" : 4`.
  - In `SnapshotTests`: `currentSchemaVersion == 4` (line 41).
- [ ] **Step 2:** `scripts/test.sh --filter ApostropheComment` → compile failure (no `.apostrophe`). Expected: FAIL.
- [ ] **Step 3:** Add the case (raw `"apostrophe"`); `comment(_:)` branch; `message(_:)` on `CommentStyle` (the three forms
  above); `defaultPause` and `ProgramBuilder.message` use it; `currentSchemaVersion = 4`; `requiredSchemaVersion` returns 4
  for `.apostrophe` before every other test; update the doc comments at the schema version and `requiredSchemaVersion`.
- [ ] **Step 4:** `scripts/test.sh --filter "ApostropheComment|Snapshot"` → PASS.
- [ ] **Step 5:** Commit `feat(post): an apostrophe comment style (#109)`.

### Task 2: The parser's comment modes and the validator

**Files:** Modify `Sources/PostCore/Validation/GCodeParser.swift`, `GCodeValidator.swift`, `ToolChangeZ.swift`,
`ProbeSequenceChecker.swift`, `Sources/PostCore/Model/PostProfile.swift` (`parserComments`, `postProblem`'s parse),
`Sources/PostCore/Editor/PostDraftReport.swift` (`runSample`); every test that calls `GCodeParser.parse`.
Test: `ApostropheCommentTests`.

**Interfaces — Produces:** `enum GCodeParser.Comments { case standard, apostrophe, any }`;
`GCodeParser.parse(_ text: String, comments: Comments) -> Result` (no default); `PostProfile.parserComments: GCodeParser.Comments`.

- [ ] **Step 1: Tests:**
  - `eachModeReadsItsComments`: `.standard`: `"G1 X1 ' Y2"` has garbage `'` and words X1, Y2; `"(Bob's) G1 X1"` → X1, no
    garbage. `.apostrophe`: `"G1 X1 ' (Y2"` → X1 only; `"(note) G1 X1"` has garbage `(` and `)`; `"G1 X1 ; c"` has `;` garbage.
    `.any`: `"(Bob's 1/4\" bit) T2 M6"` → T2, M6; `"T2 ' (note"` → T2; `"T2 ; ' x"` → T2. In all three, `"%"` gives nothing
    and `"/G1 Z-1"` is in `blockDeleteLines`.
  - `garbageIsAnErrorOnlyInAnApostrophePost`: validating `"G21\n(note)\nG0 Z5\n"` with an apostrophe post gives an error
    containing "reads only `'` comments"; `"G21\n#100=5\n"` an error starting "Unrecognised text"; the same texts with the
    Avid mm post give warnings and no error.
  - `anImportedApostrophePostWithAParenthesisPauseIsRefused`: a post from `PostProfile.fromJSON` (non-family id, `.apostrophe`,
    `pause = ["M5", "(MSG, {MESSAGE})", "{STOP}"]`), posted with a paused job and validated → has an error.
  - `anM6InsideAnApostropheCommentIsNoToolChange`: a non-family apostrophe post with tool change
    `["M5", "' then M6 by hand", "M0"]` → `ToolChangeZ.setsZ == false`.
- [ ] **Step 2:** run `--filter ApostropheComment` → FAIL (no `comments:`).
- [ ] **Step 3:** Implement the modes (in `.apostrophe` the `'` replaces `;` as the end-of-line opener and parentheses are not
  stripped; in `.any` the first of `'`/`;` at depth 0 ends the code). `parserComments` = `.apostrophe` iff the style is.
  Validator: in `.apostrophe` mode the garbage issue is `.error`, message by fragment (spec E1). Pass `parserComments` in
  `GCodeValidator`, `ToolChangeZ.setsZ`, `postProblem`, `runSample`; `.standard` in `ProbeSequenceChecker`. Update
  `GCodeParser`'s doc comment. Tests that call `parse(x)` get `comments: .standard`.
- [ ] **Step 4:** `scripts/build.sh`, then `scripts/test.sh` → all green; existing goldens untouched.
- [ ] **Step 5:** Commit `feat(post): parse comments by the post's style; stray text is an error in an apostrophe post`.

### Task 3: Writer, reader and deepest cut

**Files:** Modify `Sources/PostCore/Processor/GCodeWriter.swift`, `Sources/PostCore/Support/GCodeReader.swift`,
`Sources/LoftLineApp/Model/DeepestCut.swift`, `Sources/LoftLineApp/Model/GCodeExporter.swift`.
Test: `ApostropheCommentTests`, `Tests/LoftLineAppTests/DeepestCutTests.swift`.

**Interfaces — Consumes:** Task 2's modes. **Produces:** `GCodeReader.read(..., comments: GCodeParser.Comments = .any)`;
`DeepestCut.find(in:job:units:postUnits:comments:)` (`comments` default `.any`).

- [ ] **Step 1: Tests:**
  - `anApostropheLineIsNeverNumbered`: an apostrophe post with `lineNumbers = true` posts a job: every line starting with `'`
    has no `N`; `GCodeWriter` given `"   ' x"` writes `"' x"` unnumbered.
  - `theReaderSkipsAnApostropheComment`: `read("G21\nG0 Z5\n' T2 X5\nG1 X10 F100\n", units: .millimeter, startZ: 5)` → no
    move to X5, no tool 2; `toolComments("' Change to Tool: Vbit\nT3 M6")` gives "Change to Tool: Vbit" for line 2;
    `"(a) ' b"` takes `a` under `.any`.
  - `DeepestCutTests`: a program `"G21\nG1 Z-3 F100 ' Z-9\n"` with `comments: .apostrophe` → deepest Z is -3.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** `append` skips numbering for a trimmed line starting with `'`; `read` passes `comments` to the parser and to
  `toolComments` (first opener at depth 0 under the mode); `DeepestCut.find` passes it; `GCodeExporter` passes
  `profile.parserComments`. Doc comments updated.
- [ ] **Step 4:** `scripts/build.sh`, then `scripts/test.sh --filter "ApostropheComment|DeepestCut|GCodeReader"` → PASS.
- [ ] **Step 5:** Commit `feat(post): write, read and measure apostrophe comments`.

### Task 4: The editor and who may use the style

**Files:** Modify `Sources/PostCore/Editor/PostDraftReport.swift`, `Sources/PostCore/Model/PostProfile.swift`
(`postProblem`), `Sources/LoftLineApp/Panels/PostProcessorsSheet.swift`. Test: `ApostropheCommentTests`,
`Tests/PostCoreTests/PostDraftReportTests.swift`.

**Interfaces — Produces:** `PostDraftReport.placeholderProblems(_:template:label:style:)`.

- [ ] **Step 1: Tests:**
  - `placeholdersFollowThePostsCommentStyle`: `.apostrophe`: `"' {TOOL_NAME}"` → no problem, `"( {TOOL_NAME} )"` → "is text
    and must be inside a comment"; `.parentheses` and `.semicolon`: `"' {TOOL_NAME}"` → that problem.
  - `onlyTheApostropheBoundaryIsLocked`: Avid copy (`-custom-1`) with `.apostrophe` → `postProblem` contains "keep the
    comment style"; Avid copy with `.semicolon` and Carbide Motion copy with `.parentheses` → nil.
  - `anApostrophePostCannotDeclareAController`: `my-post` from `fromJSON`, `.apostrophe`, `controller = .mach4` → posting
    throws `PostError.invalidPost`; the draft report lists the same message.
  - `anApostropheProgramWritesNoOtherComment`: Avid fields, id `my-apostrophe-post`, `.apostrophe`, tool change
    `["M5", "' Change to Tool: {TOOL_NAME}", "T{T} M6"]`; a job with two tools, a pause, a toolpath dwell and a second side →
    no line contains `(` or `;`, every comment line starts with `'`, validator gives no error.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3:** `placeholderProblems` takes `style` (only `'` at depth 0 opens a comment for `.apostrophe`; `'` opens none
  otherwise); its caller passes `p.commentStyle`. `postProblem`: the controller rule before the family guard, then the family
  lock `(commentStyle == .apostrophe) != (builtIn.commentStyle == .apostrophe)`; update its doc comment. The draft report
  shows the controller rule beside the TLO one. Picker: `Text("' …").tag(PostProfile.CommentStyle.apostrophe)`.
- [ ] **Step 4:** `scripts/build.sh`, then `scripts/test.sh` → green.
- [ ] **Step 5:** Commit `feat(post): the editor and the build know which posts may write apostrophe comments`.

### Task 5: The `ncstudio-mm` post and its family rules

**Files:** Modify `Sources/PostCore/Profiles/BuiltInPosts.swift`, `Sources/PostCore/Model/PostProfile.swift`
(`postProblem`), `Sources/PostCore/Validation/DialectChecks.swift`, `Sources/PostCore/Editor/PostSampleJob.swift`;
Test: create `Tests/PostCoreTests/NcStudioTests.swift`; modify `PostGoldenTests.swift`, `SnapshotTests.swift`,
`MachineConfigTests.swift`, `PostDraftReportTests.swift`, `LoftLineCLITests.swift` (sample count); goldens; `samples/expected/`.

**Interfaces — Produces:** `BuiltInPosts.ncstudioMM`, `ncstudioIDs`, `noMistReasons: [String: String]`.

- [ ] **Step 1: Tests** (`NcStudioTests`, each rule on the built-in and on `ncstudio-mm-custom-1`):
  - `theRulesAtBuild`: copies with `.parentheses`, `.incrementalIJ`, `.absoluteIJ`, `units = .inch`, or offset on with
    `toolLengthOffset = "G43 H{T}"` → `postProblem` has the spec's message; the built-in → nil.
  - `theRulesAtExport`: mist → error starting "NcStudio documents M8 but not M7"; Air → no error and the program has `M8`
    then `M9`; offset on (`G0 G43 Z{APPROACH_Z} H{T}`) with T7 → no error, T8 and T0 → "G43 takes H00 to H07".
  - `itWritesOnlyItsCodes` (material top and spoilboard, optional pause): no `G2`, `G3`, `G17`, `G90.1`, `G91.1`, `G94`,
    `M1`, `M6`, `M7`, `T` word, `(`, `;`; has `M0`, `"\nG4 P3000\n"`; `GCodeReader.read(..., comments: .apostrophe)` gives no
    warnings.
  - `PostGoldenTests`: a `newPosts` row (`G21`, preamble `["G90","G40","G49","G54"]`, tool change
    `["M5", "' \(endMillChange)", "M0"]`, footer tail `["G0 Z20.320","M5","G0 X0.000 Y0.000","M30"]`) and a
    `newPostNumbers` row (name "NcStudio (mm)", `nc`, mm, 3/0).
  - `SnapshotTests`: `versionFour = ["ncstudio-mm"]`. `MachineConfigTests`: append `ncstudio-mm` to the other-posts list.
  - `PostDraftReportTests`: the NcStudio sample has `M8` and `M9`, no `M7`, parsed `.apostrophe`.
- [ ] **Step 2:** run `--filter "NcStudio|PostGolden|Snapshot"` → FAIL.
- [ ] **Step 3:** The post per the spec's P2 table, appended to `all`; `ncstudioIDs`; join `approachToolLengthIDs` (doc and
  refusal message no longer name only Syntec and Haas); `postProblem` family rules; `noMistReasons` read by `DialectChecks`
  and by `PostSampleJob` (Air when the family has a reason); the T1–T7 rule in `DialectChecks`; its header doc.
- [ ] **Step 4:** `scripts/build.sh`; `LOFTLINE_UPDATE_GOLDEN=1 scripts/test.sh --filter PostGolden`;
  `scripts/check-samples.sh --update` and read the new `samples/expected/ncstudio-mm/` by eye (every comment `'`, `G4 P3000`,
  lines for arcs); `git diff --stat samples/expected` shows only the new folder; then `scripts/test.sh` → green.
- [ ] **Step 5:** Commit `feat(post): built-in NcStudio post (#109)`.

### Task 6: Docs

**Files:** `docs/DECISIONS.md` (`apostrophe-comments`, `ncstudio-post`: the R6 source, ASCII `'`, linear arcs, M0 tool change
and optional stop, mm only, mist refused, H range, ids already in use), `docs/PARITY.md` (`io-post-processors`),
`Sources/LoftLineApp/Model/HelpTopics.swift` (comment styles; NcStudio in the post list and the M0 list), `TESTING.md`
(owner checks: ASCII `'`, `( )`, the I/J mode setting, M0 waits for Cycle Start, an F on a G00 line, air cut), `README.md`.

- [ ] **Step 1:** Write them. **Step 2:** `scripts/test.sh --filter Help` → PASS (the help tests pin lists).
- [ ] **Step 3:** Commit `docs: NcStudio post and apostrophe comments`.
