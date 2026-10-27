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

Revised after the round 1 review (Executor, Auditor, Claude Skeptic, Claude Simplifier). The main change: **the builder writes the
park-and-probe sequence in code**, and the validator recognises its constructs by value. There are no new post template fields, no
comment markers (the G-code parser strips comments, and a user's pause text could forge one), and `PostProfile` stays at schema 1.

### 1. Coolant

- `Coolant` (CAMCore): `enum { case mist, air }`. `OperationSetup.coolant: Coolant?` (nil = Off, absent in every older file) and
  `Toolpath.coolant: Coolant?`, filled where `pauseAfter` is (`GCodeExporter.toolpaths`). Codes are fixed: Mist `M7`, Air `M8`,
  Off `M9` (all already known to the validator).
- **State machine in the builder.** The builder tracks the coolant that is on. Before a toolpath's moves (after its spindle start,
  if there is one), when the toolpath's coolant differs from the state: write `M9` if anything is on, then `M7` or `M8` for the new
  one (so Mist to Air never leaves both running). Before every tool change, before every pause and before the footer, write `M9`
  if coolant is on and set the state to Off, so a toolpath after a pause turns its coolant back on. A program whose toolpaths all
  have coolant Off writes no coolant code at all.
- **Post-time only.** Like the pause, coolant does not change a toolpath's moves: the comparison that decides whether a toolpath is
  stale (`AnyOperation.withoutPause`) also ignores coolant, so changing it never recalculates.
- **Merge.** Merging two toolpaths whose coolant differs is refused (beside the existing same-tool rule in `MergeCommands`); a merged
  toolpath carries the shared coolant.
- **GRBL.** Stock GRBL 1.1 is built without `M7`. LoftLine does not know how a controller was compiled, so Mist stays available, and
  Help and the GRBL post's notes say to use Air on a stock GRBL (the controller stops with `error:20` on `M7`).
- Toolpath form: a Coolant picker (Off / Mist / Air) beside the pause setting. An older LoftLine opening a project with coolant
  set drops it silently (no format bump): acceptable because coolant never changes a depth.

### 2. The machine's park-and-probe settings

`ToolChangeProbe` (PostCore), an optional field `toolChangeProbe` on `MachineDefinition` (nil = off, the default for every built-in),
in machine units:

- `parkX`, `parkY`, `parkZ`: machine coordinates (`G53`). Convention, stated in Help and checked: machine Z 0 is the top of travel
  and Z is negative downward (Mach4 and GRBL both home Z to the top); `parkZ` must be in the top quarter of Z travel
  (`-zTravel/4 ≤ parkZ ≤ 0`); `|parkX| ≤ xTravel`, `|parkY| ≤ yTravel` (either sign, since X/Y conventions differ).
- `plateThickness` and `plateSize` (the plate's largest dimension), both positive.
- `probeFeed`: positive, at most 10 in/min (250 mm/min), so the overshoot after contact stays negligible.
- `probeTravel`: positive, at most the machine's Z travel.
- `probeCommand`: `G31` (Mach4) or `G38.2` (GRBL).

One `ToolChangeProbe.problems(machine:)` gives these checks to both the Machines editor and the export.

**How it reaches the post.** `MachineDefinition.applied(to:)` already folds the machine's limits into the effective post. It also
copies `toolChangeProbe`, converted to the post's units, onto a field of the effective `PostProfile` that is never encoded (no post
file and no project copy carries it). `ProgramBuilder` and `GCodeValidator` read it from the profile they are given, so the six
export paths need no new parameters.

**Schema.** `MachineDefinition` splits the two meanings of `schemaVersion`: `supportedSchemaVersion = 2` is what this LoftLine reads;
the version **written** is the lowest that holds what the machine uses (2 with `toolChangeProbe`, else 1), set when the machine is
encoded (`snapshot()`, `toJSON()`). The stored value is not part of equality, so a copy read at 2 equals an installed machine.
A machine that is read at 1, given a probe in Preferences and saved, writes 2. Tests that use "2" as the newer version move to
`supportedSchemaVersion + 1`. `PostProfile` gets no new stored field and stays at 1.

### 3. The job's touch-off spot

`JobSetup.touchOffSpot: Vec2?`, in the material frame and document units; `JobSetup.scaled(by:)` scales it like `datumOffset`. Nil
means not set: with park-and-probe on, a project with no spot is an export error ("Set the touch-off spot in Job Setup"). Job Setup
shows X and Y when the project's machine has park-and-probe on.

### 4. The sequence

With park-and-probe on, the sequence **replaces** the post's `toolChange` lines and the tool-length offset (a post with
`useToolLengthOffset` and a machine with park-and-probe is an export error: `G43` and a probe would disagree on Z). It is written
before the first toolpath and at every tool change:

1. Retract to safe Z (as today, when a tool was cutting); `M9` if coolant is on; `M5`.
2. `G53 G0 Z{parkZ}`, then `G53 G0 X{parkX} Y{parkY}`.
3. `T{n}` (so the controller knows the tool; no `M6`, which on Mach4 runs its own tool-change macro).
4. A stop through the post's pause lines (`M0`): "Load T{n}: {name}. Put the touch plate on the material at the touch-off spot, then
   Cycle Start".
5. `G53 G0 Z{parkZ}` again (the operator may have jogged down during the swap).
6. `G0 X{spot} Y{spot}`: the spot through `MachineCoordinates.machineXY` (origin and datum offset), in the post's units. No Z word, so
   the bit crosses at the park height.
7. `G91`, then `{probeCommand} Z-{probeTravel} F{probeFeed}`, then `G90`.
8. `G10 L20 P0 Z{plateZ}`, where `plateZ = MachineCoordinates.z(aboveTop: plateThickness)`: the plate's top above the material top,
   in material-top mode the plate thickness, in spoilboard mode material thickness plus plate thickness.
9. `G0 Z{clearZ}`, where `clearZ = z(aboveTop: plateThickness + job.safeZ)`: always **up** from the plate, never down to plain safe Z.
10. A stop: "Remove the touch plate, then Cycle Start".
11. The writer resets its modal state and position (X/Y at the spot, Z at `clearZ`), then today's `reenter` (approach height, across
    to the next toolpath), spindle start, dwell and coolant.

Numbers use the post's `decimals`, feeds its `feedDecimals`. `G92` is never written. The program header gains a "Tool change: park
and probe" line and a coolant column only when the program uses them, so every existing program is byte-identical.

### 5. The validator recognises the sequence by value

Only when the profile carries a `ToolChangeProbe`; otherwise every rule is exactly today's.

- `G53 G0` with X/Y/Z equal to the park values (within the validator's tolerance, so rounding to `decimals` passes at the limit):
  no coordinate-shift warning, not counted in the work-coordinate travel extents, and the tracked Z becomes unknown with a `parked`
  flag. While parked, an X/Y rapid raises no unknown-Z warning (the gantry is at the park height by construction). Any other `G53`
  keeps today's warning.
- `G91`, `G31`/`G38.2 Z-d F f`, `G90` as one probe: `d ≤ probeTravel` and `f ≤ probeFeed` (tolerance), no incremental warning, no
  unknown-G warning (31 and 38.2 join the known codes), and the Z word is not a rapid. Sets `justProbed`.
- `G10 L20 P0 Z v`: accepted only right after a probe and only when `v` equals `z(aboveTop: plateThickness)` computed by the
  validator itself from the job and the machine value, an independent check of the Z-zero mapping. Then Z = `v`, and the next Z
  move must go up. Anything else keeps today's coordinate-shift warning.
- A cutting move (`G1`/`G2`/`G3`) while Z is unknown after a park is an error.

`GCodeReader` (the G-code preview) learns the same three constructs: a park and a probe are not drawn as moves, and `G10 L20` sets
the preview's Z, so the preview shows no phantom plunge and no "G53 not previewed" note.

### 6. Checks before export (errors)

- The machine's `ToolChangeProbe.problems` (section 2).
- The spot is set, at least `plateSize/2` inside every edge of the material, outside every keep-out zone and clamp layer
  (`Fixtures`), and **not on material an earlier tool removed**: no move below the material top of any toolpath that runs before
  the last tool change comes within `plateSize/2 + tool radius` of the spot (the plate would rest low and every later cut would
  go that much deeper).
- `plateThickness + safeZ` is within Z travel above the material (so step 9 is reachable).
- `useToolLengthOffset` with park-and-probe on.

### 7. Time estimate

Each park-and-probe adds the worst-case probe (`probeTravel / probeFeed`) to the estimate, beside the existing tool-change
allowance.

### 8. What the user sees

- Toolpath form: Coolant (Off / Mist / Air).
- Preferences > Machines: a "Tool change: park and probe" switch and its values, with the checks shown as the user types.
- Job Setup: the touch-off spot when the machine has park-and-probe on.
- Deferred: a canvas marker for the spot.

## Tests

1. Coolant: codes only where the state changes, `M9` then `M8` for Mist to Air, `M9` before every change, pause and the footer, a
   toolpath after a pause turns it back on, a change without an RPM change, all Off byte-identical to the golden; merge refused
   when coolants differ; changing coolant leaves a calculated toolpath fresh.
2. Sequence: exact lines for one and two tools, inch and mm posts, an mm document with an inch post (spot and machine values
   converted), `.center` origin with a datum offset, both Z-zero modes (`plateZ`, `clearZ`), plate thicker than safe Z (step 9 still
   goes up), `toolChange` and `G43` absent.
3. Validator: a program with the sequence has no coordinate-shift, incremental, unknown-G or unknown-Z warnings and still catches
   a too-deep cut after the second tool; a `G10 L20` with the wrong value, a probe longer than `probeTravel`, a park that is not the
   machine's, a cut while parked and a down move after `G10` are errors; limits exactly at the rounding edge pass; outside a
   probe-on profile the old warnings stand.
4. Preview: no phantom plunge, Z after `G10 L20` correct.
5. Export checks: spot unset, near an edge, in a keep-out zone, in a clamp, over a pocket cut before the change; probe feed and
   travel limits; `G43` with probing.
6. Schema: a machine with a probe writes 2 and round-trips; without one writes 1; read at 1, given a probe, saved: 2; a copy read
   at 2 equals the installed machine; a project carrying a machine copy newer than supported is refused.
7. Goldens, samples and `scripts/check-samples.sh` unchanged; the full suite green.

## Risks

- **Mach4's `G31` without contact.** GRBL's `G38.2` alarms at the end of its travel without contact; Mach4's `G31` may stop there
  and carry on, and `G10` would then zero Z in the air. The feature is off by default. TESTING.md gets an air-probe procedure (with
  the plate held under the bit; then with no plate and a hand on the E-stop; then confirm `G10 L20 P0` sets the active work offset)
  that must pass on the owner's controller before the feature is used on material. A Mach4 contact check, if needed, is a code
  change made after that result.
- **Park in machine coordinates.** A wrong value can move the gantry into a fixture; the checks cover the envelope, not what sits
  on the bed.
- **A plate left on the material.** The stop asks for it to be removed; nothing can verify that it was.
- **Spoilboard mode.** `G10 L20` sets the work Z from the probed material top minus the entered thickness, so a wrong thickness moves
  through-cuts, and the new zero stays in the controller's work offset after the program. Help says so and recommends material-top
  mode with probing.

## Out of scope

A fixed tool setter, probing the material top or XY corner at the start, dust-collector control, automatic tool changers, and the
post editor (part 3).

## Docs

`docs/DECISIONS.md` (`park-and-probe`, `coolant`), `docs/PARITY.md` (add coolant and tool-change-probe rows), `TESTING.md` (the
air-probe procedure, the coolant check), Help (Toolpaths, Machines, Job Setup).

## Order of work

Coolant ships as its own commits first (model, builder, form). Then: 2. `ToolChangeProbe`, the schema split, `applied(to:)` and the
touch-off spot. 3. The sequence in `ProgramBuilder`. 4. Validator recognisers and the preview reader. 5. Export checks and the time
estimate. 6. UI (Machines, Job Setup). 7. Docs and the air-probe procedure.
