# Post engine: dwell in milliseconds (issue #99, item 1)

Revision 2, 2026-10-28. Part of the dialect roadmap (#98), approved by Sean ("go", then "keep moving through post
processors", 2026-10-28). Revision 2 answers the first review (executor, auditor, skeptic, simplifier): every other option
of revision 1 (a first-line prelude, CRLF line endings, G70/G71 or no units code, a forced-dot seconds placeholder) moves to
the dialect issue that needs it. Each reached readers revision 1 did not cover (the post editor's checks, the deepest-cut
readback, the preview, the probe recovery line), and none is confirmed needed by the next batch.

## Goal

A post can write its dwell in milliseconds. Today `{SECONDS}` prints `G4 P3` for the 3 s spin-up; on a controller where `P`
is milliseconds (MASSO, NcStudio, UCCNC by default; #99 item 1's table) that is a 3 ms spin-up and a plunge into a bit that
has not reached speed. This unblocks MASSO (#107), UCCNC (#108) and NcStudio (#109). Every existing post writes the same bytes.

## Change

1. **`{MILLISECONDS}`, in the dwell template only.** The dwell in whole milliseconds, `NumberFormat.fixed(seconds * 1000,
   decimals: 0)` (no integer conversion, so no trap on a huge value; `%.0f` rounding): 3 s → `3000`, 0.5 → `500`,
   0.125 → `125`, 2.9996 → `3000`, 0.0004 → `0`. `GCodeWriter.dwell` is the one place the dwell template is rendered (the
   spindle spin-up and every in-toolpath dwell go through it); it supplies `SECONDS` and `MILLISECONDS` from one
   `PostProfile.dwellValues(seconds:) -> [String: String]`. `baseValues` and the other templates do not change.
2. **The post editor** accepts `G4 P{MILLISECONDS}` (and `P{MILLISECONDS} G4`) beside `G4 P{SECONDS}`, still rejects
   anything else (`G4 P{SECONDS}000` included), lists `MILLISECONDS` for the dwell template, and the Help text names both
   forms. Its fixed-codes message becomes "Dwell must be G4 P{SECONDS} or G4 P{MILLISECONDS}".
3. **Schema.** An older LoftLine leaves an unknown placeholder in the text (`TemplateRenderer`), so it would post
   `G4 P{MILLISECONDS}`. `PostProfile.currentSchemaVersion` becomes 2. One computed `requiredSchemaVersion` is 2 when the
   dwell template contains `{MILLISECONDS}`, else 1; `toJSON()` and `snapshot()` (the two places a post is written; nothing
   else encodes one) write `max(schemaVersion, requiredSchemaVersion)`. The stored default stays 1, so every built-in and
   every post without the placeholder is written as 1 and an older LoftLine still reads it; a project carrying a post that
   uses it is refused whole by an older LoftLine ("made with a newer LoftLine"), which DECISIONS says.
4. **Preview.** `GCodeReader` keeps guessing a `G4 P` unit (`P > 100` is ms): right for a millisecond post's spin-up
   (`P3000` → 3 s) and wrong for a millisecond dwell of 100 ms or less (`P50` reads as 50 s). That is the preview of an
   arbitrary file, which cannot know the unit; DECISIONS records the gap.

## Not in this change (answered on #99)

Items 2 (prelude), 4 (CRLF), 7 (units code) and the forced-dot seconds placeholder go to the dialect issues that need them
(#111 Haas/Fanuc, #107 MASSO, #108 UCCNC, #110 Syntec), each with the readers this review found: `PostDraftReport`'s line
split and sample warnings, `ExportGCodeSheet`'s preview split, `DeepestCut`'s and `GCodePreviewModel`'s assumed units,
`ProgramBuilder.recoveryLine` and `ProbeSequenceChecker`, `GCodeReader`'s units and dwell words. Items 3 and 9 wait for a
dialect that needs them. Item 6: a controller with no Optional Stop writes M0 for GRBL (#115) and the Othermill (#114) only;
MASSO, UCCNC and NcStudio need it in their own issues. Items 5, 8, 10–15 are answered per dialect.

## Tests

- A post with `dwell: "G4 P{MILLISECONDS}"` writes `G4 P3000` after `M3` (golden lines for that post), and `G4 P500` for a
  0.5 s dwell move; `dwellValues` gives `125` for 0.125, `3000` for 2.9996, `0` for 0.0004 and a finite string for 1e300.
- Every existing post's dwell is unchanged (goldens, `samples/expected`, no `--update`).
- Editor: `G4 P{MILLISECONDS}` and `P{MILLISECONDS} G4` pass and the draft is saveable; `G4 P{SECONDS}000` and
  `G4 P{MILLISECONDS}0` fail with the new message; `placeholders[.dwell] == ["SECONDS", "MILLISECONDS"]`.
- Schema: a post whose only change is the millisecond dwell encodes `schemaVersion` 2 through `toJSON()` and `snapshot()`;
  a post without it encodes 1; every built-in encodes 1; a reader that supports only 1 refuses the first. The tests that
  write `2` as "newer than supported" for a post (`SnapshotTests`, `ProjectPostDocumentTests`, `ProjectOpeningTests`,
  `ProjectPostResolveTests`) use `PostProfile.currentSchemaVersion + 1`.

## Docs

DECISIONS (`dwell-ms`: the placeholder, the schema rule and what an older LoftLine does, the preview gap); Help (Post
Processors: both dwell forms, and that `P` means milliseconds on some controllers); a comment on #99 answering every item.
