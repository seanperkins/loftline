# Text placeholders outside a comment, refused at build

Status: revision 2 (round 1 answered: see "Rulings" at the end). Issue: #125 (found in the NcStudio spec review, #109).

## Problem

`PostDraftReport.placeholderProblems` refuses a text placeholder (`{TOOL_NAME}`, `{JOB_NAME}`, `{POST_NAME}`, `{POST_VERSION}`,
`{MESSAGE}`) outside a comment, and `{STOP}` inside one. It runs only in the post editor. A post that never passes the editor
(a file in the posts folder, an imported `.loftlinepost`, a project's own copy, a post read with `PostProfile.fromJSON`) reaches
`ProgramBuilder.build` unchecked. `TemplateRenderer.commentSafe` makes text plain ASCII (control characters become spaces) and
turns `(`/`)` into `[`/`]`; it cannot stop a word. A tool named `X5 Y5` in a tool-change line `{TOOL_NAME}` is written as
`X5 Y5`, a move. A pause line `(… {STOP})` writes its `M0` inside a comment.

## Change

1. **One scan, two strictnesses.** `placeholderProblems(_:template:label:style:unsafeOnly: Bool = false)`. With `unsafeOnly`, it
   reports only the two findings that can write a word or lose a stop:
   - a text placeholder the template can use, outside a comment: `<label>: {<NAME>} is text and must be inside a comment, or it
     could write G-code words.`
   - `{STOP}` inside a comment: `<label>: {STOP} inside a comment stops nothing.`

   It skips stray braces and names the template cannot use: the renderer writes those as literal text (each template is
   rendered with exactly the names it may use, `PostDraftReport.placeholders`), so they cannot write a word, and the parser
   already reports a `{` as unrecognized text at export (an error in an apostrophe post, a warning otherwise). The editor calls it
   without the flag and reports exactly what it reports today.
2. **One list of the lines.** `PostDraftReport.templateLines(_ p: PostProfile) -> [(Template, [String])]`: the eight templates,
   labelled by `Template.label`, with the pause as written (`p.pauseLines`, which is the default pause when `pause` is nil).
   `staticProblems` builds its list from it plus the five fixed codes (`nil` template), so the editor and the build scan the
   same lines.
3. **`public var placeholderProblem: String?`** in `PostProfile.swift`, beside `dwellProblem` and `postProblem`: the first
   `unsafeOnly` finding over `templateLines`, scanned with the post's `commentStyle`, else nil.
4. **The build.** `ProgramBuilder.build`: `profile.dwellProblem ?? profile.postProblem ?? profile.placeholderProblem` throws
   `PostError.invalidPost(problem)`; every export path reaches it (`GCodeExporter` reports `invalidPost`). `PostError.invalidPost`'s
   doc comment names the three sources.
5. The editor is unchanged. It posts its sample only when its static rules pass, so it never meets the build's refusal, and
   each problem is reported once.

## The bar

The build refuses a post that would write user text where the controller reads code, or a stop where it reads a comment, on any
line the editor scans: the same lines, the same comment rules, the same messages. A template the post does not write (a tool
length line with the offset off) is still scanned: a refused line there is one the editor already refuses, and the rule stays
the same in both places.

## Not in this change

- **A pause or tool change with no stop at all** (no `{STOP}`, no `M0`): the editor finds it in its posted sample
  (`stopProblems`); a tool change can stop with a literal `M0` or select the tool with `T{T} M6`, which a template scan cannot
  judge as well as the posted program. Filed as its own issue.
- **Nested parentheses** (`((x) {TOOL_NAME})`) and **`( … )` in a `;` post**: the scanner reads comments as `GCodeParser` does
  (`.standard`), which is what the validator checks. Whether a given controller agrees is a question per controller, not this
  issue's.

## Tests (`Tests/PostCoreTests/PostDraftReportTests.swift`)

A refused row asserts `PostError.invalidPost(<exact message>)` at `TemplatePostProcessor(profile:).post`, and that
`PostDraftReport.make(p).problems` holds that message once (the pattern at `ApostropheCommentTests.swift:147`).

| Post | Line | Expected at export |
|---|---|---|
| Avid read with `fromJSON` (the issue's case) | tool change `["M5", "{TOOL_NAME}", "M0"]` | refused: `Tool change: {TOOL_NAME} is text …` |
| Avid | pause `["M5", "(MSG, {MESSAGE} {STOP})"]` | refused: `Pause: {STOP} inside a comment stops nothing.` |
| Avid | spindle on `M3 S{S} {TOOL_NAME}` | refused (a file post skips the editor's spindle-on pattern) |
| Avid, offset off | tool length `G43 H{T} {TOOL_NAME}` | refused (scanned though not written) |
| Apostrophe post (id outside the built-in families) | tool change `["M5", "({TOOL_NAME})", "M0"]` | refused: parentheses are not a comment there |
| Avid | preamble `["G90", "{FOO} {TOOL_NAME}"]` | posts: neither name is one the preamble can use, so both render as text the parser flags |
| Avid | tool change `["M5", "} {TOOL_NAME}", "M0"]` | refused: a stray brace before the placeholder does not hide it |
| Every built-in post | | `placeholderProblem == nil` |

**Existing tests that change.**
- `ApostropheCommentTests.apostrophePost()` copies Avid's `(Change to Tool: {TOOL_NAME})`; its tool change becomes
  `["M5", "' Change to Tool: {TOOL_NAME}", "M0"]` so `anApostropheLineIsNeverNumbered` still posts.
- `anImportedApostrophePostWithAParenthesisPauseIsRefused` now expects `invalidPost` at post time (the refusal moves from the
  validator's error to the build, which is stronger).
- `PostPauseTests.aProfileCanReplaceTheTemplate` writes `M117 {MESSAGE}`, which is refused (a message `X5` would be a word). Its
  template becomes `["G0 Z{SAFE_Z}", "M5", "(MSG, {MESSAGE})", "{STOP}"]` and it expects `["G0 Z0.2000", "M5", "(MSG, Hi)",
  "M0"]`.

Goldens and `samples/expected` stay byte-identical: this adds a refusal, not output. No built-in post or sample project post is
refused.

## Docs

DECISIONS: one entry (`placeholders-at-build`). TESTING, PARITY: nothing.

## Rulings (round 1)

- **The filter is a flag on the one scanner** (simplifier; executor; skeptic asked for a typed scan). A flag keeps one scanner and
  one set of messages; a typed result would add a type for two callers.
- **The broken tests are named and changed** (all four reviewers).
- **The pause test keeps the `(MSG, …)` form** (auditor: `M117 ({MESSAGE})` would lose its argument).
- **Unknown names stay unrefused, and a name the template cannot use is unrefused even when it is a text name** (simplifier):
  it renders as literal text.
- **The no-stop check stays out** (skeptic m6): its template-only version would misjudge literal `M0` and `T{T} M6`; filed.
- **Nested parentheses and `( … )` in `;` posts** (skeptic m4, m5): out of scope, listed above.
