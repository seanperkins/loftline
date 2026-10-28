# More built-in posts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship three new built-in posts (`generic-grbl-inch`, `linuxcnc-inch`, `linuxcnc-mm`), GRBL probe defaults for an
inch-only GRBL machine, and the docs that say how to use them safely.

**Architecture:** Three `PostProfile` literals appended to `BuiltInPosts.all`, sharing a new `m2Footer` constant and the existing
`machPreamble`. `probeController(for:)` maps the GRBL inch post to `.grbl`; `ToolChangeProbe.defaults(for:)` asks
`probeController` instead of checking one id. No existing post, machine, golden or sample file changes.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing. Build `scripts/build.sh`, test `scripts/test.sh [--filter X]`.

**Spec:** `docs/specs/2026-10-28-more-built-in-posts-design.md` (revision 4).

## Global Constraints

- Existing posts' bytes, the four inline goldens and every existing `samples/expected/` file stay identical.
- `BuiltInPosts.all` order: `avidMach4Inch, avidMach4MM, genericGRBLMM, genericGRBLInch, linuxCNCInch, linuxCNCMM`.
- `genericGRBLMM` and `BuiltInMachines` are not edited.
- Never weaken a `GCodeValidator` or `PostDraftReport` rule; a failure in `everyBuiltInIsClean`, `unchangedDuplicatesAreClean`,
  `goldenProgramsPassTheValidator` or `builtInProfilesRoundTripJSON` is a finding about the post.
- Don't write a source file and run tests in the same shell command.

## Review Focus

1. The GRBL touch-plate sequence posted in G20 (`unchangedDuplicatesAreClean` covers it once Task 2 maps the post): the probe
   travel, feed and plate values must come out in inches.
2. A user post file already named `linuxcnc-mm.json` (or another new id) keeps overriding the built-in after upgrade.
3. A machine listing both GRBL and Avid posts: `defaults(for:)` must still choose GRBL (today's behaviour when it lists `generic-grbl-mm`).
4. LinuxCNC's `(MSG, Change to Tool: {TOOL_NAME})`: a tool name with `)` in it must not end the comment early (the comment
   sanitiser already handles tool names in the GRBL/Avid comments; check the MSG form goes through the same path).
5. `samples/expected/` regeneration must add only the three new folders.

---

### Task 1: The three posts

**Files:**
- Modify: `Sources/PostCore/Profiles/BuiltInPosts.swift`
- Test: `Tests/PostCoreTests/PostGoldenTests.swift`, `Tests/LoftLineAppTests/MachineConfigTests.swift:36-41`
- Generated: `samples/expected/generic-grbl-inch/`, `samples/expected/linuxcnc-inch/`, `samples/expected/linuxcnc-mm/`

**Interfaces:**
- Produces: `BuiltInPosts.genericGRBLInch`, `.linuxCNCInch`, `.linuxCNCMM` (`static let … : PostProfile`), `static let m2Footer: [String]`.

- [ ] **Step 1: Write the failing tests** in `PostGoldenTests.swift`:
  - `newPostsWriteTheirDialect` — `@Test(arguments:)` over three rows `(id, unitsCode, preamble, toolChange, footerTail, zSample)`,
    literals only. `generic-grbl-inch`: `G20`, `["G90","G17","G94"]`, `["M5","(Change to Tool: <tool name>)","M0"]`,
    footer tail `["M5", "G0 X… Y…", "M2"]` checked as the last lines, and a Z word with 4 decimals. `linuxcnc-inch`: `G20`,
    `["G90","G91.1","G17","G40","G49","G80","G94"]`, `["M5","(MSG, Change to Tool: <tool name>)","M0"]`, `M2`, 4 decimals.
    `linuxcnc-mm`: `G21`, same preamble and tool change, `M2`, 3 decimals. Look the post up with `BuiltInPosts.profile(id:)`
    (`#require`), post `PostFixtures.postJob()` with the existing `post(_:)` helper, and assert the preamble lines appear in
    order and the tool-change lines appear consecutively (use the fixture's real tool name, read from the program text).
  - `newPostsCarryTheirNumbers` — `@Test(arguments:)` over the spec table: `name`, `fileExtension`, `limits` (x, y, z,
    `maxSpoilboardCut`), `rapidRate`, `maxFeed`, `minRPM`, `maxRPM`, `arcTolerance`, `units`, `decimals`, `feedDecimals`.
    GRBL inch: 29.5, 29.5, 2.55, 0.039, 314.9, 314.9, 0, 30000, 0.0005. LinuxCNC inch: 48, 48, 6, 0.05, 200, 200, 0, 24000, 0.0005.
    LinuxCNC mm: 1219.2, 1219.2, 152.4, 1.27, 5080, 5080, 0, 24000, 0.01.
- [ ] **Step 2: Update `orderedPostsPutsMachinePostsFirst`**: `other` ids ==
  `["generic-grbl-mm", "generic-grbl-inch", "linuxcnc-inch", "linuxcnc-mm"]` (literals); no-machine count `== BuiltInPosts.all.count`.
- [ ] **Step 3: Run** `scripts/test.sh --filter "PostGolden|MachineConfig"`. Expected: the new tests fail (`#require` nil / count), the old ones pass.
- [ ] **Step 4: Implement** the three literals, `m2Footer = ["G0 Z{HOME_Z}", "M5", "G0 X{HOME_X} Y{HOME_Y}", "M2"]`, and append
  them to `all` in the order above. GRBL inch copies `genericGRBLMM`'s preamble and tool change as literals; LinuxCNC uses
  `machPreamble`; both LinuxCNC posts share one `linuxCNCToolChange` constant. Spindle dwell 3, `arcOutput: .incrementalIJ`.
- [ ] **Step 5: Run** the same filter. Expected: PASS. Then `scripts/test.sh --filter "PostDraftReport|PostGolden|PostProfile|Snapshot"`. Expected: PASS.
- [ ] **Step 6: Regenerate samples**: `scripts/check-samples.sh --update`, then `git status --short samples/`. Expected: only
  `?? samples/expected/generic-grbl-inch/`, `linuxcnc-inch/`, `linuxcnc-mm/`. Read one LinuxCNC file's header, first tool change and footer.
- [ ] **Step 7: Commit** `feat(post): built-in GRBL inch and LinuxCNC inch/mm posts`.

### Task 2: GRBL probing for the inch post

**Files:**
- Modify: `Sources/PostCore/Profiles/BuiltInPosts.swift` (`probeController`), `Sources/PostCore/Model/ToolChangeProbe.swift:46-50`
- Test: the existing test file that covers `probeController` / `ToolChangeProbe.defaults` (grep `probeController(for:` and `defaults(for:` in `Tests/PostCoreTests`).

**Interfaces:**
- Consumes: `BuiltInPosts.genericGRBLInch`, `.linuxCNCInch`, `.linuxCNCMM`.

- [ ] **Step 1: Write the failing tests**:
  - `grblInchPostProbesAsGRBL`: `probeController(for: .genericGRBLInch) == .grbl`; `probeController(for: .linuxCNCInch) == nil`;
    `probeController(for: .linuxCNCMM) == nil`.
  - `inchOnlyGRBLMachineDefaultsToGRBL`: a `MachineDefinition` copied from `BuiltInMachines.genericGRBL` with
    `postIDs = ["generic-grbl-inch"]` → `ToolChangeProbe.defaults(for:).controller == .grbl`; `BuiltInMachines.avidPRO6096` → `.mach4`;
    a machine listing `["avid-pro6096-mach4-inch", "generic-grbl-mm"]` → `.grbl` (today's rule kept).
- [ ] **Step 2: Run** `scripts/test.sh --filter "<that suite>"`. Expected: FAIL on the GRBL inch cases only.
- [ ] **Step 3: Implement**: add `genericGRBLInch.id` to the `.grbl` case of `probeController`. `defaults(for:)` picks `.grbl`
  when `machine.postIDs.contains { id in BuiltInPosts.profile(id: id).map { BuiltInPosts.probeController(for: $0) == .grbl } ?? false }`,
  else `.mach4`; update its doc comment.
- [ ] **Step 4: Run** the suite filter, then `scripts/test.sh --filter "PostDraftReport|ProbeSequence|MachineConfig"`. Expected: PASS
  (`unchangedDuplicatesAreClean` now posts the GRBL probe sequence in G20).
- [ ] **Step 5: Commit** `feat(post): GRBL probe defaults for a machine with the GRBL inch post`.

### Task 3: Docs

**Files:** `docs/DECISIONS.md`, `README.md:117`, `Sources/LoftLineApp/Model/HelpTopics.swift` (`.machines` body), `TESTING.md` (after section 4's air cut).

- [ ] **Step 1: DECISIONS** — one `more-posts` entry: spec path; decisions 1 (M0, one file per tool, single multi-tool file still
  allowed, follow-up), 2 (no Mach3; a Mach3 owner may list the Avid posts with tool change set to stop, `G4 P` in seconds,
  touch-plate tool changes off), 3 (probing), 4 (machines unchanged), 6 (M7 out of scope); a user file with a new id keeps winning.
- [ ] **Step 2: README** — replace "ships with Avid Mach4 inch/mm and Generic GRBL (mm)" with wording that names no list
  (e.g. "ships with posts for Mach4, GRBL and LinuxCNC (inch and mm)").
- [ ] **Step 3: Help (`.machines`)** — three sentences: only the Avid Mach4 posts have run on a machine (air-cut first with any
  other); with any post but the Avid or GRBL mm ones, make a machine for your controller and list the post in it; on LinuxCNC
  (and GRBL without a touch plate) save one file per tool and load and touch off each tool before starting its file. Run the
  existing Help tests (spelling, links): `scripts/test.sh --filter Help`. Expected: PASS.
- [ ] **Step 4: TESTING** — a `**Other controllers (GRBL, LinuxCNC):**` paragraph after the air cut: post one file per tool; load
  and touch off each tool before its file; air-cut each file; confirm it stops at the top and the spindle dwell is seconds.
- [ ] **Step 5: Full gate**: `scripts/build.sh`, then `scripts/test.sh`. Expected: `Test run with N tests … passed`.
- [ ] **Step 6: Commit** `docs: more built-in posts (decisions, help, testing, readme)`.
