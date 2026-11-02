# Line endings per post (#99 item 4)

Status: revision 2, after the round 1 panel (two GPT-6 seats, an Opus skeptic, a Sonnet simplifier).

## Problem

`ProgramBuilder.build` joins lines with `"\n"` (`ProgramBuilder.swift:95`), so every program is LF only. MASSO's own
Vectric post writes CRLF (`LINE_ENDING = "[13][10]"`). Whether MASSO reads LF is unknown, and no post can choose.
The #99 survey found CRLF in everyday use on hobby controllers (Kiri:Moto writes it for every machine, GRBL included),
and FreeCAD and dxf2gcode make it a post option.

## Design

### 1. A post setting

`PostProfile.lineEnding: LineEnding?` with `public enum LineEnding: String, Codable, Sendable { case crlf }`. nil is
LF. One case only, like `UnitsCodes` (`PostProfile.swift:25-27`): no file can spell out the default, so a post
recognised by value as a built-in (`BuiltInPosts.probeController`, `MachineDefinition`) never drifts. The memberwise
`init` gets `lineEnding: LineEnding? = nil` as its last parameter.

- `requiredSchemaVersion` returns 5 for `.crlf` before any other check (an NcStudio copy with `'` comments and CRLF must
  not be stamped 4). `currentSchemaVersion` becomes 5. An older LoftLine refuses a CRLF post, or a project carrying
  one, rather than dropping the field and writing LF.
- The post editor's Numbers section gets `Picker("Line endings")`: "LF (macOS, Linux)" = nil, "CRLF (Windows)" =
  `.crlf`, shaped like the Controller picker.

### 2. Programs stay LF in memory; files get the post's ending

The program text is read back by the validator, `DeepestCut`, `PostDraftReport.stopProblems` (the export's stop
check), the export sheet's preview, the job sheet and tests, several of which split on `"\n"`; Swift treats `"\r\n"` as
one `Character`. So the text stays LF and the ending is applied only to the bytes written to disk:

- `GCodeExportResult` stores `lineEnding: PostProfile.LineEnding?` (set by `GCodeExporter.export` from the profile) and
  computes `fileText: String?` from `text`, so the two cannot drift.
- `PostProfile.LineEnding.apply(_ program: String) -> String` (or a static on `PostProfile`) works on UTF-8 bytes: a CR
  is inserted before every LF not already preceded by one. It is idempotent, so a template line that already carries
  `\r\n` (a post read from JSON never passes the editor's ASCII rule) does not become `\r\r\n`; a lone CR is left as it
  is, exactly as an LF post writes it today.
- Every place that writes a program to a file writes `fileText`: `ExportGCodeSheet` (`:192`), `SaveAllToolpathsSheet`
  (`:175`), `GCodeFileSet.init(posted:)` and `init(tiles:)` (Save All and tiled export), and the CLI's `export` (file at
  `:326` and `--out -` at `:316`). Nothing puts a program on the pasteboard.
- Reading a CRLF program back (Toolpaths ▸ Preview G-code File…) already works: `GCodeParser.swift:55` and
  `GCodeReader.swift:307,330` split on `"\r\n"`. A test pins it.

### 3. MASSO writes CRLF

`masso-g3-inch` and `masso-g3-mm` set `lineEnding: .crlf`, matching the maker's post, and their `version` becomes
"1.1". This moves the bytes of `samples/expected/masso-g3-*` (a CR before every LF and the version in the header
comment). `.gitattributes` gets `samples/expected/** -text` so git never normalises them.

A project that already carries a MASSO copy keeps posting with it (LF), as every project copy does since
self-contained projects: the copy wins. The existing "differs from the installed post" notice shows the new version and
offers the installed post. A MASSO project saved by this version is stamped schema 5, so an older LoftLine refuses it.

No other built-in changes: there is no evidence that any other controller needs CRLF.

## Tests

Every line-ending assertion compares UTF-8 bytes (`Array(s.utf8)`), never `Character`s or `split(separator: "\n")`.

- PostCore: apply for CRLF (byte 13 before every byte 10, line count by bytes unchanged, the last line too) and
  idempotent (a `"\r\n"` in a line stays one CR); nil leaves bytes unchanged; `requiredSchemaVersion` 5 for CRLF,
  including with `'` comments; a CRLF post round-trips through JSON (`everyFieldSurvivesTheDecoder`); `"lf"` in JSON is
  refused; `SnapshotTests` pins (MASSO now 5, current 5); both MASSO built-ins are CRLF and version 1.1, no other is CRLF.
- App: `GCodeExporter.export` with the MASSO post: `text` bytes have no 13, `fileText` is `text` with CRLF;
  `GCodeFileSet` writes CRLF bytes to disk; `ProjectPost.resolve` of a project carrying the old MASSO copy reports
  `postCopyDiffers`; `GCodeReader` reads a CRLF program to the same moves as its LF form; the CLI samples test
  (`LoftLineCLITests`) compares the MASSO files byte for byte.
- `scripts/check-samples.sh --update`, then `git diff --ignore-cr-at-eol --stat -- samples/expected`: only the MASSO
  header's version line differs.
- UI: `scripts/ui.sh post-processors` shows the Line endings picker.

## Docs

DECISIONS `line-endings`; PARITY row; the post-editor help topic (`HelpTopics`); a note that the next release's feed
sets `gcodeChanged` (MASSO output changes); #99 comment answering item 4.
