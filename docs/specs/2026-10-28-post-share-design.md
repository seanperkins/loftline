# LoftLine: share a post as a file

Part 4 of the post-processor work. Parts 1–3 (projects carry their post; coolant and park-and-probe; the post editor) are on
main at `1a7812a`. Part 5 (more built-in posts) is out of scope.

## Why

A shop that has a working post wants to give it to someone else (another Mac, a friend with the same machine, a forum). Today the
only ways are to dig the JSON out of `Application Support/LoftLine/posts` or to send a whole project that carries it, and the
receiver of a project can post with its copy but cannot add that post to their own list.

## Goals

- **Export** any post (built in or custom) from Toolpaths ▸ Post Processors as one file.
- **Import** a post file, and **install the post a project carries** when this Mac does not have it.
- An imported post never overwrites a post already here, never skips the editor's checks, and never posts until the user saves
  it.
- Nothing changes in G-code, posts, goldens or `samples/expected/`.

## Decisions

1. **The file is the post's JSON**, exactly what the posts folder holds (`PostProfile.toJSON()`, pretty-printed, sorted keys),
   with the extension `.loftlinepost` so it is recognisable in a mail or a forum post. Import also accepts `.json`. No UTType is
   declared: the files are opened from the sheet, not by double-click, so the bundle's Info.plist does not change.
2. **Import opens an unsaved draft** in the editor, exactly as Duplicate does: the report runs, and only **Save** writes it. So an
   imported post goes through every check of part 3, and the user sees its sample program before it can be used.
3. **Ids.** The imported post keeps its id when that id is a plain file name and no built-in or file in the posts folder has it
   (case-folded); otherwise it gets `newID(from:)` of its id, or of `imported-post` when its id is not a plain name. The name is
   kept. Export writes the id unchanged.
4. **What an import keeps.** Every field, the declared controller included (the editor shows it, and the probe sample runs when it
   is set). The never-coded probe setting is not in the file.
5. **Refusals with a message, no draft**: a file that does not decode (the `SnapshotError` reason: newer LoftLine, malformed with
   its path), or larger than 1 MB (a post is a few kilobytes).
6. **Install the project's post.** When the open project carries a post this Mac does not have (`carriedPostNotInstalled`, from
   part 1), Job Setup's notice gets an **Install…** button that opens Post Processors with that post as an import draft (same
   rules). A carried post that differs from an installed one of the same id is not offered (part 1's Update This Project covers
   that direction).

## Interfaces

- `PostShare.exportData(_ p: PostProfile) throws -> Data` and `static let fileExtension = "loftlinepost"`.
- `PostShare.importDraft(from data: Data, store: PostProfileStore) throws -> PostProfile` (decode, size check, id rule).
- `PostEditorModel.beginImport(_ p: PostProfile)` — the draft, `isNew = true`, selection = its id.
- Post Processors buttons: **Import…** (`NSOpenPanel`, `.loftlinepost` and `.json`) and **Export…** (`NSSavePanel`, suggested
  name `<name>.loftlinepost`), both disabled while a draft has unsaved changes.
- `DocumentSheet.postProcessors` gains an optional draft to open with (`postProcessors(importing: PostProfile?)`).

## Tests

1. Export: the data decodes back to an equal post; a built-in exports with no `controller` key and its bytes equal its
   `toJSON()`.
2. Import: keeps a free id; a built-in's id, a custom post's id (also case only), and an unsafe id each get a new id; the name and
   the declared controller are kept; a malformed, a newer-schema and a 2 MB file are refused with their reasons; the draft is
   unsaved (no file written) and its report runs.
3. Install: a project whose carried post is not installed offers it; the model opens it as an import draft; a carried post equal
   to an installed one is not offered.
4. UI: the sheet's Import and Export buttons exist and are disabled while a draft is dirty (model test); an offscreen render of
   Job Setup's notice with Install.
5. Goldens, samples and the full suite unchanged.

## Docs

`docs/DECISIONS.md` (`post-share`), `docs/PARITY.md` (`io-post-processors` row), `TESTING.md` (export, import, install), Help.
