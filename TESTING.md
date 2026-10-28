# Testing LoftLine

## 1. Open the app

- The app is at `dist/LoftLine.app`. To rebuild it, run `scripts/bundle.sh` (release build, ad-hoc signed).
- **First launch:** the app is ad-hoc signed, not notarised. Right-click `LoftLine.app` → **Open** → **Open**.
  If macOS still blocks it, go to System Settings → Privacy & Security → "Open Anyway".
- The **Welcome** window opens at launch (Help ▸ Welcome to LoftLine reopens it). "Open the Sample Sign" opens an
  untitled copy of `sign.loftline`; Help ▸ LoftLine Help (⌘?) has a topic for every form.
- Sample files are in `samples/`:

| File | What it is |
|---|---|
| `sign.loftline` | 24 × 12 × 0.75 in sign with Pocket, V-Carve, Drilling and Profile toolpaths already set up |
| `sign.tap` | The G-code for that sign, from the "Avid PRO6096 Mach4 (inch)" post, with no validator errors |
| `sign.svg` | The sign's vectors on four layers (Outline, Pocket, Text, Drill) |
| `bracket-plate.dxf` | 8 × 5 in plate with bolt holes, a slot and a bore |
| `relief.stl` | 75 mm square relief (dome and waves) for the 3D toolpath |

To regenerate the samples, run `LOFTLINE_WRITE_SAMPLES=1 scripts/test.sh --filter SampleFiles`, then, as a separate run,
`LOFTLINE_WRITE_SAMPLES=1 scripts/test.sh --filter HarnessProjects` (the harness projects are the sample plus a patch each and
embed its ids, so they go stale whenever the sample is regenerated).

## 2. Ten-minute test script

1. **Open the sample.** File → Open `samples/sign.loftline`. Toolpath results are not saved in the
   file, so run Toolpaths → **Calculate All** (⌘R). The four toolpaths appear in the sidebar with
   their tools and estimated times, and the toolpaths are drawn over the design.
2. **Job Setup** (⇧⌘J). Switch the Z zero between Material top and Spoilboard, and try a few XY
   origins (corners or centre). Leave the settings at Material top and lower left.
3. **Preview.** Open the 3D preview (⌥⌘3) and press Play. The pocket, carved letters, holes and the
   cut-out with tabs should look right. Try scrubbing and changing the speed, stepping one move at a
   time, and "run to next retract". Try the scope picker (all / visible / selected toolpaths), the
   material palette (wood type, painted top), the ruler (click the stock twice to measure), the
   camera button (save a PNG) and the stopwatch (acceleration and calibration). Use the cube menu for
   Top / Front / Left / Isometric views and Orthographic, and the Show menu to draw toolpath lines,
   rapids and vectors in 3D. With the pencil button, click points on the stock to draw a polyline
   (click the first point to close it, Return to finish); it appears in the 2D view too. The arrow
   button selects vectors by clicking them in 3D. Switch back with ⌥⌘1.
4. **Export.** File → Export G-code… (⇧⌘E) and save `test.tap`. It should match `samples/sign.tap`
   (only the date or job name may differ). Toolpaths → Check Toolpaths… (⇧⌘K) should report no errors.
5. **Import.** Make a new document (⌘N). Use File → Import… (⇧⌘I) to import `bracket-plate.dxf`.
   The plate and its six inner features should appear.
   Then import `Tests/Fixtures/CADCore/outline-with-gap.dxf`: it arrives as one open vector, and the
   Import alert names the layer (Cabinet) and a gap of about 0.2 mm (0.0079 in), not joined at 0.0005 in.
   Select it and choose Arrange → Join Open Vectors…: the dialog says the closest ends are 0.0079 in apart.
   Set "Join gaps up to" to 0.01 and press Join: the outline becomes one closed vector.
6. **Draw.** Use the canvas tools (V select, N node edit, R rectangle, C circle, E ellipse, L line,
   P Bézier pen, T text). In the Arrange menu, try Align, Boolean (union/subtract/intersect),
   Offset…, Mirror, Rotate, Group/Ungroup and Join/Close vectors. Use ⌘Z/⇧⌘Z to undo and redo.
   Type some text in a font you have installed.
7. **Each toolpath type.** Select vectors, then choose Toolpaths → New Toolpath → …:
   - **Profile** on the plate outline: outside, tabs on, ramp on. Then edit tabs on the canvas
     (Tabs → Placement: Manual → Edit on Canvas). The note under Tab height says what the tabs hold
     (with a 0.77 in cut in 0.75 in material and 0.125 in tabs: 0.105 in).
   - **Pocket** on the slot, with offset and then raster clearing.
   - **Drilling** on the bolt holes, with peck drilling on.
   - **V-Carve** on some text, with and without a flat-bottom clearance tool.
   - **Inlay (Pocket + Plug)…** on a simple shape. The wizard creates a female pocket and a plug
     (the plug is disabled; export it as its own file).
   - **Fluting** on an open line, and **Texture** on a rectangle.
   - **Facing** with nothing selected: Toolpaths → New Toolpath → Facing faces the whole material (with
     vectors selected it takes the box round them instead). Try Along X, Along Y and Spiral in the 2D
     preview: the first pass is fed in from outside, a raster runs out past the stock before it lifts, and a spiral lifts in the middle of the faced floor.
     In the form, a stepover over 95% or an overhang under 0 refuses to calculate; with "Selected
     vectors" on a part inside the stock, the form warns that the cutter reaches past the box. The
     note under the result (and on the job sheet) says how far below the original top the new surface
     is and not to re-zero Z afterwards. Air-cut `samples/faced-board.tap` before cutting real stock.
   - **3D:** import `relief.stl`. The "Place 3D Model" dialog creates Roughing and Finishing toolpaths.
     In the inspector, try Offset roughing, the Offset/Spiral finishing patterns, "Rest after" a
     larger ball nose, "Combine with" a second model, and "Two-Sided" (one toolpath per side).
     On a Fluting or Profile toolpath, "Project onto 3D" drops it onto the model's surface.
   - **Follow the thickness.** A new Profile shows "Follow the material thickness" on under Cut depth.
     Change the thickness in Job Setup (Design → Job Setup…) from 0.75 to 0.5 in: the profile's cut
     depth becomes 0.5 in; a pocket's depth and a profile with the toggle off do not move.
   - **Tooltips.** Hover any setting in a toolpath form: every field, toggle and picker shows a one-line
     explanation (not just its label). In the Tool Database's feeds calculator, choose a material in the
     Material pop-up: the target chip load fills in for that tool's diameter and Apply sets the feed.
   - **Pre-flight.** On the Profile, turn tabs off and set the cut depth to the material thickness:
     Export G-code… and Check Toolpaths… show a warning that the part comes loose, and the Save
     button still works (it is a warning, not an error). Turn tabs back on and the warning goes.
   - **Pause.** On a toolpath that is not the last, turn on Pause → "Pause the machine after this
     toolpath" and type a message. The sidebar row gets a pause mark. Export all toolpaths: between
     that toolpath and the next the program lifts to safe Z, then `M5`, `(MSG, your message)`, `M0`,
     and the next toolpath starts with `M3`. File → Export Job Sheet… lists the pause under the step.
   Press Calculate All, then check the 2D overlay and the 3D preview for each one.
8. **Save All Toolpaths…** (⌥⌘S): try "one file per toolpath" in a scratch folder. Save into the
   same folder again: "Replace N files?" names the files; Cancel leaves them. If a program failed to
   generate, the Save button is disabled (a set with a file missing is never written).
   **Sheet errors.** In Terminal make a read-only folder (`mkdir /tmp/ro && chmod 555 /tmp/ro`), then
   File ▸ Export G-code… ▸ Save… into it: a red line "Could not save G-code: …" appears above the
   buttons and the sheet stays open; choose a writable folder and it saves and closes. Same for
   Save All Toolpaths (one file, and per-toolpath into the folder) and Save Tiled G-code.
   **Edits under an open sheet.** With File ▸ Export G-code… open, open the Tool Database (⇧⌘T, a
   window of its own) and change the diameter of a tool the job uses: Save… greys out for a moment and
   the program and the validator list below it are posted again (the tool table in the header shows the
   new diameter). Renaming the tool updates the names at once. Same for Save All Toolpaths, Save Tiled
   G-code and Check Toolpaths….
9. **Toolpath form warnings.** Select a toolpath and set its cut depth well below the material bottom, a tab height equal to the cut depth, a tool with feed 0 or a spindle speed of 60000: each shows an orange line under the tool picker, and clears when it is put right. A through-cut at the material thickness (or within the machine's spoilboard allowance) shows nothing.
9. **Tool Database** (⇧⌘T): type `1/4`, `60°`, `T3` or a material name in the search field and the list narrows to the tools that match every word. Give a tool a description (the Description box): its first line shows under the name and in the operation's tool picker. The wand button next to Name names the tool from its size. Give two tools the same Tool number: both rows get a warning badge naming the other, and the editor says so with a "Use T…" button for the smallest free number. Add and Duplicate take a free number. Add or edit a tool. Tools are stored in
   `~/Library/Application Support/LoftLine/`. Type a long name and watch `tools.json`'s modified time:
   it changes once, when you press Return or click another field, not per letter. With a toolpath
   calculated, renaming the tool leaves the toolpath unfaded and the new name shows in the sidebar
   summary; changing the diameter fades it. Click Duplicate straight after typing a name (no Return):
   the copy carries the new name.
10. **Round trip.** Save the document as a `.loftline` file, close it and open it again.

### More file and job features

- **Job sheet:** File → Job Sheet… saves an HTML page (material, origin, tools, toolpaths, times,
  picture) and opens it in the browser for printing. File → Print… / Print at Actual Size… print
  the 2D design.
- **More imports:** File → Import… also takes PDF/AI vectors, JPG/PNG/… tracing images (edit them in
  the Design sidebar's Images section: fade, crop, size), OBJ and COLLADA (.dae, e.g. exported from
  SketchUp) models. Export Vectors… writes PDF, EPS or AI by file extension.
- **SVG scale:** File → Import… an SVG that does not state its size (Illustrator, Inkscape 0.91 and older,
  hand-made files) opens "Scale of …": the program's own scale (72, 90 or 96 pixels per inch) is
  selected and the size the drawing comes out at is shown for the choice. Pick another and the size
  changes; Import brings it in at that size, Cancel brings in nothing. An SVG that states a physical
  size (Inkscape 1.x, CorelDRAW) imports at once. Measure the imported shape in the inspector against
  the size you drew it at.
- **A failed save keeps your work.** Save a document into a folder, then in Terminal make the file and folder
  read-only (`chmod 444 file.loftline && chmod 555 folder`). Change something and press ⌘S: macOS refuses the save (a
  permission or "could not be saved" alert, or a "locked" sheet offering Duplicate: choose Cancel) and the window
  stays edited (dot in the close button). Wait for the recovery interval (Preferences)
  and check `~/Library/Application Support/LoftLine/Recovery/` still holds a copy. Then `chmod 755 folder && chmod 644
  file.loftline`, press ⌘S, and the copy goes away at the next interval. (An untitled document keeps its copy until it
  has been saved to a file.)
- **Templates:** File → Save as Template…, then File → New from Template.
- **Job Setup:** Plunge Z, datum offset, and a two-sided job (Design → Show Bottom Side, ⇧⌘B).
  Design → Sheets adds more material sheets; each sheet exports its own G-code.
- **Variables:** Design → Document Variables…; type `=thickness - 0.05` or `1/4in` in any number field.

## 3. New since first build

The first test build was commit `2ea022c`. These steps cover what was added after it; each takes a
minute or two. Use `samples/sign.loftline` (or a new document) unless a step says otherwise.

1. **More toolpaths.** Toolpaths → New Toolpath now also has Quick Engrave, Chamfer, Hole Milling
   (helical bore; turn on threads), Prism Carve, Photo V-Carve (needs a tracing image), Straight-Wall
   Inlay (Pocket + Plug) and Moulding (pick a rail and a profile vector). Make one of each and press
   Calculate All. On a Profile, try a separate last pass, start point, cut order, sharp corners and
   open-vector left/right offset; on a Pocket or V-Carve, add a second clearance tool.
2. **Merging and templates.** Select two toolpaths that use the same tool and choose Toolpaths → Merge
   With Next Toolpath, then Split Merged Toolpath. Save Toolpath Template…, then Apply Toolpath
   Template… in a new document with the same layer names.
3. **Tools.** Tool Database… (⇧⌘T): tools sit in folders, have per-material feeds and a feeds
   calculator. In a toolpath's inspector, edit the tool's feeds for that toolpath only.
4. **Layout.** Design → Layout → Nest Parts… on the bracket plate copied several times (parts that do not
   fit spill onto extra sheets). Then try Clamps and Fixture Holes…, Toolpaths → Keep-Out Zones… (export
   refuses cuts in a zone), Label Parts…, and Production Plates… with a two-row CSV and `{Name}` in
   a text object. Toolpaths → Save Tiled G-code… splits a job longer than 96 in into bed-sized tiles;
   saving twice into one folder asks "Replace N files?" the same way Save All does.
5. **Drawing.** Vectors menu: Dog-bone Fillets…, Fillet / Chamfer Corners…, Rectangular and Circular
   Array…, Copy Along Vector…, Trim Tool, Extend to Nearest Vector, Fit Curves to Vectors…, Text on
   Curve / Arc…, Fit Text to Box…, Convert Text to Curves, Distort Envelope on Canvas and Validate
   Vectors… (problem spots are marked on the canvas). Drag guides out of the rulers and snap to them;
   use the measure tool; while drawing a rectangle, type `3,2` and Return.
6. **Files.** File → Import… a PDF and a JPG (trace it with Vectors → Trace Bitmap…). Export Vectors…
   as PDF/EPS/AI. Save as Template…, then New from Template. File → Clipart… browses a folder of your own
   files. File → Import 3D Model as 2D Parts… flattens a COLLADA/OBJ model into outlines. Toolpaths →
   Preview G-code File… draws a `.tap` from another job.
7. **Job setup.** Job Setup… (⇧⌘J): Plunge Z, datum offset, two-sided job (Design → Show Bottom Side),
   and Design → Sheets for a multi-sheet job. Design → Document Variables… and type `=thickness/2` in a
   depth field.
8. **3D.** With `relief.stl` placed: Offset roughing, Offset/Spiral finishing, Rest after a larger tool,
   Combine with a second model, Two-Sided, and "Project onto 3D" on a Fluting toolpath.
9. **Preview.** In the 3D preview (⌥⌘3): scope picker, material palette, ruler, PNG snapshot,
   stopwatch calibration, camera presets, toolpath lines/rapids/vectors, and the pencil and arrow tools
   for drawing and selecting vectors in 3D. View → Show 2D and 3D Side by Side.
10. **Gadgets and help.** Gadgets menu: run a bundled gadget and open the Gadget API Reference. Help →
    LoftLine Help (⌘?), Keyboard Shortcuts, Welcome to LoftLine. File → Recover Unsaved Work… after a force-quit.
11. **Job sheet.** File → Export Job Sheet… and check the tools, times, part labels and picture. Change
    the calibration Scale in the time-estimate popover and export again: the step times and the total
    both follow it, and the line under the toolpath table says what the total holds beyond the steps.

Every toolpath in steps 1–8 should calculate without an error, and Check Toolpaths… (⇧⌘K) should
report no errors for the sample. The status of every VCarve Pro feature is in `docs/PARITY.md`.

## 4. On the machine (Avid PRO6096, Mach4)

**Dry run in Mach4 (no cutting):**
1. Load the `.tap` file. Check the header comments for the job, the tools, the material size and
   the Z-zero mode, and check that they match the job you set up.
2. Look at the toolpath display. The part should sit inside the material outline at the chosen
   origin. No moves should go off the bed (X 0–60 in, Y 0–96 in), and the lowest Z should be
   what you expect. With Material-top zero, the deepest cut is −thickness minus any cut-through
   allowance. With Spoilboard zero, it is about Z 0.

**Air cut (always do this before the first real cut):**
1. Secure the material and zero X/Y at the origin you chose in Job Setup.
2. Zero Z with the touch plate as usual, then **jog up 1–2 in and set Z zero there**. The whole
   program now runs in the air.
3. **Leave the spindle off** (disable it or keep the VFD off). The program still sends M3/S, so
   watch that nothing spins.
4. Run the program with feed override around 50%. Keep a hand on E-stop. Check that it pauses
   with "Change to Tool" at each M6. Check that it retracts to safe Z before every rapid move.
   Check that the cut order is pocket, carve, drill, then profile last.
5. If everything looks right, re-zero Z on the real surface (material top or spoilboard, matching
   Job Setup), turn the spindle on and cut. Run the first real cut at reduced feed override.

**Other controllers (GRBL, LinuxCNC):** these posts have not run on a machine yet. On your own machine, with a
machine defined for it in Preferences ▸ Machines:
1. Post a job with more than one tool with Save All Toolpaths ▸ one file per tool.
2. Before each file, load its tool and set Z zero 1–2 in above the surface, as in the air cut above.
3. Air-cut each file with the spindle off. Check that it stops at the top, and that the spindle dwell after M3 lasts
   seconds, not milliseconds. LinuxCNC shows the tool's name in the `MSG` line; stock GRBL drops comments, so your sender
   may not show it: check the loaded tool against the file's name.

**Onefinity (Buildbotics controller):** the Onefinity posts have not run on a machine.
1. Air-cut a one-tool job with the spindle off and Z zero raised 1 in: it runs to `M2` with no error (no `G40`/`G80` is written;
   check the controller accepts `G91.1` and `G49`).
2. Post a two-tool job with Save All Toolpaths ▸ one file per tool; each file stops at the top (`M0`) with the tool's name.
3. Add an optional-stop pause: the program stops there (LoftLine writes `M0`, because BB resumes an `M1` at once).
4. Time the spin-up dwell: about 3 seconds.

**Carbide Motion (Shapeoko):** the Carbide Motion posts have not run on a machine.
1. Load the `.nc` file: Carbide Motion shows no error for the `;` comments or the preamble (`G90 G17 G40 G49 G54`).
2. Time the spin-up dwell in an air cut: about 3 seconds. If it is instant, `G4 P` is milliseconds here: stop and report it.
3. A two-tool job: at `T2 M6` Carbide Motion asks for the swap and measures the bit with the BitSetter. Without a BitSetter,
   note where Z zero is after the swap. Then run a file whose first tool has the number of the bit already loaded: does it
   still prompt and measure?
4. A tool numbered above 255: does Carbide Motion accept it?
5. At the end the program lifts and moves home before `M2`: check that the move clears your clamps.

**GRBL machines (Genmitsu, LongMill):** check `$30` against the machine's Max RPM in LoftLine (duplicate the built-in machine
to set it), and `$31` against its lowest speed, before trusting any S word.

**Othermill (Bantam Tools software):** the Othermill posts have not run on a machine. Each check below confirms something the
post assumes (in brackets); stop and report if one does not hold.
1. Job Setup: the Othermill Pro machine, a 4 x 3 x 0.25 in sheet, Z zero at the material top, XY origin lower left, Home Z
   0.5 in. Export shows no errors. Load the `.gcode` in the Bantam software with Material Size 4 x 3 x 0.25 in.
2. The preview places the cuts on the stock as in LoftLine, with no collision or red warnings [file X0 Y0 Z0 is the stock's
   front-left top; the file is placed by its origin, not its toolpaths' outline]. An outside profile reaches past the stock
   by the tool radius: check that it stays on the bed.
3. No line is skipped or reported, including the header comments with `:`, `[` and `]` [they load].
4. Air-cut a two-tool file with the spindle off, Z zero raised 0.5 in: at `T1 M6` before the first cut the software asks for
   the tool and touches it off, even with T1 already loaded; at the second tool it pauses, asks for the swap and touches off
   again [both happen].
5. A pause step: the program stops and Resume continues [the stop always happens; its message may show with a leading comma].
6. Note whether 1.35 in is the axis travel or the room under the collet [axis travel].

**Editing a post (Toolpaths ▸ Post Processors…):**
1. Select the Avid inch post: the form is read-only and the sample program shows "Posts the sample job cleanly".
2. Duplicate it, change the footer, Save. The posts folder (Folder button) holds `<id>.json`; the post is listed under Custom.
3. Type `G3` in Arc CW: Save is disabled with "Arc CW must be G2". Cancel puts it back.
4. Delete the custom post: its file is in the Trash (put it back from there to restore it).
5. Put a file named `wrong.json` holding another id in the posts folder and press Reload Post Profiles: it is listed under Did
   not load with the reason.
6. A custom post with a declared controller: run the air-probe check below with it before cutting.
7. Export a custom post, then Import the file: a draft opens with a new id (the original still has its id); Save adds it.
8. Open a project from another Mac whose post is not installed here: Job Setup says "(not installed here: add it in Toolpaths >
   Post Processors)"; Add This Project's Post, then Save: Job Setup now says the post is installed, with no "differs" warning.

**Air-probe check (before the first job with park-and-probe on):** Preferences ▸ Machines, the
machine's "Tool change: park and probe" settings. Do every step with the spindle off and a hand on the E-stop.
1. **Dry run to the park.** Home the machine. Post a one-tool job and run only to the first stop. The gantry must lift to the
   traverse height near the top of travel without touching the limit switch, travel to the park in the right direction (the
   `G53` signs), and the longest bit you use must clear the tallest stock and every clamp along the whole path from the park to
   the touch-off spot.
2. **Held plate.** Run on: at the spot, clip the lead and touch the plate to the bit (the probe light comes on), hold the plate
   under the bit, jog Z only to about half the probe travel above it, continue. The probe must stop on contact.
3. **No contact.** Over scrap, with the plate NOT under the bit, continue past the placement stop. GRBL must alarm; on Mach4 your
   zero macro must stop the program. The bit must not go further than the probe travel.
4. **Probe already touching.** Start the probe with the plate already touching the bit (the light on). The program must stop (GRBL
   is expected to raise "probe fail"; Mach4's behavior depends on your macro).
5. **The zero.** After a normal probe, remove the plate, jog to work Z 0 over bare stock: the bit must just touch the material top
   (a paper check). Do this in both Z-zero modes and with every post the machine lists (inch and mm: the macro's `P` is in the
   program's units), and check that the zero landed in the work offset the machine is set to (G54 for 1).
6. **Coolant.** A toolpath set to Mist or Air turns it on after the spindle start and off at the next tool change, pause and the end.

Reference Mach4 zero macro (`m199.mcs`, Lua). It is an UNVERIFIED sketch: the API calls and `#5070` were written from memory
of Mach4's Lua API, not run on a controller. Adapt it to your set-up and prove it with steps 3 to 5 before relying on it:

```lua
function m199(hParam)
    local inst = mc.mcGetInstance()
    local plateZ = mc.mcCntlGetLocalVar(inst, hParam, mc.SV_P)
    local hit = mc.mcSignalGetState(mc.mcSignalGetHandle(inst, mc.ISIG_PROBE))
    -- #5070 is 1 when the last G31 made contact on many set-ups; check yours.
    if mc.mcCntlGetPoundVar(inst, 5070) ~= 1 and hit ~= 1 then
        mc.mcCntlEStop(inst)
        mc.mcCntlSetLastError(inst, "Probe made no contact: program stopped")
        return
    end
    mc.mcAxisSetPos(inst, mc.Z_AXIS, plateZ)   -- the current Z reads the plate's top in the active offset
end
if (mc.mcInEditor() == 1) then m199() end
```

## 5. Known limitations and stubs

- The app is ad-hoc signed and not notarised (Gatekeeper warns on first launch).
- Finder / Quick Look thumbnails of `.loftline` files come from the bundled extension
  (`Contents/PlugIns/LoftLineThumbnail.appex`). macOS picks it up once the app has been launched from
  its final place (e.g. /Applications); `pluginkit -m -i com.seanperkins.loftline.thumbnail` shows whether
  it is registered. Only files saved by this version carry the picture.
- Toolpath results are not stored in `.loftline` files. After opening a file, run Calculate All
  (export also recalculates automatically).
- 3D roughing needs an end mill in the library.
- EPS import only handles a minimal set of path operators (no PostScript programs). PDF-based `.ai`
  files are rejected; save them as SVG instead. DXF splines are approximated with curves.
- "Group by tool" is off by default, so the cut order is the toolpath list order. When it is on,
  it never moves profiles ahead of other toolpaths.
- Inlay plugs are generated in place over the pocket. Export the plug as its own program and cut
  it on a separate board.
- Tool changes are manual (M5, comment, T#M6). G43 H# is off unless you turn it on in the profile.
- App time estimates model acceleration (default 15 in/s², one value for all axes) and allow 90 s per tool
  change; calibrate them in the 3D preview (stopwatch button). The estimate in the G-code header is
  still length / feed.
- The GRBL profile is untested on real hardware.

## Command line (loftline-cli)

1. `swift run loftline-cli export samples/sign.loftline --out .tmp/cli`: writes `.tmp/cli/sign.tap`. Export the same file from the app
   (File → Export G-code with the same post): the two programs are byte-for-byte the same.
2. `swift run loftline-cli export samples/sign.loftline --operation "Pocket 1" --out -` prints only that toolpath's program.
3. Cut the sign's profile deeper than the material plus the spoilboard allowance and save a copy: `export` prints
   `error:` lines and exits 1 without writing; with `--force` it writes the file and still exits 1.
4. `scripts/check-samples.sh` passes on a clean checkout. Change a feed rate in `Sources/PostCore/Profiles/BuiltInPosts.swift` and
   it fails with the diff (undo the change; `--update` is for intended changes only).

## Migrating from Kerf

1. Make sure LoftLine has not been run on this account: `~/Library/Application Support/LoftLine` does not exist and
   `defaults delete com.seanperkins.loftline loftline.migratedFromKerf` reports nothing to delete. Put a `tools.json` in
   `~/Library/Application Support/Kerf/` (copy one from a Kerf install) and run `defaults write com.seanperkins.kerf kerf.groupByTool -bool true`.
2. Launch LoftLine. Toolpaths ▸ Tool Database lists the tools from that file, not the seeded ones, and Export G-code groups the program
   by tool. A `kerf.*` setting you changed in Kerf (Settings ▸ General, window positions) is back.
3. Quit and launch again: nothing is copied twice and no alert appears.
4. The failure path: delete `~/Library/Application Support/LoftLine` and the `loftline.migratedFromKerf` default, then run
   `touch ~/Library/Application\ Support/LoftLine` (a file where the folder must go). Launch: an alert names the reason and offers
   Retry or Continue Without Importing, before any window opens. Remove the file, choose Retry: the first window already has the
   imported tools and settings (change a setting, then check the others kept their Kerf values). Run it again and
   choose Continue Without Importing instead: LoftLine starts with the seeded tools and never asks again.
5. After you have checked that your data came across, delete the old `Kerf.app` by hand: it stays installed and keeps registering `.kerf`.

## A heavy SVG

1. Import an SVG with thousands of paths (a traced drawing; `File → Import…`): the window stays responsive, every new shape is selected and drawn in the selection color, and zooming and panning keep up (a drawing over 5,000 segments is drawn as one-point lines: they look slightly thinner than the shapes of a small drawing).
2. Edit → Select All, then move the selection with the inspector's Move field and group it (⌘G): each takes a moment, not minutes.

## Projects that carry their post, machine and tools

Run with a build you made yourself. Posts and machines are read once per launch, so use **Toolpaths ▸ Reload Post Profiles** after editing a file.

1. Open `samples/sign.loftline`, then Job Setup (⇧⌘J): under the post picker it says `Using this project's copy of "Avid PRO6096 Mach4 (inch)" v1.0` and the same for the machine.
2. Built-in posts come from code, so create `~/Library/Application Support/LoftLine/posts/<the project's post id>.json` as a copy of that post with one changed footer line (a user file with a built-in's id replaces the built-in), then choose Reload Post Profiles. Job Setup and the Export G-code sheet now show a warning that the project's copy differs from the installed one; the exported G-code still has the old footer. **Update This Project** switches it; ⌘Z switches it back.
3. For "(not installed here)", use a post with its own id (deleting an override of a built-in's id only reveals the built-in again): copy a post file to a new id, pick it in Job Setup, save the project, delete that file and Reload Post Profiles. The project still posts and says "(not installed here)", with no error.
4. Tools: with the project open, change its cutter's diameter in the Tool Database; the toolpaths change at once and the project is marked unsaved. Close it without saving, change the same tool again with the project closed, reopen it: the warning names the tool, the exported G-code still uses the file's diameter, and Update This Project switches it to the library's and ⌘Z back.
5. Edit a copy in the file by hand so `schemaVersion` is `2` (or set `"postSnapshot": null`) and open it: LoftLine refuses with a message, and `loftline-cli export` exits 2 with the same message.

## Release candidate checklist

Run once on the notarised build from a `workflow_dispatch` rehearsal of `release.yml` (and again on the final candidate before a tag). The rehearsal proves the build, the signature, notarisation and the posted G-code; these cannot be seen headless.

1. Download the run's artifact `LoftLine-<version>-macos-arm64` with a browser (so it carries the quarantine flag), unzip it twice and open `LoftLine.app`. macOS may say it was downloaded from the Internet and ask you to confirm; it must not say the developer is unidentified or that it cannot be checked for malware. `spctl --assess --type execute -v LoftLine.app` prints `accepted` and `source=Notarized Developer ID`.
2. `plutil -p LoftLine.app/Contents/Info.plist` shows `LoftLineChannel` `rehearsal` and the version you gave; `LoftLine.app/Contents/Resources/updater.sh` exists and is executable.
3. Welcome ▸ Open the Sample Sign, calculate, and switch to the 3D preview: it renders and simulates (the hardened runtime must not stop the runtime Metal shader compile).
4. Run a built-in gadget from the Gadgets menu: it draws its shapes (the hardened runtime must not stop JavaScriptCore). If 3 or 4 fails, add `Resources/LoftLine.entitlements` with only the entitlement the failure proves necessary (likely `com.apple.security.cs.allow-jit`), rebuild through `bundle.sh` and rehearse again.
5. Move the app to `/Applications` and open it once, then `qlmanage -r` and `qlmanage -t -s 256 -o .tmp/ql samples/sign.loftline`: `.tmp/ql/sign.loftline.png` shows the sign (the Quick Look extension kept its sandbox).
6. `LoftLine.app/Contents/MacOS/LoftLine export samples/sign.loftline --post generic-grbl-mm --builtin-only --out .tmp/rc` and `diff .tmp/rc/sign.nc samples/expected/generic-grbl-mm/sign.nc` print nothing; export the same sample from the app (File ▸ Export G-code, Generic GRBL (mm)) and compare it too.

## Updates

The update checker is tested headless (`UpdateCoreTests`, `UpdateControllerTests`, `UpdateUITests`, `UpdaterHelperTests`, `ReleaseScriptsTests`). What those cannot see is the app running: the menu item, the window, the quit hook and a real GitHub release. Run these on a build you made yourself, and again on the final candidate.

1. **Local feed (a dev build).** A dev build never updates and says so; with a feed override it can find a version. `scripts/bundle.sh`, then make a throwaway key and a fixture feed:
   `mkdir -p .tmp/updates && echo fixture > .tmp/updates/fixture.zip`
   `UPDATE_SIGN_KEY_FILE=.tmp/updates/throwaway.dat scripts/update-feed.sh genkey >/dev/null 2>&1`
   `UPDATE_SIGN_KEY_FILE=.tmp/updates/throwaway.dat scripts/update-feed.sh v9.9.9 --zip .tmp/updates/fixture.zip --out .tmp/updates/latest.json`
   `python3 -m http.server 8123 --directory .tmp/updates` (leave it running), then `LOFTLINE_UPDATE_FEED_URL=http://localhost:8123/latest.json dist/LoftLine.app/Contents/MacOS/LoftLine`. LoftLine ▸ Check for Updates… opens the window and says "LoftLine 9.9.9 is available" with the four choices. Do not install: a dev build refuses ("Development builds do not install updates."). Quit, start it without the variable and check again: "Development builds do not update."
2. **Tamper drill** (needs a published release). Take that release's `latest.json`, change its `sha256` to 64 zeros, serve it as in step 1 and run a dev build against it. Choose Install when I quit: the window must say the download did not match its checksum and was deleted, `~/Library/Caches/LoftLine/Updates/` must be empty, and nothing is installed.
3. **Cancelled quit** (needs a release installed in `/Applications` and a newer one published). Check for Updates…, choose Install when I quit, open a document with unsaved changes and quit. **Cancel** at the save prompt: the app keeps running and `~/Library/Caches/LoftLine/Updates/` still holds the zip. Then quit for real and open LoftLine again (Install when I quit does not reopen it): LoftLine ▸ About shows the new version and `/Applications` holds no `LoftLine.old-*`. To see the reopen too, repeat with Install and Restart: cancel the quit, then quit for real, and the new version opens by itself.
4. **An update that did not happen.** The helper runs after LoftLine has quit, so its reasons are in `~/Library/Caches/LoftLine/Updates/updater.log` (a digest or signature that did not match, a version that was not newer, a folder that was not writable). Read that first.
5. **Recovery.** Only if an update was interrupted and `/Applications/LoftLine.app` is missing: `packaging/updater/macos.sh --recover /Applications` puts the old app back.
