# Post engine: dwell in milliseconds (issue #99, item 1)

Revision 3, 2026-10-28. Part of the dialect roadmap (#98), approved by Sean ("go", then "keep moving through post
processors", 2026-10-28). Revision 2 answers the first review (executor, auditor, skeptic, simplifier): every other option
of revision 1 (a first-line prelude, CRLF line endings, G70/G71 or no units code, a forced-dot seconds placeholder) moves to
the dialect issue that needs it. Each reached readers revision 1 did not cover (the post editor's checks, the deepest-cut
readback, the preview, the probe recovery line), and none is confirmed needed by the next batch. Revision 3 answers round 2: the written version is computed from content and a
decoded post keeps 1 in memory, dwells are bounded, and two editor rules stop a millisecond post from also writing seconds.

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
   `G4 P{MILLISECONDS}`. `PostProfile.currentSchemaVersion` (the highest version this LoftLine reads) becomes 2; the stored
   property's default (`PostProfile.swift:75`, today `= PostProfile.currentSchemaVersion`) becomes the literal `1`, and
   `fromJSON` and `init(snapshot:)` set the stored value to 1 after the version check. So in memory every post holds 1, and
   value equality (`BuiltInPosts.probeController`, which #115's GRBL M0 rule relies on; a snapshot round trip) never sees a
   version: a GRBL built-in's copy carrying `"schemaVersion": 2` still equals the built-in. One computed `requiredSchemaVersion` is 2 when the
   dwell template contains `{MILLISECONDS}`, else 1; `toJSON()` and `snapshot()` (the two places a post is written; nothing
   else encodes one) write `requiredSchemaVersion` itself, not the stored value, so a post whose dwell is switched back to
   `{SECONDS}` is written as 1 again. Every built-in and every post without the placeholder is written as 1 and an older
   LoftLine still reads it (a file from a newer LoftLine is refused on reading, before it can be written back); a project carrying a post that
   uses it is refused whole by an older LoftLine ("made with a newer LoftLine"), which DECISIONS says, with the exception it
   cannot cover: v0.2.0, the one release, predates `schemaVersion` and loads a millisecond post file from the posts folder,
   posting `G4 P{MILLISECONDS}` literally (projects are still refused there, by the project format version).
4. **Bounds.** `{MILLISECONDS}` is the first placeholder that can print a non-number (`%.0f` of `s * 1000` is `INF` above
   1.8e305 s). `spindleDwellSeconds` must be 0–3600 s (`checkingBounds` refuses a file outside it; the editor reports it), and
   the builder refuses a toolpath dwell over 3600 s (`PostError.nonFiniteMove`'s check, extended, with its own message).
5. **Editor rules.** A post whose dwell uses `{MILLISECONDS}` may not use `{SECONDS}` in any other template ("A post that
   dwells in milliseconds cannot also write {SECONDS}: a G4 P{SECONDS} elsewhere would dwell milliseconds"), since
   `baseValues` gives `{SECONDS}` in seconds to every template. A post that declares the GRBL controller may not use
   `{MILLISECONDS}` (GRBL's P is seconds: `G4 P3000` is a 50-minute wait).
6. **Preview.** `GCodeReader` keeps guessing a `G4 P` unit (`P > 100` is ms): right for a millisecond post's spin-up
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
  `G4 P{MILLISECONDS}0` fail with the new message; `placeholders[.dwell] == ["SECONDS", "MILLISECONDS"]` (the existing
  assertion in `PostDraftReportTests` changes); a millisecond post with `{SECONDS}` in its pause is a problem; a GRBL-declared
  post with `{MILLISECONDS}` is a problem; `spindleDwellSeconds` 3601 is a problem and a file with it is refused.
- Builder: a toolpath dwell of 3601 s throws; `dwellValues` never prints a non-number for any value the bounds let through.
- Schema: a GRBL built-in's snapshot with `schemaVersion` set to 2 decodes equal to the built-in and writes M0 for an optional
  stop; a millisecond post round-trips equal through `snapshot()` and `toJSON()`;
  a post whose only change is the millisecond dwell encodes `schemaVersion` 2 through `toJSON()` and `snapshot()`;
  a post without it encodes 1; the same post read back as 2 and switched back to `{SECONDS}` encodes 1; every built-in
  encodes 1; a reader that supports only 1 refuses the first. The tests that
  write `2` as "newer than supported" for a post (`SnapshotTests`, `ProjectPostDocumentTests`, `ProjectOpeningTests`,
  `ProjectPostResolveTests`) use `PostProfile.currentSchemaVersion + 1`; in `SnapshotTests` the post assertions expect
  `supported: PostProfile.currentSchemaVersion` and the constant check changes, while the machine half stays `found: 2,
  supported: 1` (machines stay at version 1).

## Docs

DECISIONS (`dwell-ms`: the placeholder, the schema rule, what builds from `98858e5` on and v0.2.0 do, the bounds, the preview
gap); the doc comments at `PostProfile.swift:6` and `:71-75`; PARITY `io-post-processors` (one line); Help (Post
Processors: both dwell forms, and that `P` means milliseconds on some controllers); a comment on #99 answering every item.
