# NcStudio post, with apostrophe comments

Status: draft, revision 1. Issue: #109 (NcStudio / Weihong); engine gap #99 item 5 (the `'` comment style). Follows
`2026-10-28-shopbot-syntec-haas-posts-design.md` (merged at ee676be). RichAuto (#112) and OpenSBP (#113) are not in this batch.

## Goal

One new built-in post, `ncstudio-mm`, and the engine option it needs that a template cannot express: comments that start with a
single quotation mark and run to the end of the line. Every existing post's output, golden file and sample stays
byte-identical, and every existing post is validated exactly as today.

## Sources and their weight

| Fact | Source | Weight |
|---|---|---|
| "A comment in a program is started with a single quotation mark" | NcStudio Programming Manual, 6th ed. R6.1 (quoted in #109) | primary, to recheck |
| `G04 P` is milliseconds, no decimal point, no `X` form ("P_: the dwell time, with unit ms") | same | primary, to recheck |
| I/J are start-relative only when the controller parameter "Arc Increment" is Yes; a program cannot set it (no `G90.1`/`G91.1`) | same, and the NK105 manual | primary, to recheck |
| `G20`/`G21`, `G54`–`G59`, `G43 H00`–`H07`, `M30`, `M8`, line numbers allowed | same | primary, to recheck |
| `G94` errors and is skipped | a Fusion user's forum post | community |
| `.nc` | Techno HD II manual: "Only a G-code file with an "nc" extension with show." | primary |

Weihong's site resets every connection from this machine (curl, WebFetch and a headless browser, 2026-10-29), so the R6.1
quotes come from the #109 research. **Gate:** the post (P2) is not encoded until each "to recheck" row is read again in the
manual itself; the engine part (E1) does not depend on it.

## E1. Apostrophe comments (#99 item 5)

- `PostProfile.CommentStyle` gains `case apostrophe` (raw value `"apostrophe"`). `comment(_:)` writes `' ` + the text, plain
  ASCII (`asciiOnly`), with `(`/`)` as `[`/`]` as in the other styles. A `'` inside the text stays: the comment already runs to
  the end of the line.
- **Parser.** `GCodeParser.parse(_:comments:)` takes a `GCodeParser.Comments`:
  - `.standard` (the default, today's rules): `( … )` and `;` to the end of the line.
  - `.apostrophe`: `'` to the end of the line, and nothing else. `(`, `)` and `;` are not comments, so they are reported as
    unrecognised text (an error in the validator), because NcStudio is not documented to read them.
  - `.any`: all three, for the previewer.
  - `PostProfile.parserComments` gives `.apostrophe` for an apostrophe post, else `.standard`. Every caller that has a post
    passes it: `GCodeValidator`, `PostDraftReport` (the sample run and its stop checks), `ToolChangeZ`, `postProblem`.
- **Reader.** `GCodeReader.read` parses with `.any` and its tool-name scan reads a `'` comment too. Its callers (the file
  preview, `DeepestCut` on an exported program) do not know the dialect; without this a `' T2 3mm` comment would read as a tool
  change. A file holding a `'` used to give "unrecognised text" warnings in the preview; it now reads it as a comment.
- **Writer.** `GCodeWriter.append` does not number a line that starts with `'`.
- **Messages.** `defaultPause(for: .apostrophe)` is `["M5", "' {MESSAGE}", "{STOP}"]`; `ProgramBuilder.message` writes
  `' <text>`.
- **Editor.** The draft report's placeholder scan takes the post's style: for `.apostrophe` only a `'` opens a comment, so
  `( {TOOL_NAME} )` in an apostrophe post is "text outside a comment". The Comments picker gains `' …`.
- **Schema.** `currentSchemaVersion` becomes 4; `requiredSchemaVersion` is 4 for an apostrophe post (an older LoftLine would
  fail to decode the style, so it must refuse the file with its "newer LoftLine" message instead). Otherwise unchanged.

## P2. The `ncstudio-mm` post

| field | value | why |
|---|---|---|
| name, extension | "NcStudio (mm)", `nc` | Techno |
| units | mm, `G21` | inch feed is not understood (#109): no inch post |
| comments | `.apostrophe` | E1 |
| preamble | `G90`, `G40`, `G49`, `G54` | each in the manual; no `G94` (errors), no `G90.1`/`G91.1` (not in the manual), no `G17` (arcs are lines) |
| tool change | `M5`, `' Change to Tool: {TOOL_NAME}`, `M0` | the editions disagree on `M6` (R6.1 has none; Techno errors above T10) |
| tool length | off | `G43` takes only `H00`–`H07` |
| spindle | `M3 S{S}`, 3 s dwell, 0–24,000 rpm | the controller's own limit is a parameter |
| dwell | `G4 P{MILLISECONDS}` | manual |
| arcs | `.linearize`, 0.01 mm | "Arc Increment" is unknown and cannot be set by the program |
| footer | `othermillFooter` (`G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M30`) | `M30` documented |
| line numbers | off | allowed, not needed |
| limits, rapid, feed | generic mm envelope, 5080 mm/min | no built-in machine (dealer figures only) |

Family rules (by `BuiltInPosts.family(of:)`, so an edited or duplicated copy keeps them), in `DialectChecks` at export:

- **Mist coolant is an error:** "NcStudio documents M8 but not M7: use Air (M8) or turn coolant off for …". Air writes M8.
- **A tool length offset turned on** in a copy is an error for any tool outside T1–T7: "NcStudio's G43 takes H00 to H07 …".
  T0 with the offset on is refused too (H00 applies no length, as on Syntec/Haas).
- **Probing refuses** for the family: a new `BuiltInPosts.noProbingReasons: [String: String]` (ShopBot's message moves into it
  unchanged; NcStudio's: "NcStudio's probing commands are not documented here: touch-plate tool changes cannot be written for
  it."). `ProgramBuilder.probeForBuild` reads it in place of the `oneGWordIDs` test.

## Testing

- E1, each by a test that fails first: the parser in all three modes (`'` comment; `(`/`;` as garbage in `.apostrophe`; a
  `'` inside parentheses in `.standard` stays a comment's text); `comment(_:)`; an unnumbered `'` line with line numbers on;
  the default pause and the builder's message; the draft report's scan (`' {TOOL_NAME}` passes, `( {TOOL_NAME} )` fails in an
  apostrophe post and passes in the others); schema 4 on write, and a version-4 file refused by a reader that knows only 3;
  the reader skipping `' T2 X5` and naming the tool from a `'` comment.
- A post that is the Avid post with `.apostrophe` is posted and validated: no `(` anywhere, every comment starts with `'`.
- P2: goldens (both Z-zero modes; mm only), samples (`samples/expected/ncstudio-mm/`), the validator passes them, the family
  rules (mist, TLO T8 and T0, probing) including on a `-custom-1` copy.
- Every existing golden and sample byte-identical; `scripts/build.sh` and `scripts/test.sh` green.

## Docs

DECISIONS (`apostrophe-comments`, `ncstudio-post`), PARITY (`io-post-processors`), HelpTopics (the comment styles), TESTING
(owner check: `( )` comments, "Arc Increment", `M6`, an air cut), README's post list. #109 gets the safety facts and the owner
checks that stay open.

## Out of scope

An inch post; `M6` tool changes; arcs as G2/G3; built-in machines; RichAuto (#112) and OpenSBP (#113).
