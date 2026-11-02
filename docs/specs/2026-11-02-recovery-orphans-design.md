# A recovery copy is found even without its metadata (issue #123, item 2)

Status: approved, revision 2 (after debate:all round 1)

## Problem

`RecoveryStore.write` writes the project (`<id>.loftline`), then its metadata (`<id>.json`). `entries()` finds
copies only through the `.json` files. So a `.loftline` whose `.json` is missing or unreadable is never offered.
That happens after a crash, a full disk or an error between the two writes. `RecoveryPrompt` then says
"Nothing to recover", and the unsaved work sits in the folder unseen.

## Design

1. **`entries()` makes one pass over the copies, not over the metadata.** For each regular file `<stem>.loftline`
   in the folder (not the Archive subfolder, not directories, not hidden files):
   - **The id.** It is `UUID(uuidString: stem)`, accepted only when its `uuidString == stem`. The app writes
     upper-case names, and `projectURL(id)` rebuilds the path from the id, so any other name would be offered and
     never cleared.
   - **With metadata.** If `<id>.json` decodes to a `RecoveryEntry` whose `id` is that id, the entry is used as
     written.
   - **Without.** Otherwise the entry is `RecoveryEntry(id:, name: "Unsaved document", savedAt: <modification date>)`.
     The project is not decoded here: this runs on the main thread at launch, and a large copy would stall every
     launch until it is dealt with. It is decoded when the user recovers it, as every copy is (`opening(from:)`,
     through `LoftLineDocument.init(configuration:)`).
   - **Order.** Newest first, as today. A copy without a modification date sorts last.
   - **No project, no entry.** A `.json` with no project is never visited, so the `fileExists` filter goes.
2. **The write order stays: project, then metadata.** A crash between the two leaves real work, which the pass
   above now finds.
3. **`RecoveryCoordinator.tick` claims the id before writing.** `ownedIDs.insert(id)` moves before `store.write`.
   - Otherwise, a metadata write that fails (a full disk) leaves an unowned `.loftline` for a document that is
     still open. "Recover Unsaved Work…" would offer it, and its Discard would archive the live copy.
   - A normal quit would not remove it, and the next launch would claim LoftLine did not quit normally.
   - With the id owned, `discard` and `cleanUpOnQuit` remove whatever part was written.

`archive` and `remove` already ignore a missing half (`try?`), so a copy with no `.json` is archived or removed
like any other.

## Not in scope

- **Pairing the two files atomically** (one file holding both). Tolerating a missing half is enough.
- **A copy's name when its metadata is lost.** It is shown as "Unsaved document" with its time. The real name
  appears once it is recovered.

## Tests (LoftLineAppTests, `RecoveryTests`)

**Listing:**
- **No `.json`:** listed with its id, "Unsaved document" and the file's date.
- **A `.json` that is not JSON:** listed the same way, once.
- **A `.json` whose body names another id:** the copy is listed under its own id, as "Unsaved document".
- **Ignored:**
  - a lowercase-UUID `.loftline`;
  - a `.loftline` that is a directory;
  - a non-UUID `.loftline`;
  - a hidden temporary file.
- **A `.json` with no `.loftline`:** not listed.
- **Sort order:** a copy without metadata sorts between two written entries by its date.

**Archive and remove on a copy without metadata:**
- `archive` moves it into the Archive.
- `remove` deletes it.

**`RecoveryCoordinator`:**
- When the project write fails, because a directory sits at `<id>.loftline`, the id is still owned.
- After the directory is removed and the document is saved, `discard` removes the stray `.json`.

**Existing:** `storeWritesListsAndRemoves` and the `SaveConfirmationTests` recovery assertions still pass.
