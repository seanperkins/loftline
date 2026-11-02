# Spindle at S0 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** No program starts or cuts with the spindle at `S0` (#99 item 10).

**Architecture:** One floor (`PostProfile.minSpindleRPM = 1`, judged `!(rpm >= 1)`) used by the builder (refuse), the validator
(error at the start, and cuts under a known zero speed count as spindle off) and the app's tool warning.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** `docs/specs/2026-11-02-spindle-zero-design.md` (revision 2)

## Global Constraints

- Builder refusal text: `<toolpath> has no spindle speed (below 1 RPM): set the tool's spindle speed.`
- Validator: code `spindle-zero-speed`, error, `Spindle speed S0 leaves the spindle stopped`.
- App warning: `The spindle speed must be at least 1 RPM.`
- No sample or golden byte changes (`scripts/check-samples.sh` with no `--update`).

## Review Focus

1. A footer `S0` after the last cut (with or without `M5`) reports nothing.
2. ShopBot's plain `M3` with no `S`: only the existing `spindle-no-speed` warning.
3. A posts-editor sample (`PostDraftReport.runSample`) is unaffected (its sample RPM is positive).
4. A NaN RPM is refused by the builder and warned by the app.
5. The six posts with `minRPM > 0` get one error for `M3 S0`, not two.

---

### Task 1: PostCore floor, builder and validator

**Files:** `Sources/PostCore/Model/PostProfile.swift`, `Sources/PostCore/Processor/PostProcessor.swift`,
`Sources/PostCore/Processor/ProgramBuilder.swift`, `Sources/PostCore/Validation/MotionChecker.swift`,
`Sources/PostCore/Validation/GCodeValidator.swift`; Test: create `Tests/PostCoreTests/SpindleZeroTests.swift`.

**Produces:** `public static let minSpindleRPM: Double = 1` on `PostProfile`; `PostError.spindleStopped(toolpath: String)`.

- [ ] Tests (spec "Tests", PostCore): builder over `BuiltInPosts.all` × {0, 0.5, 0.99, .nan} throws
  `.spindleStopped(toolpath:)`; GRBL copy at 1 RPM contains `S1`; validator cases on `validate(gcode:)` with issue codes.
- [ ] `scripts/test.sh --filter SpindleZero`: FAIL. Implement. PASS. Commit `fix(post): refuse and report a spindle at S0 (#99)`.

### Task 2: App message and warning, docs

**Files:** `Sources/LoftLineApp/Model/GCodeExporter.swift`, `Sources/LoftLineApp/Model/OperationWarnings.swift`,
`docs/DECISIONS.md`; Test: create `Tests/LoftLineAppTests/SpindleZeroExportTests.swift`.

**Consumes:** Task 1 `PostProfile.minSpindleRPM`, `PostError.spindleStopped`.

- [ ] Tests: `rpmProblem` for 0 (Avid), 0.5 and NaN (GRBL) → floor message; 18000 (Avid) → nil; export of a project whose
  tool is 0 RPM → `errorMessage` is the refusal text, `text` nil.
- [ ] FAIL, implement, PASS. DECISIONS `spindle-zero`. Commit `fix(app): say why a 0 RPM tool cannot post (#99)`.
- [ ] `scripts/build.sh`, `scripts/test.sh`: green.
