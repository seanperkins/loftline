# LoftLine: the post editor

Part 3 of the post-processor work. Part 1 (projects carry their post) and part 2 (coolant, park-and-probe) are on main at
`f186ee7`. Part 4 (share a post as a file) and part 5 (more built-in posts) are out of scope.

Revision 3, after two review rounds (Executor, Auditor, Claude Skeptic, Claude Simplifier).

## Why

A post is the G-code dialect. Today a custom post is a hand-written JSON file in `Application Support/LoftLine/posts`: no
form, no preview, no check, and a file that does not load is skipped without a word (part 1 promised to tell the user). Part 2
left two things for this part: a custom post cannot use touch-plate tool changes because a post cannot say which controller it
speaks, and the skipped-file message.

## Goals

- Edit every field of a post in a form, starting from a duplicate, and see the G-code it writes for a sample job, with the
  validator's verdict, as you type.
- A post whose fields break the program, or that cannot post the sample job cleanly, cannot be saved.
- A custom post can declare its controller, which lets it use touch-plate tool changes.
- Post files that did not load are listed with the reason, in the app and by the command line.
- **Built-in posts, goldens and `samples/expected/` stay byte-identical.** One stated change: a post file whose name is not
  `<id>.json`, whose id is not a safe name, or whose id another file already uses, no longer loads; it is listed with that
  reason (renaming the file fixes it). Projects that carry its copy keep posting with the copy.

## Decisions

1. **Built-in posts are read-only; edit a duplicate.** **Duplicate** makes an unsaved draft; only **Save** writes a file. The
   draft's id is `<base>-custom-<n>` (an existing `-custom-<n>` suffix on the base is dropped first) and is not editable. A
   user file that carries a built-in's id still overrides it (today's rule); the list shows it as "Custom (replaces the
   built-in)".
2. **A sheet on the document window: Toolpaths ▸ Post Processors…** (beside Open Post Profiles Folder). The Settings window is
   a fixed 640 × 480; this sheet is about 960 × 680 with the list, the form and the preview side by side, and the UI harness can
   open it (`"postProcessors"` in its sheet list). While a draft has unsaved changes the list is locked: **Save** or **Cancel**.
3. **Delete moves the file to the Trash**, never removes it: a post is machine output. The store takes the move as an injected
   function (default `FileManager.trashItem`), so tests never touch the real Trash; TESTING.md checks the real one.
4. **Controller declaration.** `PostProfile.controller: ToolChangeProbe.Controller?` (Mach4 or GRBL; nil = not declared), coded
   only when set, so every existing file and project copy keeps its bytes. Built-in posts stay nil and keep part 2's by-value
   mapping. `BuiltInPosts.probeController(for:)` becomes: a built-in compared by value gives its controller; any other post gives
   its declared `controller`. The probe sequence is written in code, not from the post's templates, so the declaration is what
   probing needs. Duplicate sets the copy's `controller` to the built-in's, so a tweaked Avid post keeps touch-plate tool
   changes. A project's post copy that declares a controller can now probe (on a machine installed here that is set up to
   probe), consistent with part 1's "the copy posts". Part 2's refusal message says what is wrong ("the post declares no
   controller" / "declares GRBL; this machine probes with Mach4").
5. **Schema stays 1.** None of parts 1–3 has shipped; v0.2.0 reads a user post file and ignores `controller`, and it has no
   probing, so dropping the key changes no G-code. The comment on `currentSchemaVersion` becomes "raise it when a reader that
   drops the field could post different G-code".
6. **Editing a post that projects carry.** Projects keep their copy (part 1). After a save, a project whose copy differs gets
   part 1's warning and **Update This Project**. Nothing is pushed into projects.

## The editor

Grouped like the file, every field of `PostProfile`:

- **Post**: name, version, file extension, units, controller (None / Mach4 / GRBL).
- **Numbers**: decimals, feed decimals, modal output, line numbers, header comments, comment style.
- **Motion**: rapid, linear, arc CW, arc CCW codes; arc output (incremental IJ, absolute IJ, lines), arc tolerance, helical arcs.
- **Spindle**: on, off ("also used by touch-plate tool changes"), dwell template and seconds, min and max RPM.
- **Program**: preamble, tool change, tool length offset (and whether it is used), footer, pause lines (empty = the default
  pause; an empty text area is saved as no pause template, never as an empty one). Multi-line templates are text areas, one
  line per G-code line, with automatic quote and dash substitution off.
  Beside each template, the placeholders that template can use (the table below).
- **Limits and speeds**: X, Y, Z travel, allowed spoilboard cut, rapid rate, max feed, min and max RPM, with the note that a
  machine's values replace them when a machine is picked.

The list on the left: Built in, Custom, and Did not load (file name and reason). Buttons: Duplicate, Folder, Delete (custom
posts), Save (disabled while there is a blocking problem), Cancel. Save of a new draft never replaces a file: if `<id>.json`
appeared since Duplicate (another window's new post), Save takes the next free id and says so. Save of an edit to an existing
custom post replaces its own file.

## The report

One function, synchronous (run on each edit; with decimals capped at 6 the sample is at most a few thousand lines):

`PostDraftReport.make(_ draft: PostProfile) -> PostDraftReport` with `problems: [String]` (blocking), `program: String?`,
`issues: [GCodeIssue]` (shown). The static rules run first; the sample is posted only when none fails, so a typed value can
never reach the builder (a huge `decimals` would exhaust memory).

**Static rules (blocking):**

- Name not empty after trimming; file extension letters and digits only; every template line and motion code printable ASCII
  (0x20–0x7E). (Name and version reach the program only through the comment-safe function.)
- Round trip: `PostProfile.fromJSON(draft.toJSON())` succeeds (the loader's own bounds, such as 0–12 decimals).
- Decimals 3 to 6 for an inch post, 2 to 6 for mm (rounding of 0.0005 in / 0.005 mm; above 6 a linearised arc runs to tens of
  thousands of lines on every keystroke); feed decimals 0–3.
- Every number finite: travels, rapid rate, max feed and max RPM above 0; allowed spoilboard cut, dwell seconds and min RPM at
  least 0; min RPM at most max RPM.
- Arc tolerance between half a digit (`0.5·10^-decimals`) and 0.01 in (0.25 mm), whatever the arc output (helices and tiny arcs
  are linearised too).
- **Fixed codes**, checked by parsing the field (`GCodeParser`) after rendering it with sample values, so `G00` and `M03` pass
  and `G40`, `M30` or a comment do not: rapid is exactly one word `G0`, linear `G1`, arc CW `G2`, arc CCW `G3`, nothing else;
  spindle on is exactly `M3` and an `S` word from `{S}`; spindle off is exactly `M5`; the dwell template is exactly `G4` and a
  `P` word from `{SECONDS}`. (A swapped or empty arc code, `G0 F600`, `M4` or `M30 S{S}` would post a program the validator
  cannot see is wrong.)
- **Placeholders per template**: a `{` or `}` in a template is allowed only as an allowed `{NAME}` for that template:

  | Template | Placeholders |
  |---|---|
  | preamble, footer | `SAFE_Z`, `HOME_X`, `HOME_Y`, `HOME_Z`, `JOB_NAME`, `POST_NAME`, `POST_VERSION`, `SECONDS` |
  | tool change, tool length offset, spindle on | the above, `T`, `TOOL_NAME`, `S` |
  | pause lines | the preamble's, `MESSAGE`, `STOP` |
  | dwell | `SECONDS` |
  | spindle off, motion codes | none |

  The text placeholders (`JOB_NAME`, `POST_NAME`, `POST_VERSION`, `TOOL_NAME`, `MESSAGE`) are allowed only inside a comment
  on their line (after an unclosed `(` or after `;`): a tool name like `1/4 Z-2` would otherwise write a `Z` word.
  `POST_VERSION` is rendered through the same comment-safe function as the name (every built-in's version is `1.0`, so no bytes
  change). `{STOP}` is the opposite: never inside a comment.
- A declared controller with the tool length offset in use (probing refuses it).

**The sample (blocking when it fails):** a fixed job in PostCore beside `BuiltInPosts`, `PostSampleJob.job(for: draft)`: an inch
document 4 × 3 × 0.5 in, material-top zero, safe Z 0.2 in, three toolpaths that cut no deeper than the material bottom: A (tool
1, a profile with a clockwise and a counter-clockwise arc, **a pause after it**), B (tool 1), C (tool 2, Mist coolant). So the
pause sits between toolpaths (the builder drops a pause after the last one) and the change from B to C has no pause before it.
Its spindle speed is `clamp(18000, max(1, minRPM), maxRPM)`, its feeds `min(feed, maxFeed)`, and it is posted with the draft's
limits widened to at least 100 × 100 × 10 in, converted to the draft's units (limits and RPM are machine numbers a machine
replaces; the sample tests the dialect). The report runs `GCodeValidator.validate(toolpaths:)` and `validate(gcode:)` on it, as
the exporter does. It blocks when:

- the builder throws, or the validator reports **any** error or warning except `coordinate-shift` (a footer may legitimately lift
  with `G53 G0 Z0`). Every built-in posts the sample with no issue at all, so this blocks a units change in a template, a stop
  with the spindle running, `M3` with no speed, garbage text and a missing program end;
- in the **parsed** program, the change from tool 1 to tool 2 has no block with `M0`/`M1`, and no block with `T<tool 2>` and
  `M6`, between B's last cut and C's first (the second tool's paths would be cut with the first bit);
- after the pause comment, no parsed `M0`/`M1` comes before the next motion block (a `{STOP}` in a comment, or an empty pause,
  stops nothing).

When the draft declares a controller, the same job is also posted with `ToolChangeProbe.defaults` for that controller (in the
draft's units, on the widened limits) and a touch-off spot at the sheet's centre, and the same rules apply, the probe state
table included.

The preview pane shows `program` read-only in a monospaced view, and the issues above it.

## The store

- `PostProfileStore.load() -> (profiles: [PostProfile], skipped: [SkippedPost])`, one scan of the folder, `SkippedPost {
  fileName, reason }`. A file is skipped when it does not decode (the `SnapshotError` reason: newer LoftLine, malformed with its
  path), when its id is not a safe name (`[A-Za-z0-9._-]`, not starting with `.`), when its name is not `<id>.json`
  (exactly, case included: save and delete act on `<id>.json`), or when an earlier file has the same id. A file's `pause: []`
  is read as no pause template. `allProfiles()` is `load().profiles`;
  `userProfiles()` goes. `PostProfileCatalog` publishes `skipped`.
- `newID(from:)` checks the folder's file names, case-folded (loaded, skipped and unreadable files alike), and the built-in ids.
- `save` refuses an unsafe id, and for a new post refuses an existing destination (the editor then takes the next free id);
  `delete(id:)` moves `<id>.json` to the Trash through the injected function.
- `loftline-cli posts` and `export` print each skipped file and its reason to stderr.

## Tests

1. Store: malformed, newer-schema, unsafe-id, name-mismatch (also case only) and duplicate-id files are skipped with their
   reasons; a good file loads; `pause: []` loads as nil; `newID` avoids a skipped file's name and a case-only clash, and drops
   an existing `-custom-<n>`; delete calls the injected function with the file's URL; save refuses `../x` and a new post over an
   existing file; the CLI prints skipped files.
2. Controller: a post with `controller` round-trips; without it no key is written (every built-in's bytes unchanged); a decoder
   that drops the key gets a post that cannot probe; a custom post declaring `.mach4` probes on a Mach4 machine, one declaring
   nothing or `.grbl` is refused with the matching message; a project copy declaring `.mach4` probes; a duplicate of the Avid
   post carries `.mach4`; the built-in by-value rule is unchanged.
3. Report, one test per static rule, including: swapped arc codes, an empty arc code, `G0 F600`, `M4 S{S}`, `M30 S{S}`,
   `M3 (S{S})`, `G40 P{SECONDS}`, `G04 P{SECONDS}` and `M03 S{S}` (accepted), `{T}` in the footer, `{SAFE_Z}` in the dwell,
   `{S}` in spindle off, a lone `{`, `{TOOL_NAME}` outside a comment, `{STOP}` inside a comment, a version with `)`, a non-ASCII
   quote in a template, decimals 2 and 7 on an inch post, an arc tolerance of 0.05 in, an infinite travel, max RPM 0, a
   controller with the tool length offset; and the sample: a tool change of `["M5"]`, `[]` and `["M5", "M6"]` (no `T`) refused;
   a tool change with `M5` removed refused; a pause of `["M05"]` refused; `G21` in an inch post's footer refused; a footer
   `G53 G0 Z0` accepted; a 0–12000 RPM post and a 100 mm travel post accepted; a declared-controller draft runs the probe
   sample.
4. Every built-in post's report is clean (no problem, no issue), and so is an unedited Duplicate of each (which carries its
   controller, so the probe sample runs).
5. UI: a harness scenario opens Post Processors with a custom post selected; the PNG and the accessibility tree are checked.
6. Goldens, samples and `scripts/check-samples.sh` unchanged; the full suite green.

## Risks

- A custom post is machine output the owner wrote. The rules and the sample cannot exercise everything (other arc planes,
  drilling cycles); the export still validates every real program.
- A declared controller that is wrong lets probing write a sequence the controller misreads. The air-probe check (TESTING.md)
  applies to custom posts too.

## Docs

`docs/DECISIONS.md` (`post-editor`), `docs/PARITY.md` (the `io-post-processors` row), `TESTING.md` (editing a post, the real
Trash, the custom-post air-probe step), Help (Machines and Post Processors), and the comments the change makes stale
(`BuiltInPosts` header and `probeController`, `MachineDefinition.applied(to:)`, `PostProfile` placeholder and schema comments).

## Order of work

1. Store: `load()`, skipped files, safe ids, `newID`, Trash delete, CLI. 2. `PostProfile.controller`, the probe rule and its
message, `POST_VERSION` comment-safe. 3. `PostSampleJob` and `PostDraftReport`. 4. The Post Processors sheet. 5. Docs.
