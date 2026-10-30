# A post that never stops, refused at export

Status: approved, revision 3 (round 1 and the revision 2 verification answered: see "Rulings"). Issue: #128 (found in the #125 spec review).

## Problem

`PostDraftReport.stopProblems` checks, in the post editor's posted sample, that the tool change before the first tool and the
one between two tools each stop (`M0`) or select the tool (`T<n>` then `M6`) with no other `T`, and that a pause stops with
`M0` before the next move. It runs only in the editor. A post that never passes the editor (a file in the posts folder, an
imported post, a project's copy, a post read with `PostProfile.fromJSON`) can export with a pause `["M5", "(MSG, {MESSAGE})"]`
(no `{STOP}`) or a tool change `["M5", "(Change to Tool: {TOOL_NAME})"]` (no `M0`, no `M6`): the machine cuts the next
toolpath through a pause, or cuts the second tool's paths with the first bit. #125 refuses `{STOP}` inside a comment at build;
it cannot judge a missing stop, which depends on the posted program (a literal `M0`, `T{T} M6`, a `{STOP}` that is `M0`).

## Change

1. **The editor's check, on its own sample, at export.** `PostDraftReport.sampleStopProblem(_ post: PostProfile) -> String?`
   (public). It posts the editor's sample job exactly as `make` posts its plain sample (one private helper, `plainSample(_:)`,
   used by both: `PostSampleJob.widened`, `toolChangeProbe` nil, `PostSampleJob.job(for:)`), parses it with the post's
   comments, and returns the first `stopProblems` finding, or nil.
2. **A sample that cannot be posted returns nil.** The builder refuses it only for a post-level problem (`invalidPost`:
   `dwellProblem`, `postProblem`, `placeholderProblem`) or a spindle range the sample's clamped speed cannot meet (min above
   max); the real job fails the same way next and reports its own message.
3. **Not in `ProgramBuilder.build`:** posting the sample goes through `build`, which would recurse. `GCodeExporter.export` is
   the one place a program is written for the user (the export sheet, Save All Toolpaths, Save Tiled G-code, Check Toolpaths,
   `loftline-cli export`; `TemplatePostProcessor.post` has no other caller outside the editor).
4. **`GCodeExporter.export` refuses** before it posts: inside its `do`, it throws `PostError.invalidPost(message)` ahead of
   `post(job)`, so the existing catch writes `The post "<name>" cannot be used: <message>`. The message says where the finding
   comes from and where to fix it, since it names the sample's tools, not the job's:
   `posting the post editor's two-tool sample, <finding> Fix it in Toolpaths ▸ Post Processors.`
   A refusal, not an error with Save Anyway: the editor refuses to save such a post, and a program that cuts through its own
   pause or with the wrong bit is not one to save anyway.
5. **`stopProblems` reads the builder's markers once each.** It finds `Toolpath: Sample A [`, `… B [`, `… C [` and `Pause after
   toolpath: Sample A` with `firstIndex`; a post's own lines (a prelude, a footer) could carry the same text and move the
   windows it checks (auditor, round 1). Each marker must occur exactly once in the sample, or the finding is `The sample
   program's toolpath comments appear more than once; a post line may not repeat them.` The editor gains the same rule. A
   marker is a line whose comment text (after the comment opener `(`, `;` or `'` and spaces) begins with it, so the header's
   `Post: <name>` does not count when a post's name holds the text (auditor, verification).
6. **A block-delete stop is no stop.** A controller with Block Delete on skips a `/` line, so `stopProblems` gives no credit
   for an `M0`, `T` or `M6` on one (`GCodeParser.Result.blockDeleteLines`): `["M5", "/M0"]` never stops (auditor,
   verification). The editor gains the same rule.

The check is of the post, not the job: a post whose pause never stops is refused even for a job with no pause, and a machine
with touch-plate tool changes (whose builder never writes the post's tool change) still refuses a post whose tool change
never stops, as the editor does. DECISIONS records both.

## Cost

One sample post per export (three toolpaths, a few dozen moves). Check Toolpaths exports once per operation and once for the
whole job, so N + 1 samples; Save Tiled G-code one per tile. No memo: a sample posts in well under the time the real export
takes.

## Tests

`Tests/PostCoreTests/PostDraftReportTests.swift` and `Tests/LoftLineAppTests/PreflightChecksTests.swift` (export). Posts are
read with `fromJSON` under an id outside the built-in families.

| Post | Expected |
|---|---|
| pause `["M5", "(MSG, {MESSAGE})"]` | `sampleStopProblem` = the editor's pause finding; export refused, `text` nil, message starts `The post "…" cannot be used: posting the post editor's two-tool sample,` and ends `Toolpaths ▸ Post Processors.` |
| tool change `["M5", "(Change to Tool: {TOOL_NAME})"]` | refused: the first-tool finding |
| tool change `["M5", "M0"]`, pause with a literal `M0` instead of `{STOP}` | `nil` |
| a prelude with forged markers and `M0`s, tool change and pause that never stop | refused: the markers finding |
| a post refused at build (tool change `["M5", "{TOOL_NAME}", "M0"]`, #125) | `nil`; the export refuses with the builder's placeholder message |
| a machine with touch-plate tool changes and a tool change that never stops | refused |
| a one-tool, no-pause job with a post whose pause never stops | refused (the post, not the job) |
| tool change `["M5", "/M0"]`; pause `["M5", "(MSG, {MESSAGE})", "/M0"]` | refused (each) |
| a post named `Toolpath: Sample A [` with stops that work | `nil` |

The `T{T}` and fixed-`T` tool changes are already the editor's tests (`toolChangesMustStopOrChangeTheTool`); every built-in
passes (`everyBuiltInIsClean`, the samples test). Goldens and samples unchanged.

## Docs

DECISIONS `stops-at-export`. Help: the post editor paragraph (`HelpTopics.swift`) says the stop rule is checked again at export.

## Rulings

- **Motion inside a tool-change template before its stop is not refused** (executor). It is the post author's own code,
  written as typed; the validator checks those moves (depth, rapids). The check is that a stop or selection exists.
- **A Z-only move between a pause's message and its stop is not "the next move"** (executor). That is the lift before the stop
  (the Avid's own replaced-pause test writes `G0 Z{SAFE_Z}` first); counting it would refuse correct posts.
- **The markers must be unique** (auditor): adopted, for the editor too.
- **The refusal names the sample and where to fix the post** (skeptic M1).
