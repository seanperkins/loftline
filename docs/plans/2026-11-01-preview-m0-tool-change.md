# Preview an M0 Tool Change: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A program that changes tools with a stop previews one segment per tool, each with its own speed
and label.

**Architecture:**
- `GCodeReader.read` splits at a marker stop, but only in programs with no `M6` and no `T` word.
- Segments carry `startsAtToolChange` and start at speed 0.
- `GCodePreviewModel` finds a stop segment's tool by matching its name against the header list.

**Tech Stack:** Swift 6, SwiftPM, swift-testing, run through `scripts/test.sh`.

**Spec:** `docs/specs/2026-11-01-preview-m0-tool-change-design.md` (revision 3, approved)

## Global Constraints

- **Marker:** a comment that begins, after an optional `MSG,`, with `Change to Tool:`. It must be on the
  `M0` line or the previous non-blank line. If the header lists tools, the name must equal a listed name.
- **Gate:** no `M6` block and no `T` word anywhere in the program.
- **`toolComments`** keeps its return type, because `ApostropheCommentTests` uses it.

## Review Focus

- **No double split:** an `M6` or `T` program with marker stops keeps its segments.
- **A pause message shaped like the marker:** in a program with a header, it does not split.
- **Same-line or blank-line comment placement:** covered by the marker-position tests.

---

### Task 1: The reader splits at marker stops and resets speed

**Files:** `Sources/PostCore/Support/GCodeReader.swift`, `Tests/PostCoreTests/PostGCodeReaderTests.swift`

- [ ] **Step 1: Write the failing tests** in a new `@Suite struct StopToolChangeReaderTests`:
  - `stopPostsGiveOneSegmentPerTool(post:)` over the six sample folders, with comment syntaxes `.any` and the
    post's `parserComments`. The comments are the four tool names, and `startsAtToolChange` is all true.
  - `eachSegmentHasItsOwnSpeed`: the GRBL sample's speeds are `[18000, 18000, 12000, 18000]`, and so are the
    Mach4 sample's.
  - `markerStopsDoNotSplitM6OrTPrograms`:
    - the Mach4 sample with `(Change to Tool: X)\nM0` inserted after each `T… M6` line still gives four segments;
    - `"G20\nT1\nG0 X0 Y0 Z1\n(Change to Tool: A)\nM0\nG1 X1 F10\nT2\nG1 X2\n"` gives tools `[1, 2]`.
  - `aPauseIsNotAToolChange`: a one-tool program whose header lists `T1: A - End Mill, dia 0.2500 in`, with
    `(MSG, Change to Tool: Clamps)\nM0`, or with `(MSG, Stop)\nM0`, between moves, gives one segment.
  - `markerPositions`:
    - `M0 (Change to Tool: B)` on one line splits;
    - a blank line between the comment and `M0` still splits;
    - a bare `M0`, or the comment two non-blank lines back, does not split.
- [ ] **Step 2: Run** `scripts/test.sh --filter "StopToolChange"`. Expected: a build failure, because there is
  no `startsAtToolChange`.
- [ ] **Step 3: Implement it.**
  - `Segment.startsAtToolChange`.
  - Private `lineComments`, with `toolComments` built on it.
  - `stopToolNames(_:comments:headerNames:)`.
  - `headerToolList(_:units:) -> [(number: Int, tool: HeaderTool)]`, with `headerTools` built from it.
  - The gate and the stop split in `read`.
  - Speed: every new segment starts at 0 and remembers the speed in force. When `read` returns, a segment
    still at 0 gets that speed.
  - Update the doc comments.
- [ ] **Step 4: Run** `scripts/test.sh --filter "PostGCodeReader|StopToolChange|ApostropheComment|DeepestCut|ProbedProgram"`.
  Expected: everything passes.
- [ ] **Step 5: Commit** `fix(post): the G-code reader follows a tool change made with a stop (#126)`.

### Task 2: Preview labels and tools

**Files:** `Sources/LoftLineApp/Model/GCodePreviewModel.swift`, plus a test in `Tests/LoftLineAppTests/`
(a new `GCodePreviewModelTests.swift` if none exists)

- [ ] **Step 1: Write the failing tests:**
  - The GRBL sample gives labels with the prefixes `T1 – `, `T6 – `, `T9 – `, `T1 – `.
  - With no header, the label is `Tool change – B`; with an empty name, `Tool change`.
  - An `M6` program with no `T` gives `Tool change – C`; a bare `M6` gives `Tool change`.
  - Two header rows on T1 (`Rough - End Mill` and `Drill - Drill`) with marker stops give `T1 – Rough` as an
    `.endMill` and `T1 – Drill` as a `.drill`.
- [ ] **Step 2: Run** `scripts/test.sh --filter GCodePreview`. Expected: FAIL.
- [ ] **Step 3: Implement** the lookup by name and the label rule from the spec.
- [ ] **Step 4: Run** `scripts/test.sh --filter GCodePreview`. Expected: PASS.
- [ ] **Step 5:** Add the DECISIONS entry `preview-stop-tool-change`. Run `scripts/build.sh`, then
  `scripts/test.sh`, and expect green apart from #130. Commit
  `fix(app): the G-code preview labels each tool of a stop tool change (#126)`.
