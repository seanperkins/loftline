# A project file whose ids clash is refused (issue #123, item 1)

Status: draft, revision 1

## Problem

Everything in a project is found by id: an operation by its `setup.id`, a shape by its `id`, a tool by its `id`.
The lookups take the first match:
- results, export and the CLI use `first { $0.id == id }` (`LoftLineCLI.swift:275`, `GCodeExporter.swift:46`);
- an operation's `shapeIDs` select every shape with that id;
- `mergedTools` keeps the last tool with an id.

Project decoding never checks that ids are unique. Take a file with two operations sharing an id: a disabled
0.2 in drill, then an enabled 0.02 in drill. It calculates and posts the first, deeper one, with no warning.

The app always makes new ids with `UUID()`, so a clash means the file was edited by hand or written by
something else. The file then says two different things, and which one LoftLine follows is an accident of
lookup order.

## Design

`LoftLineProject.duplicateIDProblem() -> String?` returns the first clash it finds, in this order:
1. **Operations.** Two top-level operations with the same `id`.
2. **Shapes.** Two shapes in `document.shapes` with the same `id`.
3. **Tools.** Two entries in the project's own `tools` with the same `id`. A project tool that shares an id with
   a library tool is not a clash: by design the project's copy wins (`mergedTools`).

The message names what clashes and how to find it:

`The file is damaged: operations "Drill 1" and "Drill 2" share the id <uuid>. Each item in a project needs its own id; fix or remove one of them in a text editor.`

The noun and the names change with the kind (`shapes "…"`, `tools "…"`). A shape with no name is called
`(unnamed)`.

`LoftLineProject.opening(from:)` calls it after `ProjectPost.validate`, and throws
`ProjectOpenError(message:)` when there is a problem. `opening(from:)` is the path every file takes to become
a project that can be posted: the open dialog, the CLI and batch export. So the file is refused with that
sentence everywhere, before anything calculates.

`LoftLineProject.decode(from:)` itself does not change. Clipart and other read-only uses keep reading such a
file, and a clipart insert gives every shape a new id anyway.

## Not in scope

- **Ids inside an operation** (the parts of a merge, clearance tools) and **layer ids.** Layers are repaired
  on decode, and nothing posts by layer id.
- **Re-assigning ids instead of refusing.** For shapes and tools, a new id would silently change which item
  an operation means. For operations alone it would be safe, but one rule for all three is clearer, and the
  app never writes a clash.

## Tests

**CAMCoreTests:**
- `duplicateIDProblem` is nil for a normal project.
- It names two operations, two shapes and two tools in turn, each in the expected sentence.
- A project tool with the same id as a library tool is not reported. `duplicateIDProblem` never sees the
  library.

**LoftLineAppTests:**
- `LoftLineProject.opening(from:)` throws `ProjectOpenError` with that message for a file whose two
  operations share an id.
- `loftline-cli export` on such a file exits non-zero and prints the message. Use the existing CLI test
  helper.

## Docs

DECISIONS entry `duplicate-ids`.
