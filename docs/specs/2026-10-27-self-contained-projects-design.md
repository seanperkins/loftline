# LoftLine: projects that carry their post and machine

Part 1 of the post-processor work. The five parts, in order: **(1) self-contained projects (this spec)**, (2) new post features
(coolant, custom tool change, probing), (3) an in-app post editor, (4) sharing a post as a file, (5) more built-in posts.
Each part gets its own spec, plan and build. Parts 2 to 5 are out of scope here.

## Decisions already taken (confirmed with the owner)

1. A `.loftline` file holds a **full copy of its post** and a **copy of its machine** (bed, travel, Z), written for every
   project, built-in posts included.
2. **The file's copy posts the G-code.** The installed post is used to compare, and when the user picks a post.
3. When the installed post differs from the file's copy, Job Setup and the export sheet say so, and Job Setup offers **Update
   This Project**. Nothing changes silently.
4. The file format goes to **version 2**. An older LoftLine refuses a version 2 file; this LoftLine opens every version 1 file.

## Goals

- A project posts **the same G-code on any Mac**, whether or not the post it was made with is installed there.
- Today's G-code does not change by one byte: `samples/expected/`, `samples/*.tap` and every golden stay as they are.
- A post that uses a feature this LoftLine does not understand is **refused, never silently misread**.

Out of scope: editing a post, saving a project's copy back to the posts folder, telling the user about a user post file with a
newer schema, and any new post feature. Those belong to parts 2 to 4.

## What exists (evidence)

- `LoftLineProject` (CAMCore) stores only `postProfileID: String?` and `machineID: String?`. Its tools are snapshotted
  ("so the file opens on any machine"); its post and machine are not.
- A project whose post is not installed gets an error issue (`LoftLineDocument.postProfileIssues`: "not installed; X is shown
  instead") and falls back to the default Avid post. The default can be another G-code dialect.
- `PostProfile` and `MachineDefinition` (PostCore) are `Codable`. Posts come from `BuiltInPosts` plus
  `~/Library/Application Support/LoftLine/posts/*.json`; machines likewise from `.../machines/`. A user file with a built-in's id
  replaces the built-in.
- **`CAMCore` cannot name `PostCore` types:** PostCore depends on CAMCore, so `LoftLineProject` cannot have a `PostProfile`
  field. The design below stores the copies as plain JSON and lets the app layer, which knows both, interpret them.
- `JSONDecoder` ignores keys it does not know, so a post that gains a field in a later LoftLine would silently lose it in this one
  and post different G-code. Nothing guards that today.
- The CLI (`LoftLineCLI`) repeats the document's post and machine resolution by hand ("as the document resolves them").
- Every edit of a project goes through `LoftLineDocument.perform(_:_:)`; every document starts at
  `LoftLineDocument.init(project:toolLibrary:)` (new, opened, template, recovered).

## Design

### 1. What the file holds

`LoftLineProject` gains two optional fields, written only when present:

```json
"postProfileID": "avid-pro6096-mach4-inch",
"postSnapshot": { "schemaVersion": 1, "id": "avid-pro6096-mach4-inch", "name": "...", "...": "every PostProfile field" },
"machineID": "avid-pro6096",
"machineSnapshot": { "schemaVersion": 1, "id": "avid-pro6096", "...": "every MachineDefinition field" }
```

- `JSONValue` (new, CADCore): `Codable, Hashable, Sendable` enum of null, bool, number (`Double`), string, array, object, with
  `init(encoding:)` and `decoded(_:)` that go through `JSONEncoder` and `JSONDecoder`. Round-trips every `PostProfile` and
  `MachineDefinition` exactly (a test pins this for the built-ins and a hand-built extreme). The copies are nested JSON, not
  base64, so the file stays readable and its diffs meaningful.
- `LoftLineProject.postSnapshot: JSONValue?` and `machineSnapshot: JSONValue?`. A project with neither behaves exactly as today
  (every existing test that builds a project by hand keeps passing).
- Roughly 2 KB for the post and 1 KB for the machine.

### 2. Schema versions (the safety rule)

- `PostProfile.schemaVersion: Int` and `MachineDefinition.schemaVersion: Int`, both `1` in this release, decoded with a default
  of 1 when the key is absent (so every existing user JSON loads), always written. `currentSchemaVersion = 1` on both.
- New in PostCore: `PostProfile(snapshot: JSONValue) throws` and `profile.snapshot() throws -> JSONValue`, the same for
  `MachineDefinition`. Reading a copy whose `schemaVersion` is **higher than the app's** throws
  `SnapshotError.newerSchema(found:supported:)`; an undecodable copy throws `SnapshotError.malformed(String)`.
- **A file with either error is refused at open** ("This project was made with a newer LoftLine. Update LoftLine to open it."),
  by the document and by the CLI. It is never opened with the installed post instead. A later part that adds post fields bumps
  `schemaVersion`, and this release is what makes that safe.
- A user post file with a newer schema is skipped like an unreadable one today. Telling the user is part 3.

### 3. File format 2 and upgrading

- `LoftLineProject.currentFormatVersion` and `LoftLineFile.currentVersion` go to 2 (they are kept in step). A migration `1 -> 2`
  is registered and changes nothing in the JSON: the copies are attached by the app after decoding, because only the app knows
  the installed posts. `DocumentFile` (design-only files) also writes version 2 and reads version 1.
- An older LoftLine opening version 2 already refuses it (`LoftLineFile.migrate`: "newer than this app supports").
- **Nothing is rewritten without a save.** Opening a version 1 file and closing it leaves the file untouched.

### 4. Which post and machine post (resolution)

One pure resolver, `ProjectPost` (LoftLineApp), used by the document and by the CLI, replaces the two hand-kept copies:

- **Post:** the project's `postSnapshot` while its `id` equals `postProfileID`; otherwise the installed post with that id (or the
  default for the document's units when `postProfileID` is nil, as today); otherwise today's fallback (the default post) together
  with the existing error issue.
- **Machine:** the project's `machineSnapshot` while its `id` equals `machineID`; otherwise today's `MachineResolver.machine(for:)`.
- The machine's limits are then applied to the post, as `MachineResolver.effectiveProfile` does today. `GCodeValidator`, the
  post writer and the goldens are untouched.
- The result also says where it came from (`projectCopy`, `installed`, `fallback(missingID:)`) and whether the copy differs
  from the installed post or machine of the same id (`Hashable ==`), with both versions for the message.

### 5. Keeping the copies in step (three choke points)

1. **`LoftLineDocument.init(project:toolLibrary:)`** calls `ProjectPost.attaching(...)`: a project without a copy gets one from
   the installed post (and the machine it resolves to). `postProfileID` and `machineID` are set to the ids of what was copied
   when they are nil, so the project is explicit: a nil id means "the default for the units", and a copy must never stay
   attached to an id that can later change meaning. A project whose post is not installed and that has no copy keeps today's
   error. This is in memory only and does not mark the document edited.
2. **`LoftLineDocument.perform(_:_:)`** runs `ProjectPost.syncing(...)` after every edit: if the selected post's id no longer
   equals the copy's id, the copy is replaced by the installed post with the new id (same for the machine). So picking a post
   in Job Setup, picking a machine (which can switch the post), applying a template and `AppPreferences.newProject` all end up
   with the right copy without each knowing about it. A copy whose id still matches is **left alone**: this is what "the file's
   copy wins" means.
3. **Update This Project** is `perform("Update Post") { replace both copies from the installed ones }`. It is undoable.

### 6. What the user sees

- `postProfileIssues` becomes: **error** when there is no copy and the selected post is not installed (unchanged text);
  **warning** when the copy differs from the installed post or machine ("This project posts with its own copy of «name» v1.0,
  which differs from the installed v1.1. Job Setup > Update This Project uses the installed one."); nothing otherwise. The
  warning reaches the export sheet and Save All through the existing `ExportGCodeSheet` / `SaveAllToolpathsSheet` merge.
- Job Setup's post and machine area says "Using this project's copy of «name» v1.0" and, when it differs, shows the warning and
  an **Update This Project** button. A copy of a post that is not installed on this Mac says "(not installed here)", with no
  error.
- Tool database warnings that read the project's post (`ToolDatabaseView`) go through the resolver, so they use the copy.

### 7. Command line

`loftline-cli export` posts with the project's copy. `--post <id>` still overrides the post (it must be installed; the project's
machine still applies) and `--builtin-only` still means "do not read the user's posts and machines folders"; the project's own
copies are not a folder and stay in force. A version 2 file with a newer schema exits with the same refusal as the app.

### 8. Files the repository writes

`samples/*.loftline`, the harness projects and any fixture regenerated with `LOFTLINE_WRITE_SAMPLES=1` become version 2 with
their copies. Hand-built projects in tests stay copy-less on purpose (they are the "version 1" case). `samples/expected/` and the
goldens must not change, and that is the acceptance test.

## Tests

1. `JSONValue`: round trip of every built-in post and machine and of a hand-built extreme (1e300, 1e-300, a 3000-character
   string, nested arrays and objects, the empty array and string); decoding a post from a snapshot yields `==` to the original.
2. `schemaVersion`: absent decodes as 1; newer throws `newerSchema`; both types.
3. Format: a version 1 fixture opens and posts identically; a project with copies encodes version 2 and round-trips; a version 3
   file is refused; the `1 -> 2` migration changes nothing but the number; `DocumentFile` reads 1 and writes 2.
4. Resolution: the copy posts when the installed post of the same id has changed (the G-code is the copy's, byte for byte);
   an uninstalled post with a copy posts without error; no copy and no installed post keeps the error and the fallback; the
   machine's limits come from the copy when the catalog lacks the machine; a copy whose id no longer matches the selection is
   ignored.
5. Choke points: opening a version 1 file attaches copies and leaves the document unedited; picking a post, picking a machine
   that switches the post, Job Setup apply, applying a template and `newProject` each leave a matching copy; Update This
   Project replaces both and undoes; syncing leaves a matching copy alone.
6. Notices: the warning appears exactly when the copy differs (post, machine, either), names both versions, and reaches the
   export validator; the error is unchanged for a version 1 file with a missing post.
7. Refusals: a copy with a newer schema and a malformed copy are refused by the document open and by the CLI, with the message.
8. CLI: posts from the copy; `--post` overrides; `--builtin-only` keeps the copy; refusal exit code.
9. Acceptance: `scripts/check-samples.sh` passes with no `--update`; `samples/sign.loftline` still posts byte for byte to
   `samples/sign.tap`; the full suite is green.

## Alternatives considered

| Option | Why not |
|---|---|
| Name, version and checksum only | Cannot reproduce the G-code when the post is missing; the owner chose a full copy. |
| A copy the project may edit | More power and a bigger surface in safety-critical output; revisit in part 3 with the editor. |
| A sidecar file beside the project | Two files to keep together; breaks "a project is one file", Quick Look and the update path. |
| Move `LoftLineProject` into PostCore, or `PostProfile` into CAMCore | A module-graph change touching every target for a storage detail. `JSONValue` keeps the graph. |
| Store the copy as base64 `Data` | Unreadable, and its diffs mean nothing. |
| Installed post wins, with a warning | The same file would post different G-code on two Macs; the owner chose the file's copy. |

## Risks and consequences

- **A built-in post fixed in a later LoftLine does not reach old projects** until Update This Project. Intended: reproducibility
  is the point. The warning makes the difference visible, and the button is one click.
- **An older LoftLine cannot open a version 2 file.** Intended: opening it with the wrong post is the failure this part exists
  to remove. Only the owner's own installs are affected today.
- **`JSONValue` number exactness.** `Int` fields travel as `Double` and back; every field is far below 2^53, and the round-trip
  test pins it.
- **A path that sets `postProfileID` directly** would be repaired by the sync on the next edit and by the encode-time check; the
  resolver also ignores a copy whose id does not match, so a stale copy can never post.
- **File size** grows by about 3 KB.

## Docs to update

`docs/DECISIONS.md` (`project-carries-post`, `snapshot-schema`), `docs/PARITY.md` (a row for self-contained projects),
`TESTING.md` (the manual check below), Help (Job Setup and Machines topics), README ("Command line" note).

## Manual check (TESTING.md)

Open `samples/sign.loftline` (version 1 copy from before, then the regenerated one), open Job Setup: it says "Using this project's
copy". Edit the installed post in `~/Library/Application Support/LoftLine/posts/` (same id, one changed footer line): the warning
appears in Job Setup and the export sheet, the exported G-code still has the old footer, Update This Project switches it, Undo
switches it back. Delete the installed post: the project still posts, and says "(not installed here)".

## Order of work and acceptance

1. `JSONValue` and the schema versions with the snapshot conversions. 2. Format 2, the project fields and the migration.
3. `ProjectPost`: resolver, attach and sync. 4. Document wiring (init, `perform`, issues, Update This Project) and the CLI.
5. Job Setup notice and button. 6. Regenerate samples and harness projects, prove the goldens are unchanged. 7. Docs and the manual
check. Acceptance is test 9 plus the manual check.
