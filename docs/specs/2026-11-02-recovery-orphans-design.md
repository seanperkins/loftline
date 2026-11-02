# A recovery copy is found even without its metadata (issue #123, item 2)

Status: draft, revision 1

## Problem

`RecoveryStore.write` writes the project (`<id>.loftline`) and then its metadata (`<id>.json`).
`entries()` finds copies only through `.json` files. Two ways to lose one:
- a crash, a full disk or an error between the two writes;
- a `.json` that cannot be read.

Either way the `.loftline` copy of unsaved work is never offered. `RecoveryPrompt` says "Nothing to recover",
and the copy stays in the folder unseen.

## Design

1. **`write` writes the metadata first, then the project.**
   - If the second write fails, the metadata has no project, and `entries()` already skips an entry whose
     project is missing.
   - Rewriting a dirty document's copy replaces each file atomically, and the project file is never
     removed in between.
2. **`entries()` also lists every `<uuid>.loftline` in the folder that has no readable `<uuid>.json`.** For
   such a copy:
   - `id` comes from the file name. A file name that is not a UUID is skipped.
   - `name` is the project's document name, read with `LoftLineProject.decode(from:)`. If that fails, or the
     name is empty, it is `"Unsaved document"`.
   - `savedAt` is the file's modification date, or `.distantPast`.
   - It is sorted with the rest, newest first.

   Recovering it goes through `project(for:)` (`opening(from:)`) like any other entry, so a copy that cannot
   be opened reports why, as today.
3. **Nothing else changes.** `archive` and `remove` already move or delete both files, and ignore a missing
   one.

## Not in scope

- **Atomic pairing of the two files** (one file with both). `entries()` tolerating either half missing is
  enough.

## Tests (LoftLineAppTests, `RecoveryTests`)

- **A copy with no `.json`** is listed: its id, the project's name, and the file's date.
- **A copy whose `.json` is not JSON** is listed the same way, and is not listed twice.
- **A copy that cannot be decoded and has no `.json`** is listed as "Unsaved document".
- **A `.loftline` whose name is not a UUID** is ignored.
- **Write order.** Make the project path unwritable by putting a directory at `<id>.loftline`, so the second
  write fails. `write` throws, and `entries()` lists nothing for that id: the metadata is there with no
  project.
- **The existing `storeWritesListsAndRemoves` still passes.**

## Docs

None beyond the code comments. This is a robustness fix with no user-facing setting.
