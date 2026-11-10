# LoftLine MCP live link (spec 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An assistant connected to `loftline-mcp` can claim a window open in the Mac app or the desktop app (after the user
clicks Allow) and read, edit, calculate, post and save it, each edit one Undo step, with a review marker kept until Dismiss.

**Architecture:**
- **Link code.** One Swift link in `LoftLineMCP`: `LinkSocket`, `LinkServer`, `ClaimBook`, `LinkToolKind`, `AssistantRunner`
  and `LinkClient`.
- **Hosts.** Hosted in process by the Mac app and on a listener thread by `loftline-core`.
- **Mac.** Edits, posts and saves each run in one main-thread turn. Nothing comes back from a copy except an edit's project.
- **Desktop.** The core is serial and refuses stale front-end requests by `changeRevision`.

**Tech Stack:**
- Swift 6 tools.
- SwiftPM only.
- swift-testing.
- POSIX/WinSDK sockets.
- SwiftUI/AppKit (Mac).
- TypeScript (desktop front end).

**Spec:** `docs/superpowers/specs/2026-11-10-loftline-mcp-live-design.md` (bd7139f). Read it with this plan; it is the authority.

## Global Constraints

- **Toolchain.**
  - Build with `scripts/build.sh` and test with `scripts/test.sh` only. Judge a run by its `Test run with N tests ... passed`
    line.
  - Don't write a source file and run tests in the same shell command.
  - No new package dependency: no Swift package, no Cargo crate. Tauri (`desktop/src-tauri`) is unchanged.
- **Safety.** Every program passes `GCodeValidator` or is not written. G-code and job sheets go only into allowed folders,
  through `AssistantWriter`. Nothing talks to the machine. `samples/expected` doesn't change.
- **Socket.** `link/assistant.sock` in the folder holding `assistant.json` (`AssistantSettings.fileURL`).
  - Folder 0700; bind under `umask(0077)`.
  - Paths over 103 UTF-8 bytes are refused.
  - Request lines up to 64 MiB; replies uncapped.
  - At most 4 connections; an unclaimed connection idle for 30 s is closed.
  - The claim wait is 120 s. The Mac busy retry runs at most 10 passes.
- **Copy.** Strings are verbatim from the spec. These are exact:
  - "Undo is yours: Edit ▸ Undo in LoftLine takes back the assistant's steps."
  - "Use File ▸ Save As in LoftLine."
  - "LoftLine is busy; try again."
  - "LoftLine closed the link (it quit, or its engine restarted); claim the document again."
  - "Another LoftLine is already listening."
  - "The assistant changed this; make your change again."
  - "An assistant changed this document (N changes); review before posting".
  - "Changed by an assistant (N changes)".
- **Base.** Work on `feat/mcp-live`, branched from `docs/mcp-live-spec`. `fix/mcp-minors` (unmerged) drops `LoftLineMCP` from
  `LoftLineApp`; this work keeps that dependency. On a merge conflict in `Package.swift`, keep it.
- **Stop conditions.**
  - Ask Sean before any push. Task 1 needs one for Windows CI.
  - If Task 1 fails, stop and bring the named-pipe option to Sean.

## Review Focus

1. A user typing in the Mac inspector while an assistant edit lands: their keystrokes survive (Task 11's same-turn test).
2. An oversize `add_shapes` over the link: the call is refused before sending and the claim survives (Task 8).
3. A desktop user edit sent just after an assistant's toolpath-only change, even after release: refused and refetched (Task 9).
4. A file reopened after quit with an undismissed marker: the bar and the Check Toolpaths warning come back (Task 10).
5. A second LoftLine, or a stale socket file from a crash: the live one is never unlinked; the stale one is replaced (Task 5).

---

### Task 1: Spike: Windows AF_UNIX from Swift

**Files:**
- Create: `Sources/LoftLineMCP/Link/LinkSocketWindows.swift` (`#if os(Windows)`)
- Test: `Tests/LoftLineMCPTests/LinkSocketWindowsTests.swift` (`#if os(Windows)`)

**Interfaces:**
- Produces: `LinkSocketWindows.makeFolder(_ url: URL) throws`, `listen(at:) throws -> Int32`, `connect(to:) throws -> Int32`,
  and `peerSID(of fd: Int32) throws -> String` (via `SIO_AF_UNIX_GETPEERPID`, `OpenProcess`, token user).

- [ ] **Step 1: Write the test `windowsLinkRoundTrip`.** In a temp folder whose name contains `é`, it:
  - makes `link\` with a protected DACL: owner the current SID, ACEs for that SID and SYSTEM only;
  - binds `assistant.sock`, connects, and sends and echoes one line;
  - checks `peerSID` equals the current SID on both ends;
  - closes the listener, sees connect refused, `DeleteFileW`s the file, and binds again.
- [ ] **Step 2:** Implement with WinSDK (`WinSock2`, `afunix.h` constants by value if the module lacks them).
- [ ] **Step 3: Ask Sean to approve pushing `feat/mcp-live`.** Run `gh run watch` on the "Windows and Linux" workflow.
  Expected: `windowsLinkRoundTrip` passes on `windows-2022`. **If it fails, stop and ask Sean about the named pipe.**
  Tasks 2–4 don't depend on it and can proceed while CI runs.
- [ ] **Step 4:** Commit `spike(mcp): AF_UNIX link socket on Windows`. Ledger the result.

### Task 2: Spike: find the NSDocument behind a Mac window and save through it

**Files:**
- Create: `Sources/LoftLineApp/Assistant/DocumentLocator.swift`
- Modify: `Sources/LoftLineApp/Harness/HarnessScenario.swift`, `UIHarness.swift` (op `assistantSave`)
- Create: `harness/scenarios/assistant-save.json`

**Interfaces:**
- Produces: `DocumentLocator.nsDocument(for doc: LoftLineDocument) -> NSDocument?`. It matches
  `NSDocumentController.shared.document(for: fileURL)`, else a document whose window's undo manager `=== doc.undoManager`.
- Produces: `DocumentLocator.save(_ doc: LoftLineDocument) async throws`. It calls
  `save(to:ofType:for: .saveOperation, completionHandler:)`, then `doc.confirmSave()`.

- [ ] **Step 1:** Write the scenario. It opens `samples/sign.loftline` copied into the harness HOME, edits it (move a shape), then
  runs `assistantSave`. The op logs `located=<bool> confirmed=<bool> dirty=<bool> recovery=<bool>`.
- [ ] **Step 2:** Run `scripts/ui.sh assistant-save --light` outside the sandbox.
  Expected log: `located=true confirmed=true dirty=false recovery=false`, and the file's bytes equal those of a ⌘S save
  (compare after a second scenario step that runs ⌘S).
- [ ] **Step 3: If `located=false`,** ledger `Ruling: Mac save_project refused ("Use File ▸ Save in LoftLine")` and continue.
- [ ] **Step 4:** Commit `spike(app): save a window's document for the assistant`.

### Task 3: Settings: `liveLink`

**Files:**
- Modify: `Sources/LoftLineKit/AssistantSettings.swift`, `Sources/LoftLineKit/CoreService.swift` (`assistantSetup`,
  `setAssistantFolders`, new `setAssistantLink`), `Sources/LoftLineApp/Panels/AssistantSetupView.swift` (`change`)
- Test: `Tests/LoftLineKitTests/CoreAssistantTests.swift`

**Interfaces:**
- Produces: `AssistantSettings.liveLink: Bool` (default false); `AssistantSettings.linkFolder: URL`
  (`fileURL.deletingLastPathComponent()/link`); the core request `setAssistantLink {on: Bool}`; `assistantSetup` gains
  `liveLink`.

- [ ] **Step 1: Tests.**
  - `anOldSettingsFileKeepsItsFoldersAndIsOff`: `{"allowedFolders":["/x"]}` loads with folders `["/x"]` and `liveLink == false`.
  - `settingFoldersKeepsTheSwitch`: `setAssistantLink {on:true}`, then `setAssistantFolders`, then `liveLink == true`.
  - `aDamagedFileIsOff`.
- [ ] **Step 2:** Run `scripts/test.sh --filter CoreAssistantTests`. Expected: FAIL (no `liveLink`).
- [ ] **Step 3:** Implement. Use a custom `init(from:)` with `decodeIfPresent ?? false` and keep the memberwise
  `init(allowedFolders:liveLink: = false)`. Writers load, change one field and save. `AssistantSetupView.change` calls
  `AssistantSettings.load()` first.
- [ ] **Step 4:** Run it again. Expected: PASS. Commit `feat(mcp): the live-link switch in assistant settings`.

### Task 4: Snapshots, the runner, tool kinds

**Files:**
- Create: `Sources/LoftLineKit/CoreSnapshot.swift`, `Sources/LoftLineMCP/Link/AssistantRunner.swift`,
  `Sources/LoftLineMCP/Link/LinkToolKind.swift`
- Modify: `Sources/LoftLineKit/CoreSession.swift`, `Sources/LoftLineMCP/AssistantTools.swift`, `OutputTools.swift`,
  `ProjectTools.swift`, `ToolpathTools.swift`, `ToolSupport.swift`
- Test: `Tests/LoftLineMCPTests/AssistantRunnerTests.swift`

**Interfaces:**
- Produces: `public struct CoreSnapshot { project, savedProject, fileURL, activeSide, designRevision, library, profiles,
  machines, results }`.
- Produces: `CoreSession.init(snapshot:)`, `CoreSession.snapshot() -> CoreSnapshot`, and
  `CoreSession.changeRevision: Int`. `changeRevision` is bumped in `perform`, `undo`, `redo`, `newProject`, `open`, `save`, and
  on every write to `results`.
- Produces: `public typealias FileWriter = ([GCodeFileSet.File], URL, Bool, AssistantAccess) throws -> [URL]`, and
  `AssistantTools.all(service:access:writer: FileWriter = AssistantWriter.write)`.
- Produces: `public enum LinkToolKind { case edit, calculate, read, writeFiles, save, never }`, with
  `static func of(_ tool: String) -> LinkToolKind?` and `static func undoName(_ tool: String) -> String` (`"Assistant: <tool>"`).
- Produces: `public enum AssistantRunner { static func run(tool: String, arguments: [String: Any], snapshot: CoreSnapshot,
  access: AssistantAccess, writer: @escaping FileWriter = AssistantWriter.write) throws -> (output: ToolOutput,
  project: LoftLineProject) }`.
- Produces: `ToolpathTools.calculationRows(session:ids:) -> [[String: Any]]`, shared by both modes.

- [ ] **Step 1: Tests.**
  - `everyNameHasAKind`: `LinkToolKind.of` covers the 20 tool names. `new_project`, `open_project` and `undo` are `.never`.
  - `snapshotRoundTripKeepsFreshResultsFresh`: a calculated sign session, snapshot, then `init(snapshot:)`. `isStale` is false
    for every operation.
  - `runnerEditMatchesFileMode`: `add_shapes` through the runner gives the same project as file mode.
  - `runnerPostsTheShownSide`: a two-sided job showing the bottom gives bytes equal to `post(side: .bottom)`.
  - `changeRevisionMovesOnAToolpathOnlyEdit`: `update_toolpath` moves `changeRevision` but not `designRevision`.
- [ ] **Step 2:** Run `scripts/test.sh --filter "AssistantRunnerTests"`. Expected: FAIL (types missing).
- [ ] **Step 3:** Implement. `OutputTools` writes through the injected `writer`, not `AssistantWriter.write`.
- [ ] **Step 4:** Run the filter, then the full `scripts/test.sh`. Expected: PASS. All 20 tools behave as before (the existing
  MCP suites pass).
- [ ] **Step 5:** Commit `feat(mcp): snapshots, a tool runner and tool kinds`.

### Task 5: The socket (Mac and Linux)

**Files:**
- Create: `Sources/LoftLineMCP/Link/LinkSocket.swift` (Unix; delegates to `LinkSocketWindows` on Windows)
- Test: `Tests/LoftLineMCPTests/LinkSocketTests.swift`

**Interfaces:**
- Produces: `public struct LinkSocket`. Its members:
  - `static func prepareFolder(_ url: URL) throws`;
  - `static func listen(at: URL) throws -> Int32`, which runs the stale-socket rule;
  - `static func connect(to: URL) throws -> Int32`;
  - `static var peerUID: (Int32) throws -> uid_t`, the test seam;
  - `static func readLine(_ fd: Int32, max: Int) throws -> Data?`;
  - `static func writeLine(_ fd: Int32, _ data: Data) throws`.
- Produces: `LinkError` cases with the spec's messages: `tooLong(path)`, `notPrivate(path)`, `alreadyListening`,
  `wrongPeer`.

- [ ] **Step 1: Tests.**
  - `folderMustBePrivate`: a 0755 folder is refused; a symlink is refused.
  - `pathOver103BytesIsRefused`, with a multibyte name counted in bytes.
  - `liveSocketIsNotUnlinked`: a second `listen` throws `alreadyListening`.
  - `staleSocketIsReplaced`: a socket file with no listener gets bound.
  - `peerWithAnotherUIDIsRefused`, through the seam.
  - `lineCapClosesNothingButReportsOversize`: `readLine(max:)` past the cap returns the oversize marker.
- [ ] **Step 2:** Run `scripts/test.sh --filter LinkSocketTests`. Expected: FAIL.
- [ ] **Step 3:** Implement with `socket(AF_UNIX)`, `lstat`, `umask(0o077)`, `getpeereid` (Darwin) or `SO_PEERCRED` (Linux).
- [ ] **Step 4:** Run it again. Expected: PASS. Commit `feat(mcp): the link socket`.

### Task 6: ClaimBook

**Files:**
- Create: `Sources/LoftLineMCP/Link/ClaimBook.swift`
- Test: `Tests/LoftLineMCPTests/ClaimBookTests.swift`

**Interfaces:**
- Produces: `public actor ClaimBook`. Its members:
  - `init(timeout: Duration = .seconds(120), onChange: @Sendable () -> Void)`;
  - `claim(_ doc: String, connection: Int) async -> ClaimResult`, where `ClaimResult` is `.allowed`, `.denied`, `.noAnswer`,
    `.taken`, `.alreadyAsking`, `.refusedAfterDeny` or `.closed`;
  - `answer(_ doc: String, allow: Bool)`;
  - `release(connection: Int)`;
  - `revoke(_ doc: String)`, for Disconnect, Revoke, window close and opening another file;
  - `revokeAll()`, for the switch going off;
  - the queries `asking: [String]`, `allowed: [String]` and `holder(of:) -> Int?`.

- [ ] **Step 1: Tests**, each one behaviour from the spec's Allow list.
  - `allowLetsTheClaimIn`.
  - `denyRefuses`.
  - `noAnswerAfterTimeout`, with a 50 ms timeout.
  - `oneQuestionAtATime`.
  - `refusedAfterDenyUntilRevokeAll`.
  - `allowedWindowSkipsTheQuestion`.
  - `revokeAsksAgain` and `revokeAllAsksAgain`.
  - `secondHolderIsTaken`.
  - `releaseKeepsAllow`.
- [ ] **Step 2:** Run `scripts/test.sh --filter ClaimBookTests`. Expected: FAIL.
- [ ] **Step 3:** Implement as an actor. Waits are continuations resumed by `answer` and the timeout.
- [ ] **Step 4:** Run it again. Expected: PASS. Commit `feat(mcp): claims and Allow`.

### Task 7: LinkServer and the protocol

**Files:**
- Create: `Sources/LoftLineMCP/Link/LinkServer.swift`, `Sources/LoftLineMCP/Link/LinkHost.swift`
- Test: `Tests/LoftLineMCPTests/LinkServerTests.swift` (a `FakeHost`)

**Interfaces:**
- Consumes: `LinkSocket` (Task 5), `ClaimBook` (Task 6), `LinkToolKind` (Task 4).
- Produces: `public protocol LinkHost`, as the spec gives it, plus `LinkCall { kind, tool, arguments, document }`.
- Produces: `public final class LinkServer`. Its members:
  - `init(folder: URL, host: LinkHost)`;
  - `start() throws` and `stop()`;
  - `release(document:reason:)`, which sends the `released` error and closes.

- [ ] **Step 1: Tests** (over a real socket in a temp folder).
  - `listAnswersThenCloses`.
  - `claimThenCallReachesTheHostWithItsKind`.
  - `neverAndUnknownToolsAreRefusedBeforeTheHost`.
  - `versionMismatchNamesTheOlderSide`, for both directions.
  - `fifthConnectionIsRefused`.
  - `idleUnclaimedConnectionCloses`, with the idle time injectable.
  - `oversizeRequestGetsAnErrorAndKeepsTheConnection`.
  - `nonObjectLineCloses`.
  - `newlineInsideArgumentsIsOneRequest`.
  - `releaseSendsReleasedWithTheReason`.
- [ ] **Step 2:** Run `scripts/test.sh --filter LinkServerTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. One reader thread per connection frames lines with no host lock held. Calls are serialised per
  connection.
- [ ] **Step 4:** Run it again. Expected: PASS. Commit `feat(mcp): the link server`.

### Task 8: The server's document mode

**Files:**
- Create: `Sources/LoftLineMCP/Link/LinkClient.swift`, `Sources/LoftLineMCP/DocumentTools.swift`
- Modify: `AssistantTools.swift` (22 tools; routing), `ProjectTools.swift` (`undo`/`save_project` descriptions, `new`/`open`
  release), `HelpTool.swift`, `MCPServer.swift` (instructions), `Tests/LoftLineMCPTests/HelpToolTests.swift` (count 22)
- Test: `Tests/LoftLineMCPTests/DocumentModeTests.swift` (against a `LinkServer` with `FakeHost`)

**Interfaces:**
- Produces: `LinkClient(folder:)`, with `list()`, `claim(_:)`, `call(_:_:)` and `close()`. It measures each encoded line
  against 64 MiB before sending.

- [ ] **Step 1: Tests.**
  - `listShowsNamesWithoutPaths`.
  - `useOpenDocumentRoutesLaterCalls`.
  - `twoWindowsWithOneNameAreRefusedWithIDs`.
  - `undoInDocumentModeSaysUndoIsYours`.
  - `openProjectReturnsToFileMode`.
  - `secondUseClosesTheFirstConnection`.
  - `closedLinkKeepsDocumentModeAndSaysWhy`, with the exact EOF message.
  - `oversizeCallIsRefusedBeforeSending`.
  - `nothingListeningNamesThePathTried`.
- [ ] **Step 2:** Run `scripts/test.sh --filter "DocumentModeTests|HelpToolTests"`. Expected: FAIL.
- [ ] **Step 3:** Implement the routing and the strings from the spec's table.
- [ ] **Step 4:** Run it again. Expected: PASS. Commit `feat(mcp): document mode in the server`.

### Task 9: The desktop core host

**Files:**
- Create: `Sources/loftline-core/CoreLinkHost.swift`
- Modify: `Sources/loftline-core/main.swift` (the lock, starting the listener), `Package.swift` (`loftline-core` gains
  `LoftLineMCP`), `Sources/LoftLineKit/CoreService.swift`
- Test: `Tests/LoftLineMCPTests/CoreLinkHostTests.swift` (the host type lives in a testable spot; move it to
  `Sources/LoftLineMCP/Link/CoreLinkHost.swift` if the executable target can't be tested)

**Interfaces:**
- Consumes: Tasks 4–7.
- Produces, in `CoreService`:
  - the envelope gains `rev: Int?`;
  - `handle` refuses a stale `rev` with the error code `stale`;
  - new requests `assistantStatus` (`{changeRevision, claimed, asking, allowed, changes}`), `assistantAnswer {allow}`,
    `assistantDialog {open}` and `dismissAssistantMarker`;
  - `new`/`open` call the host's `documentChanged()`, which revokes.

- [ ] **Step 1: Tests.**
  - `claimAnsweredThroughStdinSucceeds`: the claim on a thread, `assistantAnswer` through `handle` within 100 ms.
  - `editIsOneUndoStep`.
  - `throwingEditLeavesSessionAndStacks`.
  - `inPlaceCalculateDoesNotDeadlock`.
  - `staleUpdateOperationIsRefusedAfterAToolpathOnlyEdit`, also after release, and for a stale `save` and `undo`.
  - `openWhileClaimedReleasesAndRevokes`.
  - `dialogOpenRefusesEdits`.
  - `saveAsWritesThroughAssistantWriter`.
- [ ] **Step 2:** Run `scripts/test.sh --filter CoreLinkHostTests`. Expected: FAIL.
- [ ] **Step 3:** Implement. The lock is taken only by the stdin loop and the listener's call path, never inside `handle`.
- [ ] **Step 4:** Run it again. Expected: PASS. Commit `feat(core): the live link in the desktop engine`.

### Task 10: The review marker

**Files:**
- Create: `Sources/LoftLineKit/ReviewMarkerStore.swift`
- Modify: `Sources/LoftLineKit/ValidationReport.swift` (a warning row from a count)
- Test: `Tests/LoftLineKitTests/ReviewMarkerStoreTests.swift`

**Interfaces:**
- Produces: `public struct ReviewMarkerStore`. Its members:
  - `init(file: URL)` (`review.json` beside `assistant.json`);
  - `count(for: URL) -> Int`;
  - `add(_ n: Int, for: URL)`;
  - `move(from: URL, to: URL)`;
  - `dismiss(_ url: URL)`.
  Keys are real paths.
- Produces: `ValidationReport.make(..., assistantChanges: Int = 0)`. It adds the warning
  "Changed by an assistant (N changes)" when the count is above 0.

- [ ] **Step 1: Tests.**
  - `countSurvivesANewStore`, the reopen case.
  - `dismissRemoves`.
  - `moveFollowsSaveAs`.
  - `realPathKeysThroughALink`.
  - `reportCarriesTheWarning`.
  - `zeroAddsNoWarning`.
- [ ] **Step 2:** Run `scripts/test.sh --filter ReviewMarkerStoreTests`. Expected: FAIL. Implement, then run again.
  Expected: PASS.
- [ ] **Step 3:** Wire it into the core host (Task 9): edits add to the store, `dismissAssistantMarker` dismisses, Save As moves
  the record, and `checkReport` passes the count. Add `coreMarkerSurvivesAssistantAndUserSave` to `CoreLinkHostTests`.
- [ ] **Step 4:** Run the full `scripts/test.sh`. Expected: PASS. Commit `feat(mcp): the review marker`.

### Task 11: The Mac host

**Files:**
- Create: `Sources/LoftLineApp/Assistant/MacLinkHost.swift`
- Modify: `Sources/LoftLineApp/App/LoftLineDocument.swift` (`linkID`, `perform(_:pending:_:)` overload, `assistantChanges`),
  `AssistantSetupView.swift` (the switch starts or stops the server)
- Test: `Tests/LoftLineAppTests/MacLinkHostTests.swift`

**Interfaces:**
- Consumes: Tasks 2, 4, 6, 7, 10.
- Produces: `MacLinkHost.shared` with `register(_ doc:)`, `unregister(_:)` and `setSwitch(_ on: Bool)`. Calls follow the
  spec's Mac host sections (edit, calculate, write files, read, save).

- [ ] **Step 1: Tests.**
  - `editIsOneUndoStepAndUndoRestores`.
  - `editRefusedUnderASheet`.
  - `editKeepsPendingExpressions`.
  - `oneSidedEditResetsTheSide`.
  - `sameTurnEditKeepsALiveInspectorEdit`: `updateOperationLive` twice, then an assistant edit; the live value survives.
  - `userActionAfterTheApplyIsItsOwnStep`, under a running run loop (`RunLoop.main.run(until:)`).
  - `busyRetryStopsAfterTenPasses`.
  - `postCalculatesFirstAndMatchesExport`.
  - `calculateCoversEveryEnabledToolpath`.
  - `saveOutsideAllowedFolderRefused`, plus `saveAsAndUntitledRefused`.
  - `markerSurvivesAutosaveAndTick`.
- [ ] **Step 2:** Run `scripts/test.sh --filter MacLinkHostTests`. Expected: FAIL.
- [ ] **Step 3:** Implement per the spec.
  - `groupsByEvent` is off only around the apply.
  - Retries use `RunLoop.main.perform`.
  - Save uses `DocumentLocator` (Task 2), or refuses per its ruling.
- [ ] **Step 4:** Run it again, then the full suite. Expected: PASS. Commit `feat(app): the live link in the Mac app`.

### Task 12: Mac bars and the switch

**Files:**
- Create: `Sources/LoftLineApp/Assistant/AssistantBars.swift`
- Modify: the document window's content view (bars above the canvas), `AssistantSetupView.swift` (the switch toggle and its
  error text), `ValidationSheet.swift` (pass `assistantChanges`)
- Create: `harness/scenarios/assistant-live.json` (switch on, a fake claim asking, then allowed, then the marker)

- [ ] **Step 1:** Add the bars, with these accessibility labels:
  - Allow: "An assistant wants to work on <name>", with Allow and Deny;
  - working: Disconnect;
  - allowed: "Assistants allowed", with Revoke;
  - marker: Dismiss.
- [ ] **Step 2:** Run `scripts/ui.sh assistant-live --light` and `--dark`. Expected: each bar appears in the PNG with the exact
  copy, and in the `.ax.txt` tree as buttons.
- [ ] **Step 3:** Run `scripts/test.sh --filter "HarnessScenarioTests|AccessibilityNamesTests"`. Expected: PASS.
  Commit `feat(app): assistant bars and the live-link switch`.

### Task 13: Desktop front end

**Files:**
- Modify: `desktop/src/state.ts` (`apply()` stamps `rev`; refetch on `stale`), `desktop/src/sheets.ts` (the switch;
  `assistantDialog` acknowledged before a dialog shows), `desktop/src/main.ts` (the poll, bars), `desktop/src/model.ts`,
  `desktop/tools/e2e.mjs`

- [ ] **Step 1:** Implement the poll at 1 s while the switch is on, the bars, Dismiss, Revoke, and the stale refetch with
  "The assistant changed this; make your change again."
- [ ] **Step 2:** Extend `e2e.mjs`: switch on, a Node `net.connect` to the socket claims, answer Allow through the bar, an
  `add_shapes` call, then the canvas redraws and the marker shows.
- [ ] **Step 3:** Run `cd desktop && npx tsc --noEmit -p .`, then `scripts/linux-desktop.sh` (Docker, outside the sandbox).
  Expected: tsc exit 0; e2e passes.
- [ ] **Step 4:** Commit `feat(desktop): the live link`.

### Task 14: Smoke, docs, final gates

**Files:**
- Modify: `scripts/mcp-smoke.sh` (a document-mode step against the app under `scripts/ui.sh`, with
  `LOFTLINE_ASSISTANT_SETTINGS` set for both), `docs/DECISIONS.md`, `README.md`, `TESTING.md`, `docs/PARITY.md`,
  `docs/PLATFORMS.md`, `docs/UI-HARNESS.md`, `Sources/LoftLineKit/HelpTopics.swift`

- [ ] **Step 1:** Write the docs the spec's Docs section lists, each item as it says.
- [ ] **Step 2:** Run `scripts/build.sh`, `scripts/test.sh`, `scripts/check-samples.sh` and `scripts/mcp-smoke.sh`. Expected:
  all green, and `samples/expected` unchanged.
- [ ] **Step 3:** Commit `docs: the live link`. Then run the final review per ml:executing-plans.
