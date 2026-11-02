# Operation Warnings at Export: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Each toolpath's `metadata["warning"]` reaches Check Toolpaths, the export sheet and the CLI, as a
warning.

**Architecture:**
- `PreflightChecks.operationWarnings(_:)` turns metadata into `GCodeIssue`s.
- `GCodeExporter.export` appends them on the line after `PreflightChecks.issues`.
- `PreflightChecks.issues` itself is unchanged. The job sheet calls it, and the sheet already prints the
  warnings in each step's notes.

**Tech Stack:** Swift 6, SwiftPM, swift-testing. Use `scripts/build.sh` and `scripts/test.sh`.

**Spec:** `docs/specs/2026-11-01-operation-warnings-at-export-design.md` (revision 3, approved)

## Global Constraints

- Message: `"Toolpath '<name>': <warning>"`, severity `.warning`, one per toolpath, in toolpath order, and the
  string is not split.
- Never write a source file and run tests in the same command.

## Review Focus

- **Samples that warn.** The `SampleFiles` and `LoftLineCLI` tests pin that the samples export with no issues.
  If a sample warns, fix the sample, not the assertion.
- **The job sheet.** It must not list the warning twice: once in the step notes and once in Warnings.
- **The combined program.** Check Toolpaths' combined section must not repeat a warning already listed under
  its operation.

---

### Task 1: Operation warnings in export

**Files:** `Sources/LoftLineApp/Model/PreflightChecks.swift`, `Sources/LoftLineApp/Model/GCodeExporter.swift`,
`Tests/LoftLineAppTests/PreflightChecksTests.swift`

- [ ] **Step 1: Write the failing tests** in `PreflightChecksTests`, in a new `// MARK: Operation warnings`:
  - `operationWarningsAreOnePerToolpathInOrder`
    - Hand-built toolpaths: one with no warning, one named "A" with "x; y", and one named "B" with
      "Profile 1: z".
    - The result's messages are `["Toolpath 'A': x; y", "Toolpath 'B': Profile 1: z"]`, all `.warning`.
  - `aTabWarningReachesExportAndCheckToolpathsOnce`
    - Use the project fixture with a profile at depth 0.5, tabs on, and `countPerPath` 50.
    - The export writes text, `errorMessage` is nil, and there are no `.error` issues.
    - Its issues contain one starting `"Toolpath 'Cut': "` and containing `"got fewer tabs than asked"`.
    - `ValidationReport.make` puts it in the operation's section, and the "combined" section has no message
      containing "got fewer tabs".
    - `JobSheet.render` of `JobSheet.make` contains "got fewer tabs than asked" exactly once.
  - `aFluteOverrunIsAnErrorAndAWarning`
    - Thickness 1.5, a profile at depth 1.2 with the 1.0 in flute end mill, tabs on.
    - The issues contain an `.error` containing "flute", and a `.warning` starting `"Toolpath 'Cut': "` and
      containing "flute".
- [ ] **Step 2: Run** `scripts/test.sh --filter PreflightChecks`. Expected: a build failure, because
  `operationWarnings` is undefined.
- [ ] **Step 3: Implement** `static func operationWarnings(_ toolpaths: [Toolpath]) -> [GCodeIssue]` in
  `PreflightChecks`. Then add `issues += PreflightChecks.operationWarnings(toolpaths)` after the
  `PreflightChecks.issues` line in `export`.
- [ ] **Step 4: Run** `scripts/test.sh --filter "PreflightChecks|SampleFiles|LoftLineCLI|AdvancedToolpathModel"`.
  Expected: all pass. A sample that now warns is fixed in the sample.
- [ ] **Step 5: Commit** `fix(app): operation warnings reach Check Toolpaths and the export sheet (#131)`.

### Task 2: Docs, then the full suite

- [ ] **Step 1: Docs.**
  - HelpTopics: the Check Toolpaths paragraph.
  - DECISIONS: a new entry, `operation-warnings-at-export`.
  - PARITY: the `io-preflight` row. Add the text exactly as the spec says.
- [ ] **Step 2: Run** `scripts/build.sh`, then `scripts/test.sh`. Expected: green, apart from the #130 flake,
  which is rerun alone.
- [ ] **Step 3: Commit** `docs: operation warnings at export (#131)`.
