# The G-code preview follows an M0 tool change (issue #126)

Status: approved, revision 3 (after debate:all rounds 1 and 2)

## Problem

`GCodeReader.read` starts a new tool segment only at `M6`, or at a `T` word in a program without `M6`.

Six built-in posts change tools with a stop instead: GRBL, UCCNC, ShopBot G-code, LinuxCNC, Onefinity and
NcStudio. Each writes the change as:
- `M5`;
- a comment on its own line: `(Change to Tool: <name>)`, `(MSG, Change to Tool: <name>)` or
  `' Change to Tool: <name>`;
- `M0`, possibly line-numbered (`N40 M0`).

A two-tool program from these posts previews as one tool, labelled "No tool change".

Separately, every new segment starts with the spindle speed of the tool before it. A segment's speed is the
largest `S` it sees, so a 12,000 RPM drill after an 18,000 RPM end mill shows 18,000. This already happens
in `M6` programs.

`DeepestCut` also reads segments, but only their moves, so it is unaffected.

## Design

### Stop tool changes

**The gate.** The rule applies only in a program with no `M6` block and no `T` word anywhere. Only
programs that preview as one tool today can change, and a marker is never counted on top of an `M6` or `T`
split.

**The marker block.** In such a program, a parsed block that has `M0` (`b.has("M", 0)`, so `M00` counts too)
starts a new segment when its marker name is not nil. The marker name is decided by the line's comment:
- Take the comment on the block's own line. If that line has none, take the comment on the previous
  non-blank line. Blank means `trimmingCharacters(in: .whitespacesAndNewlines).isEmpty`.
- The comment must begin, after an optional `MSG,` and whitespace, with `Change to Tool:`. The name is the
  rest, trimmed. It may be empty.
- If the program's header lists tools (`headerTools` is non-empty), the name must equal a listed tool's name.
  This stops a pause whose message happens to start with "Change to Tool:" from splitting a one-tool
  program. A pause message equal to a listed tool's name does split, which is right, since the operator is
  changing to that tool.

**One scan of the comments.**
- A private `lineComments(_ text:comments:) -> [(comment: String?, isBlank: Bool)]` reads each line's
  first comment once, with the existing comment-syntax rules.
- `toolComments`, whose return type is unchanged (`ApostropheCommentTests` reads it), uses it.
- So does a new `stopToolNames(_ text:comments:headerNames:) -> [Int: String]`, which maps line to name for
  the marker lines.

**Where a segment began.** `Segment` gains `startsAtToolChange: Bool`. It is true for every segment started by
`M6`, a `T` word or a stop marker, and false for the segment the program starts in.

**What a stop segment holds.**
- `toolNumber` is nil: it still means "the T word in force".
- `toolComment` is the bare name.

For `M6` segments, `toolComment` stays the whole comment, as today, `Change to Tool:` prefix included. The
`Segment` doc comment says which form each path stores.

### Spindle speed per segment

Every new segment (`M6`, `T` or stop) starts with `spindleRPM` 0. It takes the largest `S` set within the
segment. If it has none, it inherits the speed in force when it began. That covers a program that sets `S`
before the change.

### The preview label (`GCodePreviewModel`)

**The tool.** For a segment with no `toolNumber`, use the one header row whose name equals the bare
`toolComment`, from a new `GCodeReader.headerToolList`. It gives the number, name, kind and diameter. Segments
with a `toolNumber` keep today's lookup by number. That list keeps every header row, including
two tools that share a number. `headerTools` is built from it, last row wins, as today. If no header tool
matches, or several match, there is no number.

**The label:**
- with a number: `T<n> – <name>`, as today;
- with no number, and `startsAtToolChange` true: `Tool change`, plus ` – <name>` when there is a name;
- otherwise: `No tool change`, as today.

This also renames an `M6` segment with no `T` from "No tool change – X" to "Tool change – X", which is what
it is.

## Not in scope

- **Custom posts that write a stop after some other comment.** They preview as one tool, as today. The
  marker is LoftLine's own wording.
- **Warning that tool changes could not be followed.** Every built-in stop post now splits, and a foreign
  program with no marker has no tool change the reader could know about.

## Tests

**PostCoreTests (`PostGCodeReaderTests`):**
- **The six stop posts.** One test parameterised over `generic-grbl-inch`, `uccnc-inch`,
  `shopbot-gcode-inch`, `linuxcnc-inch`, `onefinity-bb-inch` and `ncstudio-mm`. Read each one's
  `samples/expected/<post>/sign.*` with `.any`, as the preview does, and with the post's own `parserComments`.
  Each read gives four segments, whose comments are the four tool names in order.
- **Speed.** In the GRBL sample, the third segment (the drill) has `spindleRPM` 12000 and the others 18000.
  The same holds for the Mach4 `M6` sample.
- **No double split.**
  - The Mach4 sample, with a `(Change to Tool: <name>)` and `M0` pair added after each `T… M6`, still gives four
    segments.
  - A T-word-only program (no `M6`) with the same marker stop keeps its T-word segments.
- **A pause stays a pause.**
  - A one-tool GRBL program (header lists T1 only) with `(MSG, Change to Tool: Clamps)` then `M0` between two
    toolpaths gives one segment.
  - The same with `(MSG, Stop for clamps)` also gives one segment.
- **The marker's position.**
  - The comment on the same line as `M0` splits.
  - `M0` with no comment, or with the marker comment two lines back, does not.
  - A blank line between the comment and `M0` still splits.

**LoftLineAppTests (`GCodePreviewModel`):**
- The GRBL sample's labels are `T1 – …`, `T6 – …`, `T9 – …`, `T1 – …`.
- A program with no header gives `Tool change – <name>`, and an empty name gives `Tool change`.
- An `M6` program with no `T` gives `Tool change – <comment>`, and with no comment either it gives `Tool change`.
- Two header rows share T1 (`Rough - End Mill` and `Drill - Drill`) with stop markers for each: the segments
  are `T1 – Rough` (an end mill) and `T1 – Drill` (a drill).

## Docs

- **`GCodeReader` doc comments.** Update the type comment (the changes it reads) and `Segment.toolNumber`/`toolComment`.

DECISIONS entry `preview-stop-tool-change`. It records:
- the gate;
- the marker, and that it must match the header;
- that a pause named like a listed tool splits;
- the speed per segment;
- the label change for `M6` segments with no `T`.
