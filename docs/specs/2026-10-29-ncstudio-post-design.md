# NcStudio post, with apostrophe comments

Status: approved, revision 3 (rounds 1 and 2 answered: see "Rulings" at the end). Issue: #109 (NcStudio / Weihong); engine gap #99
item 5 (the `'` comment style). Follows `2026-10-28-shopbot-syntec-haas-posts-design.md` (merged at ee676be). RichAuto (#112)
and OpenSBP (#113) are not in this batch.

## Goal

One new built-in post, `ncstudio-mm`, and the engine option it needs that a template cannot express: comments that start with a
single quotation mark and run to the end of the line. Every existing post's output, golden file and sample stays
byte-identical, and every post that does not use the new style is validated exactly as today.

## Source

NcStudio Programming Manual, 6th edition, R6 (Weihong, 2016.03), read from the copy at
`ncstudio.ru/wa-data/public/site/doc/10/NcStudio-programming-manual-6th-edition.pdf` (Weihong's own site resets every connection
from this machine). #109 cited R6.1; nothing below depends on a difference between the two.

| Fact | Manual |
|---|---|
| Comments | §3.11.3: "A comment in a program is started with a single quotation mark … content behind the single quotation mark does not work until the end of line." The PDF prints `’`; Autodesk's `ncstudio.cps` writes an ASCII `'`, which the post writes. No other comment form is described. |
| Dwell | G04: "P_: the dwell time, with unit "ms"", example `G04 P1000 ’dwell for 1000ms`; the canned cycles add "with no decimal point". No range is given. |
| Arc centres | G02/G03: "When I, J, K incremental mode is true, the coordinates of circle center is relative to the start point of the arc, otherwise, relative to the coordinates of workpiece origin." The mode is not a program word (no `G90.1`/`G91.1` in the index). |
| Units, feed | `G20/G21` or `G70/G71`; "Command F … Its unit is mm/min." (no inch feed) |
| M codes | M00 stop, M01 optional stop, M02, M03/M04/M05, M08 coolant on, M09 coolant off, M30 "End of program, and return to program top". No M06, no M07. |
| Tool length | `G43 H_` with "H00~H07"; its example is `G43 G0 Z10 H1`. |
| Others | G00, G01, G17, G40, G49, G53, G54–G59, G90, T, S. No G94 in the index. |
| `.nc` | Techno HD II manual: "Only a G-code file with an "nc" extension with show." |

## E1. Apostrophe comments (#99 item 5)

- `PostProfile.CommentStyle` gains `case apostrophe` (raw value `"apostrophe"`). `comment(_:)` writes `' ` + the text, plain
  ASCII (`asciiOnly`), `(`/`)` as `[`/`]` as in the other styles. A `'` inside the text stays: the comment runs to the end of
  the line, and `asciiOnly` leaves no line break.
- `CommentStyle.message(_ text: String) -> String` is the one place a message line is formed: `(MSG, text)`, `; text` or
  `' text`. `defaultPause(for:)` uses `message("{MESSAGE}")` and `ProgramBuilder.message` uses it with the safe text, so the
  two copies of the choice become one.
- **Parser.** `GCodeParser.parse(_:comments:)` takes a `GCodeParser.Comments`, with **no default**, so the compiler finds every
  caller:
  - `.standard` (today's rules): `( … )`, and `;` at parenthesis depth 0 to the end of the line.
  - `.apostrophe`: `'` to the end of the line, and no other comment. `(`, `)` and `;` are garbage. A `%` line and a leading
    `/` (block delete) are handled as today in all three modes.
  - `.any`: all three. `'` and `;` open a comment only at depth 0, and the first of them ends the code:
    `(Bob's 1/4" bit) T2 M6` is `T2 M6`; `T2 ' (note` is `T2`.
  - `PostProfile.parserComments` gives `.apostrophe` for an apostrophe post, else `.standard`. Callers with a post pass it:
    `GCodeValidator`, `PostDraftReport.runSample` (and so its stop checks), `ToolChangeZ.setsZ`, `postProblem`,
    `DeepestCut` (through the reader, below). `ProbeSequenceChecker` parses a fixed `G17 G40 …` line with no comment and
    passes `.standard`. Tests pass `.standard` where they parse today.
- **The validator.** In `.apostrophe` mode a garbage fragment is an **error**: for `(`, `)` or `;`, "This controller reads only
  `'` comments: '<text>' would be sent to it as code."; for anything else, "Unrecognised text '<text>' would be sent to the
  controller as code." Garbage stays a warning for every other post.
- **Reader.** `GCodeReader.read` gains `comments:` (default `.any`): the file preview does not know the dialect and passes
  nothing; `DeepestCut.find` passes the post's `parserComments`, so the export sheet's figure reads the program as the validator
  does. Its tool-name scan (`toolComments`) takes the first comment opener on the line at depth 0 under the same mode.
- **Writer.** `GCodeWriter.append` does not number a line that starts with `'` after trimming.
- **The editor.** `placeholderProblems` takes the post's style: under `.apostrophe` only a `'` at depth 0 opens a comment, so
  `( {TOOL_NAME} )` is text outside a comment there; under the others a `'` opens nothing, so `' {TOOL_NAME}` is text outside a
  comment there. The Comments picker gains `' …`.
- **Who may use it.** `postProblem` refuses:
  - **any** apostrophe post that declares a controller for touch-plate probing (Mach4 and GRBL are not documented to read
    `'`), checked **before** its family guard so the owner's own post is refused too. The draft report gives the same
    message, and `postProblem`'s doc comment says one rule applies to every post;
  - a family copy where `(style == .apostrophe) != (builtIn.commentStyle == .apostrophe)` ("This controller reads … comments:
    keep the comment style …"), as it already does for the units words. Only the apostrophe boundary is locked: an Avid copy
    set to `;` or a Carbide Motion copy set to `( )` stays allowed, as today.
- **Schema.** `currentSchemaVersion` becomes 4; `requiredSchemaVersion` is 4 for an apostrophe post, tested before the other
  returns (the NcStudio post also has a millisecond dwell). An older LoftLine checks the version before decoding
  (`SnapshotDecoding`), so it refuses the file as "made with a newer LoftLine" rather than as malformed.

E1 adds no built-in that uses `.apostrophe`; it can merge alone.

## P2. The `ncstudio-mm` post

| field | value | why |
|---|---|---|
| id, name, extension | `ncstudio-mm`, "NcStudio (mm)", `nc` | Techno |
| units, decimals | mm, `G21`, 3 decimals, feed 0 decimals | F is mm/min; no inch post |
| comments, header | `.apostrophe`, header comments on | E1 |
| preamble | `G90`, `G40`, `G49`, `G54` | each in the manual; no `G94`, no `G17` (arcs are lines) |
| tool change | `M5`, `' Change to Tool: {TOOL_NAME}`, `M0` | no M06 in the manual (Techno's later firmware allows `M6 T1`–`T10`) |
| tool length | off; template `G0 G43 Z{APPROACH_Z} H{T}` | the manual's own form moves Z on the same line |
| spindle | `M3 S{S}`, 3 s dwell, 0–24,000 rpm | the controller's own limit is a parameter |
| dwell | `G4 P{MILLISECONDS}` | manual |
| arcs | `.linearize`, 0.01 mm, helical arcs off (lines anyway) | the I/J mode is a controller setting |
| footer | `othermillFooter` (`G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M30`) | manual |
| line numbers, modal | off, on | as the other mm posts |
| limits | `genericMMLimits`, rapid 5080, feed 5080 mm/min | no built-in machine (dealer figures only) |

Family rules (by `BuiltInPosts.family(of:)`, so an edited or duplicated copy keeps them):

- **At build (`postProblem`), in a new `BuiltInPosts.ncstudioIDs` set:**
  - the comment lock above;
  - units stay millimetres ("NcStudio reads F in mm/min whatever G20 says: keep the post in millimetres");
  - arcs stay `.linearize`, refusing both `.incrementalIJ` and `.absoluteIJ` ("NcStudio's I/J mode is a controller setting
    the program cannot set: keep arcs as lines");
  - the family joins `approachToolLengthIDs`, so a copy that turns the offset on keeps `G0 G43 Z{APPROACH_Z} H{T}` (its doc
    comment and refusal message stop naming only Syntec and Haas).
- **At export (`DialectChecks`):**
  - Mist is an error, from a new `BuiltInPosts.noMistReasons: [String: String]` ("NcStudio documents M8 but not M7"),
    message "<reason>: use Air (M8) or turn coolant off for …". Air writes M8, then M9.
  - With the offset on, a tool numbered outside 1–7 is an error: "NcStudio's G43 takes H00 to H07, and H00 applies no
    length: renumber …". One range rule; NcStudio does not join `noToolZeroIDs` (it writes no T word).
- **Probing** needs no new rule: a post that declares no controller is refused by `MachineDefinition.probeSetting`, and an
  NcStudio copy that declares one is refused by the apostrophe-and-controller rule.
- **Optional stops** write M0 (NcStudio stays out of `optionalStopIDs`): the manual lists M01, but whether the controller has
  an Optional Stop switch is not stated, and an M0 that always stops is the safe reading. Said in DECISIONS and HelpTopics.
- **The editor's sample** reads the same `noMistReasons` table as `DialectChecks`, so the NcStudio sample gets Air, not mist,
  and the two cannot drift.
- **Ids already in use:** a user's post or duplicate whose id was `ncstudio-mm` or `ncstudio-mm-custom-<n>` before this
  change joins the family after it and is held to these rules (refused with their messages if it breaks one), as Syntec and
  Haas did. Said in DECISIONS.

## Testing

Each by a test that fails first:

- Parser: all three modes, the `.any` precedence cases, a `'` inside parentheses in `.standard` staying comment text.
- Validator: garbage in `.apostrophe` is an error, still a warning in `.standard`; a post read from JSON with `.apostrophe` and
  `pause = ["M5", "(MSG, {MESSAGE})", "{STOP}"]` is refused at export.
- `comment(_:)`, `CommentStyle.message`, `defaultPause`; an unnumbered `'` line (bare and with leading spaces) with line
  numbers on.
- `placeholderProblems`: `' {TOOL_NAME}` passes and `( {TOOL_NAME} )` fails in an apostrophe post; `' {TOOL_NAME}` fails in a
  parentheses or semicolon post.
- `postProblem`: an Avid copy switched to `.apostrophe` refused; an Avid copy set to `.semicolon` and a Carbide Motion copy set
  to `.parentheses` still nil; an NcStudio copy switched to `.parentheses` refused; a non-family post (`my-post`, read with
  `PostProfile.fromJSON`) with `.apostrophe` and a controller makes `TemplatePostProcessor.post` throw `invalidPost`; NcStudio
  copies with `.incrementalIJ`, `.absoluteIJ`, inch units, or an offset line without the approach Z refused.
- `ToolChangeZ.setsZ` on an apostrophe post whose tool change is `' then M6 by hand` and `M0`: it still warns.
- Schema: `ncstudio-mm` and any apostrophe post stamp 4; a version-4 file is refused as newer by a reader that knows 3.
- Reader: `' T2 X5` skipped; a tool name read from a `'` comment; `DeepestCut` with an apostrophe post.
- A post built from the Avid's fields under a non-family id (`my-apostrophe-post`, no controller) with `.apostrophe` and its
  tool change's comment as `'`, posted with two tools, a pause, a dwell and a second side: no `(` or `;` anywhere, every
  comment starts with `'`, no errors.
- P2: goldens in both Z-zero modes; `samples/expected/ncstudio-mm/`; a `newPosts` row in `PostGoldenTests`; a "writes only its
  codes" test in both Z-zero modes with an optional pause: no `G2`, `G3`, `G17`, `G90.1`, `G91.1`, `G94`, `M1`, `M6`, `M7`, `T`
  word, `(` or `;`; it has `M0` for the optional stop and `G4 P3000`; the golden read back by `GCodeReader` with
  `comments: .apostrophe` gives no warnings; the editor's NcStudio sample has M8 and M9 and no M7; the family rules (mist
  refused, Air allowed with M8 and M9, offset T7 allowed, T8 and T0 refused), each also on a `-custom-1` copy.
- Every existing golden and sample byte-identical; `scripts/build.sh` and `scripts/test.sh` green.

## Docs

DECISIONS (`apostrophe-comments`, `ncstudio-post`), PARITY (`io-post-processors`), HelpTopics (the comment styles; NcStudio
in the post list and among the posts that stop with M0), the doc comments that list comment styles or stop-only posts,
TESTING (owner checks: the ASCII `'`, `( )` comments, the I/J mode setting, M0 waiting for Cycle Start, an F on a G00 line, an
air cut), README's post list. #109 gets the safety facts and the owner checks that stay open.

## Out of scope

An inch post; `M6` tool changes; arcs as G2/G3 or R; built-in machines; a dwell cap (none documented); RichAuto (#112) and
OpenSBP (#113).

## Rulings (round 1)

- **Keep three parser modes** (Simplifier: treat `'` like `;` everywhere). Declined: the validator would then pass a `'`
  comment in a Mach4 or GRBL program, which those controllers are not documented to read, and that weakens a check.
- **Garbage is an error only in `.apostrophe`** (all four seats). Existing posts keep their warning.
- **Lock the style per family; refuse `.apostrophe` with a declared controller** (Skeptic).
- **Lock NcStudio's arcs to lines** (Auditor).
- **The sample gets Air for NcStudio** (Auditor). Running `DialectChecks` in the editor's sample is not added: it would add
  UCCNC's units warning to every UCCNC sample.
- **No `noProbingReasons`** (Simplifier, round 1; Skeptic, round 2): the NcStudio entry could not be reached, since the
  comment lock refuses a declared controller first. `probeForBuild` is unchanged.

## Rulings (round 2)

- **The apostrophe-and-controller rule runs before the family guard** (Skeptic A).
- **NcStudio copies stay in millimetres** (Skeptic B): the manual gives F only in mm/min.
- **The arcs lock refuses `.absoluteIJ` too; mist comes from one table; the golden is read back in `.apostrophe` mode; the
  error message depends on the fragment** (Skeptic E, G, F, I).
- **The end-to-end apostrophe test uses a non-family id** (Auditor, Skeptic C).
- **The reader's M0 segments and `P > 100` guess stay deferred** (Auditor, again). The "read back with no warnings" test proves
  only that the program parses; previewing an imported multi-tool NcStudio file shows one tool, a known limitation filed as its
  own issue.
- **R6.1:** the auditor read the R6.1 copy on Weihong's storage and found it agrees on comments, dwell, M00 and H registers;
  it times out from this machine, so R6 stays the cited source.
- **The reader's M0 tool change does not start a new segment, and its `P > 100` dwell guess** (Auditor) are outside this
  change. Both already affect every M0 post and every millisecond post; the guess was ruled to stay in the previous batch.
- **A text placeholder outside a comment is refused only in the editor, not at build** (Skeptic). This is outside this change:
  it applies to every comment style today. It is filed as its own issue.
- **The manual gate is met**: the R6 copy confirms each row, and the post is no longer blocked.
