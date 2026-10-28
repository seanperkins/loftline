# LoftLine

**CAD/CAM for CNC routers, native on the Mac.** Draw or import a design, set up toolpaths, watch the
cut in 3D, and export G-code that is checked before it reaches the machine.

LoftLine is built for the Avid CNC PRO6096 (Mach4) and replaces VCarve Pro for that machine. It covers 2D,
2.5D and basic 3D routing on Apple Silicon Macs with macOS 14 or later.

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/images/hero-dark.png">
  <img alt="LoftLine's document window: the sample sign's toolpaths drawn over the design on the left, and the carved sign in the 3D preview on the right" src="docs/images/hero-light.png">
</picture>

## See the cut before the router does

<img alt="The 3D preview cutting the sample sign (the pocket, then the V-carved letters, then the cut-out), followed by the design and the simulation side by side" src="docs/images/preview.gif">

The 3D preview removes material move by move and estimates the run time. This is the sample sign
(`samples/sign.loftline`) without its drill holes: a pocket, V-carved letters, then the cut-out with tabs, about 16 minutes
of machine time. Scrub it, step it one move at a time, or run to the next retract.

## From design to G-code

<table>
  <tr>
    <td width="50%" valign="top">
      <img alt="The 2D canvas with the LOFTLINE text selected" src="docs/images/step-1.png"><br>
      <b>1. Draw or import.</b> Shapes, a Bézier pen, text in any installed font, node editing,
      booleans and offsets. Import SVG, DXF, EPS, AI and PDF vectors, trace images, or bring in
      STL/OBJ models.
    </td>
    <td width="50%" valign="top">
      <img alt="Pocket and V-carve toolpaths drawn over the design" src="docs/images/step-2.png"><br>
      <b>2. Set up toolpaths.</b> Profile, pocket, drilling, V-carve, inlay, fluting, texture and 3D
      relief. Each one is drawn over the design as soon as it is calculated.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img alt="The 3D preview partway through the job" src="docs/images/step-3.png"><br>
      <b>3. Preview in 3D.</b> Play, scrub or step through the job one move at a time, with time
      estimates. Measure the stock, and draw or select vectors in the 3D view.
    </td>
    <td width="50%" valign="top">
      <img alt="The Export G-code sheet with the post processor, Z zero, deepest cut and a validator warning" src="docs/images/step-4.png"><br>
      <b>4. Export checked G-code.</b> The Export sheet names the post, Z zero and deepest cut. A
      built-in validator flags risky moves before you save.
    </td>
  </tr>
</table>

## The parts that save a cut

<table>
  <tr>
    <td width="50%" valign="top">
      <img alt="The Export sheet refusing to stay quiet: a through cut with tabs off is flagged before the G-code is saved" src="docs/images/preflight.gif"><br>
      <b>Pre-flight checks.</b> Every export is checked before it is written: a through cut with no
      tabs, a cut past the material, two tools sharing a number, a rapid through a clamp. The sheet
      also names the post, the Z zero and the deepest cut, so the numbers can be read against the machine.
    </td>
    <td width="50%" valign="top">
      <img alt="Selecting a toolpath that pauses the machine, with the operator message in the inspector" src="docs/images/pause.gif"><br>
      <b>A pause between toolpaths.</b> Stop the machine to flip the part, add clamps or clear chips.
      The operator sees your message on the controller, the program gets a retract, M5 and M0, and the
      next toolpath restarts the spindle.
    </td>
  </tr>
  <tr>
    <td width="50%" valign="top">
      <img alt="Typing =width/2 into the Width field, and the panel resizing to half the material width" src="docs/images/variables.gif"><br>
      <b>Numbers that follow the job.</b> Any numeric field takes an expression (`=width/2`,
      `1/4in + 1mm`). `width`, `height`, `thickness` and `safez` are built in, you can add your own
      under Design > Variables, and a through cut follows the material thickness when it changes.
    </td>
    <td width="50%" valign="top">
      <img alt="Importing a DXF whose outline has a small gap: the import names the gap, and Join Open Vectors closes it" src="docs/images/import.gif"><br>
      <b>Imports that say what they found.</b> A DXF outline whose ends nearly meet is reported on
      import, with the size of the gap. Join Open Vectors closes it at a tolerance you choose and says
      how far each end moved.
    </td>
  </tr>
</table>

## Highlights

- **172 of 196 VCarve Pro features**, including every one marked essential (P1). Status is tracked
  in [docs/PARITY.md](docs/PARITY.md).
- **Production runs.** True-shape nesting across sheets, production plates (one design per CSV row),
  and tiled G-code for jobs bigger than the bed.
- **Gadgets.** JavaScript add-ons that draw vectors and set up toolpaths (Gadgets > Gadget API Reference).
- **A real Mac app.** SwiftUI and AppKit, light and dark mode, and Finder thumbnails for `.loftline` files.

<details>
<summary><b>Full feature list</b></summary>

- **Design:** import SVG (incl. text and embedded images), DXF, EPS, AI and PDF vectors, tracing
  images (JPG/PNG/BMP/TIF/GIF/WebP) and STL/OBJ/COLLADA models (or their parts as flat outlines);
  browse your own clipart folders; export SVG, DXF, PDF, EPS and AI. Job notes are saved with the file.
  Jobs can be two-sided or span several material sheets, start from saved templates, and numeric
  fields accept expressions and linked document variables (`=thickness/2`, `1/4in`). Drawing tools include shapes,
  polylines, Bézier pen, text in any installed font, node editing, transforms, align/distribute,
  booleans, offset, layers, snapping and undo/redo. **Gadgets** (Gadgets menu) are JavaScript
  add-ons that draw vectors and set up toolpaths; see Gadgets > Gadget API Reference.
- **Toolpaths:** Profile (tabs, ramps, leads, last pass, start point, cut order), Pocket (offset/raster,
  several clearance tools), Drilling (peck), Hole Milling (helical bores and threads), V-Carve, Photo
  V-Carve, Prism, Quick Engrave, Chamfer, V-bit and straight-wall Inlay, Fluting, Texture, Moulding and
  3D relief (roughing + finishing, rest machining, two-sided, projection onto the model). Toolpaths can
  be merged, saved as templates by layer, and checked against keep-out zones; a tool database holds
  folders, per-material feeds and a feeds calculator. Toolpaths > Preview G-code File… shows another job's G-code.
- **Layout:** true-shape nesting with overflow onto extra sheets, clamp and fixture keep-out
  zones, part labels, production plates (one design repeated per CSV row with `{Field}` text),
  a printable job sheet, material and bed checks, and tiled G-code for jobs
  larger than the bed (Design > Layout, File > Export Job Sheet…, Toolpaths > Save Tiled G-code…).
- **Preview and output:** 2D overlay, 3D material-removal simulation and time estimates, and
  printing of the 2D design.
  Data-driven posts (JSON profiles) ship for Mach4, GRBL, LinuxCNC and the Othermill, in inches and millimeters, and output
  goes through a built-in G-code validator. The 2D and 3D views can be shown side by side, and
  File > Recover Unsaved Work… restores autosaved work after a crash.

Feature status against VCarve Pro is tracked in [docs/PARITY.md](docs/PARITY.md) (196 features: 172 done,
7 partial, 17 missing, every P1 item done). [TESTING.md](TESTING.md) §3 walks through what is new since the
first test build.

</details>

## Machine safety

LoftLine drives a real 60 × 96 in router, so G-code is treated as safety-critical.

- Every program goes through the G-code validator before it is saved.
- The post's output is pinned by golden files: `samples/sign.loftline` must post byte-for-byte to
  `samples/sign.tap`, and every sample posted with every built-in post must match `samples/expected/`
  (`scripts/check-samples.sh`, also run by CI).
- Programs retract to safe Z before XY rapids. Keep-out zones and the move home are checked on export.
- Before cutting real material, follow the air-cut procedure in [TESTING.md](TESTING.md).

## Install and update

Download `LoftLine-vX.Y.Z-macos-arm64.zip` from the [Releases](https://github.com/seanperkins/loftline/releases) page (Apple Silicon, macOS 14 or later), unzip it and drag `LoftLine.app` to Applications. Releases are signed and notarised, so macOS can check them before they open.

LoftLine looks for a newer release when it starts and then once a day. A found update opens a window with the release notes; you can install it when you quit (the default) or now, skip that version, or decide later. Settings ▸ General ▸ **Check for updates automatically** turns the daily check off, and LoftLine ▸ Check for Updates… looks once, on request. The only request goes to github.com, with the user agent `LoftLine/<version>` and nothing else. A download is checked against its SHA-256 and a signature made with LoftLine's own key before anything is installed, and an update installs only when LoftLine quits.

## Build and run

Requires an Apple Silicon Mac on macOS 14+ with Swift 6 (Command Line Tools are enough;
Xcode works too). Install the tools with `xcode-select --install` if `swift --version` fails.

```sh
git clone https://github.com/seanperkins/loftline.git && cd loftline
scripts/bundle.sh && open dist/LoftLine.app
```

The bundle is ad-hoc signed, so macOS treats a copy downloaded from elsewhere as unverified.
A locally built one opens normally. The Welcome window has a button that opens the sample sign, and
Help > LoftLine Help (⌘?) has a topic for every form.

```sh
scripts/build.sh            # debug build
scripts/test.sh             # swift-testing suite
scripts/bundle.sh           # release build → dist/LoftLine.app (ad-hoc signed)
scripts/run.sh              # debug bundle + launch
```

## Command line

`loftline-cli` posts a project exactly as the Export G-code sheet does, with the same validator, and needs no window:

```sh
swift run loftline-cli export samples/sign.loftline --out out        # out/sign.tap
swift run loftline-cli export samples/sign.loftline --post generic-grbl-mm --operation "Pocket 1" --out -
swift run loftline-cli posts                                      # the installed post processors
```

Validator errors and warnings go to standard error. The exit status is 0 when the program is clean (warnings
included), 1 when the validator reports errors (nothing is written unless `--force`) or there is nothing to
export, and 2 for a usage or file error. `--builtin-only` ignores the posts and machines in Application Support, so
the result is the same on every Mac; `--name` sets the job name in the header (the project's by default). A project carries its own copy of its post, machine and tools, and the command line posts with those: `--post <id>` replaces only the post, with the installed one; `--builtin-only` still keeps the project's copies. A file whose copy this LoftLine cannot read (written by a newer one, or damaged) exits 2 with a message.
`scripts/check-samples.sh` runs it over `samples/` with every built-in post and diffs the programs against the
committed ones in `samples/expected/` (`--update` after an intended change). The same code answers to
`LoftLine export …`; `loftline-cli` is a second product of the app's target, so it starts the command line whatever it is given.

## How it's built

- **Coding agents in parallel workstreams.** Each workstream owned its own folders
  ([docs/OWNERSHIP.md](docs/OWNERSHIP.md)) and logged its design choices in
  [docs/DECISIONS.md](docs/DECISIONS.md). [AGENTS.md](AGENTS.md) holds the rules they work by.
- **SwiftPM only.** It builds with the Command Line Tools, with no Xcode project. There are five modules:
  `CGeom` (vendored Clipper2 and Boost.Polygon Voronoi), `CADCore`, `CAMCore`, `PostCore` and the
  `LoftLineApp` itself.
- **Over 1,000 tests** in swift-testing, including the golden G-code above.
- **A UI harness.** `scripts/ui.sh` drives the app through a scripted scenario and saves each window as
  a PNG with its accessibility tree, in light or dark mode. The screenshots and clips on this page are
  made the same way: `scripts/reel.sh all` regenerates them after a UI change
  (see [docs/UI-HARNESS.md](docs/UI-HARNESS.md)).

## More

- [TESTING.md](TESTING.md): guided test and the safe air-cut procedure.
- [docs/PARITY.md](docs/PARITY.md): feature status against VCarve Pro.
- [docs/DECISIONS.md](docs/DECISIONS.md): design decisions.
- [THIRD_PARTY.md](THIRD_PARTY.md): vendored Clipper2 and Boost.Polygon.
