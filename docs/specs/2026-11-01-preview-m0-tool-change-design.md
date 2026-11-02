# The G-code preview follows an M0 tool change (issue #126)

Status: draft, revision 1

## Problem

`GCodeReader.read` starts a new tool segment only at `M6`, or at a `T` word in a program without `M6`.

Six built-in posts change tools with a stop instead: GRBL, UCCNC, ShopBot G-code, LinuxCNC, Onefinity and
NcStudio. Each writes its tool change as `M5`, then a comment, then `M0`. The comment is
`(Change to Tool: <name>)`, `(MSG, Change to Tool: <name>)` or `' Change to Tool: <name>`. The `M0` may
carry a line number (`N40 M0`).

So a two-tool program from any of these posts previews as one tool, labelled "No tool change".
`DeepestCut` reads segments too, but it only scans moves, so it is unaffected.

## Design

**The marker.** The reader treats a block as a tool change when both of these hold:
- it has `M0` (or `M00`) and no `T` word;
- the comment on the same line, or on the line immediately before it, begins with `Change to Tool:`
  after an optional `MSG,` and whitespace. "The line immediately before" is the previous non-empty line.

**What it does.**
- The marker block starts a new segment, as `M6` does.
- `toolComment` is the text after `Change to Tool:`, trimmed.
- The rule applies only in a program with no `M6` and no `T` word anywhere. Programs that already change
  tools by `M6` or `T` keep today's segments, so the marker is never counted twice.

**Recovering the tool number.** `toolNumber` comes from the program's header tool list, which LoftLine's
own posts write (`GCodeReader.headerTools`). It is the number of the one header tool whose name equals
`toolComment`. With no match, or more than one, it is nil.

**Other stops are unchanged.**
- The post's pause writes `M0` after a different comment (`(MSG, {MESSAGE})`), so it does not start a segment.
- An `M0` in someone else's program, with no `Change to Tool:` comment, stays a pause.

**The label.** `GCodePreviewModel` labels each segment:
- with a tool number: `T<n> – <name>`, as today;
- with no number but a comment: `Tool change – <name>`;
- with neither: `No tool change`, as today.

**The comment map.** `toolComments` (line → comment for `M6` lines) stays as it is. A sibling
`stopToolChanges(_ text:comments:) -> [Int: String]` returns line → tool name for the marker blocks. It
follows the same comment-syntax rules: parentheses only when the comment syntax is not `.apostrophe`, and
`;` or `'` as end-of-line comments by syntax.

## Not in scope

- **A `T` word or `M6` alongside a stop.** Those programs are already split today.
- **Custom posts that write a stop after some other comment.** They preview as one tool, as today. The
  marker is LoftLine's own wording.
- **Warning that tool changes could not be followed.** Every built-in stop post now splits. A foreign program
  with no marker has no tool changes the reader could know about.

## Tests (PostCoreTests, `PostGCodeReaderTests`)

- **GRBL golden.** `samples/expected/generic-grbl-inch/sign.nc` gives four segments: T1, T6, T9, then T1
  again. Their tool numbers come from the header, and their comments are the tool names.
- **NcStudio.** `samples/expected/ncstudio-mm/sign.nc`, read with `.apostrophe`, splits the same way.
- **The other formats.** ShopBot (`N40 M0`) and LinuxCNC (`MSG,`) split.
- **A pause stays a pause.** A GRBL program with a pause (`(MSG, Stop for clamps)` then `M0`) between two
  toolpaths of one tool gives one segment.
- **No marker.** An `M0` without a comment, or with the comment three lines back, is not a tool change.
- **No match in the header.** A program whose header lists no tools gives `toolNumber` nil and the label
  `Tool change – <name>`. This is checked in `LoftLineAppTests` through `GCodePreviewModel`.
- **M6 programs are unchanged.** The existing `m6ProgramsKeepTodaysSegments` test covers it.

## Docs

- A DECISIONS entry, `preview-stop-tool-change`.
