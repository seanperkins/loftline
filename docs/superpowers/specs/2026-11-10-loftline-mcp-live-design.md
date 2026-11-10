# LoftLine MCP server (spec 2 of 2: the open app)

Status: design approved in chat 2026-11-10; awaits the review panel and Sean's review.

## Goal

With LoftLine open, an AI assistant works on a document on screen: the user watches each change land and can undo it. Spec 1
(`2026-11-10-loftline-mcp-design.md`, merged as f59aa08) built the server and its tools over project files. This spec adds a
link from that same server into the running app (the Mac app, and the desktop app on Windows and Linux) and keeps every rule
of spec 1: G-code only into allowed folders, never a program with an error, nothing that talks to the machine.

## Decisions (Sean, 2026-11-10)

| Question | Decision |
|---|---|
| How an edit lands | At once, as one Undo step per tool call; the window shows that an assistant is working on it |
| Which document | The assistant lists the open documents and picks one by name |
| Consent | Off until the user turns it on (a switch in Help ▸ Connect an AI Assistant…), then stays on |
| Saving | Save and Save As are allowed, into allowed folders only |
| Approach | A local socket into the app; the app runs the same tool code; one server configuration |

Assumption stated in chat and not corrected: when the app isn't running or the switch is off, the server keeps working on files
exactly as in spec 1.

## Architecture

```
assistant ──stdio── loftline-mcp ──(file mode)── its own CoreSession, as spec 1
                         │
                         └──(document mode)── local socket ── app ── AssistantRunner on a copy ── the open document
```

**The switch.** `AssistantSettings` gains `liveLink: Bool`, default false, kept in `assistant.json` beside `allowedFolders` and
edited from Help ▸ Connect an AI Assistant… ("Let assistants edit open documents") on both apps. A missing or damaged file
reads as off, as a damaged file already allows no folders.

**The listener.** Runs only while the switch is on; turning it off closes it and drops every link.

| Platform | Listener | Where |
|---|---|---|
| Mac | Unix socket, in the app | `~/Library/Application Support/LoftLine/assistant.sock`, folder mode 0700, socket 0600 |
| Linux | Unix socket, in the desktop app's Rust side | `$XDG_RUNTIME_DIR/loftline/assistant.sock` (0700/0600); the support folder when that variable is unset |
| Windows | Named pipe, in the desktop app's Rust side | `\\.\pipe\loftline-assistant-<user SID>`, its DACL granting only the current user |

A Unix socket path over 103 bytes is refused with a message naming the path, and the switch shows the error instead of turning
on. `LOFTLINE_ASSISTANT_SOCKET` overrides the path, for tests and the UI harness.

**The link protocol.** Newline-delimited JSON, one connection per claimed document, requests answered in order:

| Request | Reply |
|---|---|
| `{"v":1,"op":"list"}` | `{"documents":[{"id","name","path","unsaved","claimed"}]}` |
| `{"v":1,"op":"claim","document":id}` | `{}`, or an error when another link holds it |
| `{"v":1,"op":"call","tool":name,"arguments":{…}}` | `{"text","image"?}` (spec 1's `ToolOutput`), or an error |

`v` is the link version; a different one is refused with "LoftLine and its assistant server are different versions; update
LoftLine." A claim lasts while its connection is open. Closing the connection, the window or the switch, or pressing
Disconnect, releases it.

**AssistantRunner** (new, in `LoftLineMCP`). It runs one tool against a copy and reports what changed, so the Mac app and
`loftline-core` share one code path:

```swift
public struct AssistantRun { public var output: ToolOutput; public var project: LoftLineProject?; public var results: [UUID: ToolpathResult] }
public func run(tool: String, arguments: [String: Any], project: LoftLineProject, results: [UUID: ToolpathResult],
                access: AssistantAccess, toolStore: ToolLibraryStore, postStore: PostProfileStore,
                machineStore: MachineStore) throws -> AssistantRun
```

It builds a `CoreService` over a `CoreSession` that starts from `project` and `results`, runs the tool exactly as file mode
does, and returns the new project when it differs (nil when the tool only read). Files are written by this process, through
the same `AssistantAccess` checks as spec 1. The Mac app links `LoftLineMCP` again for this.

**Mac app.** Each `LoftLineDocument` gets a link id when its window opens (not saved). A call:

1. On the main thread: refuse if a sheet or dialog is open on that window ("Close the dialog in <name> first."); otherwise copy
   `project` and `results` and note `outputSerial`, the counter bumped whenever the project or a result changes.
2. On a background queue: `AssistantRunner.run`.
3. On the main thread: if `outputSerial` moved, apply nothing and reply "The document changed while the assistant worked; try
   again." Otherwise apply the project through `perform("Assistant: <tool>")` (one Undo step) and merge the results.

Reads (`describe_project`, `check`, `preview`, `help`, `list_library`) skip the dialog refusal and step 3.

**Desktop app.** Tauri owns the listener and passes each `call` to `loftline-core` as a new request,
`assistantCall {tool, arguments}`. The core runs `AssistantRunner` on a copy of its session, applies a changed project with one
`perform("Assistant: <tool>")`, and replies. Tauri then emits `assistant-changed`, and the front end fetches its state as it does after its own requests.
The desktop app has one document per window and one window, so `list` returns at most one document. A dialog open in the
window refuses edits as on the Mac; the front end tells the core when one opens and closes.

**Server modes.** `loftline-mcp` starts in file mode. Three new tools:

| Tool | Does |
|---|---|
| `list_open_documents` | Names, ids, paths, unsaved flags, and whether another assistant holds each; or why there are none (LoftLine isn't running, or the switch is off) |
| `use_open_document` | Claims a document by id or name; a name shared by two windows is refused with their ids. Later calls go to that window |
| `use_files` | Releases the document; later calls go to the server's own session |

`open_project` and `new_project` also release the document and act in file mode. In document mode the 20 tools of spec 1 keep
their names and arguments, and these change meaning:

| Tool | In document mode |
|---|---|
| `save_project` | Save writes the document's own file when it is inside an allowed folder, and clears the window's unsaved flag through the app's own save; otherwise it is refused with "Use Save As into an allowed folder." Save As (`path`) writes into an allowed folder and the window takes the new file, as Save As does |
| `undo` | Undoes the window's last step only when it is the assistant's ("Assistant: …"); otherwise "The last change is yours (<name>); undo it in LoftLine." |
| `describe_project` | Adds `"document": name` |

If the window closes, the switch goes off or the app quits, the next call fails with what happened and the server stays in
document mode until `use_files`, so an assistant can't edit files when it meant the window.

**What the user sees.** While a document is claimed, its window shows a bar: "An assistant is working on this document",
with Disconnect. Each change appears as it lands and is listed in Edit ▸ Undo as "Assistant: <tool>".

## Safety

Everything in spec 1's Safety section holds in document mode: programs come from the checked exporter and pass
`GCodeValidator` or are not written, reads and writes stay inside the allowed folders, and no tool sends anything to a machine.
In addition:

- The listener is off by default and only the current user can connect (permissions above). It never listens on a network port.
- A tool edits only the claimed document, one at a time, and never a document the user changed under it (step 3).
- An assistant can undo only its own steps.
- Files written in document mode are written by the app process, which checks the allowed folders itself; it doesn't trust the
  server to have checked.

## Testing

| What | Test |
|---|---|
| Runner | Each of the 20 tools through `AssistantRunner` gives the same project, and the same G-code bytes, as file mode; reads return a nil project |
| Mac document | One Undo step per call and Undo restores the project; the stale-copy refusal; the open-dialog refusal; results survive the round trip |
| Core | `assistantCall` applies one Undo step; the dialog refusal |
| Server | Switching modes; every refusal message; two documents with one name; a closed window keeps document mode |
| Link | Round trip over a Unix socket (Mac, Linux) and a named pipe (Windows CI); permissions; nothing listens with the switch off; a second claim is refused; a different `v` is refused |
| Desktop | `desktop/tools/e2e.mjs`: turn the switch on, edit through the pipe, the window redraws |
| Smoke | `scripts/mcp-smoke.sh` gains a document-mode step against the app under a UI harness scenario |

## Docs

DECISIONS (socket vs HTTP, the copy-and-apply runner, undo limited to the assistant's steps); README "AI assistants";
TESTING (a manual step: edit, watch, Undo, Disconnect); PARITY `app-assistant`; PLATFORMS (socket and pipe locations);
HelpTopic `assistant`.

## Out of scope

Telling the assistant about the user's edits as they happen (it reads again instead); two assistants on one document at once;
the selection (the assistant neither sees nor changes it); any network listener; anything that talks to the machine.
