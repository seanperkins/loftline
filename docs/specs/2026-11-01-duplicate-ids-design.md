# Ids in a project are unique (issue #123, item 1)

Status: approved, revision 3 (after debate:all rounds 1 and 2)

## Problem

A project finds its items by id, and the lookups take one match:
- **Operations:** the CLI uses `first { $0.id == id }` (`LoftLineCLI.swift:275`), results are a dictionary keyed by
  the operation id, and so are selection, `upsertOperation` and variable links (`.operation(id)`).
- **Shapes:** `Document.shapes(ids:)` takes the first match.
- **Layers:** `layer(id:)` takes the first match, which decides a shape's side in a two-sided job.
- **Placed models:** `model(id:)` takes the first match, which decides which heightmap a relief cuts.
- **Tools:** the app keeps the first carried tool with an id (`ToolSync.carrying`). The CLI keeps the last
  (`mergedTools`). So the app and the CLI post different tools for the same file.

Nothing checks that ids are unique. A file with a disabled 0.2 in drill and an enabled 0.02 in one under one
id posts the first, deeper one, with no warning.

**The app can write an operation clash itself.**
- Duplicate Toolpath on a merged toolpath gives the copy a new id but keeps its children's ids
  (`duplicateOperation`, `LoftLineDocument.swift:763`).
- Splitting both merges (`splitMerged`) then puts two operations with one id at the top level.
- So does merging a toolpath with its own duplicate and splitting the result.

Files written that way may already exist.

## Design

### Operations: never written twice, and repaired on open

Add `[AnyOperation].givingRepeatedIDsNewOnes()` in CAMCore, next to `MergeOperation`.
- It first reserves the top-level ids in order, so a top-level operation always keeps its id, along with its
  results, selection and variable links. A later top-level operation repeating an earlier top-level id gets a
  fresh `UUID()`.
- Then it walks the merge children, depth first, and gives a fresh `UUID()` to any child whose id is already
  taken.
- Nothing in a file refers to the later one, so changing its id changes nothing that was saved about it.

It is used in three places:
1. **`duplicateOperation`:** after giving the copy a new id, the copy's merge children (if any) get new ids too,
   all of them, through a `withNewIDs()` on `AnyOperation`.
2. **`splitMerged` and `mergeWithNext`:** after the edit, the project's operations go through
   `givingRepeatedIDsNewOnes()`. Then neither command can bring back an id that is already in use.
3. **`LoftLineProject.opening(from:)`:** a file written before this fix, or by hand, opens with its repeated
   operation ids repaired. This is not refused: the app wrote these files.

### Shapes, layers, models and tools: refused

The app never writes these twice:
- shape duplication, paste and clipart give new ids;
- layers and models are created with `UUID()`;
- `ToolSync` writes one tool per id.

A clash in one of these means the file was edited by hand or written by something else, and LoftLine cannot
know which item an operation means. `ProjectPost.rejectDuplicateIDs(in project:)`, next to `validate`,
throws `LoftLineIOError.malformed` (`ProjectOpenError` already carries its message) for the first clash it
finds. It checks, in this order:
1. layers;
2. shapes;
3. placed models;
4. keep-out zones (deleting one of two zones on one id deletes both, and the clamp check goes with them);
5. the project's own `tools`.

A project tool that shares an id with a library tool is not a clash: the project's copy wins by design.

The message names the kind, the positions and the names, so two items with the same name can be told apart:

`Two shapes share the id <uuid>: the 2nd ("Hole") and the 5th ("Hole"). Every item in a project needs its own id; change or remove one of them.`

- With three or more items on one id, it names the first two.
- An item with no name is `(unnamed)`.
- Ordinals are `1st`, `2nd`, `3rd`, then `Nth`.

`opening(from:)` runs, in order: `rejectNullCopies`, decode, `validate`, `rejectDuplicateIDs`, then the
operation repair. Every way a file becomes a project that can be posted goes through it: the open dialog,
recovery and versions (`LoftLineDocument.init(opening:)`), job templates, and the CLI. `decode(from:)` itself
is unchanged, so clipart still reads.

## Not in scope

- **Ids inside an operation's own parameters** (clearance-tool and model references), which point at items
  this check covers.
- **The CLI's "is not a LoftLine project:" prefix.** It is unchanged.

## Tests

**CAMCoreTests:**
- `givingRepeatedIDsNewOnes`:
  - for `[A, B, A′]` (A′ with A's id), A keeps its id, A′ gets a new one, and B is untouched;
  - inside a merge, a child repeating a top-level id is re-identified;
  - three items on one id leave the first alone;
  - a merge's child A, then top-level A′ with the same id: A′ keeps the id and the child gets a new one.

**LoftLineAppTests:**
- **Duplicate on a merged toolpath, then split both:** every operation id at the top level is unique.
  - The same for merging a toolpath with its own duplicate, then splitting.
- **The `ProjectOpeningTests.Bad` table** gains duplicate shapes, layers, models, keep-out zones and tools, each with its
  message fragment. They run through the document, recovery and job-template paths.
- **Message details:** two clashing kinds at once report the earlier kind; three shapes on one id name the
  1st and 2nd; an unnamed shape reads `(unnamed)`.
- **Repair on open:** a file with two top-level operations on one id opens; both are there with different
  ids, and the first keeps the original id.
- **CLI:**
  - Exporting a file with clashing shapes exits `2`, and stderr contains the message.
  - Exporting the issue's file (a disabled 0.2 in drill, then an enabled 0.02 in drill, on one id) posts the
    enabled drill at 0.02 in, not 0.2 in.

## Docs

DECISIONS entry `duplicate-ids`.
