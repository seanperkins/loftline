# Line endings per post (#99 item 4)

Status: draft, revision 1.

## Problem

`ProgramBuilder.build` joins lines with `"\n"` (`ProgramBuilder.swift:95`), so every program is LF only. MASSO's own
Vectric post writes CRLF (`LINE_ENDING = "[13][10]"`). Whether MASSO reads LF is unknown, and no post can choose.
The #99 survey found CRLF in everyday use on hobby controllers (Kiri:Moto writes it for every machine, GRBL included),
and FreeCAD and dxf2gcode make it a post option.

## Design

### 1. A post setting

`PostProfile.lineEnding: LineEnding?` with `public enum LineEnding: String, Codable, CaseIterable, Sendable { case lf,
crlf }`. nil means LF, so every existing post, file and project copy is unchanged, and built-ins without it keep their
value equality.

- `requiredSchemaVersion` is 5 when `lineEnding == .crlf`: an older LoftLine would drop the field and write LF, which
  is different bytes for a controller that may need CRLF (the rule in `currentSchemaVersion`'s comment).
  `currentSchemaVersion` becomes 5.
- The post editor's Numbers section gets `Picker("Line endings")` with "LF (macOS, Linux)" and "CRLF (Windows)".
- `public func fileText(_ program: String) -> String` returns `program` for LF and every `"\n"` replaced by `"\r\n"`
  for CRLF. A program never contains `"\r"` (templates are single lines; `GCodeWriter` writes no `\r`).

### 2. Programs stay LF in memory; files get the post's ending

The program text is read back by the validator, `DeepestCut`, the job sheet, the G-code preview and the time
estimate. Swift treats `"\r\n"` as one `Character`, so code that splits on `"\n"` would see one line. Rather than
audit every reader, the text stays LF and the ending is applied only to the bytes written to disk:

- `GCodeExportResult` gets `fileText: String?`, set by `GCodeExporter.export` to `profile.fileText(text)`.
- Every place that writes a program to a file writes `fileText`: `ExportGCodeSheet` (single save),
  `SaveAllToolpathsSheet` (one-file save), `GCodeFileSet` (Save All and tiled export, via `init(posted:)` and
  `init(tiles:)`), and the CLI's `export` (file and `--out -`).
- Reading a CRLF program back (File ▸ Preview G-code File…) already works: `GCodeParser` splits on `"\r\n"`. A test
  pins it.

### 3. MASSO writes CRLF

`masso-g3-inch` and `masso-g3-mm` set `lineEnding: .crlf`, matching the maker's post. This moves the bytes of
`samples/expected/masso-g3-*` (a CR before every LF, nothing else). `.gitattributes` gets
`samples/expected/** -text` so git never normalises them, and `scripts/check-samples.sh --update` regenerates them.

No other built-in changes: there is no evidence that any other controller needs CRLF, and every built-in's documented
transfer path accepts LF.

## Tests

- PostCore: `fileText` for LF (unchanged) and CRLF (every line ends `\r\n`, the line count is unchanged, the last line
  too); `requiredSchemaVersion` 5 for CRLF and unchanged for nil; a CRLF post round-trips through JSON; a v5 file is
  refused by a reader capped at 4 (the existing schema test pattern); both MASSO built-ins are CRLF and no other is.
- App: `GCodeExporter.export` with the MASSO post: `text` has no `\r`, `fileText` is `text` with CRLF; `GCodeFileSet`
  writes `fileText` bytes (a CRLF file on disk); the CLI writes a CRLF file for a MASSO export; `GCodeReader` reads a
  CRLF program to the same moves as its LF form.
- `scripts/check-samples.sh` after `--update`: only the MASSO files differ, and only by CR bytes
  (`diff <(tr -d '\r' < new) old` is empty).

## Docs

DECISIONS `line-endings`; #99 comment answering item 4.
