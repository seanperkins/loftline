# LoftLine MCP Server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `loftline-mcp` stdio server, bundled with LoftLine on Mac, Windows and Linux, through which an AI assistant opens,
edits, checks and posts LoftLine projects inside folders the user allows.

**Architecture:** A `LoftLineMCP` library holds the protocol, the tools, the folder rules and the 2D picture; a tiny
`loftline-mcp` executable runs it over stdio. Tools drive the same `CoreService`/`CoreSession` engine as `loftline-core`;
what they need from it (posting context, one-call batches, a check report, a pluggable writer) is added to `LoftLineKit` first.

**Tech Stack:** Swift 6 / SwiftPM, swift-testing, JSON-RPC 2.0 over stdio, `RasterCodec` for PNG, Tauri sidecars for desktop.

**Spec:** `docs/superpowers/specs/2026-11-10-loftline-mcp-design.md`

## Global Constraints

- No new package dependency (SwiftPM only; the Mac app gains none).
- No G-code change: `scripts/check-samples.sh` → `samples/expected matches: 48 programs`; never regenerate `samples/expected`.
- `GCodeValidator` and every export check stay as they are; no tool has a force or skip option.
- Protocols: 2026-07-28 (no handshake; version in `_meta`; `server/discover`) and the `initialize` handshake of 2025-06-18,
  2025-03-26, 2024-11-05.
- Server name "loftline"; version = `CFBundleShortVersionString` from `../Info.plist` beside the executable when it runs inside
  `LoftLine.app/Contents/MacOS/`, else the `--version` argument the desktop app passes, else "dev" (`MCPServer.appVersion()`).
- Limits per call: 200 shapes, 10,000 points per polyline, 1,000 characters of text, 50 MB import, preview ≤ 4,096 px a side
  and ≤ 8,000,000 px.
- Allowed folders in `assistant.json` in LoftLine's support folder; default `Documents/LoftLine`.
- Tool names snake_case, stable once released.
- New tests live where Linux and Windows CI run them (`Tests/LoftLineKitTests`, `Tests/LoftLineMCPTests`), not app tests.

## Review Focus

1. A path with a symlink component or `..` that lands outside an allowed folder → refused, even when the target exists.
2. A tool call that fails half way (bad shape 150 of 200, unknown toolpath kind) → project unchanged, one undo step at most.
3. A project whose post or machine is missing → `check`/`post_gcode` report the error and write nothing, as Save All now does.
4. Units: `set_job` from inches to millimetres on a project with shapes and toolpaths → design and job converted once.
5. Two-sided or multi-sheet project → `post_gcode` with a side posts that side's toolpaths only, and the job sheet says so.

Each line has its test in the owning task (Tasks 3, 2, 8, 6, 8).

---

### Task 1: Posting context, check report and pluggable writes in the engine

**Files:** Modify `Sources/LoftLineKit/CoreSession.swift`, `Sources/LoftLineKit/CoreService.swift`; test
`Tests/LoftLineKitTests/CorePostingContextTests.swift`.

**Interfaces — Produces:**
- `public struct PostingContext: Equatable { public var postID: String?; public var groupByTool: Bool; public var side: JobSide? }`
  (`init` with defaults nil/false/nil).
- `CoreSession.postAll(mode: SaveAllMode, context: PostingContext) throws -> [(file: PlannedGCodeFile, result: GCodeExportResult)]`
  — the body of `CoreService`'s `saveAll` after 4b4fa12 (sheet toolpaths, post issues), moved here; `saveAll` calls it.
- `CoreSession.jobSheetHTML(context: PostingContext) throws -> String` — `jobSheet`'s body with the context's post and grouping
  (today it fixes `own.post`, `groupByTool: false`); `jobSheet` gains optional `postID`, `groupByTool`, `side` params.
- `CoreSession.checkReport(context: PostingContext) throws -> ValidationReport` — calculates stale enabled toolpaths and calls
  `ValidationReport.make(project: outputProject(side), …, sheetToolpaths: GCodeExporter.sheetToolpathsIfProbing(…))`, with
  `ProjectPost.issues` prepended as `post` does; new core request `checkReport` returns sections `{title, issues: [IssueRow]}`.
- `CoreSession.save(to: URL, writer: (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) throws`.

- [ ] **Step 1: Write the failing tests**
  - `jobSheetFollowsTheProgramsGrouping`: sign with an extra profile on T6 between pocket and profile (alternating tools);
    `jobSheetHTML(context: .init(groupByTool: true))` lists steps in the order of `post(scope: .all, … groupByTool: true)`'s
    toolpaths, and `.init(postID: "generic-grbl-inch")` prints that post's name.
  - `checkReportFlagsAVectorOutsideTheMaterial`: a visible rectangle at x = 30 on the 24 in sign with no toolpath →
    a report issue containing "entirely outside the material".
  - `checkReportCarriesAMissingPost`: postProfileID "gone-post", no snapshot → first issue says `"gone-post" is not installed`.
  - `saveUsesTheGivenWriter`: `save(to:writer:)` passes the encoded project and URL to the closure; `isDirty` false after.
- [ ] **Step 2:** `scripts/test.sh --filter CorePostingContextTests` → FAIL (no `PostingContext`).
- [ ] **Step 3:** Implement the four members above; route `saveAll`, `jobSheet` and the new `checkReport` request through them.
- [ ] **Step 4:** `scripts/test.sh --filter 'CorePostingContextTests|CoreServiceTests|CoreSaveAllTests'` → PASS.
- [ ] **Step 5:** Commit `feat(core): posting context, check report and a pluggable writer for the MCP server`.

### Task 2: One-call shape batches

**Files:** Modify `Sources/LoftLineKit/CoreService.swift`; test `Tests/LoftLineKitTests/CoreBatchTests.swift`.

**Interfaces — Produces:** core request `addShapes` with params
`{ "shapes": [ {"kind":"tool","tool":String,"from":Vec2,"to":Vec2,"options":ShapeOptions?} | {"kind":"polyline","points":[Vec2],"closed":Bool} | {"kind":"text","spec":TextSpec} ] }`;
every item is built first (same builders as `addShape`, `addPolyline`, `addText`), then all are added in one
`s.perform("Add Shapes")`. Reply: `{state, ids: [UUID]}` in input order.

- [ ] **Step 1: Write the failing tests** `aBatchAddsInOneUndoStep` (3 shapes → 3 new ids, one `undo` removes all) and
  `aBadItemLeavesTheProjectAsItWas` (second item is a polyline of one point → error naming item 2; shapes unchanged;
  `undoAction` unchanged).
- [ ] **Step 2:** `scripts/test.sh --filter CoreBatchTests` → FAIL ("Unknown method \"addShapes\"").
- [ ] **Step 3:** Implement `addShapes` in `CoreService` (factor the three single-shape builders into `makeShape(…) throws -> Shape`).
- [ ] **Step 4:** `scripts/test.sh --filter 'CoreBatchTests|CoreServiceTests'` → PASS.
- [ ] **Step 5:** Commit `feat(core): add shapes in one undoable batch`.

### Task 3: Allowed folders

**Files:** Create `Sources/LoftLineMCP/AssistantAccess.swift`; modify `Package.swift` (library `LoftLineMCP` depending on
`LoftLineKit`; test target `LoftLineMCPTests`); test `Tests/LoftLineMCPTests/AssistantAccessTests.swift`.

**Interfaces — Produces:**
- `public struct AssistantSettings: Codable, Equatable { public var allowedFolders: [String] }`,
  `static func load(from: URL) -> AssistantSettings` (missing or unreadable file → default `[Documents/LoftLine]`),
  `func save(to: URL) throws`, `static var fileURL: URL` (support folder as `ToolLibraryStore` finds it + `assistant.json`).
- `public struct AssistantAccess { init(settings: AssistantSettings); func resolve(_ path: String) throws -> URL }` — makes the
  path absolute, resolves symlinks of the existing prefix (`URL.resolvingSymlinksInPath` on the deepest existing ancestor),
  standardizes, compares by path components (case-insensitively on Mac and Windows) against each resolved allowed folder.
  Error text: `"\(path) is outside the folders LoftLine lets assistants use (\(list)). Add the folder in LoftLine's settings: Connect an AI Assistant."`
- `func folder(for url: URL) throws -> GCodeFileSet.Folder` — opens the containing folder for writing (creates the default folder
  when missing; any other missing folder is an error).

- [ ] **Step 1: Write the failing tests:** `aFileInsideIsAllowed`; `dotDotOutIsRefused` (`allowed/../secret.txt`);
  `aSymlinkPointingOutIsRefused` (link inside allowed → `/tmp/x`); `aMissingSettingsFileAllowsTheDefaultFolder`;
  `aSiblingWithTheSamePrefixIsRefused` (`/a/LoftLine2` when `/a/LoftLine` is allowed).
- [ ] **Step 2:** `scripts/test.sh --filter AssistantAccessTests` → FAIL (no target/type).
- [ ] **Step 3:** Implement as above.
- [ ] **Step 4:** `scripts/test.sh --filter AssistantAccessTests` → PASS.
- [ ] **Step 5:** Commit `feat(mcp): allowed folders for assistants`.

### Task 4: Protocol server and executable

**Files:** Create `Sources/LoftLineMCP/MCPServer.swift`, `Sources/LoftLineMCP/AssistantTool.swift`,
`Sources/loftline-mcp/main.swift`; modify `Package.swift` (executable `loftline-mcp`); test `Tests/LoftLineMCPTests/MCPServerTests.swift`,
fixture `Tests/LoftLineMCPTests/Fixtures/protocol-2026-07-28.json`.

**Interfaces — Produces:**
- `public struct AssistantTool { let name: String; let description: String; let inputSchema: [String: Any]; let call: ([String: Any]) throws -> ToolOutput }`
- `public struct ToolOutput { var text: String; var image: Data? = nil }` (image = PNG).
- `public final class MCPServer { init(tools: [AssistantTool], version: String); func handle(_ line: Data) -> Data? }`
  (nil for notifications). Tool errors → result `{content:[{type:"text",text:message}], isError:true}`; JSON-RPC errors
  -32700 parse, -32600 invalid request, -32601 unknown method, -32602 unknown tool or bad arguments.

- [ ] **Step 1: Read the published 2026-07-28 specification** (modelcontextprotocol.io/specification/2026-07-28: base protocol,
  `server/discover`, `_meta` protocol version, tools) and copy its example requests and responses for discover, tools/list and
  tools/call into the fixture, with the spec URL in a `"source"` field.
- [ ] **Step 2: Write the failing tests:** `initializeAnswersAKnownVersion` (2025-06-18 → same), `initializeFallsBackToTheNewest`
  ("2024-01-01" → "2025-06-18"), `discoverMatchesTheFixture`, `aRequestCarryingTheVersionInMetaIsServed`,
  `everyToolSchemaIsAnObjectWithItsRequiredFieldsListed`, `anUnknownToolIsInvalidParams`, `aMalformedLineIsAParseError`,
  `aNotificationGetsNoReply`, `aThrowingToolIsAnErrorResultNotAProtocolError`.
- [ ] **Step 3:** `scripts/test.sh --filter MCPServerTests` → FAIL.
- [ ] **Step 4:** Implement `MCPServer`; `main.swift` reads lines from stdin, writes each reply plus `\n` to stdout and flushes,
  and builds the tools from `AssistantTools.all(session:access:)` (Task 5 onward; an empty list until then).
- [ ] **Step 5:** `scripts/test.sh --filter MCPServerTests` → PASS; `scripts/build.sh` builds `loftline-mcp`.
- [ ] **Step 6:** Commit `feat(mcp): the MCP protocol over stdio, both generations`.

### Task 5: Project tools

**Files:** Create `Sources/LoftLineMCP/AssistantTools.swift` (registry), `Sources/LoftLineMCP/ProjectTools.swift`,
`Sources/LoftLineMCP/CoreClient.swift`; test `Tests/LoftLineMCPTests/ProjectToolsTests.swift`.

**Interfaces — Produces:** `struct CoreClient { let service: CoreService; func call(_ method: String, _ params: [String: Any] = [:]) throws -> [String: Any] }`
(throws `CoreFailure` with the reply's `error`); `enum AssistantTools { static func all(service: CoreService, access: AssistantAccess) -> [AssistantTool] }`.
Tools: `new_project {units, width, height, thickness, name?, discard?}`, `open_project {path, discard?}`,
`save_project {path?, replace?}`, `describe_project {limit? = 200, offset? = 0}`, `undo {}`.

- [ ] **Step 1: Write the failing tests:** `openRefusesToDropUnsavedChanges` (edit, then open without `discard` → error containing
  "unsaved"; with `discard: true` → opens); `saveOutsideTheAllowedFoldersIsRefused`; `saveOverAnExistingFileNeedsReplace`;
  `saveWritesThroughTheFolderWriter` (file present, `describe_project.unsaved == false`); `describeListsClampsByTheirSheetNames`
  (two unnamed shapes on "Clamps" → `Clamp 1`, `Clamp 2` with positions); `describePages` (250 shapes, limit 200 → 200 and
  `"more": 50`).
- [ ] **Step 2:** `scripts/test.sh --filter ProjectToolsTests` → FAIL.
- [ ] **Step 3:** Implement. `save_project` uses `session.save(to:writer:)` with a writer that writes one
  `GCodeFileSet.File` (text = the encoded project) into `access.folder(for:)`, `replacing` only when `replace: true`.
  `describe_project` reads `state` and adds `ClampList.items` with `position`/`heightText`.
- [ ] **Step 4:** `scripts/test.sh --filter ProjectToolsTests` → PASS.
- [ ] **Step 5:** Commit `feat(mcp): project tools`.

### Task 6: Design tools

**Files:** Create `Sources/LoftLineMCP/DesignTools.swift`; test `Tests/LoftLineMCPTests/DesignToolsTests.swift`.

**Interfaces:** Consumes `CoreClient`, core `addShapes` (Task 2), `convertJob`, `setJob`, `jobForm`, `transformShapes`,
`command`, `align`, `distribute`, `group`, `ungroup`, `combine`, `boolean`, `join`, `close`, `deleteShapes`, `import`,
`addLayer`, `updateLayer`, `deleteLayer`. Produces tools `set_job`, `add_shapes`, `edit_shapes {action, ids, …}`,
`import_file {path}`, `edit_layers {action: add|rename|show|hide|delete|clamps, id?, name?, height?}`.

- [ ] **Step 1: Write the failing tests:** `setJobConvertsUnitsFirst` (24 × 18 in sign → `units: "millimeter"` with no sizes →
  width 609.6, a shape's bounds scaled by 25.4); `setJobRejectsWhatJobSetupRejects` (thickness 0 → the Job Setup message);
  `addShapesOverTheLimitIsAnErrorAndAddsNothing` (201 shapes; a 10,001-point polyline; 1,001-character text);
  `editShapesMovesRotatesAndDeletes`; `importFromOutsideIsRefused`; `anImportOver50MBIsRefusedUnread`;
  `markingALayerAsClampsSetsItsHeight`.
- [ ] **Step 2:** `scripts/test.sh --filter DesignToolsTests` → FAIL.
- [ ] **Step 3:** Implement. `set_job`: when `units` differs, `convertJob` first, then `jobForm` merged with the given fields,
  then `setJob`. Limits checked before any core call. `edit_shapes` maps `move|rotate|mirror|scale` to `transformShapes`
  (a `Transform2D` about the selection's centre unless `center` is given) and the rest to their core requests by name.
- [ ] **Step 4:** `scripts/test.sh --filter DesignToolsTests` → PASS.
- [ ] **Step 5:** Commit `feat(mcp): design tools`.

### Task 7: Library and toolpath tools

**Files:** Create `Sources/LoftLineMCP/ToolpathTools.swift`, `Sources/LoftLineMCP/JSONPatch.swift`; test
`Tests/LoftLineMCPTests/ToolpathToolsTests.swift`.

**Interfaces — Produces:** `enum JSONPatch { static func merge(_ patch: [String: Any], into base: [String: Any]) -> [String: Any] }`
(recursive; a JSON `null` removes a key); tools `list_library {kind: tools|posts|machines}`,
`add_toolpath {kind, shape_ids, tool_id?, settings?}`, `update_toolpath {id, settings?, enabled?, move_to?}`,
`delete_toolpath {id}`, `calculate {ids?}` → per toolpath `{id, name, status, time, warnings}`.

- [ ] **Step 1: Write the failing tests:** `addToolpathAppliesSettingsOverTheDefaults` (pocket on the sign's panel with
  `settings: {"depth": {"cutDepth": 0.1}}` → stored cut depth 0.1, other fields the factory's); `anUnknownKindChangesNothing`;
  `updateToolpathDisablesAndMoves`; `calculateReportsTimeAndWarnings`; `listLibraryHasTheBuiltInPosts`.
- [ ] **Step 2:** `scripts/test.sh --filter ToolpathToolsTests` → FAIL.
- [ ] **Step 3:** Implement: `add_toolpath` = `addOperation`, then (if `settings` or `tool_id`) read the new operation's JSON from
  `state`, `JSONPatch.merge`, `updateOperation` — on any failure `undo` back to before the call, so one call is one change.
- [ ] **Step 4:** `scripts/test.sh --filter ToolpathToolsTests` → PASS.
- [ ] **Step 5:** Commit `feat(mcp): library and toolpath tools`.

### Task 8: Check and output tools

**Files:** Create `Sources/LoftLineMCP/OutputTools.swift`; test `Tests/LoftLineMCPTests/OutputToolsTests.swift`.

**Interfaces:** Consumes `PostingContext`, `postAll`, `post(scope:…)`, `jobSheetHTML`, `checkReport` (Task 1), `AssistantAccess.folder`.
Produces tools `check {post_id?, group_by_tool?, side?}`, `post_gcode {folder, mode: one_file|per_toolpath|per_tool|toolpath, toolpath_id?, post_id?, group_by_tool?, side?, replace?, job_sheet? = true}`,
`job_sheet {path, post_id?, group_by_tool?, side?, replace?}`. Every `post_gcode` reply starts with the operator summary:
machine, post, units, material, Z zero, deepest cut, time, tool changes, pauses, files written, job sheet path.
Descriptions of `check` and `post_gcode` contain: "LoftLine checks every program and never writes one with an error. Show the
user the summary and the job sheet; they check the program and do an air cut before cutting."

- [ ] **Step 1: Write the failing tests:**
  - `postingTheSampleMatchesExpectedForEveryBuiltInPost`: for each built-in post id, open `samples/sign.loftline`, `post_gcode`
    `one_file` → written bytes equal `samples/expected/<id>/sign.*`.
  - `aProgramWithAnErrorWritesNothing` (flute length 0.01 → reply `isError`, folder empty).
  - `aMissingPostWritesNothing` (postProfileID "gone-post").
  - `aFolderSwappedForALinkIsRefused`: a `GCodeFileSet.FileOperations` test seam replaces the folder with a link between
    open and write → error, nothing written outside (as `GCodeFileSetTests` does).
  - `anExistingFileNeedsReplace`; `theJobSheetBesideTheProgramUsesItsContext` (per_tool + group_by_tool → sheet steps in program order).
  - `theBottomSideIsPostedAlone` (two-sided project, `side: "bottom"` → only bottom toolpaths; sheet says "(Bottom side)").
  - `checkReportsWhatTheMacReports` (vector outside the material → that warning; nothing written).
- [ ] **Step 2:** `scripts/test.sh --filter OutputToolsTests` → FAIL.
- [ ] **Step 3:** Implement; all writes are one `GCodeFileSet` (program files + job sheet) written with
  `write(to: folder, replacing:)`, so the set is all or nothing.
- [ ] **Step 4:** `scripts/test.sh --filter OutputToolsTests` → PASS; `scripts/check-samples.sh` → 48 match.
- [ ] **Step 5:** Commit `feat(mcp): check, post and job sheet tools`.

### Task 9: The 2D picture

**Files:** Create `Sources/LoftLineMCP/DesignPreview.swift`, `Sources/LoftLineMCP/PreviewTool.swift`; test
`Tests/LoftLineMCPTests/DesignPreviewTests.swift`.

**Interfaces — Produces:** `struct DesignPreview { static func png(project: LoftLineProject, toolpaths: [Toolpath], width: Int, height: Int) throws -> Data }`
— RGBA buffer, scanline polygon fill (even-odd) and 1 px lines (Bresenham), material `#F3E7CF`, vectors in their layer colour,
toolpath lines `#2B6CB0`, clamps hatched `#B00000` on `#F8D7D3`, origin cross red; encoded with
`RasterCodec.png(width:height:samples:components: 4)`. Tool `preview {width? = 1024, height? = 768, show_toolpaths? = true}`
returns `ToolOutput(text: "<w>x<h> picture of <name>", image: png)`.

- [ ] **Step 1: Write the failing tests:** `thePictureDecodesAtTheAskedSize` (`RasterCodec.info` → 800 × 600);
  `materialAndAClampAreWhereTheyShouldBe` (pixel at the material's centre is material colour; a pixel inside a clamp is hatch or
  fill colour); `anOverLargePictureIsRefusedBeforeAllocating` (5,000 × 10 → error; 3,000 × 3,000 → error).
- [ ] **Step 2:** `scripts/test.sh --filter DesignPreviewTests` → FAIL.
- [ ] **Step 3:** Implement.
- [ ] **Step 4:** `scripts/test.sh --filter DesignPreviewTests` → PASS.
- [ ] **Step 5:** Commit `feat(mcp): a PNG of the 2D design`.

### Task 10: Help for assistants

**Files:** Modify `Sources/LoftLineKit/HelpTopics.swift` (case `assistant`); create `Sources/LoftLineMCP/HelpTool.swift`;
test `Tests/LoftLineMCPTests/HelpToolTests.swift`.

- [ ] **Step 1: Write the failing tests:** `helpListsTopicsAndReturnsOne` (`help {}` → ids include "assistant" and "pocket";
  `help {topic: "pocket"}` → body); `theAssistantTopicStatesTheRules` (contains "never writes a program with an error",
  "allowed folders", "air cut").
- [ ] **Step 2:** `scripts/test.sh --filter HelpToolTests` → FAIL.
- [ ] **Step 3:** Add `HelpTopic.assistant` ("Connecting an AI assistant": what it can do, the setup config, allowed folders,
  the safety rules) and the `help` tool over `HelpTopic.allCases`.
- [ ] **Step 4:** `scripts/test.sh --filter 'HelpToolTests|HelpTopicsTests'` → PASS.
- [ ] **Step 5:** Commit `feat(mcp): help for assistants`.

### Task 11: Bundling, CI and the smoke test

**Files:** Modify `scripts/bundle.sh`, `scripts/check-bundle.sh`, `desktop/src-tauri/tauri.conf.json` (`externalBin` adds
`binaries/loftline-mcp`), `.github/workflows/platforms.yml` (desktop job copies `loftline-mcp` beside `loftline-core`),
`scripts/linux-desktop.sh`; create `scripts/mcp-smoke.sh`.

- [ ] **Step 1:** `scripts/mcp-smoke.sh [binary]`: pipes initialize, tools/list, `new_project`, `add_shapes` (one rectangle),
  `add_toolpath` (profile), `post_gcode` into a temp allowed folder (settings file via `LOFTLINE_ASSISTANT_SETTINGS` env, read by
  `AssistantSettings.fileURL` when set), and checks: 6 replies, no `"error"`, a `.tap` file exists. Run it → FAIL (no binary flag yet).
- [ ] **Step 2:** `bundle.sh` builds `loftline-mcp` release and copies it to `LoftLine.app/Contents/MacOS/loftline-mcp`, signed
  with the app; `check-bundle.sh` runs `mcp-smoke.sh` on the bundled binary.
- [ ] **Step 3:** Desktop: build and copy the sidecar in CI and `linux-desktop.sh`; add it to `externalBin`.
- [ ] **Step 4:** `scripts/mcp-smoke.sh .build/debug/loftline-mcp` → PASS; `scripts/check-bundle.sh` → passes.
- [ ] **Step 5:** Commit `build(mcp): bundle loftline-mcp with the Mac app and the desktop installers`.

### Task 12: Mac: Connect an AI Assistant…

**Files:** Create `Sources/LoftLineApp/Panels/AssistantSetupSheet.swift`, `harness/scenarios/assistant-setup.json`; modify
`Sources/LoftLineApp/App/LoftLineCommands.swift` (Help menu item), the app's sheet enum and `HarnessScenario.sheets`.

- [ ] **Step 1:** Test (app tests): `AssistantSetupTests.theConfigNamesTheBundledServer` — `AssistantSetup.config(serverPath:)`
  returns `{"mcpServers":{"loftline":{"command":"<path>"}}}` and `claudeCodeLine(serverPath:)` returns
  `claude mcp add loftline -- "<path>"`. Run → FAIL.
- [ ] **Step 2:** Implement `AssistantSetup` (in `LoftLineMCP`, so the desktop text matches) and the sheet: server path
  (`Bundle.main.executableURL` sibling), both configs with Copy buttons, the allowed folders list with Add…/Remove (writes
  `assistant.json`), a link to the help topic. Nothing writes an assistant's config.
- [ ] **Step 3:** `scripts/test.sh --filter AssistantSetupTests` → PASS; `scripts/ui.sh assistant-setup --light` → look at the PNG.
- [ ] **Step 4:** Commit `feat(app): Help > Connect an AI Assistant…`.

### Task 13: Desktop: Connect an AI Assistant…

**Files:** Modify `desktop/src/main.ts` (Help menu), create `desktop/src/assistant.ts`; core request `assistantSetup`
(returns `AssistantSetup` texts and the settings) and `setAssistantFolders {folders}` in `CoreService`; test in
`Tests/LoftLineKitTests/CoreServiceTests.swift` and `desktop/tools/e2e.mjs`.

- [ ] **Step 1:** Tests: `assistantFoldersRoundTrip` (core sets and reads `assistant.json` in a temp support folder);
  e2e section "assistant": the dialog shows the sidecar path and a Copy button. Run → FAIL.
- [ ] **Step 2:** Implement the requests and the dialog (folder picker through Tauri's dialog plugin).
- [ ] **Step 3:** `scripts/test.sh --filter CoreServiceTests` → PASS; `desktop/tools/e2e.mjs` → all checks passed.
- [ ] **Step 4:** Commit `feat(desktop): Connect an AI Assistant…`.

### Task 14: Docs

**Files:** `docs/PARITY.md` (row `app-assistant`), `docs/DECISIONS.md` (in-process engine; task-level tools; allowed folders;
no force option; both protocol generations), `docs/PLATFORMS.md` (same on all three; desktop setup dialog), `README.md`
(a short "AI assistants" section with the config), `TESTING.md` (connect Claude Code to the bundled server, make and post a sign,
compare with the app's program).

- [ ] **Step 1:** Write them; `scripts/test.sh` → all pass; `scripts/check-samples.sh` → 48 match.
- [ ] **Step 2:** Commit `docs: LoftLine MCP server`.
