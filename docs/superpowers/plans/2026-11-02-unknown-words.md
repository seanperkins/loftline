# Unknown Words Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Export warns when a built-in family's post writes G/M codes its built-in does not, with the controller's unknown-word behaviour (#99 item 14).

**Architecture:** `UnknownWords.issues(text:job:profile:)` in PostCore compares the exported program's G/M codes with the built-in's program for the same job; `GCodeExporter.export` adds its issues.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** `docs/specs/2026-11-02-unknown-words-design.md` (revision 2)

## Global Constraints

- Message and consequence texts exactly as the spec.
- No program output changes.

## Review Focus

1. A machine-applied built-in (limits, RPM, probe) is never warned.
2. The reference post fails: silent.
3. Comments in every comment style never count.

---

### Task 1: UnknownWords and the exporter

**Files:** create `Sources/PostCore/Validation/UnknownWords.swift`; modify `Sources/LoftLineApp/Model/GCodeExporter.swift`, `docs/DECISIONS.md`; Test: create `Tests/PostCoreTests/UnknownWordsTests.swift`, one app test in `Tests/LoftLineAppTests/SpindleZeroExportTests.swift` style for the exporter.

- [ ] Tests per the spec. FAIL. Implement. PASS. DECISIONS. Commit `feat(post): export warns of a word a copy writes that its built-in does not (#99)`.
- [ ] `scripts/build.sh`, `scripts/test.sh`: green.
