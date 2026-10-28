# LoftLine: the post editor

Part 3 of the post-processor work. Part 1 (projects carry their post) and part 2 (coolant, park-and-probe) are on main at
`f186ee7`. Part 4 (share a post as a file) and part 5 (more built-in posts) are out of scope.

## Why

A post is the G-code dialect. Today a custom post is a hand-written JSON file in `Application Support/LoftLine/posts`: no
form, no preview, no check, and a file that does not load is skipped without a word (part 1 promised to tell the user). Part 2
left two things for this part: a custom post cannot use touch-plate tool changes because a post cannot say which controller it
speaks, and the skipped-file message.

## Goals

- Edit every field of a post in a form, starting from a duplicate, and see the G-code it writes for a sample job, with the
  validator's verdict, as you type.
- A post that cannot post the sample job cleanly cannot be saved.
- A custom post can declare its controller, which lets it use touch-plate tool changes.
- Posts that did not load are listed with the reason.
- **Nothing changes until a user saves a post**: built-in posts, goldens and `samples/expected/` stay byte-identical.

## Decisions

1. **Built-in posts are read-only; edit a duplicate**, exactly as machines are (Preferences ▸ Machines). A duplicate gets a fresh
   id `<base>-custom-<n>`; the id is the file name and is not editable. A user file that carries a built-in's id still overrides
   it (today's rule), and the editor shows it as "Custom (replaces the built-in)".
2. **Preferences ▸ Posts**, a fourth tab beside Machines, with the same shape: list on the left (Built in, Custom, and "Did not
   load" with the reason), the editor on the right, Duplicate, Folder, Delete.
3. **Delete moves the file to the Trash** (`FileManager.trashItem`), never removes it: a post is machine output.
4. **Controller declaration.** `PostProfile.controller: ToolChangeProbe.Controller?` (Mach4 or GRBL; nil = not declared). Coded
   only when set, so every existing post file and project copy keeps its bytes. Built-in posts stay nil and keep part 2's
   by-value mapping. `BuiltInPosts.probeController(for:)` becomes: a built-in compared by value gives its controller; any other
   post gives its declared `controller`. A post declaring a controller is the owner's statement that its program runs on that
   controller; the probe sequence is written in code, not from the post's templates, so the declaration is all it needs.
5. **Editing a post that projects carry.** Projects keep their copy (part 1). After a save, a project whose copy differs gets
   part 1's warning and **Update This Project**. Nothing is pushed into projects.

## The editor

Grouped like the file, every field of `PostProfile`:

- **Post**: name, version, file extension, units, controller (None / Mach4 / GRBL).
- **Numbers**: decimals, feed decimals (0–12, today's bound), modal output, line numbers, header comments, comment style.
- **Motion**: rapid, linear, arc CW, arc CCW codes; arc output (incremental IJ, absolute IJ, lines), arc tolerance, helical arcs.
- **Spindle**: on (`M3 S{S}`), off, dwell template and seconds, min and max RPM.
- **Program**: preamble, tool change, tool length offset (and whether it is used), footer, pause lines (empty = the default
  pause). Multi-line templates are text areas, one line per G-code line.
- **Limits and speeds**: X, Y, Z travel, allowed spoilboard cut, rapid rate, max feed (the machine's values replace these when
  a machine is picked; the form says so).
- A **placeholder list** beside the templates: `{T}`, `{TOOL_NAME}`, `{S}`, `{SECONDS}`, `{SAFE_Z}`, `{HOME_X}`, `{HOME_Y}`,
  `{HOME_Z}`, `{JOB_NAME}`, `{POST_NAME}`, `{POST_VERSION}`; in pause lines also `{MESSAGE}` and `{STOP}`.

Buttons: Save (disabled while there is a blocking problem), Revert (discard the draft), Delete (custom posts only).

## Checks (blocking)

`PostDraftCheck.problems(_ draft: PostProfile) -> [String]`, shown under the form; any problem disables Save:

- Name empty; file extension empty or with a character other than letters and digits; decimals or feed decimals outside 0–12;
  min RPM above max RPM; any travel, rapid rate or max feed not positive; arc tolerance not positive when arcs are linearised.
- Rapid, linear, spindle-on or spindle-off empty.
- An unknown placeholder in any template (`{X}` would be written as text and break the program), or `{MESSAGE}`/`{STOP}`
  outside the pause lines.
- A template line with a control character.
- **The sample program**: the draft posts the sample job (below) without throwing, and `GCodeValidator` reports **no error** on
  it. Warnings are shown, not blocking.

## The preview

`PostPreview.render(_ draft: PostProfile) -> PostPreview.Result` (text or a thrown error's message, and the validator's
issues), run on every edit, debounced. The **sample job** is fixed and covers the output paths: an inch document, material-top
zero, two tools, a profile with an arc, a pause after it, Mist coolant on the second tool. It is posted with the draft as is (no
machine applied), so the preview shows what the post itself writes. The pane shows the program in a monospaced, read-only text
view and the issues above it.

## Posts that did not load

`PostProfileStore.load() -> (profiles: [PostProfile], skipped: [SkippedPost])`, `SkippedPost { fileName, reason }`, the reason
from `SnapshotError` (newer LoftLine, malformed with its path) or the decode error. `PostProfileCatalog` publishes `skipped`; the
Posts tab lists them under "Did not load". Machines do the same (`MachineStore.load()`, listed in the Machines tab).

## Tests

1. Store: a malformed file and a newer-schema file are skipped with their reasons; a good file loads; `delete(id:)` moves the
   file to the Trash (a test directory; the file is gone from the folder and present in the trash URL returned); `newID(from:)`
   never clashes.
2. Controller: a post with `controller` round-trips; a post without it encodes no key (every built-in's bytes unchanged); a
   custom post declaring `.mach4` probes on a Mach4 machine, one declaring nothing is refused, one declaring `.grbl` is refused on
   a `.mach4` probe; the built-in by-value rule is unchanged.
3. Checks: one test per blocking rule, including an unknown placeholder, `{MESSAGE}` in the tool change, a control character,
   and a draft whose sample program has a validator error (for example a rapid code `G1`).
4. Preview: every built-in post previews with no error and no warning; the preview of a duplicate equals the original's.
5. UI: a harness scenario or an offscreen render of the Posts tab with a custom post selected (the editor and the preview).
6. Goldens, samples and `scripts/check-samples.sh` unchanged; the full suite green.

## Risks

- A custom post is machine output the owner wrote. The editor blocks a post that cannot post the sample job cleanly, but the
  sample cannot exercise everything (other arc planes, drilling cycles). The export still validates every real program.
- A declared controller that is wrong lets probing write a sequence the controller misreads. The air-probe check (TESTING.md)
  applies to custom posts too.

## Docs

`docs/DECISIONS.md` (`post-editor`), `docs/PARITY.md` (post editor row), `TESTING.md` (editing a post), Help (Machines and
Post Processors).

## Order of work

1. Store and catalog: `load()`, skipped files, Trash delete, `newID`. 2. `PostProfile.controller` and the probe rule.
3. `PostDraftCheck` and `PostPreview`. 4. The Posts tab. 5. Docs.
