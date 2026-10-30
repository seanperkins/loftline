# Text placeholders outside a comment, refused at build

Status: draft, revision 1. Issue: #125 (found in the NcStudio spec review, #109).

## Problem

`PostDraftReport.placeholderProblems` refuses a text placeholder (`{TOOL_NAME}`, `{JOB_NAME}`, `{POST_NAME}`, `{POST_VERSION}`,
`{MESSAGE}`) outside a comment, and `{STOP}` inside one. It runs only in the post editor. A post that never passes the editor
(a file in the posts folder, an imported `.loftlinepost`, a project's own copy, a post read with `PostProfile.fromJSON`) reaches
`ProgramBuilder.build` unchecked. `TemplateRenderer.commentSafe` only turns `(`/`)` into `[`/`]`, so a tool named `X5 Y5` in a
tool-change line `{TOOL_NAME}` is written as `X5 Y5`, a move. A pause line `(… {STOP})` writes its `M0` inside a comment, and
nothing at export checks that a pause stops (`stopProblems` runs only on the editor's sample).

## Change

1. `PostDraftReport` keeps one list of the templates it scans, `static func templateLines(_ p: PostProfile) -> [(Template?, String,
   [String])]` (the list `staticProblems` builds today, unchanged: prelude, preamble, footer, tool change, tool length offset,
   spindle on, pause, dwell, and the five fixed codes). `staticProblems` uses it, so the editor and the build scan the same lines.
2. `PostProfile.placeholderProblem: String?` (in `PostDraftReport.swift`, an extension, beside the rule it shares): the first
   problem `placeholderProblems` reports for any template line that is **a text placeholder outside a comment** or **`{STOP}`
   inside a comment**, else nil. A comment is what the post's controller reads as one (`commentStyle`, as the editor does).
3. `ProgramBuilder.build` checks it beside the others: `profile.dwellProblem ?? profile.postProblem ?? profile.placeholderProblem`
   throws `PostError.invalidPost(problem)`. The message is the editor's, e.g.
   `Tool change: {TOOL_NAME} is text and must be inside a comment, or it could write G-code words.`
4. The editor is unchanged: it reports every placeholder problem as today and posts its sample only when none is found, so it
   never meets the build's refusal.
5. `PostError.invalidPost`'s doc comment names the three sources (`dwellProblem`, `postProblem`, `placeholderProblem`).

## Not refused at build

- **Unknown placeholders and stray braces** (`{FOO}`, `}`): the renderer writes them as text, and the parser already reports a `{`
  as unrecognised text at export (an error for an apostrophe post, a warning for the others). Refusing them at build would refuse
  hand-written post files that export today without making a move possible.
- **A pause or tool change that does not stop at all** (no `{STOP}`, no `M0`): that is `stopProblems`, which needs a posted
  program. Filed as a follow-up issue rather than widened here.
- **A template that is never written** (for example a tool length line in a post with `useToolLengthOffset` off) is still
  scanned, as the editor scans it: one rule in both places.

## Tests (`Tests/PostCoreTests/PostDraftReportTests.swift` or a new `PlaceholderBuildTests.swift`)

| Post | Line | Expected at export |
|---|---|---|
| Avid read with `fromJSON` | tool change `["M5", "{TOOL_NAME}", "M0"]` | `invalidPost` naming `{TOOL_NAME}` |
| Avid | prelude `["O1000 {JOB_NAME}"]` | refused |
| Avid | pause `["M5", "(MSG, {MESSAGE} {STOP})"]` | refused (`{STOP}` inside a comment) |
| NcStudio copy (apostrophe) | tool change `["M5", "({TOOL_NAME})", "M0"]` | refused: parentheses are not a comment there |
| NcStudio copy | tool change `["M5", "' {TOOL_NAME}", "M0"]` | posts |
| Semicolon (Centroid) | tool change `["M5", "; {TOOL_NAME}", "M0"]` | posts |
| Parentheses (Avid) | tool change `["M5", "({TOOL_NAME})", "M0"]` | posts |
| An unknown placeholder `{FOO}` in the preamble | | posts (not refused at build) |
| Every built-in post | | `placeholderProblem == nil` |

`PostPauseTests.aProfileCanReplaceTheTemplate` writes `M117 {MESSAGE}`, which this change refuses (a message `X5` would be a
word). Its template becomes `M117 ({MESSAGE})`; the test still shows a replaced pause template.

Goldens and `samples/expected` stay byte-identical: this adds a refusal, not output.

## Docs

DECISIONS: one entry (`placeholders-at-build`). TESTING: nothing (no output change). PARITY: nothing.
