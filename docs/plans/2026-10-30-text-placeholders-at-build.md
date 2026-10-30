# Text placeholders at build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refuse at build a post that writes user text outside a comment or `{STOP}` inside one, whether or not it passed the editor.

**Architecture:** The editor's placeholder scan gains an `unsafeOnly` flag; `PostProfile.placeholderProblem` runs it over the lines
the editor scans (`PostDraftReport.templateLines`); `ProgramBuilder.build` throws `invalidPost` beside `dwellProblem`/`postProblem`.

**Tech Stack:** Swift 6, SwiftPM, swift-testing.

**Spec:** `docs/specs/2026-10-30-text-placeholders-at-build-design.md`

## Global Constraints

- Goldens and `samples/expected` stay byte-identical; `GCodeValidator` is not changed.
- The editor's problems and messages stay exactly as today.
- American spelling in user-visible text.
- Build with `scripts/build.sh`, test with `scripts/test.sh`; never write a source file and run tests in one command.

## Review Focus

- A post whose only problem is an unknown `{FOO}` must still export (the spec's "not refused").
- A semicolon post with `( … {TOOL_NAME} … )` must still export (both are comments in `.standard`).
- A project's embedded post copy (no built-in family) is refused with the editor's message, not a crash.
- The message reaches the export sheet once (`GCodeExporter` catches `invalidPost`).
- The editor never shows the build's message twice (its sample is skipped when static rules fail).

---

### Task 1: The build refuses unsafe placeholders

**Files:**
- Modify: `Sources/PostCore/Editor/PostDraftReport.swift` (`placeholderProblems`, new `templateLines`, `staticProblems` uses it)
- Modify: `Sources/PostCore/Model/PostProfile.swift` (`placeholderProblem` beside `postProblem`)
- Modify: `Sources/PostCore/Processor/ProgramBuilder.swift:41`, `Sources/PostCore/Processor/PostProcessor.swift:15` (doc)
- Test: `Tests/PostCoreTests/PostDraftReportTests.swift`, `Tests/PostCoreTests/ApostropheCommentTests.swift`,
  `Tests/PostCoreTests/PostPauseTests.swift`

**Interfaces:**
- Produces: `static func placeholderProblems(_ line: String, template: Template, label: String, style: PostProfile.CommentStyle,
  unsafeOnly: Bool = false) -> [String]`; `static func templateLines(_ p: PostProfile) -> [(Template, [String])]`;
  `public var placeholderProblem: String?` on `PostProfile`.

- [ ] **Step 1: Write the failing tests** in `PostDraftReportTests.swift`, one `@Test` per spec table row:
  `aFilePostWithToolNameOnACodeLineIsRefusedAtExport` (Avid via `fromJSON(toJSON())`, tool change `["M5", "{TOOL_NAME}", "M0"]`,
  expects `PostError.invalidPost("Tool change: {TOOL_NAME} is text and must be inside a comment, or it could write G-code words.")`
  from `TemplatePostProcessor(profile:).post(PostFixtures.postJob())`, and that message appears once in `PostDraftReport.make(p).problems`);
  `aStopInsideACommentIsRefusedAtExport` (pause `["M5", "(MSG, {MESSAGE} {STOP})"]`, message `Pause: {STOP} inside a comment stops nothing.`);
  `spindleOnTextIsRefusedAtExport` (`M3 S{S} {TOOL_NAME}`, label `Spindle on`); `anUnwrittenToolLengthLineIsStillScanned`
  (`useToolLengthOffset = false`, `G43 H{T} {TOOL_NAME}`, label `Tool length offset`);
  `parenthesesAreNoCommentInAnApostrophePost` (id `my-apostrophe-post`, `.apostrophe`, tool change `["M5", "({TOOL_NAME})", "M0"]`);
  `namesATemplateCannotUseStillExport` (preamble `["G90", "{FOO} {TOOL_NAME}"]` posts without throwing);
  `aStrayBraceDoesNotHideThePlaceholder` (tool change `["M5", "} {TOOL_NAME}", "M0"]` refused with the text message);
  `noBuiltInHasAPlaceholderProblem` (`BuiltInPosts.all.allSatisfy { $0.placeholderProblem == nil }`).

- [ ] **Step 2: Run** `scripts/test.sh --filter PostDraftReportTests`. Expected: FAIL to compile (`placeholderProblem` undefined).

- [ ] **Step 3: Implement.** `unsafeOnly` skips the `}`, not-a-placeholder and "cannot use" appends (a name the template cannot
  use is skipped, not reported as text). `templateLines` returns the eight `Template` cases with `p.prelude ?? []`, `p.preamble`,
  `p.footer`, `p.toolChange`, `[p.toolLengthOffset]`, `[p.spindleOn]`, `p.pauseLines`, `[p.dwell]`; `staticProblems` maps it to
  `(Template?, template.label, lines)` and appends the five fixed codes. `placeholderProblem` returns the first `unsafeOnly`
  finding. `ProgramBuilder.build` line 41 becomes `profile.dwellProblem ?? profile.postProblem ?? profile.placeholderProblem`.

- [ ] **Step 4: Change the three existing tests** as the spec's "Existing tests that change" says (`apostrophePost()`'s tool
  change; `anImportedApostrophePostWithAParenthesisPauseIsRefused` expects `invalidPost("Pause: {MESSAGE} is text and must be
  inside a comment, or it could write G-code words.")`; `aProfileCanReplaceTheTemplate` uses `(MSG, {MESSAGE})`).

- [ ] **Step 5: Run** `scripts/test.sh --filter "PostDraftReportTests|ApostropheCommentTests|PostPauseTests"`. Expected: PASS.

- [ ] **Step 6: Commit** `fix(post): refuse a text placeholder outside a comment at build, not only in the editor (#125)`.

### Task 2: Docs and the follow-up issue

**Files:** Modify `docs/DECISIONS.md` (entry `placeholders-at-build`: the bar, the flag, why unknown names stay unrefused).

- [ ] **Step 1:** Append the entry; commit `docs: placeholders refused at build (#125)`.
- [ ] **Step 2:** File the follow-up issue: a post file whose pause or tool change never stops is not checked at export
  (`stopProblems` runs only on the editor's sample).
- [ ] **Step 3:** `scripts/build.sh` then `scripts/test.sh` (full suite). Expected: the `Test run with N tests` line passes;
  `scripts/check-samples.sh` shows no diff.
