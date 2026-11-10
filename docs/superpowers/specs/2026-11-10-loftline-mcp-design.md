# LoftLine MCP server (spec 1 of 2: project files)

Status: design approved in chat 2026-11-10; revised after the review panel (executor, auditor); awaits Sean's review.

## Goal

Anyone who installs LoftLine can connect an AI assistant (Claude or any MCP client) to it. The assistant can open or create a
project, draw and edit the design, add and calculate toolpaths, see what Check Toolpaths reports, and save G-code and a job
sheet into a folder the user allows. A program posted through the assistant is byte-identical to the one the app posts.

Spec 2, later: a live link into the open Mac app (and the desktop app), so an assistant edits the document on screen. This spec
keeps the tool names and shapes that spec 2 will reuse, and builds nothing for it.

## Decisions (Sean, 2026-11-10)

| Question | Decision |
|---|---|
| Audience | LoftLine users: a product feature, with setup steps and stable tool names |
| Power | Read, edit, calculate and post |
| Target | Project files now; the open app in spec 2 |
| G-code | Written only to folders the user allows; a program with errors is never written |
| Build | Swift, in this package, speaking MCP over stdio itself; no new package dependency |
| Setup | Help ▸ Connect an AI Assistant… shows the steps and a config to copy; nothing edits the assistant's settings |
| Tools | About 20 task-level tools (not one per engine request, not one generic call) |
| Pictures | A PNG of the 2D design; no 3D picture |

Assumptions stated in chat and not corrected: it runs on Mac, Windows and Linux; reads are limited to the allowed folders as
writes are; nothing ever talks to the machine.

## Architecture

```
AI assistant ──stdio, MCP (JSON-RPC 2.0)──► loftline-mcp (executable)
                                               │
                         LoftLineMCP (library; Mac, Windows, Linux)
                           MCPServer       the 2026-07-28 protocol, and the earlier initialize handshake
                           AssistantTools  the tools: name, description, input schema, handler
                           AssistantAccess the allowed folders; every path resolved and checked
                           DesignPreview   2D picture → pixels → PNG (RasterCodec)
                                               │
                         CoreService / CoreSession (LoftLineKit)
                           the engine loftline-core and the desktop app use
```

- **Targets.** `Sources/LoftLineMCP` (library, depends on LoftLineKit), `Sources/loftline-mcp` (a `main.swift` that reads
  lines from standard input and writes replies to standard output, as `loftline-core` does), `Tests/LoftLineMCPTests`.
- **One engine path.** Tool handlers call `CoreService` with the same requests the desktop app sends, in process. The MCP layer
  holds no CAM, posting or checking logic, so a program posted through it is the app's program.
- **One project per process**, as one window: unsaved changes stay in memory until `save_project`. A new or opened project
  replaces it; `describe_project` says when there are unsaved changes. The MCP handlers for `open_project` and `new_project`
  check `session.isDirty` themselves and refuse unless the call says `discard: true` (the core's own `new` and `open` don't ask).
- **One change per call.** A tool that edits validates its whole input first and applies it as one undoable change, so a call
  that fails leaves the project as it was. Where the core applies a batch one item at a time (`addShape`), the core gains a batch
  request that does it in one `perform`.
- **One posting context.** `check`, `post_gcode`, `job_sheet` and `preview` take the same optional context: post, group by
  tool, material sheet, and side for a two-sided job (each defaulting to the project's own). The job sheet written with a
  program is made from the same context, so its post, steps and tool changes are the program's.
- **Protocol.** MCP over stdio, newline-delimited JSON-RPC 2.0, in two generations:
  - **2026-07-28**, the current one: no handshake; each request names its protocol version in `_meta`, and `server/discover`
    tells the client the server's name ("loftline"), version and tools capability.
  - **The initialize handshake** of 2025-06-18, 2025-03-26 and 2024-11-05, for clients that still use it: `initialize` answers with
    the client's version when supported, else the newest of these; `notifications/initialized` is ignored.
  - Both: `ping`, `tools/list`, `tools/call`. Anything else gets JSON-RPC error -32601. The exact field names come from the
    published specification at implementation time, and the protocol tests use its own examples.
- **Results.** A tool returns MCP content: text (a short summary line, then the details as JSON), plus an image for `preview`.
  A tool that fails returns `isError: true` with LoftLine's own message, in the app's words. A malformed request gets a JSON-RPC
  error; the process never exits on bad input.

- **The picture.** `DesignPreview` draws into its own RGBA buffer (lines, filled polygons, hatching, no text rendering beyond what
  `TextOutliner` gives as outlines), the same on every platform, and encodes it through `RasterCodec`: ImageIO on the Mac, the
  vendored stb_image_write elsewhere, as image import already splits. A `RasterCodec.png(rgba:width:height:)` is added if missing.

## Engine changes this needs

The MCP layer adds no posting logic, so what the tools need from the engine is added to `LoftLineKit`, where the desktop app
gets it too:

1. **Save All, fixed first, on its own branch.** The core's `saveAll` doesn't pass the sheet's toolpaths to a probing post, so a
   touch-plate post can't be saved, and it doesn't add the "post is not installed" error the Mac's Save All adds, so a project
   whose post is missing is written with the fallback post. The Windows and Linux apps have this today. Fix both, with tests,
   before `post_gcode` uses Save All.
2. **A check report request** that returns `ValidationReport.make`, the report the Mac's Check Toolpaths shows (including layout
   findings such as vectors outside the material), for `check`.
3. **Batch edits** as one change (above).
4. **Writes through the folder writer.** Every file the tools write (program, Save All set, project, job sheet) goes through the
   folder-anchored writer `GCodeFileSet` already uses: the folder is held open (Mac and Linux) or its identity checked before each
   step (Windows), a new file is created exclusively, and only `replace: true` replaces one. A check on the path followed by a
   plain write by path is not enough.
5. **Units in `set_job`** follow the desktop's order: `convertJob` to the new units first, then the edited fields, so changing a
   24 in job to millimetres gives 609.6 mm, not 24 mm.

## The tools

| Group | Tool | Does |
|---|---|---|
| Project | `new_project` | Units, material size and thickness, name; refuses to drop unsaved changes without `discard` |
| | `open_project` | Opens a `.loftline` file from an allowed folder |
| | `save_project` | Saves to its own path, or to a new path in an allowed folder (`replace: true` to overwrite) |
| | `describe_project` | Job setup, layers, shapes (id, name, layer, bounds, closed), toolpaths (id, kind, tool, depths, enabled, calculated, time, warnings), clamps (`ClampList`: name, position, height), unsaved flag. `limit`/`offset` for large projects |
| | `undo` | Undoes the last change |
| Design | `set_job` | Material, thickness, units (converted first, as Job Setup does), Z zero, XY origin, safe Z, home |
| | `add_shapes` | A batch of rectangles, rounded rectangles, circles, ellipses, polygons, stars, polylines and text |
| | `edit_shapes` | One action on given shapes: move, rotate, mirror, scale, align, distribute, offset, boolean, join, close, fillet, chamfer, group, ungroup, delete |
| | `import_file` | SVG, DXF, EPS, PDF or a bitmap from an allowed folder |
| | `edit_layers` | Add, rename, show or hide, delete, mark as clamps (keep-out with a height) |
| Library | `list_library` | Tools, posts or machines |
| Toolpaths | `add_toolpath` | Kind (profile, pocket, drilling, V-carve…), shapes, tool, settings |
| | `update_toolpath` | Settings, enabled, order |
| | `delete_toolpath` | |
| | `calculate` | Calculates the stale toolpaths; per toolpath: status, time, warnings |
| Check and output | `check` | The Check Toolpaths report for a posting context: errors, warnings, layout findings, time, deepest cut. Writes nothing |
| | `post_gcode` | Posts to an allowed folder: one file, or one file per toolpath or per tool (Save All's modes); writes the job sheet beside it unless told not to |
| | `job_sheet` | Writes the job sheet HTML to an allowed folder, for the same posting context as the program |
| | `preview` | PNG of the 2D design: material, vectors, toolpath lines, clamps (hatched, named), origin |
| | `help` | LoftLine's help topics, so the assistant can look up what a setting means |

Tool names are snake_case and stable once released; a change of meaning gets a new name. Each description says what the tool
changes, and `post_gcode`'s and `check`'s descriptions carry the safety text below.

## Safety

- **The checks can't be loosened.** `post_gcode` has no force or skip option. With an error from `GCodeValidator`, keep-out
  zones, machine limits, the touch-plate check or a missing toolpath, nothing is written and the result lists the issues. Warnings
  never block and are always returned.
- **Every post names what the operator must check.** The result starts with machine, post, units, material, Z zero, deepest cut,
  estimated time, tool changes and pauses, and the job sheet's path when one was written. The descriptions tell the assistant to
  show these to the user, and that the user checks the program, the job sheet and an air cut before cutting (`TESTING.md`).
- **Files.** Reads and writes only inside allowed folders. A path is resolved (symlinks, `..`, case on case-insensitive volumes)
  before the check, and the write itself goes through the folder-anchored writer (engine change 4), so a folder swapped for a
  link after the check can't redirect it. An existing file is replaced only with `replace: true`. Save All's set is all or nothing.
- **Allowed folders** are a list in `assistant.json` in LoftLine's support folder (where `ToolLibraryStore` keeps `tools.json`),
  default `Documents/LoftLine` (created on first use). Help ▸ Connect an AI Assistant… edits it, on the Mac and the desktop. A refusal says
  which folder was asked for and how to allow it.
- **Never**: network access, controlling a machine, running anything a project contains (gadgets stay in the app).
- **Limits** per call: 200 shapes, 10,000 points per polyline, 1,000 characters of text, 50 MB import, and a preview of at most
  4,096 pixels a side and 8 million pixels, checked before anything is allocated. Over a limit is an error, not a truncation.
- **Untrusted text.** Shape, layer and toolpath names and imported text come from files; results return them as data only.

## Setup for users

- The Mac app bundles `loftline-mcp` in `LoftLine.app/Contents/MacOS/`, signed with the app (`scripts/bundle.sh`,
  `scripts/check-bundle.sh` checks it is there and runs).
- The Windows and Linux installers bundle it as a second sidecar beside `loftline-core` (`desktop/src-tauri`).
- Help ▸ Connect an AI Assistant… (Mac and desktop): the server's full path, a ready config for Claude Desktop and Claude Code
  (`{"mcpServers": {"loftline": {"command": "<path>"}}}` and the `claude mcp add` line), the allowed folders with a button to
  change them, and a Copy button. Nothing writes the assistant's config.
- A help topic, `HelpTopic.assistant`, says the same, including the safety rules in plain words.

## Testing

- `Tests/LoftLineMCPTests`, run on Mac and in the Linux and Windows CI jobs:
  - the handshake, version negotiation, `tools/list` (every schema is valid JSON Schema with required fields), an unknown tool,
    a malformed line;
  - both protocol generations: a 2026-07-28 session with `server/discover` and the version in `_meta`, and an `initialize` one;
  - the engine changes: Save All with a probing post saves; Save All with a missing post refuses; the check report flags a
    vector wholly outside the material as the Mac does; a failed batch leaves the project unchanged; `set_job` from inches to
    millimetres converts first; a job sheet made with a grouped, alternating-tool program lists the program's order;
  - a folder replaced by a link between the check and the write (through the writer's test seam) is refused, as Save All's is;
  - each tool's normal use, and its refusals: a path outside the allowed folders, a symlink inside one that points out, a program
    with an error (nothing written), an existing file without `replace`, unsaved changes without `discard`, each size limit;
  - parity: `samples/sign.loftline` posted through `open_project` + `post_gcode` for each built-in post equals
    `samples/expected` byte for byte;
  - `preview`: the PNG decodes at the requested size, and known pixels (material, a clamp's hatch) are set.
- `scripts/mcp-smoke.sh`: pipes a scripted session into the built `loftline-mcp` and checks the replies.
- `TESTING.md`: connect Claude Code to the bundled server, make and post a sign end to end, compare it with the app's program.
- No G-code change anywhere: `scripts/check-samples.sh` matches 48.

## Docs

`docs/PARITY.md` (a row for the assistant connection), `docs/DECISIONS.md` (in-process engine, task-level tools, allowed folders,
no force option), `docs/PLATFORMS.md` (same on all three), `README.md` (a short section with the setup), `THIRD_PARTY.md`
unchanged (stb_image_write is already vendored for Windows and Linux).

## Out of scope

The live link into the open app (spec 2); a 3D picture; resources and prompts (MCP features beyond tools); HTTP transport;
sending a program to a machine.
