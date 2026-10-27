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

- A project uses **the same post and machine on any Mac**, whether or not they are installed there.
- Today's G-code does not change by one byte: `samples/expected/`, `samples/*.tap` and every golden stay as they are.
- A post that uses a feature this LoftLine does not understand is **refused, never silently misread**.
- Opening an old project and choosing posts and machines behave exactly as they do today: attaching a copy never changes which
  post or machine a project resolves to.

Out of scope: editing a post, saving a project's copy back to the posts folder, telling the user about a user post file with a
newer schema, and any new post feature. Those belong to parts 2 to 4.

**Also out of scope, and a known gap in "same G-code on any Mac": tools.** `LoftLineProject.mergedTools(with:)` lets a tool in the
local library win over the project's snapshot of the same id (`for t in tools where lib.tool(id: t.id) == nil`), and
`ToolpathCalculator` uses that merge. A tool edited on one Mac therefore cuts differently there. That precedence is deliberate
today (editing a library tool updates the projects that use it), so changing it is a product decision, not a storage detail. It
is filed as a separate follow-up; this part's promise covers the post and the machine only.

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
- **A key that is present but `null` is a malformed copy, not an absent one.** Synthesized `Codable` reads `"postSnapshot": null`
  as nil, and `LoftLineProject` has no hand-written decoder to change. So `LoftLineProject.opening(from:)` (section 3) also
  reads the file's top-level object as `[String: JSONValue]` and refuses a `postSnapshot` or `machineSnapshot` key whose value
  is `.null` as `malformed`. An absent key stays nil (version 1 files). Encoding omits a nil copy, as the default does.
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
- **User files get the same check.** `PostProfile.fromJSON` and the machine equivalent (the load path of `PostProfileStore` and
  `MachineStore`) share the checked decode behind `init(snapshot:)`, so a user post or machine file whose `schemaVersion` is
  higher than the app's throws `newerSchema`, and the stores' existing `try?` skips it like an unreadable file. Today
  `fromJSON` only decodes, which would load such a file and drop the fields it does not know. Telling the user is part 3.

### 3. File format 2 and upgrading

- `LoftLineProject.currentFormatVersion` and `LoftLineFile.currentVersion` go to 2 (they are kept in step). A migration `1 -> 2`
  is registered and changes nothing in the JSON: the copies are attached by the app after decoding, because only the app knows
  the installed posts. `DocumentFile` (design-only files) also writes version 2 and reads version 1.
- An older LoftLine opening version 2 already refuses it (`LoftLineFile.migrate`: "newer than this app supports").
- **Nothing is rewritten without a save.** Opening a version 1 file and closing it leaves the file untouched.
- **The refusal happens before a document exists.** `LoftLineDocument.init(project:toolLibrary:)` cannot throw and
  `LoftLineProject.decode` (CAMCore) cannot read a snapshot, so the check is a separate step: `LoftLineProject.opening(from:)`
  (LoftLineApp) is `decode` plus `ProjectPost.validate`, which tries `PostProfile(snapshot:)` and `MachineDefinition(snapshot:)`
  on whichever copies exist and throws `SnapshotError`. Every place that turns a file into a project that can be edited or posted
  calls it instead of `decode`: `LoftLineDocument.init(configuration:)`, `LoftLineCLI`, `RecoveryStore`, `JobTemplateStore` and
  the two `UIHarness` loads. `ClipartLibrary` reads only the drawing and keeps `decode`. `init(project:toolLibrary:)` treats a
  copy it cannot read as absent; only code that skipped `opening` can reach that, and the tests cover each caller.

### 4. Which post and machine post (resolution)

One pure resolver, `ProjectPost` (LoftLineApp), used by the document and by the CLI, replaces the two hand-kept copies:

- The **effective post id** is `postProfileID ?? PostProfileStore.defaultID(for: units)`, exactly what `postProfile` uses today.
  A nil id is never written into the file: a nil id keeps meaning "the default for the units", so converting an old project
  from inch to mm still moves it to the mm default, as it does now.
- **Post:** the project's `postSnapshot` while its `id` equals the effective post id; otherwise the installed post with that id;
  otherwise today's fallback (the default post) together with the existing error issue.
- **Machine:** the project's `machineSnapshot` while it is still the machine the project selects: its `id` equals `machineID`
  when `machineID` is set, or, when `machineID` is nil, while it `supports(postID:)` the effective post id (the same test that
  `MachineResolver.machine(for:)` uses to infer a machine). Otherwise today's `MachineResolver.machine(for:)`.
- The machine's limits are then applied to the post, as `MachineResolver.effectiveProfile` does today. `GCodeValidator`, the
  post writer and the goldens are untouched.
- The result also says where it came from (`projectCopy`, `installed`, `fallback(missingID:)`) and whether the copy differs
  from the installed post or machine of the same id (`Hashable ==`), with both versions for the message.

### 5. Keeping the copies in step (three choke points)

1. **`LoftLineDocument.init(project:toolLibrary:)`** calls `ProjectPost.attaching(...)`: a project missing a copy gets one of
   **what its selection names**. Post: the installed post with the effective post id. Machine: when `machineID` is set and
   names an installed machine, that machine; when `machineID` is nil, the machine `MachineResolver` infers today; when
   `machineID` names a machine that is not installed, **no copy** (today's fallback machine would not be what the project
   selected, and the resolver would ignore a copy of it). `postProfileID` and `machineID` are never changed by attaching. A
   project whose post is not installed and that has no copy keeps today's error. This is in memory only and does not mark the
   document edited.
2. **`LoftLineDocument.perform(_:_:)`** runs `ProjectPost.syncing(...)` after every edit, and keeps each copy only while it is
   still what the selection means (the rules in section 4): a post copy whose id no longer equals the effective post id, or a
   machine copy that no longer matches `machineID` (or no longer supports the post when `machineID` is nil), is replaced by what
   the installed catalogs resolve to now, or dropped when nothing is installed. So picking a post, picking a machine (which can
   switch the post), converting units, applying a template and `AppPreferences.newProject` all end up with the right copy
   without each knowing about it, and an old project with no `machineID` that switches from the Avid post to GRBL gets the GRBL
   machine's limits, as it does today. A copy that still matches is **left alone**: this is what "the file's copy wins" means.
3. **Update This Project** is `perform("Update Post") { ... }`, and undoable. Each copy is replaced with the installed
   definition that has **the copy's own id**, when one is installed; a copy with no installed counterpart is kept. So a project
   whose post differs but whose machine is not installed gets the new post and keeps its machine copy. The warning and the
   button only appear for a copy that has an installed counterpart to differ from.

### 6. What the user sees

- `postProfileIssues` becomes: **error** when there is no copy and the selected post is not installed (unchanged text);
  **warning** when the copy differs from the installed post or machine. A post's notice names both versions ("This project
  posts with its own copy of «name» v1.0, which differs from the installed v1.1. Job Setup > Update This Project uses the
  installed one."); equal version strings (a post edited without bumping `version`) drop the versions and say "differs from the
  installed one". A machine has no version, so its notice names the machine and the bed size of each ("copy 60 × 96 in, installed
  48 × 96 in"). Nothing otherwise. The warning reaches the export sheet and Save All through the existing `ExportGCodeSheet` /
  `SaveAllToolpathsSheet` merge.
- Job Setup's post and machine area says "Using this project's copy of «name» v1.0" and, when it differs, shows the warning and
  an **Update This Project** button. A copy of a post or machine that is not installed on this Mac says "(not installed here)",
  with no error, and the pickers list it so the selection still shows.
- **Job Setup resolves through `ProjectPost`, in the form and in the sheet.** Today `JobSetupForm.init(project:machines:)` asks
  `MachineResolver`, which swaps in a different installed machine when the named one is missing, and Apply writes that swap.
  The form instead starts on the project's own machine and keeps it as `form.machine` (the project's copy when it is valid,
  else the installed machine, else nil). `JobSetupSheet` uses `form.machine` for the bed-fit check
  (`MachineResolver.fitProblems`) and the compatible-post grouping, where it now reads `machines.machine(id: form.machineID)`
  and would lose both for an uninstalled machine. The machine picker lists a copy that is not installed as "«name» (not
  installed here)", and choosing it keeps the copy.
- **Apply keeps its current contract:** `apply(to:)` writes `machineID` and `postProfileID` only when the form holds one. A form
  built from a project always holds a post id (a nil id becomes the default for the units the form opened with, and a units
  change inside Job Setup keeps that post) and holds a machine id when one resolves; a form built from a document alone
  holds neither and leaves the project's ids alone. This part changes none of that. What changes is that the ids a project's
  form holds are the ones the project's copies already carry, so a material-size-only Apply resolves to the same post and
  machine as before, and the copies stay attached.
- Tool database warnings that read the project's post (`ToolDatabaseView`) go through the resolver, so they use the copy.

### 7. Command line

`loftline-cli export` posts with the project's copy. `--post <id>` still overrides the post (it must be installed; the project's
machine still applies): the machine is resolved first, from the project exactly as opened (its machine copy, or the machine
inferred from the project's own post when `machineID` is nil, as the CLI does today), and the override then replaces only the
post, with the **installed** post of that id, never the project's post copy, even when the ids are equal. The CLI does not
write `postProfileID` into the project, so the override cannot change which machine a project with no `machineID` infers.
Two more CLI behaviors stay as they are: an explicit `--post` suppresses the "project's post is not installed" error (the
override is what posts), and the rapid rate that times the toolpaths comes from the project's own resolved post (its copy, or the
installed post, or the fallback), never from the override. `--builtin-only` still means "do not read the user's posts and
machines folders"; the project's own copies are not a folder and stay in force. A version 2 file with a newer schema exits with the same refusal as the app.

### 8. Files the repository writes

`samples/*.loftline`, the harness projects and any fixture regenerated with `LOFTLINE_WRITE_SAMPLES=1` become version 2 with
their copies. Hand-built projects in tests stay copy-less on purpose (they are the "version 1" case). `samples/expected/` and the
goldens must not change, and that is the acceptance test.

## Tests

1. `JSONValue`: round trip of every built-in post and machine and of a hand-built extreme (1e300, 1e-300, a 3000-character
   string, nested arrays and objects, the empty array and string); decoding a post from a snapshot yields `==` to the original.
2. `schemaVersion`: absent decodes as 1; newer throws `newerSchema`; both types. A user post file and a user machine file with
   a newer schema are skipped by `PostProfileStore` / `MachineStore` and the built-in of that id shows instead.
3. Format: a version 1 fixture opens and posts identically; a project with copies encodes version 2 and round-trips; a version 3
   file is refused; the `1 -> 2` migration changes nothing but the number; `DocumentFile` reads 1 and writes 2.
4. Resolution: the copy posts when the installed post of the same id has changed (the G-code is the copy's, byte for byte);
   an uninstalled post with a copy posts without error; no copy and no installed post keeps the error and the fallback; the
   machine's limits come from the copy when the catalog lacks the machine; a copy whose id no longer matches the selection is
   ignored; a nil `machineID` with a machine copy keeps the copy only while it supports the effective post; a `machineID` that
   names an uninstalled machine and has no copy attaches nothing and resolves as today.
5. Choke points: opening a version 1 file attaches copies, leaves the ids as they were (nil stays nil) and leaves the document
   unedited; picking a post, picking a machine that switches the post, Job Setup apply, applying a template and `newProject` each
   leave a matching copy; an old project with a nil `machineID` that switches from the Avid post to GRBL ends with the GRBL
   machine's limits and copy, equal to what `MachineResolver` gives today; converting a nil-post project from inch to mm with
   `LoftLineProject.converted(to:)` through `perform` moves it to the mm default post and copy (Job Setup is different and
   unchanged: its form keeps the post it opened with); Update This Project replaces each copy with the installed definition of the
   same id and undoes, and when only one of the two has an installed counterpart it replaces that one and keeps the other;
   syncing leaves a matching copy alone;
   Job Setup apply with only a material-size change writes the same resolved post and machine ids as today and leaves both copies
   attached (checked for a nil-id project and for a project that carries an uninstalled machine's copy, which stays on that
   machine); the sheet's bed-fit warning and compatible-post grouping use the copy of an uninstalled machine, and its picker lists
   it as "not installed here".
6. Notices: the warning appears exactly when the copy differs (post, machine, either); a post's names both versions, or drops
   them when they are equal; a machine's names the bed size of each; it reaches the export validator; the error is unchanged
   for a version 1 file with a missing post; reloading the post catalog (`Reload Post Profiles`) makes the notice appear or
   disappear without reopening the project.
7. Refusals: a copy with a newer schema, a malformed copy and a copy that is present but `null` (each of the two keys) are
   refused with the message by every caller of
   `LoftLineProject.opening(from:)` (document open, the CLI, recovery, templates), and by none of them opened with the
   installed post instead.
8. CLI: posts from the copy; `--post` overrides, including with an id equal to the copy's id, where the installed post posts
   and the copy does not, and a project with no `machineID` overridden from Avid to GRBL still posts with the Avid machine's
   limits, as today; the rapid rate under `--post` still comes from the project's own post (the copy), and `--post` on a project
   whose post is not installed still prints no missing-post error; `--builtin-only` keeps the copy; refusal exit code.
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
- **A path that sets `postProfileID` or `machineID` directly** is repaired by the sync on the next edit; until then the resolver
  ignores a copy that no longer matches the selection, so a stale copy can never post.
- **Tools can still differ between Macs** (see Out of scope). Mitigation for now: none in this part. Whether a library tool that
  differs from the project's snapshot should warn, or the snapshot should win, is for the owner to decide separately.
- **File size** grows by about 3 KB.

## Docs to update

`docs/DECISIONS.md` (`project-carries-post`, `snapshot-schema`), `docs/PARITY.md` (a row for self-contained projects),
`TESTING.md` (the manual check below), Help (Job Setup and Machines topics), README ("Command line" note).

## Manual check (TESTING.md)

Open `samples/sign.loftline` (version 1 copy from before, then the regenerated one), open Job Setup: it says "Using this project's
copy". Built-in posts come from code, so create `~/Library/Application Support/LoftLine/posts/<the project's post id>.json` as a
copy of that post with one changed footer line (a user file with a built-in's id replaces the built-in), then choose
**Reload Post Profiles** (the catalog is read once per launch): the warning appears in Job Setup and the export sheet, the
exported G-code still has the old footer, Update This Project switches it, Undo switches it back. For "(not installed here)",
use a post with its own id, because deleting an override of a built-in's id just reveals the built-in again: copy a post file to
a new id, pick it in Job Setup, save the project, delete that file and Reload Post Profiles. The project still posts, and says
"(not installed here)".

## Order of work and acceptance

1. `JSONValue` and the schema versions with the snapshot conversions. 2. Format 2, the project fields and the migration.
3. `ProjectPost`: resolver, validate, attach and sync. 4. `LoftLineProject.opening(from:)` at every caller, then document wiring
(init, `perform`, issues, Update This Project) and the CLI. 5. Job Setup notice, button, and `JobSetupForm` through the resolver. 6. Regenerate samples and harness projects, prove the goldens are unchanged. 7. Docs and the manual
check. Acceptance is test 9 plus the manual check.
