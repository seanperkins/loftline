# Operation warnings reach Check Toolpaths and the export sheet (issue #131)

Status: draft, revision 1

## Problem

An operation records what it could not do as asked in `Toolpath.metadata["warning"]`, one string with its
sentences joined by `"; "`. Examples:
- tabs: "the part may come free";
- vectors too small for the tool, or open vectors cut on the line;
- pocket floor left uncut;
- V-carve and prism limits;
- cuts deeper than the flute length (`AnyOperation`);
- ramps steeper than their maximum angle (#124).

Only the job sheet (`JobSheet.swift:129`) and the operation editor read it. `GCodeExporter.export` builds
its issues from the validator and the export checks, and never adds the warning. So Check Toolpaths and the
export sheet say nothing about a part that may come free, or a cut deeper than the flutes.

## Design

- `GCodeExporter.operationWarnings(_ toolpaths: [Toolpath]) -> [GCodeIssue]`: one warning per toolpath that
  has a non-empty `metadata["warning"]`. The message is `"<toolpath name>: <warning>"`. The severity is
  `.warning`, never `.error`: these are judgement calls the operation already let through, and Save
  Anyway must not be needed for them.
- `export` adds `operationWarnings(toolpaths)` straight after `validator.validate(toolpaths:)`. It uses the
  toolpaths as passed in, before keep-out linking, which keeps their metadata. They are listed in toolpath
  order.
- The string is not split on `"; "`. A sentence can itself contain `"; "` (the #124 ramp warning does), and
  one line per toolpath matches what the job sheet shows.
- Check Toolpaths already calls `export` per operation and for the combined program. The combined section
  drops messages already listed under an operation (`seen`), so each warning appears once, under its
  operation. Tiled and batch export go through `export` too, so they show it as well.
- `GCodeIssue.merged` folds identical messages, so a toolpath posted twice in one program (a tile copy, an
  array) is listed once.

## Not in scope

- **A per-toolpath `warning` key in the operation editor** (`OperationEditor.swift:217` keys rows by key).
  The editor is unchanged. A pocket still reports a steep clearance ramp on its finish toolpath (#124).
- **Splitting warnings into structured values in CAMCore.** The string is what every operation already
  writes, and the job sheet reads it the same way.

## Tests (LoftLineAppTests, beside `PreflightChecksTests`)

- **A tab warning reaches export.** A profile whose loop is too short for its tabs exports with a warning
  issue `"<name>: 1 loop(s) got fewer tabs than asked …"`. It is a warning, the program is still written,
  and `errorMessage` is nil.
- **A clean toolpath adds nothing.** A toolpath with no warning adds no issue.
- **Check Toolpaths lists it once.** In a `ValidationReport` for that project, the warning appears in the
  operation's section and not in "Combined program".
- **Order and severity.** For two toolpaths with warnings, the two issues come in toolpath order and are
  both `.warning`.

## Docs

- HelpTopics, Check Toolpaths paragraph: add "and what each operation could not do as asked (tabs that may
  let the part come free, cuts deeper than the flutes)".
- DECISIONS: a new entry, `operation-warnings-at-export`.
