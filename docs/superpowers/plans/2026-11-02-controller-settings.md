# Controller Settings Warnings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export reminds of the controller settings that change how a built-in program runs (Centroid dwell unit, UCCNC dwell unit, GRBL `$30`/`$32`), and a machine can carry a spindle range (#99 item 13).

**Architecture:** `DialectChecks` warnings per family; Min/Max RPM fields in the machine editor (the harness cannot open Settings: unit tests and the build check them).

**Tech Stack:** Swift 6, SwiftPM, swift-testing, SwiftUI.

**Spec:** `docs/specs/2026-11-02-controller-settings-design.md` (revision 2)

## Global Constraints

- Warning texts exactly as the spec's Decision 1-3; prefixes `public`.
- No program output changes.

## Review Focus

1. The CLI samples test asserts the new warnings are printed, not just allowed.
2. A GRBL machine with its own Max RPM gets that number in the warning.
3. Max RPM 0 in the editor means the post's value (nil), as Rapid rate does.

---

### Task 1: The warnings

**Files:** `Sources/PostCore/Validation/DialectChecks.swift`; Tests: `Tests/PostCoreTests/DialectChecksTests.swift`, `Tests/LoftLineAppTests/LoftLineCLITests.swift`.

- [ ] Tests per the spec. FAIL. Implement. PASS (`--filter "DialectChecks|LoftLineCLI"`). Commit `feat(post): export reminds of Centroid, UCCNC and GRBL settings a program cannot set (#99)`.

### Task 2: Machine RPM fields, harness step, docs

**Files:** `Sources/LoftLineApp/Panels/PreferencesView.swift`, `Sources/LoftLineApp/Model/HelpTopics.swift`, `TESTING.md`, `docs/DECISIONS.md`; Test: `Tests/LoftLineAppTests/MachineRPMFieldTests.swift`.

- [ ] Min RPM / Max RPM fields (whole RPM, effective range per listed post), unit tested. Help, TESTING, DECISIONS. Commit `feat(ui): a machine can set its spindle range (#99)`.
- [ ] `scripts/build.sh`, `scripts/test.sh`: green.
