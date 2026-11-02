# UI harness

A scripted way to look at the running app without a person (or an agent) driving the screen:
`scripts/ui.sh <scenario>` builds a debug LoftLine, runs a short list of steps against a real document
window, and writes PNGs and text dumps. It exists so a UI change can be checked in light and dark mode, at
any window size, in states that are tedious to reach by hand (a calculated job, a sheet open, a toolpath
selected), and so a reviewer can read the result as an image and as an accessibility tree.

```sh
scripts/ui.sh main                    # harness/scenarios/main.json
scripts/ui.sh toolpaths --light       # force light (or --dark) mode
scripts/ui.sh sheets --size 1000x640  # override the window's content size
scripts/ui.sh interact --key          # draw the window as key without taking your focus (see Clips)
scripts/ui.sh interact --active       # really activate the app (steals focus; table rows then take clicks)
scripts/ui.sh path/to/mine.json --out .tmp/ui/mine
scripts/ui.sh main -- -preview3D.showToolpaths '<false/>'   # everything after -- goes to the app as launch arguments
scripts/reel.sh reel-pause            # record harness/scenarios/reel-pause.json → docs/images/pause.{gif,mp4}
scripts/reel.sh all                   # every reel-*.json
```

Output goes to `.tmp/ui/<scenario>-<time>/` (git-ignored):

| File | What it is |
|---|---|
| `<name>.png` | The window as drawn, title bar and toolbar included, at 2x. Sheets are separate PNGs. |
| `<name>.ax.txt` | The accessibility tree: role, label, value, help, enabled state and the frame in window points (origin top left). This is what VoiceOver sees, and it shows real control sizes. |
| `<name>.menus.txt` | The menu bar: titles, enabled state and key equivalents for the current selection. |
| `harness.log` | The steps run and any error. |

## How it works

`LoftLine --ui-scenario file.json --ui-out dir` (debug builds only, `#if DEBUG`) skips the Welcome window,
the recovery timer and prompt, opens an untitled document, and runs the steps from inside the process
(`Sources/LoftLineApp/Harness/`). The window is drawn into a bitmap by the app itself, so **no Screen Recording
permission is needed**, the window does not have to be in front, and the display can be asleep. SwiftUI
only builds its accessibility nodes for an attached client, so the `.ax.txt` dump and the `press` step read
the app's own tree through the Accessibility API from a background thread; that needs your terminal to be
trusted for Accessibility (without it the dump lists only the window chrome and says so).

`scripts/ui.sh` gives each run its own `HOME` inside the output folder, so the app never reads or writes
your real tool library, recovery copies or window files. Preferences are the exception: macOS serves `UserDefaults`
through a daemon that does not follow `HOME`, so a run reads and writes the real defaults domain of the debug binary
(`LoftLine`, not `com.seanperkins.loftline`), including the one-time settings migration's copy of the old app's values. Set
`LOFTLINE_NO_MIGRATION=1` to skip the migration, and use launch arguments after `--` instead of `defaults write` to
change a setting for one run. A 90 s watchdog on its own thread ends a run that hangs once the harness has started; `scripts/ui.sh` stops one
that hangs before that (see the end of this page).

## Scenario format

```json
{
  "name": "profile inspector, light",
  "appearance": "light",
  "window": [1280, 820],
  "steps": [
    {"op": "sample", "name": "sign"},
    {"op": "tab", "value": "toolpaths"},
    {"op": "calculate"},
    {"op": "selectToolpath", "name": "Profile 1"},
    {"op": "expand", "name": "Last Pass"},
    {"op": "capture", "name": "profile"}
  ]
}
```

`appearance` is `light`, `dark` or `system`; `window` is the content size in points (the document window's
minimum is 1000 x 640). Steps run in order and the run stops at the first error, naming the step.

| op | arguments | does |
|---|---|---|
| `sample` | `name`: `sign` | loads the sample project into the document |
| `project` | `name`: a `.loftline` path relative to the repo root | loads that project; `harness/projects/` holds variants of the sample |
| `appearance` | `value`: light / dark / system | changes appearance mid-run |
| `size` | `size`: `[w, h]` | resizes the window |
| `mode` | `value`: 2d / split / 3d | centre view |
| `tab` | `value`: design / toolpaths | sidebar tab |
| `tool` | `value`: a canvas tool (`rectangle`, `nodeEdit`…) | active drawing tool |
| `select` | `names`: shape names | selects shapes |
| `selectToolpath` | `name` | selects a toolpath (and shows the Toolpaths tab) |
| `calculate` | | calculates all toolpaths and waits |
| `editTool` | `value`: `diameter`, `rename`, `number`, `describe` or `rpm` | edits the tool of the first toolpath in the Tool Database, as that window does while a sheet is open: `diameter` makes the toolpaths stale, `rename` only relabels them, `number` gives it another library tool's T number, `describe` gives it a description, `rpm` gives it a spindle speed no post runs |
| `editToolpath` | `value`: `deeper` or `tabs`; `name`: the toolpath (default the first) | `deeper` cuts a profile or pocket 0.5 below the material bottom, `tabs` turns on tabs as tall as a profile's cut; the toolpath form shows its warnings |
| `captureWindow` | `value`: a window's title (`Tool Database`), `name` | window PNG and accessibility tree of a window other than the document's; open it first with `press` on its toolbar button (`"name": "Tool Database", "value": "AXButton"`) |
| `selectTool` | `name`: a tool's name | selects that tool in the open Tool Database window (its list rows cannot be clicked) |
| `searchTools` | `value`: text | puts that text in the open Tool Database window's search field (empty clears it) |
| `fileTarget` | `name`: a file or folder path (empty clears it) | the save or folder panel of Export G-code, Save All Toolpaths and Save Tiled G-code answers OK with that path at once, until `closeSheet` or an empty `fileTarget` (other panels are not routed through it), so the sheet's real save runs (and fails, for an unwritable path); `closeSheet` clears it. The system file panel itself is never driven |
| `sheet` / `closeSheet` | `value`: jobSetup, exportGCode, validation, … | opens a sheet, or closes the open sheet or alert |
| `import` | `name`: a file path relative to the repo root | imports it as File > Import does; an import alert stays open until a `closeSheet` step |
| `expand` | `name`: a collapsible section's title | opens it (the state the app remembers) |
| `press` | `name`: a control's title, label, text, help or id (an exact title wins over a mention; a field can be named by its label, `"Width"` with role `AXTextField`); `value`: optional role (`AXButton`) | clicks that control with a real mouse event |
| `move` | `name`, `value`: as `press` | moves the recorded pointer onto the control without clicking |
| `scroll` | `name`, `value`: as `press` | scrolls the enclosing scroll view until the control sits in the middle |
| `pointer` | `size`: `[x, y]` window points, origin top left; `value`: `click` to click there | moves the pointer to a point (for the canvas) |
| `type` | `value`: text | types it one key at a time into the focused field (`press` the field first; `key` `selectAll` replaces its text) |
| `key` | `value`: `escape`, `return`, `tab`, `space`, `delete`, `selectAll` | sends that key to the sheet or window |
| `fit` | | zooms the 2D canvas to the material |
| `wait` | `seconds` | lets background work finish (the 3D preview builds its stock asynchronously) |
| `capture` | `name` | window PNG and accessibility tree |
| `captureSheet` | `name` | the open sheet's PNG and accessibility tree |
| `menus` | `name` | the menu bar dump |
| `record` | `name`, `fps` (default 10) | starts recording frames of the window (with its sheet, the pointer and the caption) as `<name>.frames/` and `<name>.ffconcat` |
| `endRecord` | | stops the recording and writes the frame list |
| `caption` | `value` (empty to clear) | text shown near the top of recorded frames |
| `simulate` | `seconds` (default 6) | scrubs the 3D simulation from start to end over that long (needs `mode` `3d` or `split` and a `wait`) |
| `view` | `value`: `threeQuarter`, `iso`, `top`, `front`, `back`, `left`, `right`, `bottom` | sets the 3D camera |

## Clips

`scripts/reel.sh <scenario>` runs a scenario and turns every recording in it into a GIF and an MP4 in
`docs/images/` (`--out`, `--width`, `--fps`). A clip scenario wraps its steps in `record` / `endRecord`
(`harness/scenarios/reel-*.json`); `caption` sets the line of text drawn over the frames, and `press`,
`move`, `select` and `selectToolpath` glide a drawn pointer onto the control first, so the clip reads as
someone using the app. Frames come from the window server (`CGWindowListCreateImage` of the app's own
window, no Screen Recording permission) at the screen's scale, in a few milliseconds each, with the sheet
composited where it sits. The window is parked just past the edge of its screen (a 4 pt sliver stays on
screen, floating, so the window server and the accessibility server keep it) and drawn as key without
activating the app, so your focus stays where it is; `--active` activates the app on screen instead.

What that quiet mode cannot do: a click on a table row (the toolpath list, the layer list) only focuses a
window that is not really key, so `selectToolpath` and `select` select in code and only pretend to click;
buttons, segmented controls, checkboxes and text fields take the click. Control lookups need a visible
window: a locked screen or a covered display hides every window from the accessibility server, and the run
says so. The `.ax.txt` dump ends with each scroll view's real frame and inset: SwiftUI reports a scroll view's content
frames without the view's own top inset, so a scroll view inset by the toolbar would show frames above its
controls (the inspector did, issue #42, and no longer does).

In an agent shell with the Bash sandbox on, the app cannot reach the system's HIServices XPC service
("Connection Invalid error for service com.apple.hiservices-xpcservice" on stderr) and hangs with no output
(no `harness.log`), even for the `empty` scenario. The app's watchdog starts only once the harness does, so it never
ends such a run. `scripts/ui.sh` therefore refuses to start in a sandboxed shell (exit 3), and stops any run that goes
a minute past its watchdog (exit 2; `LOFTLINE_UI_TIMEOUT` sets the cap in seconds). Run it outside the sandbox. For
Claude Code, list it in `.claude/settings.local.json` (git-ignored), and call it without `cd` or an output redirect,
either of which keeps a call in the sandbox:

```json
{ "sandbox": { "excludedCommands": ["scripts/ui.sh *", "/Users/sean/sites/loftline/.worktrees/*/scripts/ui.sh *"] } }
```

Its own HOME does not isolate your preferences (see the start of this page).

The GIF is encoded from the frames with one palette per clip and no alpha channel (an alpha channel makes
every frame a full frame and the file fifty times larger). ffmpeg from Homebrew is required.

`scripts/ui.sh --help` and `HarnessScenario.ops` list them too; a bad scenario fails with the valid ops.
Add a scenario by dropping a JSON file in `harness/scenarios/` (`HarnessScenarioTests` checks every file
there parses).

## Limits

- The window is drawn inactive unless you pass `--active` (grey traffic lights, grey selection). `--active`
  asks to bring LoftLine to the front for the run; macOS may not grant it.
- `menus` lists the menu bar's structure, titles and key equivalents. Items that depend on the focused document
  (Group, Mirror, Align…) show as disabled, because SwiftUI's menu focus does not reach the document in this
  setup, so check enablement in the running app. Every harness flag takes a value (`--ui-active 1`): a bare
  flag shifts AppKit's `-key value` argument pairing, and the next value is taken for a file to open.
- Popovers, pop-up menu contents and file panels are not captured. `menus` dumps the menu bar's structure.
- SceneKit (the 3D preview) is composited from its own snapshot; give it a `wait` before a capture, or the
  simulated stock is not built yet.
- `press` delivers a mouse click; it does not toggle a disclosure group (use `expand`) and does not type.
- `--key` draws the window as key through the key and main notifications; the title bar can fall back to
  its inactive look on some redraws, which the run corrects after every step.
- Debug builds only. A release build has no harness.
