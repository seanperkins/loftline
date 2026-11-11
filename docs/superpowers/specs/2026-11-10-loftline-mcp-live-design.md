# LoftLine MCP server (spec 2 of 2: the open app)

Status: design approved in chat 2026-11-10. Reviewed by the panel (executor, auditor, Opus skeptic, simplifier, pentester) over
three rounds, with Sean's answers to six questions it raised. The round-3 findings are applied below and have not been
re-reviewed. Awaits Sean's review.

## Goal

With LoftLine open, an AI assistant works on a document on screen: the user watches each change land and can undo it.

Spec 1 (`2026-11-10-loftline-mcp-design.md`, merged as f59aa08) built the server and its tools over project files. This spec
adds a link from that same server into the running app: the Mac app, and the desktop app on Windows and Linux. It keeps every
rule of spec 1 that concerns programs:

- G-code goes only into allowed folders.
- A program with an error is never written.
- Nothing talks to the machine.

One rule of spec 1 is widened on purpose: a window the user allows can be read and edited wherever its file lives.

## Decisions (Sean, 2026-11-10)

| Question | Decision |
|---|---|
| How an edit lands | At once, as one Undo step per tool call. The window shows that an assistant is working on it |
| Which document | The assistant lists the open documents and picks one by name |
| Consent | A switch, off until the user turns it on (Help ▸ Connect an AI Assistant…). Plus an Allow click in the window when an assistant claims it. Allow belongs to the window and lasts until the window closes or opens another file, the app quits, or the user presses Disconnect or Revoke or turns the switch off |
| Which windows | Any open window can be claimed, wherever its file lives. The help and DECISIONS say so plainly. On the Mac, autosave writes its edits into that file |
| Saving | Save into allowed folders. Save As too on the desktop. On the Mac, Save As stays the user's, because writing behind the Mac document breaks its save tracking |
| Undo | The assistant's `undo` tool doesn't work on an open window: Undo is the user's (Edit ▸ Undo) |
| Review marker | After an assistant changes a document, a bar and a Check Toolpaths warning stay until the user clicks Dismiss. They are kept on disk, so autosave, quitting and reopening don't lose them. Saving doesn't clear them |
| Approach | A local socket into the app. The app runs the same tool code. One server configuration |

Assumption stated in chat and not corrected: when the app isn't running or the switch is off, the server keeps working on files
exactly as in spec 1.

## Architecture

```
assistant ──stdio── loftline-mcp ──(file mode)── its own CoreSession, as spec 1
                         │
                         └──(document mode)── LinkClient ══ local socket ══ LinkServer ── LinkHost
                                                                                         ├─ Mac app (in process)
                                                                                         └─ loftline-core (listener thread)
```

`LoftLineMCP` holds all the link logic that both hosts share.

| Piece | Does |
|---|---|
| `LinkServer` | Framing, the version check, the request and connection caps, the idle timeout. It classifies each call by the tool-kind table and refuses Never and unknown names before a host sees them |
| `ClaimBook` | The one owner of claim and Allow state, per document: `idle`, `asking`, `allowed(holder?)`, `denied`. It holds the 120 s wait, "already asking", "taken", the after-Deny latch and revocation. An actor, so no host lock is held across a wait |
| `LinkToolKind` | The table below. It also gives the Undo step's name |
| `AssistantRunner` | Runs one tool on a `CoreSnapshot`, for both hosts |
| `LinkClient` | What the server's tools use |

The host draws the bars and forwards clicks to the `ClaimBook`. It runs calls by kind:

```swift
public protocol LinkHost: AnyObject {
    func documents() -> [LinkDocument]                      // id, name, unsaved
    func run(_ call: LinkCall) async throws -> ToolOutput    // LinkCall: kind, tool, arguments, document
    var claims: ClaimBook { get }                            // the host calls answer, revoke and revokeAll on it
}
```

`AssistantRunner.run(tool:arguments:snapshot:access:)` works in four steps:

1. Build a `CoreSession` from the snapshot.
2. Wrap it in a `CoreService`.
3. Build `AssistantTools.all(service:access:)` over it. Every tool closes over its service's session, so the tools are
   built per call. They write through `AssistantWriter`, as in file mode.
4. Run the named tool exactly as file mode does.

`CoreSnapshot` holds:

- the project;
- the saved baseline, for the unsaved flag;
- `fileURL`;
- the shown side;
- `designRevision`;
- the tool library, posts and machines;
- the results the source calls fresh.

`CoreSession.init(snapshot:)` takes them as they are, so its `isStale` agrees with the source's. Nothing comes back from a copy
except the project of an edit.

`loftline-core` gains a `LoftLineMCP` dependency. `LoftLineApp` has one on main, and `fix/mcp-minors` drops it; this work keeps
it. Tauri (`desktop/src-tauri/src/main.rs`) is unchanged: it never sees link traffic.

### The switch

`AssistantSettings` gains `liveLink: Bool`. Decoding uses `decodeIfPresent(...) ?? false`, so an existing
`{"allowedFolders":[…]}` keeps its folders and reads as off. A damaged file allows no folders and reads as off. The memberwise
`init(allowedFolders:)` stays, with `liveLink` defaulting to false.

Every writer loads the file, changes one field and saves:

- the core's `setAssistantFolders`, which today builds a new value from the folders alone;
- a new `setAssistantLink {on}`;
- the Mac's `AssistantSetupView.change`, which today saves the copy it loaded when it opened.

`assistantSetup` replies with `liveLink`, and the desktop's `AssistantSetup` interface and Help window gain the switch.

The host reads the switch at launch. Its own switch (the Help view on the Mac, `setAssistantLink` on the desktop) starts or
stops the listener directly. An edit of the file by anything else takes effect at the next launch.

The switch is a convenience, not the security control. The file is the user's, and an assistant with a shell can write it. The
control is the Allow click. Allow in turn doesn't stop an assistant that can drive the UI itself (`xdotool` on X11, or a terminal
holding macOS Accessibility permission). DECISIONS records both, and that spec 1's `allowedFolders` has the same property.

### The listener

One rule on every platform: the socket is `link/assistant.sock` in the folder that holds `assistant.json`
(`AssistantSettings.fileURL`). The existing `LOFTLINE_ASSISTANT_SETTINGS` override moves it too, for tests, the UI harness
(whose HOME makes the default too long) and the smoke test.

| Platform | Transport | Default path |
|---|---|---|
| Mac | Unix socket | `~/Library/Application Support/LoftLine/link/assistant.sock` (64 bytes + the user name) |
| Linux | Unix socket | `~/.local/share/LoftLine/link/assistant.sock` (48 + the user name), or under `$XDG_DATA_HOME` when set |
| Windows | AF_UNIX socket (Windows 10 1803+) | `%LOCALAPPDATA%\LoftLine\link\assistant.sock` |

An app and an assistant started with different `XDG_DATA_HOME` look in different places. PLATFORMS says so, and
`list_open_documents` names the path it tried when nothing answers.

Unix rules, on Mac and Linux:

- **The folder.** `link/` is a subfolder made for this, so the support folder keeps its mode. The host creates it 0700, `lstat`s
  it, and refuses unless it is a real directory owned by `getuid()` with mode 0700. It binds under `umask(0077)`.
- **Path length.** Paths are measured in UTF-8 bytes. Over 103 is refused, with the path in the message. 103 is the Mac's
  limit; Linux allows 107, and 103 is used everywhere on purpose.
- **A socket left by a crash.** The host tries to connect first. Refused means it unlinks and binds. Answered means another
  LoftLine owns it, and the switch shows "Another LoftLine is already listening."
- **Peer checks.** Both sides check the other end on the connected socket: `getpeereid` on the Mac, `SO_PEERCRED` on Linux. A
  peer whose uid isn't the user's is refused. The client also checks the socket file's owner before connecting, only for a
  clearer error. The peer-credential call sits behind a seam, so a test can feed another uid.

Windows is the plan's first task, a spike: AF_UNIX from Swift through WinSDK. It passes only if all of these work:

- the `link` folder is created with an explicit, protected DACL: owner the user's SID, access only for that SID and SYSTEM;
- the host and the client each check the other end with `SIO_AF_UNIX_GETPEERPID`, `OpenProcess`, and the process token's user
  SID compared with their own;
- the stale-socket rule, using `DeleteFileW`;
- a profile path with non-ASCII characters.

If it fails, the plan stops and brings the named-pipe option to Sean. That option needs first-instance and reject-remote-clients
flags, a DACL, identification-level client access, and a check of the server's SID.

### The link protocol

Newline-delimited JSON. The listener reads and frames each line on its own thread, before any host lock.

**Limits.**

- **Requests.** A request line may be up to 64 MiB, above the tools' own bounds: `add_shapes`, and the 50 MiB import cap. Over
  that, the host answers with an error line and keeps the connection. The server measures each encoded line before sending
  and refuses an oversize call itself, so the claim survives.
- **Bad lines.** A line that isn't a JSON object closes the connection.
- **Replies.** Uncapped. A 4096 × 1953 preview is about 32 MB of base64.
- **Connections.** At most 4 open at once. A fifth gets an error line and is closed.
- **Idle connections.** One that holds no claim and sends nothing for 30 s is closed.
- **`list`.** Answered, then the connection is closed. A claiming connection stays open.

| Request | Reply |
|---|---|
| `{"v":1,"op":"list"}` | `{"documents":[{"id","name","unsaved","claimed"}]}`, then close |
| `{"v":1,"op":"claim","document":id}` | `{}`, or an error; waits up to 120 s for the user's answer |
| `{"v":1,"op":"call","tool":name,"arguments":{…}}` | `{"text":…, "image":<base64 PNG>?}`, or an error |
| any error | `{"error":{"code":…, "message":…}}` |

**Versions.** `v` is the link version. A mismatch names the older side:

- "This LoftLine is older than its assistant server; update LoftLine."
- "The assistant server is older than this LoftLine; point the assistant at the server inside this LoftLine."

**Ending a claim.** A claim lasts while its connection is open. When the host ends one, it sends
`{"error":{"code":"released","message":…}}` with the reason, then closes. The reasons:

- the window closed;
- the window opened another file or a new project (desktop New, Open or recovery open);
- the switch went off;
- Disconnect;
- Revoke.

When the connection simply ends (the app quit, or the desktop engine crashed), the server says "LoftLine closed the link (it
quit, or its engine restarted); claim the document again."

A second `use_open_document` from one server keeps the claim when it names the window already held, and otherwise closes its first
connection before claiming.

**Allow** (all in `ClaimBook`):

- A claim of a window shows a bar in it: "An assistant wants to work on <name>", with Allow and Deny.
- Allow belongs to that window, not to one assistant. It lasts until the window closes or opens another file, the app quits, or
  the user presses Disconnect or Revoke or turns the switch off. Until then, later claims of that window skip the question.
- While a window is allowed but unclaimed, it shows "Assistants allowed", with Revoke.
- Deny, or no answer in 120 s, refuses the claim and says which.
- One question per window at a time. A claim that arrives while one is pending gets "LoftLine is already asking."
- After Deny, that window refuses claims without asking until the user turns the switch off and on, or reopens the window.
- Only one connection holds a document. A second gets "Another assistant is working on <name>."
- A Mac window whose undo manager isn't attached yet can't be claimed.

**Names.** A document's name is its window's title ("Sign", "Untitled", "Untitled 2"). `use_open_document` takes a name or an
id. A name that two windows share is refused, with their ids. `list` carries no path; `describe_project` gives it after the
claim.

### Tool kinds

| Kind | Tools |
|---|---|
| Edit | `set_job`, `add_shapes`, `edit_shapes`, `import_file`, `edit_layers`, `add_toolpath`, `update_toolpath`, `delete_toolpath` |
| Calculate | `calculate` |
| Read | `describe_project`, `list_library`, `check`, `preview`, `help` |
| Write files | `post_gcode`, `job_sheet` |
| Save | `save_project` |
| Never | `new_project`, `open_project`, `undo` |

The host switches on the kind and never compares tool names itself. The server handles the Never tools:

- `new_project` and `open_project` release the document and act in file mode.
- `undo` replies "Undo is yours: Edit ▸ Undo in LoftLine takes back the assistant's steps."

`calculate`'s reply rows (status, time, warnings) come from one function that both modes share. Its default is every enabled
toolpath, as in file mode.

### The guard

The host checks this before anything changes a window or writes a file for it. If any part fails, nothing changes and the reply
says which part.

1. The claim is held by this connection and allowed.
2. The switch is on.
3. The window is open.
4. No sheet, panel or alert is up: `presentedSheet == nil`, no attached sheet, no app-modal window. On the desktop, the front
   end opens a dialog only after the core has acknowledged `assistantDialog {open: true}`, and it sends `false` when it loads.

### The Mac host

Each `LoftLineDocument` gets a link id when its window attaches. The id isn't saved.

A helper finds the `NSDocument` behind a window: `NSDocumentController.shared.document(for: fileURL)` (as `FileThumbnail`
already does), else a match on the window's undo manager. The host uses it for the window's name and for Save. Finding it
reliably is a spike, beside the Windows one. If it fails, Mac `save_project` answers "Use File ▸ Save in LoftLine" and
nothing else changes.

**Edit.** One main-thread turn, so nothing interleaves with it: not a live inspector edit, not a Tool Database change, not a
side change.

1. Run the guard.
2. If `undoManager.groupingLevel != 0`, try again on the next run-loop pass (`RunLoop.main.perform`), at most 10 times, then
   reply "LoftLine is busy; try again."
3. Take the snapshot and run `AssistantRunner`.
4. Apply with `groupsByEvent` off for the step:
   - `perform("Assistant: <tool>", pending: [])`, a new overload of `perform`, so expressions the user typed for their own
     next edit are left alone;
   - then turn `groupsByEvent` back on, so a user action later in the same pass is its own step;
   - `replaceProject` bumps `editSerial`, which also ends live-edit merging. That is intended.
5. If the job became one-sided, reset the shown side to the top, as `CoreSession.replace` does.

The window recalculates as it does after any edit. A very large `import_file` holds the window, as the app's own Import does.

**Calculate.** Run the guard, then `await calculateUntilFresh(targets:)`, the app's own wait (up to five passes; used by Export,
Check, Tiling and Save All). Reply from the window's results.

**Write files** (`post_gcode`, `job_sheet`). The app's own Export does the same:

1. Run the guard.
2. `await calculateUntilFresh(targets:)`.
3. One main-thread turn: run the guard again, take the snapshot (its results are fresh, so the runner calculates nothing), and
   run the tool with the real `AssistantWriter`.

Nothing interleaves inside the turn, so no further change check is needed. The operator summary of spec 1 comes with every
program written.

**Read** (`check`, `preview`, `describe_project`, `list_library`, `help`).

1. `check` and `preview` first `await calculateUntilFresh`.
2. Take a snapshot on the main thread.
3. Run on a background queue. Nothing comes back.

**Save.** One main-thread turn:

1. Run the guard.
2. The window must have a file, and its real path must be inside an allowed folder, checked immediately before.
3. Save through the `NSDocument`: `save(to:ofType:for: .saveOperation, completionHandler:)`.
4. Call `confirmSave()` in the completion, so the window is clean and its recovery copy gone when the reply goes back.

A `path` argument, or an Untitled window, is refused: "Use File ▸ Save As in LoftLine." The document's own save isn't
folder-anchored; DECISIONS records the same-user race left between the check and the write.

### The desktop host

`loftline-core` gets one lock, taken only by its two callers, the stdin loop and the listener, around each request they hand to
`service.handle`. It is never taken inside `handle`, so tools that call the core through `CoreClient` don't re-enter it.

The core handles one request at a time, so nothing interleaves:

- **Edits:** run `AssistantRunner` on a snapshot of the core's own session, then
  `session.perform("Assistant: <tool>") { $0 = copy.project }`. A throw leaves the session untouched.
- **Calculate, reads and write files:** run in place on the session, as file mode does.
- **Save and Save As:** go through `CoreSession.save(to:writer:)` with `AssistantWriter`.
- **New, Open and recovery open:** the core's `new` and `open` end the claim ("the window opened another file") and reset the
  window's Allow and after-Deny latch.

**Stale front-end edits.** The core gets a `changeRevision`, bumped by every `perform`, undo, redo, new, open and save, and every
change to `results`.

- The request envelope gains an optional `rev`.
- The front end's `apply()` (`desktop/src/state.ts`), through which every state-changing request goes, including save, undo and
  redo, stamps the `changeRevision` it last saw. Plain reads through `call()` don't.
- `handle` refuses a request whose `rev` is present and older than the current `changeRevision`, before dispatch, whether or
  not anything is claimed. The front end then refetches and says "The assistant changed this; make your change again."
- This is needed because the front end sends whole operations built from what it last drew (`desktop/src/inspector.ts`, upserted
  whole by `updateOperation`), and `designRevision` doesn't move for toolpath edits.

**Polling.**

- While the switch is on, the front end polls `assistantStatus` once a second. The reply is
  `{changeRevision, claimed, asking, allowed, changes}`.
- It fetches `state` when `changeRevision` moves, shows the Allow bar when `asking` is set (`assistantAnswer {allow}`), and shows
  Revoke when `allowed` is set.
- `state` carries the same fields, so an edit refreshes them for free.

An assistant call holds the core like any request, so a long Calculate from the assistant makes the window wait, as the user's
own does. If the core crashes, the listener goes with it. The link's connection ends, and Tauri restarts the core as it does
today.

### The review marker

**Where it's kept.** A record in the support folder, `review.json`, keyed by the file's real path: `{changes, since}`.

- Each applied assistant edit adds one.
- A Save As by the assistant on the desktop moves the record to the new path.
- An Untitled window keeps the count in memory, and writes it to the record when the window first gets a file.
- Opening a file with a record shows the marker. So do autosave, quitting and reopening, and saving.
- Only Dismiss clears it: the bar's button on the Mac, `dismissAssistantMarker` on the desktop. Dismiss removes the record.
- A file moved or renamed outside LoftLine loses its record. DECISIONS says so.

**What the user sees.**

- **The Allow bar**, when an assistant claims a window.
- **While claimed:** "An assistant is working on this document", with Disconnect.
- **While allowed but unclaimed:** "Assistants allowed", with Revoke.
- **The marker:** "An assistant changed this document (N changes); review before posting", with Dismiss. Check Toolpaths lists
  the same as a warning, "Changed by an assistant (N changes)", on the Mac and the desktop. Warnings never block.
- **Edit ▸ Undo:** each change appears as "Assistant: <tool>".

### The server

`loftline-mcp` starts in file mode. Two new tools, 22 in all:

| Tool | Does |
|---|---|
| `list_open_documents` | Names, ids, unsaved flags, and whether another assistant holds each. Or why there are none: LoftLine isn't running at <path>, or the switch is off |
| `use_open_document` | Claims a document by name or id; the user clicks Allow. Later calls go to that window until `open_project` or `new_project` |

In document mode `describe_project` adds `"document"` and `"path"`. If the link ends, the next call fails with the reason. The
server stays in document mode until `open_project` or `new_project`, so an assistant never edits a file when it meant the
window.

Strings and tests that change with it:

| Where | Change |
|---|---|
| `save_project` description | In document mode, its own file must be in an allowed folder, and Save As is desktop-only |
| `undo` description | The document-mode reply |
| `help` | Covers the two new tools |
| `MCPServer` instructions ("Files are read and written only in the folders the user allows") | Name document mode |
| `AssistantSetupView.swift` and `desktop/src/sheets.ts` ("It reads and writes files only here.") | Name document mode |
| README | Name document mode |
| HelpTopic `assistant` | Name document mode |
| `HelpToolTests` | Its count of 20 becomes 22 |

## Safety

Programs: everything in spec 1 holds.

- They come from the checked exporter and pass `GCodeValidator`, or they are not written.
- G-code and job sheets are written only into allowed folders, through the folder-anchored writer.
- No tool sends anything to a machine.

In addition:

- **Reach.** Nothing is reachable from the network. The socket is in a folder only the user can open, and peers are checked by
  uid or SID on the connected socket. The listener is off by default.
- **Consent.**
  - An assistant reaches a window only after the user clicks Allow in it.
  - Disconnect, Revoke, the switch, and opening another file take the Allow back.
  - Once allowed, it can read and edit that window wherever its file lives, and on the Mac autosave writes those edits there.
    That is the user's choice per window, and the help says so.
  - Allow is not a guard against an assistant that can drive the UI, and DECISIONS says so.
- **No edit under the user.**
  - On the Mac, an edit, a post and a save each run in one main-thread turn.
  - On the desktop, the core is serial and stale front-end requests are refused.
  - Neither runs while a dialog is up or after the claim ended.
- **No stale toolpaths.** Results never come back from a copy. Programs are posted from the window's own fresh results, in the
  same turn that writes them.
- **Tool list.** The tool-kind table is enforced by the link before any host sees a call. `new_project`, `open_project` and
  `undo` never run over the link, and nothing off the socket reaches the core's other requests.
- **Review.** The review marker is kept on disk and clears only on Dismiss, so an assistant's changes are looked at before a
  cut, whatever was saved or autosaved meanwhile.

## Testing

| What | Test |
|---|---|
| Settings | An old `assistant.json` keeps its folders and reads as off. `setAssistantFolders` and the Mac view keep the switch. A damaged file is off |
| Runner | Each edit, read and write-files tool on a snapshot gives the same project and the same G-code bytes as file mode. A two-sided job showing the bottom posts the bottom, byte-identical to the window's Export. Seeded fresh results are used, not recalculated |
| ClaimBook | Against a fake host: Allow, Deny, 120 s with no answer, one question at a time, refused after Deny. Disconnect, Revoke, switch off, window close and opening another file revoke. A second holder is refused. Each host keeps one test that its click reaches `answer` |
| Mac edit | One Undo step per call. Undo restores the project. Refused under a sheet, an app-modal alert, and after Disconnect. Pending expressions are kept. A one-sided result resets the side. Under a running run loop, a user action before the apply and one after it in the same pass are each their own step. The busy retry stops after 10 passes |
| Mac post | A post calculates first, then writes the same bytes as the window's Export |
| Mac calculate | The window's own results come back fresh. The default covers every enabled toolpath |
| Mac save | Saves in an allowed folder with the same bytes as ⌘S. Afterwards the window is clean with no recovery copy, and a later live edit dirties it. Outside an allowed folder, a `path`, or Untitled: refused |
| Marker | Mac and desktop: it appears after an edit. It survives the assistant's save, a user save, an autosave (`.autosaveInPlaceOperation`), a recovery tick, and quit and reopen. Dismiss clears it and removes the record. Check Toolpaths shows the warning. An Untitled window's count reaches the record on its first save |
| Core | A claim answered through stdin during the wait succeeds well before 120 s. An in-place `calculate` over the link doesn't deadlock. A throwing edit leaves the session and both undo stacks as they were. After a toolpath-only assistant edit, a front-end `updateOperation` built from the earlier state is refused, even after the claim ends, as are a stale save and undo. `open` while claimed releases the claim and resets Allow. A dialog shows only after `assistantDialog` is acknowledged |
| Link | Round trip on Mac, Linux and Windows CI. Folder and socket checks. A live socket isn't unlinked; a stale one is. Another uid through the seam is refused. Nothing listens with the switch off. A different `v` names the older side. An oversize request gets an error and keeps the connection. The fifth connection is refused. An idle unclaimed connection is closed. A maximum-size `preview` comes through. `new_project`, `open_project`, `undo` and an unknown name sent straight to the socket are refused. Arguments holding a newline and another request change nothing. The released reply and EOF messages |
| Server | Both modes. Every refusal message. Two windows with one name. A second `use_open_document` closes the first connection. A closed window keeps document mode. 22 tools. An oversize call is refused before sending |
| Desktop | `desktop/tools/e2e.mjs` turns the switch on, answers Allow, edits through the socket from Node, and sees the window redraw and the marker appear |
| Smoke | `scripts/mcp-smoke.sh` gains a document-mode step against the app in a UI harness scenario, with `LOFTLINE_ASSISTANT_SETTINGS` set for both |

## Docs

- **DECISIONS** records:
  - the socket in Swift for both hosts, with claims and tool kinds in `LoftLineMCP`;
  - one main-thread turn for Mac edits, posts and saves, and nothing back from a copy;
  - the Allow click as the control, the switch as a convenience, and neither stopping a UI-driving assistant;
  - `allowedFolders` writable by an assistant with a shell;
  - any allowed window readable, and autosaved on the Mac wherever it lives;
  - no assistant undo in document mode;
  - Mac Save As user-only, and the race left in the document's own save;
  - the marker on disk, cleared only by Dismiss, and lost if the file is moved outside LoftLine.
- **README**: "AI assistants".
- **TESTING**: a manual step: Allow, edit, watch, Undo, the marker surviving a quit, Dismiss, Disconnect, Revoke.
- **PARITY**: `app-assistant`.
- **PLATFORMS**: the socket locations, `XDG_DATA_HOME`, and the Windows transport the spike chose.
- **UI-HARNESS**: the settings override moving the socket.
- **HelpTopic**: `assistant`.
- **THIRD_PARTY**: only if a dependency is added.

## Out of scope

- Telling the assistant about the user's edits as they happen; it reads again instead.
- Two assistants on one document at once.
- The selection: the assistant neither sees nor changes it.
- Any network listener.
- Anything that talks to the machine.
