# LoftLine: share a post as a file

Part 4 of the post-processor work. Parts 1–3 (projects carry their post; coolant and park-and-probe; the post editor) are on
main at `1a7812a`. Part 5 (more built-in posts) is out of scope.

Revision 3, after two review rounds (Executor, Auditor, Claude Skeptic, Claude Simplifier).

## Why

A shop that has a working post wants to give it to someone else (another Mac, a friend with the same machine, a forum). Today the
only ways are to dig the JSON out of `Application Support/LoftLine/posts` or to send a whole project that carries it, and the
receiver of a project can post with its copy but cannot add that post to their own list.

## Goals

- **Export** a saved custom post from Toolpaths ▸ Post Processors as one file (a built-in is on every Mac already; Duplicate it
  first to share a changed copy).
- **Import** a post file, and **add the post the open project carries** when this Mac does not have it.
- An imported post never overwrites a post already here, never skips the editor's checks, and never posts until the user saves it.
- Nothing changes in G-code, posts, goldens or `samples/expected/`.

## Decisions

1. **The file is the post's JSON** (`PostProfile.toJSON()`), with the extension `.loftlinepost`, declared in the save and open
   panels as `UTType(filenameExtension: "loftlinepost", conformingTo: .json)` as `.loftlinetools` already is. Import also accepts
   `.json`. No document type is registered in the bundle.
2. **Import opens an unsaved draft** in the editor, exactly as Duplicate does (`PostEditorModel.beginImport`, sharing a private
   `beginDraft` with `duplicate()`): the report runs, and only **Save** writes it, through `saveNew` (exclusive create).
3. **The draft.** `beginImport(_ p:)` sets `controller = BuiltInPosts.probeController(for: p) ?? p.controller` (a file of an
   unchanged built-in keeps its controller, as Duplicate does), reads `pause: []` as no pause template (as the loader does), and
   sets the id with `PostProfileStore.importID(for:)`: the id unchanged when it is a plain file name that no built-in and no file in
   the posts folder has (case-folded, whether that file loaded or not), else `newID(from:)` of it, or of `imported-post` when it is
   not a plain name. The name and every other field are kept.
4. **Reading a file**: the size is checked before reading (more than 1 MB is refused; a post is a few kilobytes), then
   `PostProfile.fromJSON`; a file that does not decode is refused with the `SnapshotError` reason, and no draft opens.
5. **The project's post.** `LoftLineDocument.carriedPostNotInstalled` returns the project's own copy as carried
   (`ProjectPost.postCopy(of:)`), not the post with the machine's limits applied: installing must save the post the project
   carries, so the project then finds it installed and equal. Its current callers read only the id and name. `PostProcessorsSheet`
   takes `carried: PostProfile?` (from `ContentView`, as `PostProfilePicker(carried:)` does) and shows **Add This Project's Post**
   when it is set and its id is free (`importID(for: id) == id`); when a file in the posts folder already has that id, the button is
   disabled (also while a draft has unsaved changes) with a reason that fits: "A post file already uses the id <id> (see Did
   not load)" when a file has it, or "The project's post id <id> is not a plain file name" when it is not safe. Job Setup's "not installed here" notice adds "Add it in
   Toolpaths ▸ Post Processors". No change to the sheet enum, so unapplied Job Setup edits are never dropped. An Add draft keeps
   the project's id on Save: it is saved with `saveNew(keepingID: true)`, which creates exactly `<id>.json` and, when another window
   created that file meanwhile, refuses ("A post with the id <id> was just saved elsewhere; it is installed now, or rename the
   file") instead of saving a renamed copy the project would not use. A carried post with an empty pause list is read as the default
   pause (see Structure), so it posts a stop and is equal to the one Add installs.
6. **A failed new save leaves no file.** `saveNew` removes the file it created when writing or closing it fails, so a partial file
   never holds an id or shows under Did not load.
7. **Export** is enabled for a saved custom post (the predicate Delete uses), writes `toJSON()` to the chosen URL, and suggests
   `<name>.loftlinepost`. Import and Export are disabled while a draft has unsaved changes.

## Tests

1. `importID`: a free id is kept; a built-in's id, a loaded custom post's id, a case-only clash and a skipped file's name each get
   `newID`; an unsafe id gets `imported-post-custom-<n>` or `imported-post`.
2. `beginImport`: the draft is new and dirty, no file is written, its report runs; a file of the unchanged Avid post imports with
   controller Mach4 (its probe sample runs); `pause: []` imports as nil; the name and a declared controller are kept.
3. Reading: a file over 1 MB is refused before it is read (a sparse file, so the test writes little); a malformed file is refused
   with its reason.
4. `carriedPostNotInstalled` returns the raw copy: a carried post whose limits differ from the project's machine is installed with
   its own limits, and after Save the project resolves it as installed with no copy-differs warning. When a skipped file has the
   carried id, Add This Project's Post is not available (`importID(for:) != id`).
5. `saveNew` removes its file when the write fails (an injected writer that throws); `saveNew(keepingID: true)` refuses an
   existing file instead of renaming; a carried post with `pause: []`, once added, resolves with no copy-differs warning; a file
   carrying a `toolChangeProbe` key imports with no probe setting.
6. Export writes bytes that decode to an equal post.
7. Goldens, samples and the full suite unchanged.

## Docs

`docs/DECISIONS.md` (`post-share`), `docs/PARITY.md` (`io-post-processors` row), `TESTING.md` (export, import, add a project's
post), Help (Machines and Post Processors).

## Structure (revision 3)

- **One empty-pause rule.** `PostProfile.normalized` (PostCore) reads `pause: []` as nil. The store's `load()`, `beginImport` and
  `ProjectPost.postCopy(of:)` all use it, so there is one copy of the rule and it sits on every path a post is read by, the posting
  path of a project's copy included: a carried `pause: []` used to post **no stop at all** at a pause (`pauseLines` empty), while
  the same post installed stopped. With the copy normalised where it is read, it posts the default stop, equals the post Add
  installs, and the copy-differs comparison needs no special case. Test: a project carrying `pause: []` posts `M0` at its pause,
  before and after Add, with no copy-differs warning.
- **One way to read a file.** `PostProfileStore.read(_ url: URL) throws -> PostProfile` checks the size (more than 1 MB is refused
  before reading), decodes with `PostProfile.fromJSON` and normalises; Import calls it.
- **The Add button's state** is one pure function, `PostEditorModel.addState(for carried: PostProfile?) -> AddState` (`.hidden`,
  `.enabled`, `.disabled(reason)`), tested on its own: hidden without a carried post; disabled while a draft is dirty, when the id is
  not a plain name, or when a post or file already has it (case-folded); enabled otherwise.
- `saveNew`'s cleanup on a failed write and its `keepingID` option are their own commit.

