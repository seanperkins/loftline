# Post engine dialect options (issue #99, items 1, 2, 4, 7)

Revision 1, 2026-10-28. Part of the dialect roadmap (#98), approved by Sean ("go", then "keep moving through post
processors", 2026-10-28).

## Goal

The engine places a few things a post's templates cannot change. Four of them block the next controllers: MASSO, UCCNC,
NcStudio, Syntec and Haas/Fanuc. This change gives a post a way to say each one, with today's posts writing the same bytes.

## What changes (each item answers its #99 item)

1. **Dwell unit (item 1, safety).** Two placeholders join `{SECONDS}` (unchanged, `NumberFormat.compact`, 3 s → `3`):
   - `{MILLISECONDS}`: the dwell in whole milliseconds, rounded (3 s → `3000`, 0.5 s → `500`);
   - `{SECONDS_DOT}`: the dwell in seconds with a decimal point always written (3 s → `3.0`, 0.5 s → `0.5`, 2.25 → `2.25`),
     for controllers where `P3` is milliseconds and `P3.` seconds (Haas, Fanuc-style).

   Both are available wherever `{SECONDS}` is (`ProgramBuilder.baseValues` and `GCodeWriter.dwell`). The post editor's dwell
   rule ("Dwell must be G4 P{SECONDS}") accepts `G4 P{MILLISECONDS}`, `G4 P{SECONDS_DOT}` and `G4 X{SECONDS_DOT}` (Syntec's
   seconds word), and the editor lists the new placeholders. A post's dwell template is the one place the unit is chosen,
   and the Export sheet and the program header say it: the header's "Units" line gains "dwell in ms" when the dwell template
   uses `{MILLISECONDS}`, so an operator can check it against the controller.

2. **First lines (item 2).** A post field `prelude: [String]?` (nil = none): lines written before the header comments and
   never numbered, for `%` and `O0001` (Fanuc-style programs start with `%` then an O-number). The writer never numbers a
   bare `%` line wherever it appears, so a footer can end with `%` too. Placeholders as in the preamble. The validator
   already skips `%` (`GCodeParser`); a test proves an `O0001` line raises no issue, and none of its checks change.

3. **Line endings (item 4).** A post field `lineEnding: LineEnding?` (`.lf`, `.crlf`; nil = `.lf`). The builder joins lines
   with it. Everything that reads a program back already splits on CRLF (`GCodeParser`), so the validators and the preview
   read both; tests prove it on a CRLF program.

4. **Units code (item 7).** A post field `unitsWords: UnitsWords?` (`.g20g21`, `.g70g71`, `.none`; nil = `.g20g21`):
   - `.g70g71` writes `G70` (inch) / `G71` (mm) in place of `G20`/`G21` (Syntec); the validator reads G70/G71 as units, the
     same as G20/G21, for a post that asks for them, and keeps reporting them as unknown for any other post;
   - `.none` writes no units line (UCCNC: "units are configured in a program profile"). The validator's `no-units` warning is
     then replaced by one that names the assumption: "This post writes no units code: the controller must be set to <units>",
     still a warning; and the header's Units line says "set on the controller".

## Deferred, with the reason (answered on #99)

Items 3 (line-number step, start and limit) and 9 (a forced decimal point on whole-number values) wait for the dialect that
needs them: no controller in the next batch is confirmed to (Mach3 has no separate post; ShopBot G-code and Syntec are later).
Items 5, 10–15 are answered per dialect. Item 6 is done (#115, #114: a controller with no Optional Stop writes M0). Item 8
(`R` arcs) is not needed: every controller in the list accepts I/J.

## Compatibility (schema)

The three fields are optional; a post that leaves them nil writes exactly what it does today, and every built-in leaves them
nil, so goldens and `samples/expected` stay byte-identical. A LoftLine older than this would drop a new field and post
different G-code (a `%` or O-line missing, LF instead of CRLF, `G20` on a Syntec), so `PostProfile.currentSchemaVersion`
becomes 2 and a post is written with `schemaVersion` 2 only when it uses a new field or a new placeholder; an older LoftLine
then refuses that post ("made with a newer LoftLine") and still reads every other post. The stamp is set in `toJSON()` and
`snapshot()`, the two places a post is written; the stored default stays 1, so a built-in compared by value is unchanged.

## Tests

- Dwell: a post with `G4 P{MILLISECONDS}` writes `G4 P3000` for the 3 s spin-up and `P500` for a 0.5 s dwell move; with
  `G4 P{SECONDS_DOT}`, `P3.0` and `P0.5`; with `G4 X{SECONDS_DOT}`, `X3.0`. The editor accepts each and still rejects
  `G4 P{SECONDS}000`. The header says "dwell in ms" for the first only.
- Prelude: `["%", "O0001"]` with line numbers on writes `%`, `O0001` unnumbered as the first two lines; a footer `%` is
  unnumbered; the validator reports nothing for either.
- CRLF: the program's lines end in `\r\n`, the last too; validating it gives the same issues as the LF program.
- Units: `.g70g71` inch writes `G70` and the validator reports no units issue; `G70` in another post's program is still an
  unknown G-code; `.none` writes no units line and gives exactly the named warning.
- Schema: a post with any new field set encodes `schemaVersion` 2, a post without one encodes 1; a decoder that supports
  only 1 refuses the first; every built-in encodes 1.
- Every existing golden and sample unchanged (`scripts/check-samples.sh` with no `--update`).

## Docs

DECISIONS (`engine-options`); Help (Post Processors: the placeholders and the three fields); the post editor shows the three
fields (a menu each, and the prelude as a template area); a comment on #99 answering every item.
