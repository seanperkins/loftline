# LoftLine training videos: the complete list (2026-11-01)

This list comes from a survey of 496 official training videos:
- Vectric: VCarve, Aspire, Cut2D and Spark;
- Carbide Create;
- Easel;
- Estlcam;
- Fusion's router CAM introductions.

Each topic is kept only if LoftLine has the feature (docs/PARITY.md). How every video is made:
[VIDEO-PROCESS.md](VIDEO-PROCESS.md). The order to make the written tutorials: [TRAINING-PLAN.md](TRAINING-PLAN.md).
The survey's raw tables (titles, links, counts per vendor) are in `.tmp/training-survey/videos.md`, which is not
committed.

**Vendors** is how many of the five surveyed vendors have a video on the topic.

**Priority:**
- 1: a flagship video points to it, or 3 or more vendors cover it.
- 2: covered by 1–2 vendors.
- 3: covered by none, or a niche topic.

## 1. First cuts: flagship projects (10–25 min, with machine footage)

| # | Video | Teaches | Vendors | Priority |
|---|---|---|---|---|
| A1 | Your first cut: the sample sign | Job Setup, preview, check, export, dry run, air cut, cut (**draft rendered**) | 2 | 1 |
| A2 | Z zero and the stock | Material top vs spoilboard zero, XY origin, touch plate, reading Z zero on the Export sheet | 2 | 1 |
| A3 | A cut-out with tabs from a DXF | Import, gap report, Join Open Vectors, profile, tabs, ramps | 2 | 1 |
| A4 | A carved sign from scratch | Rectangle, text, pocket, V-carve, two tools, tool changes, pre-flight warnings | 2 | 1 |

## 2. The basics (2–5 min each, no machine)

The flagships point here instead of explaining these in passing.

| # | Video | Teaches | Vendors | Priority |
|---|---|---|---|---|
| B1 | A tour of LoftLine | Sidebar, canvas, inspector, 2D / 2D-3D / 3D, toolbar, Help | 5 | 1 |
| B2 | Job Setup in detail | Size, units, thickness, Z zero, XY origin, safe Z, home, plunge Z | 3 | 1 |
| B3 | The Tool Database and feeds | Adding tools, materials, chip load, the feeds calculator, sharing tools | 5 | 1 |
| B4 | Saving G-code and choosing a post | Export sheet, Save All Toolpaths (four ways), file per tool, post selection | 4 | 1 |
| B5 | Previewing a job | 3D simulation, playback and scrubbing, single step, measuring, run time, saving an image | 2 | 1 |
| B6 | Check Toolpaths and pre-flight warnings | What the validator checks, every warning and what to change | 0 | 1 (only LoftLine has it) |
| B7 | Machine configuration | Bed size, travel limits, the machine a project carries with it | 1 | 2 |

## 3. Drawing and editing (1–4 min each)

| # | Video | Teaches | Vendors | Priority |
|---|---|---|---|---|
| D1 | Basic shapes | Rectangle, circle, ellipse, polygon, star, arc; typing exact sizes | 3 | 1 |
| D2 | Move, size, rotate, mirror, align | Handles, typed values, align to material, distribute | 3 | 1 |
| D3 | Selecting, grouping and locking | Selection, groups and nested groups, lock | 3 | 1 |
| D4 | Snapping, guides, rulers and grid | Smart snap, guides, extension lines | 3 | 1 |
| D5 | Text | Fonts, spacing, text on a curve, convert to curves | 3 | 1 |
| D6 | Lines, curves and the pen | Polyline, Bézier pen, smooth curve | 2 | 2 |
| D7 | Node editing | Move, insert, delete, smooth/corner, set start point, to arc, curve fitting | 2 | 2 |
| D8 | Trim, join, weld and boolean | Trim, join and close, weld, subtract, intersect | 2 | 2 |
| D9 | Offsets, fillets, chamfers and dog-bones | Offset (open and closed), corner fillet and chamfer, dog-bone and T-bone | 3 | 1 |
| D10 | Layers | Visibility, lock, colour, order, moving shapes between layers | 2 | 2 |
| D11 | Measuring and dimensions | Measure tool, linear, angular and radial dimensions | 2 | 2 |
| D12 | Arrays | Rectangular and circular array copies | 1 | 2 |

## 4. Importing (2–4 min each)

| # | Video | Teaches | Vendors | Priority |
|---|---|---|---|---|
| I1 | Importing SVG, DXF, EPS, PDF and AI | Scale on import, the gap report, Join Open Vectors | 2 | 1 (A3 points here) |
| I2 | Images and Trace Bitmap | Placing, cropping and fading an image; tracing it to vectors | 3 | 1 |
| I3 | 3D models (STL, OBJ) | Size, position, Z offset, more than one model | 3 | 1 |
| I4 | Clipart folders | Browsing your own clipart folders | 0 | 3 |

## 5. Toolpaths (3–8 min each, one toolpath per video)

| # | Video | Teaches | Vendors | Priority |
|---|---|---|---|---|
| T1 | Profile | Inside/outside/on, open vectors, passes, last pass | 2 | 1 |
| T2 | Tabs and ramps | Automatic and placed tabs, ramp types, lead-ins | 2 | 1 |
| T3 | Pocket | Offset and raster, islands, allowance, several clearance tools | 2 | 1 |
| T4 | Drilling and hole milling | Peck, dwell, helical holes, internal threads | 3 | 1 |
| T5 | V-carve | V angle, flat depth, clearance tools, corner sharpening, start depth | 2 | 1 |
| T6 | Engraving and sketch carving | Quick engrave on a centreline, V-bit sketch carving | 2 | 2 |
| T7 | Chamfer | Width or depth, tip clearance | 4 | 1 |
| T8 | Inlays | V-carve inlay (pocket and plug, glue gap), straight-wall inlay | 2 | 1 |
| T9 | Prism and moulding | Raised bevel lettering, moulding along a rail | 1 | 2 |
| T10 | Fluting | Flutes with ramp in and out | 1 | 2 |
| T11 | Textures | Texture toolpath and vector textures | 1 | 3 |
| T12 | Facing a spoilboard | Facing the material or a box round a selection | 1 | 2 |
| T13 | PhotoVCarve | A photo to V-grooves | 1 | 2 |
| T14 | 3D roughing and finishing | Roughing allowance, raster/offset finish, boundary, rest machining | 2 | 1 |
| T15 | 2D toolpaths on a 3D surface | Projecting a V-carve or engrave onto a model | 0 | 3 |
| T16 | Editing, merging and arraying toolpaths | Recalculate, duplicate, merge, array copies | 1 | 2 |
| T17 | Toolpath templates | Saving a set of toolpaths and reusing it on new vectors | 1 | 2 |

## 6. Jobs and production (3–8 min each)

| # | Video | Teaches | Vendors | Priority |
|---|---|---|---|---|
| J1 | Two-sided jobs | Flip axis, per-side Z zero, locating the flip | 2 | 1 |
| J2 | Sheets and nesting | Several sheets, true-shape nesting, overflow | 2 | 2 |
| J3 | Tiling a job larger than the bed | Tile size, overlap, registration | 2 | 2 |
| J4 | Job templates | New from Template, Save as Template | 1 | 2 |
| J5 | Variables and expressions | `=width/2`, `safez`, a design that resizes with the material | 0 | 2 (only a Carbide lesson page) |
| J6 | Production plates from a spreadsheet | One design, text from a CSV | 2 | 2 |
| J7 | Part labels, job sheets and notes | Labels on parts, the printable job sheet, notes shown on open | 2 | 2 |
| J8 | Keep-out zones and fixtures | Clamp helpers, zones checked on export, "lift over" | 1 | 2 |
| J9 | Gadgets | Running and installing gadgets | 3 | 2 |

## 7. Your controller (one per post family, 3–6 min, with a first-run check at the machine)

| # | Video | Priority |
|---|---|---|
| C1–C13 | One video per family:<br>- Avid/Mach4<br>- GRBL (with grblHAL and FluidNC)<br>- LinuxCNC<br>- Othermill<br>- Onefinity Buildbotics<br>- Carbide Motion<br>- MASSO G3<br>- UCCNC<br>- Centroid CNC12<br>- ShopBot G-code<br>- Syntec<br>- Haas<br>- NcStudio<br><br>Each covers the post, tool changes, dwell, units and the air-run check. | 1 (only LoftLine has these; each doubles as the owner check) |
| C14 | Park-and-probe tool changes | 2 |
| C15 | Writing or changing a post (the post editor and its sample job) | 2 |

## 8. Projects (15–40 min, like Vectric's "In the Labs")

These are the project types competitors make most often, limited to what LoftLine can cut.

| # | Project | Uses | Competitors made |
|---|---|---|---|
| P1 | Coasters with an inlay | V-carve inlay, array | Carbide (coasters), Vectric (inlay projects) |
| P2 | Cutting board with a juice groove | Pocket, fillet, profile with tabs, facing | Carbide (drop tray), boards and trays recur |
| P3 | Box with a lid | Two-sided or two parts, pocket, fit | Vectric (several boxes) |
| P4 | Slot-together project | Dog-bones, nesting, sheets | Vectric (slot-together, arcade game) |
| P5 | Game board (tic-tac-toe or similar) | Pocket, V-carve, two-sided pieces | Vectric (four game projects) |
| P6 | Holiday ornaments | Array, profile, small parts and tabs | Easel, Vectric |
| P7 | Relief carving from an STL | 3D roughing and finishing | Vectric, Carbide (topographic) |
| P8 | Topographic map | 3D model or layered pockets | Carbide (two) |
| P9 | Photo carving | PhotoVCarve | Vectric, Cutting It Close (popular) |

## 9. Switching to LoftLine (5–10 min)

| # | Video | Priority |
|---|---|---|
| S1 | Coming from VCarve: where everything is | 1 |
| S2 | Coming from Carbide Create or Easel | 2 |
| S3 | Coming from Kerf | 3 |

## 10. When something goes wrong (1–3 min each, named after the symptom)

Easel has 22 of these and they are its most practical videos.

| # | Video | Priority |
|---|---|---|
| F1 | "It cut too deep" or "it cut air" (Z zero mode against the actual zero) | 1 |
| F2 | "It moved 25.4 times too far" (units on the controller) | 1 |
| F3 | "It plunged before the spindle was up to speed" (dwell units) | 1 |
| F4 | "It didn't stop for the tool change" (GRBL, M1, file per tool) | 1 |
| F5 | What each validator and pre-flight message means | 1 |
| F6 | Recovering after a crash, and where autosaves live | 2 |

## 11. Release videos

One "What's new in LoftLine x.y" per release (Vectric makes one per version), 3–6 min. Priority 2.

## Not on the list, and why

- **Rotary / wrapped jobs:** LoftLine has no rotary (PARITY `3d-rotary`).
- **Laser:** not supported (`tp-laser`).
- **3D modelling, sculpting and AI model generation:** LoftLine imports 3D models but does not model them.
- **Cabinet import, drag knife, keyhole slots:** not supported.
- **Machine connection and jogging:** LoftLine writes a file for your controller and does not drive the machine.
  The controller videos (section 7) cover loading the file.

## Counts and order

There are 86 videos in all, plus one per release:

| Group | Videos |
|---|---|
| Flagships | 4 |
| Basics | 7 |
| Drawing | 12 |
| Importing | 4 |
| Toolpaths | 17 |
| Jobs | 9 |
| Controllers | 15 |
| Projects | 9 |
| Switching | 3 |
| Troubleshooting | 6 |
| Release videos | one per release |

Make them in this order:

1. Finish A1 (machine footage).
2. B1–B6, which the flagships point to.
3. A2–A4.
4. The C series, which gets the posts run on real machines.
5. The F series.
6. Everything else marked priority 1.
7. Priority 2, then priority 3.
