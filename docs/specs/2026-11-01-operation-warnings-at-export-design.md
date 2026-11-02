# Operation warnings reach Check Toolpaths and the export sheet (issue #131)

Status: approved, revision 2 (after debate:all round 1)

## Problem

An operation records what it could not do as asked in `Toolpath.metadata["warning"]`. It is one string,
with its sentences joined by `"; "`. Examples:
- tabs: "the part may come free";
- vectors too small for the tool, or open vectors cut on the line;
- a pocket floor left uncut;
- V-carve and prism limits;
- array copies off the material;
- ramps steeper than their maximum angle (#124).

Only the job sheet (`JobSheet.swift:129`) and the operation editor read it. `GCodeExporter.export` never
adds it to its issues. So Check Toolpaths, the export sheet and the CLI say nothing about a part that may
come free.

## Design

- **New check.** `PreflightChecks.operationWarnings(_ toolpaths: [Toolpath]) -> [GCodeIssue]` returns one
  `.warning` per toolpath that has a non-empty `metadata["warning"]`.
  - The message is `"Toolpath '<name>': <warning>"`, in the same form as the validator's and layout's
    per-toolpath issues.
  - The issues come in toolpath order.
- **Where it runs.** `PreflightChecks.issues(project:toolpaths:units:)` appends it.
  - `export` already calls that function, after keep-out linking, on `toolpaths` (not `checked`). Linking
    keeps names and metadata. The move home has no metadata.
  - `export` itself does not change.
- **Always a warning.** The severity is never `.error`: the operation already let these through, and they
  must not need Save Anyway.
- **One string per toolpath.** The string is not split. A sentence can itself contain `"; "`, as the #124
  ramp warning does. One line per toolpath matches the job sheet.
- **Flute overruns appear twice, on purpose.** A cut deeper than the flutes is already an error from the
  validator (`GCodeValidator.swift:66-70`). `AnyOperation` also appends a note about it to the warning
  string, so export now shows both:
  - the error, which needs Save Anyway;
  - the warning, which carries the rest of the operation's notes.

  Removing the note would mean either parsing the joined string or adding a separate metadata key. Neither
  is worth it for a duplicate that sits next to an error the operator must accept anyway.

**Where the warning shows:**
- **Check Toolpaths.** It calls `export` per operation and for the combined program. The combined section
  drops messages already listed under an operation (`seen`), so each warning shows once, under its operation.
- **Export sheet.** It lists the warning.
- **CLI.** It prints `warning: …` to stderr. The exit status is unchanged, since only errors set it.
- **Save All and tiling sheets.** They count the warning; they show counts only.

## Not in scope

- **Refusals.** An export refused before its checks run returns no issues at all, so it shows no
  operation warnings either: no toolpaths, a probing spot problem, or a tiled probing refusal.
- **Tiles.** A tile carries its source toolpath's metadata (`ToolpathTiling.swift:215`). Each tile's file
  repeats the operation's warning, even where the short loop it describes is in another tile. The warning
  is a note about the whole operation.
- **Same-named operations.** `GCodeIssue.merged` folds identical messages. Two operations with the same name
  and the same warning show one line in the combined program. Their own Check Toolpaths sections still show
  both.
- **A per-toolpath `warning` key in the operation editor** (`OperationEditor.swift:217`).

## Tests (LoftLineAppTests, in `PreflightChecksTests`)

- **`operationWarnings` alone.** Use hand-built toolpaths:
  - one with no `warning`, which adds nothing;
  - two with warnings, which give two `.warning` issues in order, with the exact messages;
  - a merge-style prefixed string (`"Profile 1: …"`), which is passed through whole.
- **A tab warning reaches export and Check Toolpaths.**
  - Setup: a profile with tabs on a loop too short for them.
  - `export` writes the program with `errorMessage` nil and no errors, and its issues contain
    `"Toolpath '<name>': 1 loop(s) got fewer tabs than asked"`.
  - `ValidationReport.make` lists it in the operation's section, not in "Combined program".
- **A flute overrun.** A profile deeper than its tool's flute gives the existing error and the operation
  warning.
- **The samples.** First run `scripts/test.sh --filter "SampleFiles|LoftLineCLI"`. These pin that the
  samples export with no issues (`SampleFilesTests.swift:119`, `:169`, `:221`) and with no unlisted stderr
  (`LoftLineCLITests.swift:308`). If a sample now warns, fix the sample, not the assertion: regenerate it with
  `LOFTLINE_WRITE_SAMPLES=1`, then `check-samples.sh --update`, and review the diff.

## Docs

- **HelpTopics, Check Toolpaths paragraph.** Add "and what each operation could not do as asked (for example
  tabs that may let the part come free), as warnings".
- **DECISIONS, new entry `operation-warnings-at-export`.** Record three things:
  - the severity is always warning;
  - the string is not split;
  - flute overruns show as both an error and a warning, on purpose.
- **PARITY `io-preflight`.** Add operation warnings.
