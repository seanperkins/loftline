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
5. **Tools follow the same rule** (added after the review panel found that a library tool overrides the file's copy today; the
   owner chose to fold it into this part). Section 9.

## Goals

- A project uses **the same post, machine and tools on any Mac**, whether or not they are installed there.
- Today's G-code does not change by one byte: `samples/expected/`, `samples/*.tap` and every golden stay as they are.
- A post that uses a feature this LoftLine does not understand is **refused, never silently misread**.
- Opening an old project and choosing posts and machines behave exactly as they do today: attaching a copy never changes which
  post or machine a project resolves to.

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

`LoftLineProject` gains three optional fields, written only when present:

```json
"postProfileID": "avid-pro6096-mach4-inch",
"postSnapshot": { "schemaVersion": 1, "id": "avid-pro6096-mach4-inch", "name": "...", "...": "every PostProfile field" },
"machineID": "avid-pro6096",
"machineSnapshot": { "schemaVersion": 1, "id": "avid-pro6096", "...": "every MachineDefinition field" },
"machineInferredFor": "avid-pro6096-mach4-inch"
```

`machineInferredFor` is present only when `machineID` is nil and a machine copy exists. It records the effective post id the
copy was inferred for (a project with no chosen machine gets the first installed machine that supports its post, so the copy is
only right for that post).

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
- **Machine:** the project's `machineSnapshot` while it is still the machine the project selects. When `machineID` is set, its
  `id` equals `machineID`. When `machineID` is nil, `machineInferredFor` equals the effective post id. Support alone is not
  enough: `MachineResolver.machine(for:)` takes the *first* installed machine that supports the post, so after a post change the
  machine has to be inferred again even when the old copy's machine also supports the new post; the marker makes that decidable
  from the file, with no state outside it, and a post id changed by anything other than the sync invalidates the copy at once.
  Otherwise today's `MachineResolver.machine(for:)`.
- The machine's limits are then applied to the post, as `MachineResolver.effectiveProfile` does today. `GCodeValidator`, the
  post writer and the goldens are untouched.
- The result also says where it came from (`projectCopy`, `installed`, `fallback(missingID:)`) and whether the copy differs
  from the installed post or machine of the same id (`Hashable ==`), with both versions for the message.

### 5. Keeping the copies in step (three choke points)

1. **`LoftLineDocument.init(project:toolLibrary:)`** calls `ProjectPost.attaching(...)`: a project missing a copy gets one of
   **what its selection names**. Post: the installed post with the effective post id. Machine: when `machineID` is set and
   names an installed machine, that machine; when `machineID` is nil, the machine `MachineResolver` infers today, with `machineInferredFor` set to the effective post id; when
   `machineID` names a machine that is not installed, **no copy** (today's fallback machine would not be what the project
   selected, and the resolver would ignore a copy of it). `postProfileID` and `machineID` are never changed by attaching. A
   project whose post is not installed and that has no copy keeps today's error. This is in memory only and does not mark the
   document edited.
2. **`LoftLineDocument.perform(_:_:)`** runs `ProjectPost.syncing(...)` after every edit, and keeps each copy only while it is
   still what the selection means (the rules in section 4): a post copy whose id no longer equals the effective post id, or a
   machine copy that no longer matches `machineID`, is replaced by what the installed catalogs resolve to now, or dropped when
   nothing is installed. A machine copy with a nil `machineID` is replaced, by the machine `MachineResolver` infers
   for the new post (the first installed one that supports it, exactly as today), as soon as `machineInferredFor` no longer
   equals the effective post id. So picking a post, picking a machine (which can
   switch the post), converting units, applying a template and `AppPreferences.newProject` all end up with the right copy
   without each knowing about it, and an old project with no `machineID` that switches from the Avid post to GRBL gets the GRBL
   machine's limits, as it does today. A copy that still matches is **left alone**: this is what "the file's copy wins" means.
3. **Update This Project** is `perform("Update Post") { ... }`, and undoable. Each copy is replaced with the installed
   definition that has **the copy's own id**, when one is installed; a copy with no installed counterpart is kept. So a project
   whose post differs but whose machine is not installed gets the new post and keeps its machine copy. The warning and the
   button only appear for a copy that has an installed counterpart to differ from. The same step replaces the carried tools that
   differ from their library counterpart (section 9).

### 6. What the user sees

- `postProfileIssues` becomes: **error** when there is no copy and the selected post is not installed (unchanged text);
  **warning** when the copy differs from the installed post or machine. A post's notice names both versions ("This project
  posts with its own copy of «name» v1.0, which differs from the installed v1.1. Job Setup > Update This Project uses the
  installed one."); equal version strings (a post edited without bumping `version`) drop the versions and say "differs from the
  installed one". A machine has no version, so its notice names the machine and the bed size of each ("copy 60 × 96 in, installed
  48 × 96 in"). Nothing otherwise. The warning reaches the export sheet and Save All through the existing `ExportGCodeSheet` /
  `SaveAllToolpathsSheet` merge, and **tiled export** too: `TilingSheet` / `TiledExport.files` do not merge
  `document.postProfileIssues` today (so even the missing-post error is absent there), and this part adds it.
- Job Setup's post and machine area says "Using this project's copy of «name» v1.0" and, when it differs, shows the warning and
  an **Update This Project** button (the button is also shown when only a carried tool differs, section 9). A copy of a post or machine that is not installed on this Mac says "(not installed here)",
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

### 9. Tools follow the same rule

**What happens today.** `LoftLineProject.mergedTools(with:)` lets a library tool win over the project's tool of the same id (`for t
in tools where lib.tool(id: t.id) == nil`), and `ToolpathCalculator`, templates and gadgets use that merge. Every time a document
is snapshotted for save (`LoftLineDocument.swift:255`) or saved as a template (`LoftLineDocument+IO.swift:32`),
`refreshToolSnapshot(from:)` overwrites the file's tools from that merge. A new operation's tool is not added to
`project.tools` until that save. `TemplateService.apply` skips a template's tool when the merge already knows the id. Some readers
skip the merge altogether: `OperationEditor` and `OperationWarnings` read the plain library, and
`LoftLineDocument.store` renames every calculated toolpath's tool from it (`r.renamingTools(from: toolLibrary.library)`, line
802; `showToolNames` does the same for stored results), and built-in posts write that name into the tool-change comment.
`replaceProject` bumps `designRevision`, which marks cached toolpaths stale, only when the *document* changed, and
`updateOperationLive` assigns `project` without going through `perform`. So the same file cuts and posts differently on two Macs whose library tool differs, a save on the second Mac
silently rewrites the file's tool, and the app disagrees with `loftline-cli`, which posts from the file's tools over the seeded
defaults (`LoftLineCLI.swift:258`).

**Design.**

- **The file's tool wins, everywhere.** `mergedTools(with:)` is flipped: the project's tools win on an id clash and the library
  supplies only what the project does not carry. Every reader of a tool for a project goes through it (`mergedLibrary` in the
  document): the calculator, templates, gadgets, and the three that skip it today (`OperationEditor`, `OperationWarnings`,
  `store`/`showToolNames` renaming). Calculated and stored toolpaths keep the project copy's name. The CLI is unchanged and now agrees with the app.
- **The project carries every tool its operations reference, all the time.** `ToolSync.carrying(...)` runs after every `perform`,
  after `updateOperationLive` (the other path that assigns `project`), and at `init`: it adds a referenced tool the project does not carry (from the library) and
  drops one no operation references. The snapshot is therefore live, not rebuilt at save. `refreshToolSnapshot(from:)` stops
  overwriting and does only this carrying step, for the paths that have no document.
- **Cached toolpaths follow the effective tools.** Any change to `project.tools`, by `perform`, `updateOperationLive`, the sync,
  Update This Project, or undo and redo, bumps `designRevision` the way a document change does, so a toolpath calculated with a
  tool that is no longer the project's is stale and is recalculated before export. (The existing library revision, which marks
  every project stale on any library change, is left as it is.)
- **Applying a template carries the template's tool**, even when the library has the same id: a template is a project, and its
  copy wins like any other. (If the library's tool differs, the warning below says so.) When the target project already carries a
  *different* tool under that id, the target's tool is not replaced, which would change its existing operations: the template's
  tool is added under a fresh id and the applied operations are remapped to it. An identical tool is reused. The fresh copy keeps
  its tool `number`, and this part does not renumber: two different cutters that share a `T` word are already caught.
  `PreflightChecks.duplicateToolNumbers` warns before export when their geometry differs, and `GCodeValidator.validate(toolpaths:)`
  makes it an **error** when the geometry differs and a warning when it is the same. An error asks for confirmation in the
  export sheets ("Save Anyway") and fails the CLI unless forced (`--force`); it is not a hard block. The two checks compare
  geometry by different rules today (`PreflightChecks` converts diameters to inches with a tolerance, `GCodeValidator` compares
  raw values); this part does not change either.
- **A Tool Database edit still reaches open projects**, by an explicit step instead of by the library winning. The document
  keeps the library as it last saw it. When `toolLibrary.$library` changes, `ToolSync.applyingLibraryChange(old:new:to:)` replaces
  a carried tool by its new library entry **only when the carried copy equals the old library entry** (on the compared fields
  below), keeping the carried tool's own `notes` and `group`: a copy that was in step follows the edit, and a copy that had already diverged is left alone and keeps its warning, so a
  rename of a library tool cannot swap a diameter. The replacement is one **undoable** step ("Update Tool from Library") that marks
  the document unsaved. Undoing it restores the file's older copy and the warning shows; undoing an earlier edit restores that
  edit's project as before, and the library is never rolled back. A tool edited in the Tool Database therefore still changes every
  open project that uses it and was in step, as today.
- **Compared fields.** Two tools are "the same" when everything but `notes` and `group` is equal. `name` counts: it is written
  into tool-change comments, so a rename changes the G-code text.
- **Notice and button.** On open and after any library change, a carried tool that differs from the library's tool of the same id is
  a **warning**: "Tool «name» in this project differs from the library's (diameter 0.25 in, library 0.375 in). Job Setup > Update
  This Project uses the library's." It joins the post and machine notices in one issue channel, so it reaches the export sheet and
  Save All. A tool-only difference shows the warning **and** the Update This Project button in Job Setup. A carried tool with no
  library counterpart shows nothing.
- **Update This Project covers tools:** each carried tool that has a library counterpart is replaced by it; the rest are kept. It
  is the same single undoable step as for the post and machine.
- **Samples and goldens:** every sample's tools equal the seeded library, so no sample's G-code moves.

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
   ignored; a nil `machineID` with a machine copy keeps the copy while `machineInferredFor` equals the effective post, and takes the
   machine `MachineResolver` infers for the new post as soon as it does not, even when the old copy's machine also supports it
   (two installed machines that both support the new post), including when only `postProfileID` is edited by hand; a `machineID` that
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
9. Tools:
   - Precedence: a library tool that differs from the file's copy does not change the toolpaths (the G-code is the file's tool's,
     byte for byte), the app's G-code equals `loftline-cli`'s for that project, also when the library tool has a different name
     (tool-change comment), and `OperationWarnings` and the operation editor describe the tool that cuts.
   - Carrying: a tool added to an operation is carried at once, also through `updateOperationLive` (save, then edit the library,
     then calculate, with no reopen);
     saving on a Mac with a differing library tool leaves the file's tool unchanged and drops an unreferenced tool; applying a
     template carries the template's tool when the library has the same id with different content; a template whose tool id is
     already carried with different content gets a fresh id and remapped operations, and the target's existing operations keep
     their tool.
   - Tiled export: its files carry the same copy-difference warnings as the other exports and use only fresh results.
   - Staleness: Update This Project, a ToolSync step and their undo and redo make previously calculated toolpaths stale (no
     export with the old cutter), including a result that lands from a calculation started before the change, which `calculateUntilFresh` recalculates before the
     sheets post (test: change a carried tool while `calculateAndWait` runs; the posted program uses the new tool); an edit of a tool
     the project does not use does not change what is exported; a template tool that shares a `T` number with a different
     carried tool raises the preflight warning.
   - Live edits: a Tool Database edit changes the open project's carried tool and its toolpaths, marks it unsaved and undoes as
     one step; an edit of a different tool changes nothing; a label-only edit (name) of a library tool whose diameter differs
     from the carried copy leaves the carried diameter alone; a sync that follows a library rename keeps the carried `notes` and `group`; undoing an
     earlier edit afterwards does not roll the library back.
   - Notice: the warning appears exactly when a carried tool differs (not for `notes` or `group`; for `name` it does), names the
     tool and what differs, reaches the export validator, and a tool-only difference also shows the Update This Project button;
     Update This Project replaces the tools that have a library counterpart, keeps the others, and undoes together with the
     post and machine.
10. Acceptance: `scripts/check-samples.sh` passes with no `--update`; `samples/sign.loftline` still posts byte for byte to
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
  ignores a copy that no longer matches the selection (the ids, and `machineInferredFor` for a project with no chosen machine),
  so a stale copy can never post.
- **A library tool edit no longer wins by itself.** It reaches an open project through `ToolSync` (section 9). A tool edited
  while a project is closed shows as a warning when the project opens, and the file's tool posts until Update This Project. That
  is the intended change; the live path keeps the common workflow (edit a tool, see the toolpaths change) as it is today.
- **A copy that had already diverged does not follow a library edit.** That is deliberate (it keeps a label-only edit from
  swapping a diameter), and the warning stays until Update This Project. The cost is one extra click in that case.
- **`ToolSync` runs on every library change**, including a reload of the library from disk, which counts as a change of every
  tool whose content differs. That matches today, where the library wins live. Undo of the sync restores the file's older copy,
  and the warning then shows.
- **A change while a calculation runs must not post.** Today `ExportGCodeSheet.run`, `SaveAllToolpathsSheet.run` and `TilingSheet.run` call
  `calculateAndWait` and then `post()` with no second look (`ValidationSheet` does the same before it validates): a result computed before an edit is stored (stale, carrying the old
  `designRevision`) and still posted. That race exists for any edit; live tool changes (section 9) make it easier to hit, and
  this is machine output, so this part closes it. A new `LoftLineDocument.calculateUntilFresh(targets:) async -> Bool` repeats
  `calculateAndWait` on whatever is still stale among **all** the target operations, re-evaluated before every pass because a
  change can make operations stale that were fresh when the export began (bounded at five passes), and returns true only when
  nothing in the target is stale; every sheet that calculates then posts or validates calls it (`ExportGCodeSheet`, `SaveAllToolpathsSheet`, `TilingSheet`,
  `ValidationSheet`) and acts only on true, otherwise they say "The project changed while it was being calculated. Export
  again."
- **Section 9 widens this part from storage to behaviour of the tool library.** It was folded in on the owner's decision after
  the review panel found the gap; it is the part most likely to need a second look in the plan.
- **File size** grows by about 3 KB.

## Docs to update

`docs/DECISIONS.md` (`project-carries-post`, `snapshot-schema`, `tool-copy-wins`), `docs/PARITY.md` (a row for self-contained projects),
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

Tools: with a project open, change its cutter's diameter in the Tool Database; the toolpaths change at once and the project is
marked unsaved. Close it without saving, change the same tool again with the project closed, reopen it: the warning names the
tool, the exported G-code still uses the file's diameter, and Update This Project switches it to the library's and Undo back.

## Order of work and acceptance

1. `JSONValue` and the schema versions with the snapshot conversions. 2. Format 2, the project fields and the migration.
3. `ProjectPost`: resolver, validate, attach and sync. 4. `LoftLineProject.opening(from:)` at every caller, then document wiring
(init, `perform`, issues, Update This Project) and the CLI. 5. Job Setup notice, button, and `JobSetupForm` through the resolver.
6. Tools (section 9): the flipped merge, the non-overwriting snapshot refresh, `ToolSync`, the notice and Update This Project.
7. Regenerate samples and harness projects, prove the goldens are unchanged. 8. Docs and the manual check. Acceptance is test 10
plus the manual check.
