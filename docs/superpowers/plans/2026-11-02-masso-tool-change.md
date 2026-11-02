# MASSO Tool Change Order Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A MASSO-family program changes tools only with the spindle stopped and the T word before M6, never on a block-delete line (#99 item 11).

**Architecture:** One rule in `GCodeValidator.validate(gcode:)` for `DialectChecks.massoIDs`, on the written program.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** `docs/specs/2026-11-02-tool-change-rules-design.md` (revision 2)

## Global Constraints

- Messages, exactly: "MASSO needs the spindle stopped (M5) before M6." / "MASSO reads the tool number before M6 (T5 M6), not after it (M6 T5): write T{T} M6." / "MASSO skips a block-delete line when Block Delete is on: take the / off the tool change."
- Other posts keep the `toolchange-spindle-on` warning; no sample or golden changes.

## Review Focus

1. The built-in MASSO export of the fixture job and every MASSO sample: no new issue.
2. A probed tool change on a MASSO copy with a controller set.
3. `T` on an earlier line than a bare `M6`.

---

### Task 1: The MASSO rule

**Files:** `Sources/PostCore/Validation/GCodeValidator.swift`, `Sources/PostCore/Validation/DialectChecks.swift` (visibility only); Test: create `Tests/PostCoreTests/MassoToolChangeTests.swift`; docs `docs/DECISIONS.md`.

- [ ] Tests: every case in the spec's Tests section.
- [ ] `scripts/test.sh --filter MassoToolChange`: FAIL. Implement. PASS. DECISIONS `masso-tool-change`. Commit `fix(post): a MASSO tool change needs M5 and the T word before M6 (#99)`.
- [ ] `scripts/build.sh`, `scripts/test.sh`: green.
