# LoftLine training materials: plan (2026-10-29)

This plan lists the training LoftLine needs before it can be sold, in the order to make it. It builds on what already
exists: the 35 in-app Help topics (`Sources/LoftLineApp/Model/HelpTopics.swift`), about 135 one-line field tooltips
(`FieldHelp`, decision `beginner-1`), the sample projects in `samples/`, the on-machine procedure in TESTING.md §4, and
the harness that records screenshots and GIF/MP4 reels from scripted scenarios (`scripts/ui.sh`, `scripts/reel.sh`,
`harness/scenarios/`).

The full list of videos, from a survey of competitors' training libraries, is in [VIDEO-LIST.md](VIDEO-LIST.md).

## Rules for every piece

1. **Every tutorial project is a checked sample.** Its `.loftline` file and source vectors live in `samples/tutorials/`,
   and `scripts/check-samples.sh` posts it with every built-in post. A tutorial whose project stops posting fails the
   suite, so the training can't drift away from the app.
2. **Every screenshot and short clip comes from a harness scenario** (`harness/scenarios/tutorial-*.json`). When the UI
   changes, rerunning `scripts/reel.sh` regenerates them; nothing is captured by hand.
3. **Safety steps are never optional.** Every tutorial that ends at the machine ends with the air cut: Z zero lifted
   above the stock, spindle off, feed override about 50 %, a hand on E-stop.
4. **Write for the person at the machine:** the number to type, the button to press, and what the machine will do next.

## Formats

| Format | Used for | Produced by |
|---|---|---|
| Written step-by-step tutorial, with screenshots | Every tutorial | Writer + harness scenario |
| Short clip (20–60 s, GIF and MP4, no narration) | One feature or one step | `scripts/reel.sh` |
| Narrated video (10–25 min) | The four flagship projects (A1–A4) only | Generated from a script, plus camera footage of the machine ([VIDEO-PROCESS.md](VIDEO-PROCESS.md)) |
| Project download (`.loftline` + SVG/DXF/STL) | Every tutorial | `samples/tutorials/` |
| Printable one-page card (PDF) | Air-cut checklist, Z-zero card, shortcuts | Writer |

## The materials, in priority order

### Track A — First cuts (make first)

| # | Tutorial | Teaches | Project |
|---|---|---|---|
| A1 | **Your first cut: the sample sign** | Open, Job Setup, preview, export, air cut, cut | `samples/sign.loftline` |
| A2 | **Z zero and the stock** | Material-top vs spoilboard zero, XY origin, reading the Export sheet's Z zero and deepest cut | A board with one pocket |
| A3 | **A cut-out with tabs from a DXF** | DXF import, gap report, Join Open Vectors, profile, tabs, ramps | `samples/bracket-plate.dxf` |
| A4 | **A carved sign from scratch** | Text, pocket, V-carve, two tools, tool changes, pre-flight warnings | New project |

Card: **Air-cut checklist** (from TESTING.md §4, rewritten for owners).

### Track B — Your controller (one page per built-in post family)

Thirteen families: Avid/Mach4, GRBL (also grblHAL and FluidNC), LinuxCNC, Othermill, Onefinity Buildbotics,
Carbide Motion, MASSO G3, UCCNC, Centroid CNC12, ShopBot G-code, Syntec, Haas and NcStudio.

Each page covers:
- which machines it fits;
- how the post changes tools (M6, M0 or a probe), and whether you need one file per tool;
- the dwell unit and the controller setting it assumes;
- the units setting on the controller;
- **a first-run check**: a small test file plus the steps to run it in the air, with what to watch at each stop.

The first-run check doubles as the owner check each post is still waiting on (#107 and the others). Owners who follow it
and report back are how the posts get proven on real machines. Make this track second for that reason.

### Track C — Projects by toolpath (recipes)

Short tutorials, one project each:
- **Woodworking:** inlay (straight and auto), drilling and hole milling, facing a spoilboard (`samples/faced-board.loftline`), chamfer and moulding.
- **3D:** 3D relief from an STL (`samples/relief.stl`), texture, fluting, prism carve, photo V-carve.
- **Workflow:** pauses for clamps and flipping, merged toolpaths.

### Track D — Working faster

- Variables and expressions (`=width/2`, `safez`), and a design that resizes with the material.
- Templates and Save All Toolpaths.
- Sheets, nesting and tiling a job larger than the bed.
- The Tool Database and the feeds calculator: material presets, chip load, then listening to the cut.
- Park-and-probe tool changes (Mach4 and GRBL), with the probe-bounds explanation in plain words.
- Sharing a post or a project with someone else, and the "copy differs" warning.
- `loftline-cli` for batch posting.

### Track E — Switching to LoftLine

- **From VCarve:** a table mapping VCarve terms and menus to LoftLine's, plus what to do with existing toolpaths. Use
  Vectric's product names only to identify them, as on a compatibility page; no logos.
- **From Carbide Create and Easel:** where design, toolpaths and sending happen; LoftLine writes a file for your sender.
- **From Kerf:** already in TESTING.md ("Migrating from Kerf"); move it into Help.

### Track F — When something goes wrong

Troubleshooting pages named after the symptom, each with cause, check and fix:
- "The cut is too deep" or "it cut air": Z zero mode against the actual zero.
- "The machine moved 25.4 times too far": units on the controller (UCCNC, Syntec).
- "The bit plunged before the spindle was up to speed": dwell unit.
- "It didn't stop for the tool change": GRBL, M1 and one file per tool.
- What each pre-flight and validator message means, and what to change.
- Recovery after a crash, and where autosaves live.

Reference to add: a glossary (climb, stepover, chip load, tabs, Z zero, post processor) and a printable shortcuts card.

## Where it lives

- The in-app Help stays the reference: one topic per feature, as now.
- Tutorials, controller pages and troubleshooting go on a docs site built from `docs/guide/` in the repo, so they are
  versioned and reviewed with the code. Help topics link to them.
- Narrated videos go on a video channel and are embedded in the matching tutorial page.

## Decisions needed from Sean

1. Where the docs site is hosted: GitHub Pages from the repo, or the product website.
2. The video voice, host and filming (listed in [VIDEO-PROCESS.md](VIDEO-PROCESS.md)).
3. Whether the Getting Started help topic should open tutorial A1's project directly.
