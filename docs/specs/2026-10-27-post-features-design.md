# LoftLine: coolant, park-and-probe tool changes

Part 2 of the post-processor work (part 1, self-contained projects, is on main at `8ec72f7`). Parts 3 to 5 (post editor, sharing a
post, more built-in posts) are out of scope.

## Decisions already taken (confirmed with the owner)

1. **Coolant is mist or air**, chosen **per toolpath** (Off / Mist / Air): `M7` mist, `M8` air, `M9` off.
2. **A tool change parks, waits for a manual swap and re-zeroes Z with a touch plate.** Every tool is probed, the first one too.
3. **The touch plate lies on the material.** Z after the probe is the plate's top above the material top.
4. **Park and touch-plate settings belong to the machine definition** (Preferences > Machines), and travel in the project's machine
   copy from part 1.
5. **Avid Mach4 first, GRBL where it can.** GRBL gets the same features where its dialect has them (it has `M7`/`M8`/`M9`, `G53`,
   `G38.2`, `G10 L20`).

One refinement, agreed in the design discussion: **the swap and the probe happen at two places.** The gantry parks at a machine-coordinate
position (`G53`) for the swap, then moves to a **touch-off spot** given in job coordinates, on the material, and probes there. LoftLine
cannot know where the material is in machine coordinates, so only a spot in job coordinates can be checked to be over the stock.

## Goals

- A program for a multi-tool job runs start to finish on the Avid with manual tool changes and no hand-zeroing, and every Z after a
  change is measured, not assumed.
- **Nothing changes until it is switched on.** Coolant defaults to Off, park-and-probe is off on every built-in machine, so today's
  G-code, `samples/expected/`, `samples/*.tap` and every golden stay byte-identical.
- The validator keeps checking depth after a probe sequence. Today `G91`, `G10` and `G53` each make it warn "depth checks no longer
  apply" for the rest of the program; the sequences this part writes must not switch the checks off.

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

### 1. Coolant

- `Coolant` (CAMCore): `enum { case mist, air }`. `OperationSetup.coolant: Coolant?` (nil = off, decoded absent as nil so every older
  file loads) and `Toolpath.coolant: Coolant?`, copied the way `pauseAfter` is (`GCodeExporter.toolpaths`, merge, templates).
- Post fields (optional, nil = the default): `coolantMist` (`M7`), `coolantAir` (`M8`), `coolantOff` (`M9`).
- The program: after the spindle start of a toolpath whose coolant differs from the current state, write that code (or `M9`).
  `M9` is written before every tool change, before every pause and before the footer when coolant is on. A program whose
  toolpaths all have coolant Off writes no coolant codes at all (byte-identical to today).
- Toolpath form: a Coolant picker (Off / Mist / Air) beside the pause setting.

### 2. Park and probe

`ToolChangeProbe` (PostCore), an optional field `toolChangeProbe` on `MachineDefinition` (nil = off, the default for every built-in):
`parkX`, `parkY`, `parkZ` (machine coordinates, machine units), `plateThickness`, `probeFeed`, `probeTravel` (the furthest the probe
may move down), all in machine units.

`JobSetup.touchOffSpot: Vec2?` (material frame, document units; nil = 1 in, or 25 mm, in from the lower-left corner of the
material). Shown in Job Setup when the machine has park-and-probe on, and drawn on the canvas as a small target.

The sequence, before the first toolpath and at every tool change, when the project's machine has `toolChangeProbe`:

1. `M9` if coolant is on, then the spindle off (`M5`).
2. Park: the post's `parkLines`, default `G53 G0 Z{PARK_Z}` then `G53 G0 X{PARK_X} Y{PARK_Y}`.
3. Swap: the post's `swapLines`, default the pause lines with the message "Load T{T}: {TOOL_NAME}, put the touch plate on the
   material at the target, then Cycle Start" and `M0`.
4. Over the spot: `G0 X{SPOT_X} Y{SPOT_Y}` in work coordinates with no Z word, so the bit stays at the park height while it crosses.
5. Probe: the post's `probeLines`. Mach4 default `G91 G31 Z-{PROBE_TRAVEL} F{PROBE_FEED}` then `G90`; GRBL default
   `G91 G38.2 Z-{PROBE_TRAVEL} F{PROBE_FEED}` then `G90`.
6. Set Z: `G10 L20 P0 Z{PLATE_Z}`, where `PLATE_Z` is `MachineCoordinates.z(aboveTop: plateThickness)` (material-top mode: the plate
   thickness; spoilboard mode: material thickness plus plate thickness). The plate thickness is converted to the post's output units.
7. `G0 Z{SAFE_Z}`, then a stop asking to remove the plate (`M0`, message "Remove the touch plate, then Cycle Start"), then the
   existing `reenter`, spindle start and coolant.

The values are written in the post's output units with the post's `decimals`. `G92` is never written.

The existing `toolChange` lines (`T{T} M6` on the Avid) still come first in the sequence, so Mach4 knows the tool number; with
park-and-probe on, the built-in Avid posts' `toolChange` has no motion of its own.

### 3. The validator understands the sequence

The sequence is bracketed by two comments the builder writes, `LoftLine tool change T<n> begin` and `... end`, in the post's comment
style. Inside a bracket the validator:

- checks each `G53` target against the machine's travel (`parkX`/`parkY` within the X/Y travel, `parkZ` at or below 0 in machine
  coordinates, the usual top of travel) and does not treat it as a coordinate shift;
- accepts exactly one incremental probe block (`G91` then `G31`/`G38.2`, then `G90`), and checks the probe distance is at most
  `probeTravel`;
- accepts `G10 L20 P0 Z<v>` and continues with the known Z = `v`, so every depth check after the bracket still runs;
- errors on anything else that moves, and on a bracket that is not closed.

Outside a bracket, `G10`, `G53`, `G91` keep today's warnings. A post template cannot open a bracket of its own: the builder writes
the bracket comments, and a template line that renders to the bracket text is refused at export.

### 4. Checks before export (errors)

- The touch-off spot is inside the material and outside every keep-out zone.
- The park position is within the machine's travel.
- `plateThickness`, `probeFeed` and `probeTravel` are positive, and `probeTravel` is at most the machine's Z travel. (Whether it is
  long enough to reach the plate from the park height is not knowable: the bit length changes with every tool.)
- A post with park-and-probe on must have non-empty `probeLines` (a GRBL or Mach4 default, or the user's own).

### 5. Schema and copies

- `PostProfile` and `MachineDefinition` go to `schemaVersion` 2 (the new optional fields). Part 1 makes this safe: an older LoftLine
  refuses a project or a file with schema 2 instead of dropping the fields.
- A post or machine written by this LoftLine writes 2 only when it uses a new field; a post or machine that uses none still writes
  1, so posts and projects that do not use the features open in the previous release. (`schemaVersion` = the lowest version that
  holds everything the definition uses.)
- `OperationSetup.coolant` and `JobSetup.touchOffSpot` are optional and need no format bump (`formatVersion` stays 2).

### 6. What the user sees

- Toolpath form: Coolant (Off / Mist / Air).
- Preferences > Machines: a "Tool change: park and probe" group with the six values and a short note on what the program will do.
- Job Setup: the touch-off spot (X, Y) when the machine has park-and-probe on.
- The program header lists "Tool change: park at X… Y… Z…, probe at X… Y…" and the coolant per toolpath.

## Tests

1. Coolant: codes appear exactly where the state changes; `M9` before every change, pause and the footer; Off everywhere writes
   none (byte-identical to the current golden); GRBL and Mach4.
2. Park-and-probe sequence: the exact lines for one and two tools, the first tool included, in inch and mm posts, both Z-zero modes
   (`PLATE_Z` from `z(aboveTop:)`), units conversion of the machine values.
3. Validator: a program with the sequence has no coordinate-shift or incremental warnings and still catches a too-deep cut after
   the second tool; a bracket with a stray move, an unclosed bracket, a probe longer than `probeTravel`, and a park outside travel
   are errors; `G53`/`G10`/`G91` outside a bracket keep today's warnings; a template that renders a bracket comment is refused.
4. Export checks: touch-off spot outside the material, inside a keep-out zone, park outside travel, zero plate thickness.
5. Schema: a post or machine using a new field writes `schemaVersion` 2 and round-trips; one using none writes 1; this LoftLine
   reads both; a project carrying a schema-2 copy is refused by a LoftLine that supports only 1 (the part 1 test, at 2).
6. Goldens and samples unchanged; the full suite green.

## Risks

- **Mach4's `G31` without contact.** GRBL's `G38.2` alarms when it reaches the end of its travel without touching; Mach4's `G31`
  may simply stop there and carry on, and the program would then zero Z in the air. The feature is off by default; TESTING.md gets
  an air-probe procedure (probe once with the plate held under the bit, once with no plate and a hand on the E-stop) that must be
  run before it is used on material, and the Avid post's `probeLines` are user-editable so the owner can add Mach4's contact check
  once confirmed on his controller.
- **The park position is in machine coordinates.** A wrong value moves the gantry into a hard stop; the travel check catches values
  outside the machine's envelope but not a fixture in the way.
- **A plate left on the material.** The stop after the probe asks for it to be removed; nothing can verify that it was.

## Out of scope

A fixed tool setter, probing the material top or XY corner at the start, dust-collector control, automatic tool changers, and the
post editor (part 3).

## Docs

`docs/DECISIONS.md` (`park-and-probe`, `coolant`, `probe-bracket`), `docs/PARITY.md` (coolant and tool-change rows), `TESTING.md`
(the air-probe procedure, the coolant check), Help (Toolpaths, Machines, Job Setup).

## Order of work

1. Coolant model and post output. 2. Machine `toolChangeProbe`, job touch-off spot, schema 2 rule. 3. The sequence in
`ProgramBuilder`. 4. The validator bracket. 5. Export checks. 6. UI (toolpath form, Machines, Job Setup, canvas target). 7. Docs and
the air-probe procedure.
