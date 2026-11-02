# Line Endings Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A post can write CRLF files (MASSO does), while program text stays LF in memory (#99 item 4).

**Architecture:** `PostProfile.lineEnding` (one-case enum, nil = LF) is applied to the bytes written to disk through a computed `GCodeExportResult.fileText`; `postProblem` refuses template lines that contain line breaks.

**Tech Stack:** Swift 6, SwiftPM, swift-testing, SwiftUI.

**Spec:** `docs/specs/2026-11-02-line-endings-design.md` (revision 3)

## Global Constraints

- Line-ending assertions compare UTF-8 bytes, never Characters.
- Only `samples/expected/masso-g3-*` change; `git diff --ignore-cr-at-eol` shows only their header version line.
- Refusal text, exactly: `A template line contains a line break: put each line on its own line.`
- Picker: label "Line endings", options "LF (macOS, Linux)" (nil) and "CRLF (Windows)" (`.crlf`).

## Review Focus

1. A tiled export with the MASSO post: every tile file is CRLF.
2. `--out -` with the MASSO post writes CRLF to stdout (the samples test reads it).
3. An existing MASSO project copy: still LF, with the copy-differs notice.
4. The editor's draft of a CRLF post saves as schema 5 and reloads as CRLF.
5. A pause or tool-change template read from JSON with `\n` inside: refused before posting.

---

### Task 1: PostCore setting, schema, refusal, MASSO

**Files:** `Sources/PostCore/Model/PostProfile.swift`, `Sources/PostCore/Profiles/BuiltInPosts.swift`; Tests: create `Tests/PostCoreTests/LineEndingTests.swift`, modify `Tests/PostCoreTests/SnapshotTests.swift`.

**Produces:** `public enum LineEnding: String, Codable, Sendable { case crlf; public func apply(_ program: String) -> String }` nested in `PostProfile`; `public var lineEnding: LineEnding?`; init parameter `lineEnding: LineEnding? = nil` (last); `currentSchemaVersion = 5`.

- [ ] Tests: `apply` bytes (CR before every LF, LF count unchanged); nil post's program bytes unchanged; `requiredSchemaVersion` 5 for CRLF with and without `.apostrophe`; JSON round-trip of CRLF; `"lineEnding": "lf"` refused by `fromJSON`; `postProblem` text for `\r\n`, `\r`, `\n` in prelude, footer, toolChange, pause; `TemplatePostProcessor.post` throws `.invalidPost` for such a post; MASSO built-ins `.crlf` and version "1.1", no other built-in CRLF. Update `schemaVersionIsAlwaysWritten` (MASSO to 5, current 5) and `everyFieldSurvivesTheDecoder` (set `lineEnding = .crlf`).
- [ ] `scripts/test.sh --filter "LineEnding|Snapshot"`: FAIL. Implement. PASS. Commit `feat(post): a post can write CRLF line endings; MASSO does (#99)`.

### Task 2: Files get the post's ending

**Files:** `Sources/LoftLineApp/Model/GCodeExporter.swift`, `GCodeFileSet.swift`, `LoftLineCLI.swift`, `Sources/LoftLineApp/Panels/ExportGCodeSheet.swift`, `SaveAllToolpathsSheet.swift`, `.gitattributes`, `samples/expected/masso-g3-*`; Tests: `Tests/LoftLineAppTests/LoftLineCLITests.swift`, a new `Tests/LoftLineAppTests/LineEndingExportTests.swift`.

**Consumes:** Task 1 `PostProfile.lineEnding`, `LineEnding.apply`.

- [ ] Tests: export with `masso-g3-inch` → `text` utf8 has no 13 and `fileText` == `apply(text)`; `GCodeFileSet(posted:)` and `(tiles:)` write CRLF bytes to a temp folder; a project carrying the old MASSO copy (nil, version 1.0) → `ProjectPost.resolve(...).postCopyDiffers != nil` and its export `fileText` has no 13; `GCodeReader` on a CRLF program gives the same segments as LF; CLI samples test compares `Data(r.out.utf8)` with `Data(contentsOf:)`.
- [ ] Run: FAIL. Implement (`GCodeExportResult.lineEnding`, computed `fileText`; every write site uses `fileText`). `scripts/check-samples.sh --update`; `git diff --ignore-cr-at-eol --stat -- samples/expected` shows only MASSO header lines. Add `.gitattributes`. Run: PASS. Commit `feat(export): write each program with its post's line endings (#99)`.

### Task 3: Editor, docs, gate

**Files:** `Sources/LoftLineApp/Panels/PostProcessorsSheet.swift`, `HelpTopics` (post editor topic), `docs/DECISIONS.md`, `docs/PARITY.md`.

- [ ] Picker in the Numbers section; `scripts/ui.sh post-processors --light` and read the `.ax.txt` for "Line endings". Help text one sentence. DECISIONS `line-endings` (incl. next release sets `gcodeChanged`). PARITY row if a post-option row exists. Commit `feat(ui): line endings in the post editor (#99)`.
- [ ] `scripts/build.sh`, `scripts/test.sh`, `scripts/check-samples.sh`: green.
