# G28/G30 Intermediate Point: Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `validate(gcode:)` checks a G28/G30 intermediate point as a rapid.

**Spec:** `docs/specs/2026-11-01-g28-intermediate-point-design.md` (revision 3, approved)

**Review Focus:** `anyCodeOtherThanAPlainMoveForgetsTheHole` keeps passing. Watch the modal motion after G28.

### Task 1: The intermediate point is a rapid

**Files:** `Sources/PostCore/Validation/GCodeValidator.swift`; `Tests/PostCoreTests/PostValidatorTests.swift`
(`ReferenceReturnTests`); `Tests/PostCoreTests/TravelWindowTests.swift`

- [ ] **Step 1:** Write the tests the spec lists, then run `scripts/test.sh --filter "ReferenceReturn|TravelWindow"`.
  Expected: they fail.
- [ ] **Step 2:** Implement it in `validate(gcode:)`:
  - Change `case 4, 28, 30` to `case 4`.
  - Add `let reference = b.values("G").contains { $0 == 28 || $0 == 30 }`.
  - Add the conflict error when a block has axis words, `reference` is true, and it has more than one code
    from {0, 1, 2, 3, 28, 30}.
  - Use `if let m = reference ? 0 : motion` at the motion dispatch. `motion` itself is never changed.
- [ ] **Step 3:** Run `scripts/test.sh --filter "PostValidator|ReferenceReturn|TravelWindow|PostDraftReport"`.
  Expected: pass.
- [ ] **Step 4:** Add the DECISIONS entry `g28-intermediate-point`. Run `scripts/build.sh`, then `scripts/test.sh`.
  Expected: green apart from #130. Commit `fix(post): the validator checks a G28/G30 intermediate point (#129)`.
