# Footer Travel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The export checks the footer's real moves (including a G28/G30 intermediate move) against keep-out zones and clamps, as written, and warns when it cannot model the rest (#132).

**Architecture:** A PostCore `FooterTravel` renders the footer through `ProgramBuilder` and walks it with an allowlist; `GCodeExporter.homeMove` builds its rapid-only toolpath from those points and marks it as written so `KeepOut.violations` skips its climb rewrite.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** `docs/specs/2026-11-02-footer-travel-design.md` (revision 3)

## Global Constraints

- Built-in posts' output must not move a byte: `scripts/check-samples.sh` clean, golden tests unchanged.
- Test both Z-zero modes for the app keep-out tests (AGENTS.md).
- Never write a source file and run tests in the same shell command; judge runs by "Test run with N tests".
- Warning text, exactly: `Keep-out zones and clamps are not checked from the footer's line "<line>" on: LoftLine cannot tell where the machine goes from there.`
- Clamp rewrite, exactly: "raise safe Z" → "raise Home Z or change the post's footer".

## Review Focus

1. A built-in footer posted in mm from an inch document: points must match the inch model, or lifted output shifts.
2. Home Z equal to safe Z: the dropped zero-length Z move must not change the lifted route.
3. A footer whose first motion line has no G word after a toolpath that ended above safe Z with a linear move.
4. `{APPROACH_Z}` in a footer: must resolve to the export's approach height, not safe Z.
5. A lift-over zone on a G28 move: the route plus the re-modelled replay must still report what the replay hits.

---

### Task 0: Pin today's lifted footer output

**Files:** Test: `Tests/LoftLineAppTests/KeepOutZoneTests.swift`

- [ ] Add `keepOutHomeLiftIsPinned(mode:)` (both Z-zero modes): the lifted export of `keepOutHomeMoveIsCheckedAndLifted`'s setup; `#expect(Array(lines[start...]) == pinned[mode])` where `start` is the last `Toolpath: B` comment. Run with an empty `pinned`, copy the actual lines from the failure into the test, run again: PASS on unchanged code. Commit `test: pin the lifted move home (#132)`.

### Task 1: FooterTravel in PostCore

**Files:** Create `Sources/PostCore/Processor/FooterTravel.swift`; modify `Sources/PostCore/Processor/ProgramBuilder.swift` (`renderedFooter()`, used by `build()`); Test: create `Tests/PostCoreTests/FooterTravelTests.swift`.

**Interfaces — Produces:** `public struct FooterTravel: Sendable, Equatable { public var points: [Vec3]; public var unmodelledFrom: String?; public static func model(profile: PostProfile, job: PostJob, from end: Vec3) -> FooterTravel }`. `end` and `points` in `job.units`, machine frame; motion mode at entry derived from `job.toolpaths.last`'s last targeted move and `end.z` vs safe Z (spec 1).

- [ ] Write the spec's PostCore tests (each built-in post at both units; G28 before Home Z; G91 G28 ending; XY before Z; mm post on inch job; G53/G2/M6/M0/`/` line/no-mode axis words stop with `unmodelledFrom` == that rendered line; after M30 nothing; `G0 X0 Y0 M30`; G91 `X1`; bare `X0 Y0` after retract vs after a linear end above safe Z; `G1` stops; `{APPROACH_Z}` resolves from `approachHeight`). Footers are set on a copy of `BuiltInPosts.avidMach4Inch`.
- [ ] Run `scripts/test.sh --filter FooterTravel`: FAIL (no `FooterTravel`).
- [ ] Implement. Allowlist exactly as spec table 2; walk stops record `unmodelledFrom` as the rendered line text trimmed; M2/M30 end after the block's move without setting it.
- [ ] Run `scripts/test.sh --filter FooterTravel`: PASS. Run `scripts/test.sh --filter PostGolden`: PASS. Commit `feat(post): model the footer's travel from its moves (#132)`.

### Task 2: KeepOut checks marked travel as written

**Files:** `Sources/CAMCore/Ops2D/Support/KeepOut.swift`; Test: the CAMCore keep-out test file (`grep -l "KeepOut.violations" Tests/CAMCoreTests`).

**Produces:** `public static let asWrittenKey = "travel as written"` on `KeepOut`.

- [ ] Test `markedTravelIsCheckedAsWritten`: rapid from Z below safe Z across a zone shorter than safe Z: marked → one violation; unmarked → none.
- [ ] Run: FAIL. Implement: skip the climb rewrite when `tp.metadata[asWrittenKey] != nil`. Run: PASS. Commit `fix(cam): keep-out checks the footer's travel as written (#132)`.

### Task 3: Export uses FooterTravel

**Files:** `Sources/LoftLineApp/Model/GCodeExporter.swift`; Test: `Tests/LoftLineAppTests/KeepOutZoneTests.swift`.

**Consumes:** Task 1 `FooterTravel.model`, Task 2 `KeepOut.asWrittenKey`.

- [ ] Tests (both Z-zero modes): check-only zone on a footer `G28 X6 Y6` move → error naming `GCodeExporter.homeMoveName` plus the stop warning; clamp on it → clamp error containing "change the post's footer"; built-in post with `job.homeZ` below safe Z and a check-only zone between Home Z and safe Z on the way home → error; no zones or clamps → no stop warning; lift-over zone on the G28 move → no silent pass (error or routed with replay checked).
- [ ] Run `scripts/test.sh --filter KeepOut`: the new tests FAIL.
- [ ] Implement: remove `homeTravel`; build `PostJob` (with `approachHeight(document:)`) once before the checks and pass it to `homeMove`, `linkHomeOverKeepOutZones` and the build; `homeMove` from `FooterTravel.points` with `metadata = [KeepOut.asWrittenKey: "1"]`; the stop warning when `unmodelledFrom != nil` and the doc has keep-out zones or `Fixtures.zones(in:)` is non-empty; clamp rewrite text.
- [ ] Run `scripts/test.sh --filter KeepOut`: PASS including Task 0's pin. Commit `fix(export): check the footer's moves, G28/G30 included, against keep-out zones and clamps (#132)`.

### Task 4: Docs and full gate

- [ ] DECISIONS: `footer-travel` entry; amend line 597 and `g28-intermediate-point`. Commit `docs: footer travel (#132)`.
- [ ] `scripts/build.sh`, `scripts/test.sh`, `scripts/check-samples.sh`: all green, no sample byte moved.
