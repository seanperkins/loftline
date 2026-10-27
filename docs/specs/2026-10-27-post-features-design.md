# LoftLine: coolant, park-and-probe tool changes

Part 2 of the post-processor work (part 1, self-contained projects, is on main at `8ec72f7`). Parts 3 to 5 (post editor, sharing a
post, more built-in posts) are out of scope.

## Decisions already taken (confirmed with the owner)

1. **Coolant is mist or air**, chosen **per toolpath** (Off / Mist / Air): `M7` mist, `M8` air, `M9` off.
2. **A tool change parks, waits for a manual swap and re-zeroes Z with a touch plate.** Every tool is probed, the first one too.
3. **The touch plate lies on the material.** Z after the probe is the plate's top above the material top.
4. **Park and touch-plate settings belong to the machine definition** (Preferences > Machines), and travel in the project's machine
   copy from part 1.
5. **Avid Mach4 first, GRBL where it can.** GRBL gets the same features where its dialect has them (`M8`/`M9`, `M7` only on a build
   with it, `G53`, `G38.2`, `G10 L20`).

One refinement, agreed in the design discussion: **the swap and the probe happen at two places.** The gantry parks at a machine-coordinate
position (`G53`) for the swap, then moves to a **touch-off spot** given in job coordinates, on the material, and probes there. LoftLine
cannot know where the material is in machine coordinates, so only a spot in job coordinates can be checked to be over the stock.

## Goals

- A program for a multi-tool job runs start to finish on the Avid with manual tool changes and no hand-zeroing, and every Z after a
  change is measured, not assumed.
- **Nothing changes until it is switched on.** Coolant defaults to Off, park-and-probe is off on every built-in machine, so today's
  G-code, `samples/expected/`, `samples/*.tap` and every golden stay byte-identical.
- The validator keeps checking depth after a probe sequence. Today `G91`, `G10` and `G53` each make it warn "depth checks no longer
  apply"; the sequences this part writes must not switch the checks off, and the validator must check the Z the probe sets
  independently of the builder.

## What exists (evidence)

- `ProgramBuilder.build` (PostCore) writes `toolChange` lines rendered from the post template at each tool change, then `reenter`
  (restate, climb to the approach height), then `spindleOn` and a dwell. `writePause` retracts, stops the spindle and renders
  `pauseLines`.
- A toolpath's stop reaches the program through `OperationSetup.pauseAfter` → `Toolpath.pauseAfter` (`GCodeExporter.toolpaths`).
- `MachineCoordinates.z(aboveTop:)` (CAMCore) is the single Z-zero helper: material-top mode gives `height`, spoilboard mode gives
  `thickness + height`.
- `GCodeValidator` (PostCore): `G91` warns "Incremental positioning"; `G10`, `G53`, `G92` warn "changes the coordinate system; depth
  checks no longer apply" and the block is treated as non-motion.
- Built-in posts: the Avid posts' tool change is `M5`, a comment, `T{T} M6`; the GRBL post's is `M5`, a comment, `M0`.

## Design

Revision 3, after two review rounds (Executor, Auditor, Claude Skeptic, Claude Simplifier). **The builder writes the park-and-probe
sequence in code**, the validator recognises it by value, and every condition under which no valid program can be written is a
**thrown `PostError`** (the export has no "Save Anyway" for it), not an overridable issue.

### 1. Coolant

- `Coolant` (CAMCore): `enum { case mist, air }`. `OperationSetup.coolant: Coolant?` (nil = Off, absent in every older file) and
  `Toolpath.coolant: Coolant?`. Codes are fixed: Mist `M7`, Air `M8`, Off `M9` (all already known to the validator).
- **Stamping.** One helper copies an operation's coolant onto **every** toolpath of that operation, and every place calculated results
  become export toolpaths calls it: `GCodeExporter.toolpaths` in both scopes, `GCodeBatchExport` (file per tool and file per
  toolpath), the per-operation `ValidationReport` and tiled export. (Unlike a pause, which belongs only after an operation's last
  toolpath and only in a whole program.)
- **State machine in the builder.** The builder tracks the coolant that is on. Before a toolpath's moves (after its spindle start
  if it has one), when the toolpath's coolant differs: `M9` if anything is on, then `M7` or `M8` (Mist to Air never leaves both on).
  Before every tool change, every pause and the footer: `M9` if coolant is on, and the state becomes Off, so a toolpath after a
  pause turns its coolant back on. All toolpaths Off: no coolant code at all.
- **Post-time only.** The staleness comparison (`AnyOperation.withoutPause`, renamed `withoutPostSettings`) ignores coolant too, so
  changing it never recalculates.
- **Merge.** Merging toolpaths whose coolant differs is refused (beside the same-tool rule in `MergeCommands`); a merged toolpath has
  the shared coolant, and splitting it gives that coolant back to every child.
- **GRBL.** Stock GRBL 1.1 is built without `M7` (it stops with `error:20`). LoftLine cannot know how a controller was compiled, so
  Mist stays available; Help and the GRBL post's notes say to use Air on a stock GRBL.
- Toolpath form: Coolant (Off / Mist / Air). An older LoftLine drops coolant from a project silently (no format bump): acceptable,
  coolant never changes a depth.

### 2. The machine's park-and-probe settings

`ToolChangeProbe` (PostCore), optional field `toolChangeProbe` on `MachineDefinition` (nil = off, the default for every built-in), in
machine units, with `scaled(by:)` used by both `applied(to:)` and the Machines editor's units switch:

- `parkX`, `parkY`, `parkZ`: machine coordinates (`G53`). Convention, stated in Help and checked: machine Z 0 is the top of travel and
  Z is negative downward; `-zTravel/4 ≤ parkZ ≤ 0`; `|parkX| ≤ xTravel`, `|parkY| ≤ yTravel` (either sign: X/Y conventions differ).
  `G53` is meaningful only on a homed machine (Help, TESTING).
- `plateThickness`, `plateSize` (largest dimension): positive.
- `probeFeed`: positive, at most 10 in/min (250 mm/min), so overshoot after contact stays negligible.
- `probeTravel`: positive, at most Z travel.
- `controller`: `.grbl` (probe `G38.2`, which alarms when it ends without contact) or `.mach4` (probe `G31`).
- `probeCheckLines: [String]` (Mach4 only): lines written right after the probe and before Z is set, that must stop the program when
  the probe made no contact. Mach4's `G31` does not stop by itself, and the exact check depends on the controller's set-up, so it is
  the owner's own line(s), confirmed by the air-probe procedure. A Mach4 probe with no check lines cannot post (thrown error).
  The lines may carry no axis words (validator).
- `workOffset`: 1 to 6 (`G54` to `G59`), default 1. Z is set with `G10 L20 P{workOffset}`, never `P0` (on Mach4 `P0` is not the active
  work offset).

`ToolChangeProbe.problems(limits:)` gives these checks to both the Machines editor and the builder.

**How it reaches the post.** `MachineDefinition.applied(to:)` already folds the machine's limits into the effective post. It also
assigns, unconditionally, the effective profile's `toolChangeProbe` (the machine's, scaled to the post's units, or nil). That field
of `PostProfile` uses a coding wrapper that is never encoded and never decoded, so no post file or project copy can carry or switch
on probing; a post with "no machine" never probes. `ProgramBuilder` and `GCodeValidator` read it from the profile they are given.

**Schema.** `MachineDefinition.currentSchemaVersion` becomes 2. Part 1's `schemaVersion` has not shipped in a release (it is not in
`v0.2.0`), and parts 1 and 2 ship together, so a machine is normalised to the current version when it is read; no
"lowest version written" rule is needed. Tests that use "2" as the newer version move to `currentSchemaVersion + 1`.
`PostProfile` stays at 1.

### 3. The job's touch-off spot

`JobSetup.touchOffSpot: Vec2?`, material frame, document units; scaled in `JobSetup.scaled(by:)` and kept exact across a units round
trip in `JobSetupForm.setUnits`, like `datumOffset`. Each sheet's `JobSetup` has its own; Job Setup edits the current sheet's. Editing
it marks toolpaths stale like any job edit (as `datumOffset` does). Nil means not set.

### 4. The sequence

With park-and-probe on, the sequence **replaces** the post's `toolChange` lines and the tool-length offset. Written before the first
toolpath and at every tool change:

1. Retract to safe Z (as today, when a tool was cutting); `M9` if coolant is on; `M5`; `G90`.
2. `G53 G0 Z{parkZ}`, then `G53 G0 X{parkX} Y{parkY}`.
3. `T{n}`, a comment "Load T{n}: {name}", `M0`.
4. `G53 G0 Z{parkZ}` again (the operator may have jogged down during the swap).
5. `G0 X{spot} Y{spot}` through `MachineCoordinates.machineXY`, in the post's units, no Z word (the bit crosses at the park height).
6. A comment "Place the touch plate under the bit", `M0`. The plate goes where the bit is, not at a coordinate.
7. `G91`, `{G38.2 | G31} Z-{probeTravel} F{probeFeed}`, `G90`; then the Mach4 `probeCheckLines`.
8. `G10 L20 P{workOffset} Z{plateZ}`, `plateZ = MachineCoordinates.z(aboveTop: plateThickness)` (material top: the plate thickness;
   spoilboard: material thickness plus plate thickness).
9. `G0 Z{clearZ}`, `clearZ = z(aboveTop: plateThickness + job.safeZ)`: always up from the plate.
10. A comment "Remove the touch plate", `M0`.
11. Re-enter from above: hold `max(clearZ, approach height)`, cross X/Y to the next toolpath at that height, and only then descend;
    nothing moves down at the spot (a plate left in place is never hit). Then the spindle start, dwell and coolant.

The stops are written as `M0` directly, not through the post's pause lines (a custom pause template need not stop). The probe feed
is written rounded **down** at `feedDecimals`. Lengths use `decimals`. `G92` is never written. The header is unchanged.

**Refused (thrown `PostError`):** probing on with no touch-off spot; probing with `useToolLengthOffset`; `ToolChangeProbe.problems`;
`plateThickness + safeZ` beyond Z travel; a Mach4 probe with no `probeCheckLines`; tiled export or a two-sided job with probing on
(the spot's frame is not defined per tile or per side; a later part can add it).

### 5. The spot is checked against the whole sheet

At export, whatever is being written (a whole program, one toolpath, one file per tool or per toolpath), the plate footprint (a
square of `plateSize` centred on the spot) must be:

- inside the material, and outside every keep-out zone and clamp layer (both stores: `doc.keepOutZones` and `Fixtures.zones`);
- clear of every move below the material top of **every enabled toolpath on the sheet**, in any file: the plate must never rest on
  material any tool removes. This reuses `LayoutChecks.keepOut` with a zone of the plate footprint at height 0 (it already grows a
  zone by the tool radius and tests every segment below the zone's top).

Each failure refuses the export with its message.

### 6. The validator recognises the sequence by value

Only when the profile carries a `ToolChangeProbe`; otherwise every rule is today's. The validator tracks one state per tool change:
`cutting → parked → atSpot → probed → zeroed → cutting`. A pre-pass marks the `G91` / probe / `G90` triple so the incremental
warning is not raised for it.

- `G53 G0` with targets equal to the park values (tolerance, so rounding at `decimals` passes): no coordinate-shift warning, not
  counted in the travel extents; X, Y and Z become unknown; state `parked`. A stop while parked keeps it parked; a `G53 G0 Z{parkZ}`
  after the stop is required before the spot move.
- The spot rapid: `G0 X Y` equal to `machineXY(spot)` (computed by the validator from the job), no Z, only while parked: state
  `atSpot`, no unknown-Z warning.
- The probe triple: non-motion (it is not checked as a rapid or a cut, and does not widen the Z extent), distance ≤ `probeTravel`,
  feed ≤ `probeFeed` (plus half a feed digit), the command matching the controller; the motion mode becomes unknown afterwards.
  `31` and `38.2` join the known G codes. State `probed`. Check lines after it may carry no axis words.
- `G10 L20 P{workOffset} Z v`: only when `probed`, and `v` equal to `z(aboveTop: plateThickness)` from the validator's own job and
  machine values (an independent check of the builder's units, mode and thickness, both through the single Z-zero helper). Z = `v`,
  state `zeroed`; the next Z move must go up, and no move goes below `clearZ` until X/Y has left the spot.
- With probing on, a `T` word starts a tool change: a cut (`G1`/`G2`/`G3`) before the state is `zeroed` again is an error, so a
  missing or incomplete sequence fails.

`GCodeReader` (the preview) handles the codes, not the values: `G31`/`G38.x` is non-modal and not drawn, `G10 L20` with Z sets the
preview's Z, `G53` gives no "not previewed" note, and a `T` word that changes the tool starts a new tool segment (with or without
`M6`), so a two-tool program previews as two tools with no phantom plunge.

### 7. What the user sees

- Toolpath form: Coolant (Off / Mist / Air).
- Preferences > Machines: a "Tool change: park and probe" switch with its values, the controller and the Mach4 check lines, the
  problems shown as the user types.
- Job Setup: the touch-off spot when the machine has park-and-probe on.
- Deferred: a canvas marker for the spot, header lines, and adding the probe time to the estimate (the user's tool-change allowance
  covers it).

## Tests

1. Coolant: codes only where the state changes; `M9`, `M8` for Mist to Air; `M9` before every change, pause and the footer; a toolpath
   after a pause turns it back on; a change without an RPM change; a multi-toolpath operation's first toolpath gets it; single
   operation, file per toolpath and per tool carry it; all Off byte-identical to the golden; merge refused when coolants differ, split
   restores it; changing coolant leaves a calculated toolpath fresh.
2. Sequence: exact lines for one and two tools, GRBL and Mach4, inch and mm posts, an mm document with an inch post, `.center` origin
   with a datum offset, both Z-zero modes (`plateZ`, `clearZ`), plate thicker than safe Z (nothing below `clearZ` at the spot), probe
   feed rounded down (`4.99` in/min → `F4.9`; inch machine, mm post `126.746` → `F126`), `toolChange` and `G43` absent, `G90` before
   the park.
3. Refusals: no spot, `G43`, machine problems, plate + safe Z beyond travel, Mach4 with no check lines, tiled and two-sided with
   probing, spot near an edge, in a keep-out zone, in a clamp, over a pocket in another file (file per tool, single operation).
4. Validator: the builder's program has no coordinate-shift, incremental, unknown-G, unknown-Z, too-deep or spindle-off warnings and
   still catches a too-deep cut after the second tool; wrong `G10` value or work offset, probe longer or faster than allowed, a park
   or spot that is not the computed one, a cut before `zeroed`, a down move at the spot, check lines with an axis word: errors;
   limits exactly at the rounding edge pass; without a probe on the profile, today's warnings.
5. A post JSON carrying a `toolChangeProbe` key posts no sequence, with and without a machine; `applied(to:)` with probing off clears
   it.
6. Preview: two tool segments, no phantom plunge, Z after `G10 L20`.
7. Schema: a machine with a probe round-trips at 2; a machine file at 1 is read and normalised to 2; a project carrying a machine
   newer than supported is refused.
8. Goldens, samples and `scripts/check-samples.sh` unchanged; the full suite green.

## Risks

- **Mach4 probing.** `G31` does not alarm without contact; the program relies on the owner's `probeCheckLines`, confirmed by the
  air-probe procedure in TESTING.md (plate held under the bit; no plate with a hand on the E-stop; bit over bare wood; `G10 L20 P1`
  sets G54 Z; a dry run to the park position confirms the `G53` signs and the top-quarter Z). The feature is off by default and a
  Mach4 probe cannot post without check lines.
- **Park in machine coordinates.** A wrong value can drive the gantry into a fixture; the checks cover the envelope only.
- **A plate left on the material.** The re-entry never moves down at the spot, but a plate left there is still on the work.
- **Spoilboard mode.** The new Z comes from the probed material top minus the entered thickness, so a wrong thickness moves
  through-cuts, and the zero stays in the controller's work offset after the program. Help recommends material-top mode with probing.
- **Mach4 tool number.** `T{n}` without `M6` tells Mach4 the next tool but may not update its current-tool display; no tool-length
  offset is used, so Z does not depend on it. Confirmed in the air-probe procedure.

## Out of scope

A fixed tool setter, probing the material top or XY corner at the start, dust-collector control, automatic tool changers, and the
post editor (part 3).

## Docs

`docs/DECISIONS.md` (`park-and-probe`, `coolant`), `docs/PARITY.md` (add coolant and tool-change-probe rows), `TESTING.md` (the
air-probe procedure, the coolant check), Help (Toolpaths, Machines, Job Setup).

## Order of work

Coolant ships as its own commits first (model, stamping, builder, form). Then: 2. `ToolChangeProbe`, the schema normalisation,
`applied(to:)` and the touch-off spot. 3. The sequence and the refusals in `ProgramBuilder`. 4. Validator states and the preview
reader. 5. The whole-sheet spot check. 6. UI (Machines, Job Setup). 7. Docs and the air-probe procedure.
