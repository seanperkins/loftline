# A post that never stops, refused at export

Status: draft, revision 1. Issue: #128 (found in the #125 spec review).

## Problem

`PostDraftReport.stopProblems` checks, in the post editor's posted sample, that the tool change before the first tool and the
one between two tools each stop (`M0`) or select the tool (`T<n>` then `M6`) with no other `T`, and that a pause stops with
`M0` before the next move. It runs only in the editor. A post that never passes the editor (a file in the posts folder, an
imported post, a project's copy, a post read with `PostProfile.fromJSON`) can export with a pause `["M5", "(MSG, {MESSAGE})"]`
(no `{STOP}`) or a tool change `["M5", "(Change to Tool: {TOOL_NAME})"]` (no `M0`, no `M6`): the machine cuts the next
toolpath through a pause, or cuts the second tool's paths with the first bit. #125 refuses `{STOP}` inside a comment at build;
it cannot judge a missing stop, which depends on the posted program (a literal `M0`, `T{T} M6`, a `{STOP}` that is `M0`).

## Change

1. **The editor's check, on its own sample, at export.** `PostDraftReport.stopProblem(_ post: PostProfile) -> String?`
   (public): posts the editor's sample job (`PostSampleJob.job(for:)`) with the post as the editor posts it (`PostSampleJob.
   widened`, `toolChangeProbe` nil), parses it with the post's comments, and returns the first `stopProblems` finding, or nil.
   A sample that cannot be posted returns nil: the export posts the real job next and reports that failure itself.
2. **`GCodeExporter.export` refuses** a post with a stop problem before it posts, beside the touch-off spot refusal:
   `The post "<name>" cannot be used: <finding>` (the `invalidPost` wording). A refusal, not an error with Save Anyway: the
   editor refuses to save such a post, and a program that cuts through its own pause or with the wrong bit is not one to save
   anyway. Every path that writes a program goes through `GCodeExporter.export` (the export sheet, Save All Toolpaths, Save
   Tiled G-code, Check Toolpaths, `loftline-cli export`).
3. The check is of the post, not the job: a post whose pause never stops is refused even for a job with no pause, as the
   editor refuses it. The sample has two tools and a pause, so every template it uses is exercised.
4. The touch-plate tool change is not checked here: the builder writes it, with its own stops, and `ProbeSequenceChecker`
   checks it in every exported program.

## Cost

One sample post per export: a three-toolpath job of a few dozen moves. Check Toolpaths exports once per operation; that adds one
sample per operation.

## Tests

`Tests/LoftLineAppTests/PreflightChecksTests.swift` (export) and `Tests/PostCoreTests/PostDraftReportTests.swift`:

| Post (read with `fromJSON`, id outside the built-in families) | Expected |
|---|---|
| pause `["M5", "(MSG, {MESSAGE})"]` | `stopProblem` = the editor's pause message; export refused with it, `text` nil |
| tool change `["M5", "(Change to Tool: {TOOL_NAME})"]` | refused: the first-tool message |
| tool change `["M5", "T{T}"]` (selects, no M6) | refused |
| tool change `["M5", "T1 M6"]` (a fixed T) | refused: the between-tools message |
| tool change `["M5", "M0"]`, pause with a literal `M0` instead of `{STOP}` | posts |
| every built-in post (machine applied) | `stopProblem == nil` |
| a post whose sample cannot be posted (spindle range that refuses the sample's speed) | `stopProblem == nil`; the export reports its own error |

Goldens and samples unchanged: built-in posts all pass.

## Docs

DECISIONS `stops-at-export`. Help: none (the editor's message is the one shown).
