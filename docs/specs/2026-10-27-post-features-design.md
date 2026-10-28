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
   with it, `G53`, `G38.2`, `G10 L20`). Mach4 sets the zero through the owner's macro (§2): its `G10 L20` sets the extended
   offset G54.1, not "this position is Z" (Mach4 Mill G-code manual, G10).

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

Revision 8, after three review rounds and four verification passes (Executor, Auditor, Claude Skeptic, Claude Simplifier). **The builder writes the park-and-probe
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
  Z is negative downward; `|parkX| ≤ xTravel`, `|parkY| ≤ yTravel` (either sign: X/Y conventions differ). `G53` is meaningful only on
  a homed machine (Help, TESTING).
- `topZ`: machine Z of the traverse height, `-zTravel/4 ≤ topZ ≤ 0`, default 0. **Every X/Y traverse of the sequence runs at
  `topZ`.** On GRBL, whose machine Z 0 after homing can be the limit switch's trigger point, `topZ` must be at or below −1 mm (−0.04 in)
  after the toward-zero rounding it is written with (`problems`; Help says to use the pull-off distance). Software cannot prove that `topZ` clears the stock (it does not know where the stock top is in machine
  coordinates); the dry run in TESTING checks that the longest bit at `topZ` clears the tallest stock. `-zTravel/4 ≤ parkZ ≤ topZ`;
  `parkZ` is only how far the spindle comes down at the park for the swap.
- `plateThickness`: positive. `plateSize`: the plate's greatest extent (its diagonal, or a round plate's diameter), positive.
- `probeFeed`: positive, at most 10 in/min. The limit is defined once as 254 mm/min = 10 in/min and compared in the probe's own units
  with a small tolerance, so a machine at the limit stays valid across a units switch and with either post.
- `probeTravel`: positive, at most 1 in (25.4 mm, same tolerance rule), and **at most `plateThickness`**. The probe starts where the
  operator jogged the bit to, at or above the plate top (step 6, a gap of half the travel). Neither controller stops a probe that
  misses before its full travel (Mach4's `G31` never does; GRBL alarms only at the end), so the travel is what bounds a missed contact:
  starting at or above the plate top, a travel no longer than the plate never takes the bit below the material top.
- `controller`: `.grbl` (probe `G38.2`, which alarms when it ends without contact) or `.mach4` (probe `G31`).
- `mach4ZeroMacro: Int?` (Mach4 only, 100 to 999): the number of the owner's own Mach4 macro, called right after the probe as
  `M{n} P{plateZ}`. Mach4's `G31` only records the contact position (`#5061`–`#5063`) and does not stop without contact, and Mach4's
  `G10 L20` writes the extended offset G54.1 rather than making the current position a given Z (Mach4 Mill G-code manual, G10 and
  G31). So on Mach4 the macro does both: it stops the program when the probe made no contact, and otherwise sets the active work
  offset so the current Z reads `P`. Its contract, stated in Help with a reference Lua macro: nothing else (no motion, no spindle, no
  other offset). It is confirmed by the air-probe procedure. A Mach4 probe with no macro cannot post. Because a macro can still change
  a mode, the builder follows it with one fixed **recovery line** (below), never the post's own preamble, which is editable and could
  start the spindle or a length offset.
- `workOffset`: 1 to 6 (`G54` to `G59`), default 1. The sequence **selects** it (`G{53+workOffset}`) before it moves to the spot, and
  on GRBL sets Z with `G10 L20 P{workOffset}` (never `P0`), on Mach4 through the macro in that selected offset, so the frame that is
  zeroed is the frame the cuts run in.

`ToolChangeProbe.problems(limits:)` gives these checks to both the Machines editor and the builder; the park values are checked
against the limits of the machine being posted with.

**How it reaches the post.** `MachineDefinition.applied(to:)` already folds the machine's limits into the effective post. It also
assigns, unconditionally, the effective profile's `toolChangeProbe: ProbeSetting?` (`.on` with the machine's probe scaled to the
post's units, `.refused` with the machine's refusal, or nil). That field of `PostProfile`, and the machine's `probeRefusal` below, use
one generic never-coded wrapper (a `KeyedDecodingContainer` overload that ignores the key and a `KeyedEncodingContainer` overload that
writes nothing, so encoded bytes do not change). The profile's field compares by value, so a probe edit in Preferences while an
export sheet is open changes `PostedInputs`, and the sheet re-posts and refuses to save the old program; the machine's
`probeRefusal` compares equal whatever it holds (it never reaches a sheet except through the profile). No
post file or project copy can therefore carry or switch on probing; a post with "no machine" never probes. `ProgramBuilder` and
`GCodeValidator` read it from the profile they are given. **The post must speak the probe's controller:** `PostProfile` has no dialect field, and a machine's
post list is editable, so with probing on `applied(to:)` gives `.refused` unless the post is a built-in post of that controller (the
Avid Mach4 posts for `.mach4`, the GRBL post for `.grbl`). A custom post cannot probe until part 3 lets a post declare its
controller.

**Probe settings always come from the machine installed here.** Part 1 posts with the project's copy of the machine. For probe
settings that would post another shop's park position, or a plate this shop no longer uses. So `ProjectPost.resolve`, after choosing
the machine copy, replaces its `toolChangeProbe` with the installed machine's of the same id, **converted to the copy's units**
(`installed.toolChangeProbe?.scaled(by: installed.units.factor(to: copy.units))`). If the copy has a probe and no machine of that id is
installed, or the installed one has none (including `loftline-cli --builtin-only`), it clears the probe and sets the machine's
`probeRefusal: String?` instead. `applied(to:)` turns the two into the profile's `ProbeSetting` and so carries it into every profile
it builds (the project's post, a post picked in the export or Save All sheet, the preview), and `ProgramBuilder` throws the refusal.
Enforcement is therefore in one place that every export path and the CLI pass through; `--force` cannot write past it. The message:
"This project was set up to probe tool changes on a machine that is not set up for it here." Part 1's copy-differs warning compares
the copy and the installed machine with `toolChangeProbe` cleared on both, so a copy that differs only in its probe gives no warning.

**Schema.** No bump. Part 1's `schemaVersion` has not shipped in a release (it is not in `v0.2.0`) and parts 1 and 2 ship together,
so an optional `toolChangeProbe` is simply part of machine version 1. `PostProfile` stays at 1.

### 3. The job's touch-off spot

`JobSetup.touchOffSpot: Vec2?`, material frame, document units; scaled in `JobSetup.scaled(by:)` and kept exact across a units round
trip in `JobSetupForm.setUnits`, like `datumOffset`. Each sheet's `JobSetup` has its own; Job Setup edits the current sheet's. Editing
it marks toolpaths stale like any job edit (as `datumOffset` does). Nil means not set.

### 4. The sequence

With park-and-probe on, the sequence **replaces** the post's `toolChange` lines and the tool-length offset. Written before the first
toolpath and at every tool change:

1. Retract to safe Z (as today, when a tool was cutting); `M9` if coolant is on; `M5`; `G90 G{53+workOffset}`.
2. `G53 G0 Z{topZ}`, `G53 G0 X{parkX} Y{parkY}`, then `G53 G0 Z{parkZ}` (down at the park only). The writer's modal state is reset
   after the first `G53` (it no longer knows where the tool is).
3. `T{n}`, a comment "Load T{n}: {name}", `M0`.
4. `G53 G0 Z{topZ}` (back up, whatever the operator jogged during the swap).
5. `G0 X{spot} Y{spot}` through `MachineCoordinates.machineXY`, in the post's units, written by a writer call that always emits both
   X and Y and never a Z (the bit crosses at `topZ`, in the frame step 1 selected).
6. A comment "Clip the probe lead on the bit and touch the plate to it: the probe light must come on. Place the plate under the bit.
   Jog Z only, down to about {gap} {unit} above the plate", `M0`, where `gap` is half of `probeTravel`. The plate goes where the bit
   is; X and Y must not be jogged (the footprint check assumes the spot).
7. `G91`, `{G38.2 | G31} Z-{probeTravel} F{probeFeed}`, `G90`.
8. Set Z to `plateZ = MachineCoordinates.z(aboveTop: plateThickness)` (material top: the plate thickness; spoilboard: material
   thickness plus plate thickness). GRBL: `G10 L20 P{workOffset} Z{plateZ}`. Mach4: `M{mach4ZeroMacro} P{plateZ}`, then the recovery
   line `G17 G40 G49 G80 G90 G94 G{90.1|91.1} G{20|21} G{53+workOffset}` (the arc mode the post uses, its units, the work offset).
9. `G0 Z{clearZ}`, `clearZ = z(aboveTop: plateThickness + job.safeZ)`: always up from the plate. The `G0` is written out (after
   `G38.2` the motion mode is the probe); writing the sequence through `GCodeWriter.code` gives this already.
10. A comment "Remove the touch plate", `M0`.
11. Re-enter from above: `reenter` gains a height parameter and holds `max(clearZ, approach height)`, crosses X/Y to the next toolpath
    at that height, and only then descends; nothing moves down at the spot (a plate left in place is never hit). Then the spindle
    start, dwell and coolant. `reenter` already resets the writer's feed, so the first feed move restates `F`.

The stops are written as `M0` directly, not through the post's pause lines (a custom pause template need not stop). The probe feed
and the travel are written rounded **down** (at `feedDecimals` and `decimals`, flooring `v·10^d + 1e-9` so `50.8 mm` on an inch post
is `2.0000`, not `1.9999`); if either formats to zero the post is refused. Every `G53` value is rounded **toward zero**, so a
park on the envelope edge never lands a rounding digit beyond it. `G92` is never written. The header is unchanged.

**Refused in the builder:** one `PostError.probe(String)` case carries every message, and `GCodeExporter.export` catches it once.
Probing on with no touch-off spot; probing with `useToolLengthOffset`; `ToolChangeProbe.problems`; `plateThickness + safeZ` beyond Z
travel; a Mach4 probe with no `mach4ZeroMacro`; a post that is not a built-in post of the probe's controller (`.refused`); a probe feed or travel that formats to zero;
`plateZ` written more than 0.001 in (0.025 mm) away from its value (a post with too few `decimals`); a `.refused` probe setting (§2); a
two-sided job with probing on (`job.isTwoSided` is on the `PostJob`, and a side export keeps it). **Tiled export** with probing on is
refused in `TiledExport.files`: every tile's result carries the refusal as its error and no text (a tile is not marked on the
`PostJob`). The spot's frame is not defined per tile or per side; a later part can add it. Help says where probing is switched off
(Preferences > Machines), since that is the way out for a job that cannot be probed.

### 5. The spot is checked against the whole sheet

At export, whatever is being written (a whole program, one toolpath, one file per tool or per toolpath), the plate footprint must be:

- inside the material, and outside every keep-out zone and clamp layer (both stores: `doc.keepOutZones` and `Fixtures.zones`);
- clear of every move below the material top of **every toolpath on the sheet, switched on or off**, in any file: the plate must
  never rest on material any tool removes, and a pocket already cut and then switched off is still a pocket. This reuses
  `LayoutChecks.keepOut` with a zone of the plate footprint at height 0 (it already grows a zone by the tool radius and tests every
  segment below the zone's top). Help says the check knows the current design only, not cuts from an earlier version of it or from
  another project.

The footprint is a disc of radius `plateSize` (the plate's greatest extent) around the spot: the bit may touch the plate anywhere,
including a corner, and the plate may lie at any angle. Zones are polygons, so the disc is approximated by a polygon that
circumscribes it. Help notes that stock narrower than twice `plateSize` cannot be probed.

**Which sheet.** The sheet whose `JobSetup` is being posted: for an `.operation(id)` export, `sheetID(of: op)` (whatever sheet is on
screen); for a whole program, the current sheet, as `sideProject` already chooses.

**Where its toolpaths come from.** `GCodeExporter.export` gains `sheetToolpaths: [Toolpath]? = nil`: every operation of that sheet,
switched on or off, all files, ungrouped, built by one helper beside `GCodeExporter.toolpaths` from the project and the calculated
results. With a probing profile, `nil` refuses ("park and probe needs the whole sheet to check the touch-off spot"), so a caller
that forgets it fails closed and the existing tests need no edit; the list must also contain the toolpaths being exported. Callers
that pass it: `ExportGCodeSheet`, `LoftLineCLI`, `ValidationReport` (once per report) and `GCodeBatchExport`; `TiledExport` passes
nothing (it is refused anyway). **Calculation targets are kept apart from exported targets**: with probing on, the export sheet, Save
All, Check Toolpaths and the CLI calculate every operation of the sheet, while the missing-from-the-program errors still judge only
what is exported. The calculation runs in the same step as the post, so the results are fresh; as a backstop, an operation of the
sheet with no result, or a switched-on operation whose calculation failed, refuses the export with its own message (a switched-off
one that failed has nothing to check and is skipped). Each failure is returned the way thrown `PostError`s are, an error message and
no text, so there is no Save Anyway.

### 6. The validator recognises the sequence by value

Only when the profile carries an `.on` probe setting; otherwise every rule is today's. **The program starts in `needsProbe`.** The
sequence's states and transitions:

| From | Block | To |
|---|---|---|
| `needsProbe`, `ready` | `G53 G0 Z{topZ}` | `lifted` (remembering where it came from) |
| `lifted` | `G53 G0 X{parkX} Y{parkY}` | `parked` |
| `lifted` | any other block except a repeated `G53 G0 Z{topZ}` | back where it came from (a pause or footer that lifts) |
| `parked` | `G53 G0 Z{parkZ}` | `parked` |
| `parked` | the `T` word | `swapReady` |
| `swapReady` | `M0` | `swapped` |
| `swapped` | `G53 G0 Z{topZ}` | `leaving` |
| `leaving` | the spot rapid, `G0 X Y` equal to `machineXY(spot)` from the validator's own job, no Z | `atSpot` |
| `atSpot` | `M0` (the placement stop) | `placed` |
| `placed` | the probe unit (below) | `probed` |
| `probed` | the zero: GRBL `G10 L20 P{workOffset} Z v`; Mach4 `M{mach4ZeroMacro} P v` and the recovery line | `zeroedAtSpot` |
| `zeroedAtSpot` | `G0 Z{clearZ}` (up from `v`) | `cleared` |
| `cleared` | `M0` (the removal stop) | `ready` |

Compared blocks ignore their `N` word (the tokenizer keeps it as a word).

- **Any block the table does not list leaves the state unchanged and gets today's checks** (comments, `M5`, `G90 G5x`, the pause
  lines, `M3`/`G4`/coolant, the footer, re-entry and cutting moves in `ready`).
- **State-gated errors:** a cut (`G1`/`G2`/`G3`) or a spindle start outside `ready`; a `T` outside `parked`; a `G53` X/Y move outside
  `lifted`; the spot rapid outside `leaving`; a probe word outside a complete probe unit in `placed`; a zero (`G10`, or the Mach4
  macro) outside `probed`; from `zeroedAtSpot` on, through `cleared` and into `ready`, a Z move down or any move below `clearZ` until
  a block first moves X/Y off the spot (the re-entry's cross); the spindle on at the `T`, at either `M0` of the sequence or at the
  probe. A `G53` move that is not `topZ` or the park keeps today's coordinate-shift warning. So a missing first sequence, a dropped
  park, swap stop, placement stop, clear move or removal stop each fail. A sequence deleted together with its `T` cannot be seen (there
  is no other sign a tool changed), and the tests do not expect it.
- `G53` moves whose targets equal `topZ` or the park values (tolerance, so rounding at `decimals` passes) give no coordinate-shift
  warning and are not counted in the travel extents; X, Y and Z become unknown.
- **Work offset, modal.** The validator tracks the active `G54` to `G59`; it must equal `G{53+workOffset}` at the spot rapid, at the
  zero (the `G10`, or the Mach4 macro, which zeroes whatever offset is active) and at every cut, and a `G54` to `G59` from `leaving`
  through `probed` is an error. (A custom preamble that writes `G54` before step 1 selects `G55` is therefore fine.)
- **The probe unit, by block lookahead.** In `placed`, the main loop looks ahead over parsed blocks for `G91`; the probe block, which
  may hold only the controller's probe word, a negative `Z` and `F` (no X/Y, no `M`/`S`/`T`), with distance ≤ `probeTravel` and feed
  ≤ `probeFeed` (each plus half a digit); then `G90`. It consumes them as one `probe` event, so the incremental rule never sees them.
  A probe word without the `G91` before it or the `G90` after it, or anywhere outside `placed`, is an error. After the unit the
  motion mode is unknown, and the next axis block without a motion word is an error (not today's warning). `31` and `38.2` join the
  known G codes.
- **The zero.** `v` must equal `z(aboveTop: plateThickness)` from the validator's own job and machine values (an independent check of
  the builder's units, mode and thickness, both through the single Z-zero helper); Z = `v` afterwards. GRBL: `G10 L20 P{workOffset}
  Z v`. Mach4: the `M` block equal to `mach4ZeroMacro` with `P v` (exempt from the unknown-M warning), followed by the recovery line
  equal to the fixed one, which the validator builds from the profile itself (its own arc mode and units), not through the builder; a Mach4 probe unit not followed by both is an error, and so is a `G10 L20` on Mach4.

`GCodeReader` (the preview) handles the codes, not the values: `G31`/`G38.x` is non-modal and not drawn, `G10 L20` with Z sets the
preview's Z (and so does an `M` block with a `P` right after a probe), and `G53` gives no "not previewed" note. Tool segments: a program with any `M6` keeps today's rule (a segment starts at
`M6`), so a post that pre-stages the next tool is unchanged; only a program with no `M6` starts a segment at a `T` word that changes
the tool, so a two-tool probed program previews as two tools with no phantom plunge.

### 7. What the user sees

- Toolpath form: Coolant (Off / Mist / Air).
- Preferences > Machines: a "Tool change: park and probe" switch with its values, the controller and the Mach4 zero macro number, the
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
   feed rounded down (`4.99` in/min → `F4.9`; inch machine, mm post `126.746` → `F126`), travel floored with the epsilon (1.13 in →
   `Z-1.1300`; a 25.4 mm machine on an inch post → `Z-1.0000`), `toolChange` and `G43` absent, `G90 G54` (and `G55` with `workOffset`
   2) before the park, every `G53` X/Y move after a `G53 G0 Z{topZ}` (`topZ` 0 and −1 mm), the Mach4 `M{macro} P{plateZ}` followed by the fixed
   recovery line (with `G90.1` on an absolute-IJ Mach4 post, `G91.1` otherwise), GRBL `G10 L20 P{n} Z{plateZ}`, `G0` written on the move after the probe, `F` restated on
   the first feed move after the sequence, the spot rapid writing X and Y and no Z when the previous toolpath ended at the spot's X,
   the placement comment with the gap and its unit, the same lines with line numbers on.
3. Refusals, each giving no text: no spot, `G43`, machine problems (`mach4ZeroMacro` outside 100–999; `topZ` above 0 or below
   `−zTravel/4`; `parkZ` above `topZ` or below `−zTravel/4`; `|parkX|` or `|parkY|` beyond travel; feed over 10 in/min; travel over
   1 in or over the plate thickness; a GRBL `topZ` above −1 mm; `workOffset` 0 or 7; `plateThickness` or `plateSize` ≤ 0), plate + safe Z beyond travel, Mach4
   with no zero macro, a post that is not a built-in post of the probe's controller (a GRBL post on the Mach4 machine, a custom post; in the export sheet
   and the CLI), `plateZ` 0.4 on a post with 0 decimals, feed or travel that formats to zero (mm post with zero feed decimals), two-sided with probing (builder, also a
   single side), tiled with probing (every tile's result), a project copy with probing for a machine not installed or installed
   without probing (also `--builtin-only`, and `--force` does not write past it); `sheetToolpaths` nil with probing; spot near an
   edge (disc of radius `plateSize`, a 3 × 3 in plate touched at a corner), in a keep-out zone, in a clamp, over a pocket in another
   file (file per tool, single operation, CLI); a multi-sheet project with a pocket under sheet B's spot and a single toolpath of sheet
   B exported while sheet A is current (app helper and CLI); a pocket under the spot that is switched off (cut, switched off, the rest
   exported) and a switched-off pocket exported on its own (app helper and CLI); a switched-on sheet operation whose calculation
   failed. Through each entry point: the export sheet with the project's post and with a picked post, Save All, Check Toolpaths,
   tiled, the CLI. Not refused: a copy with a different `plateThickness`, or in other units (inch copy, mm installed, and the reverse),
   posts the installed values and gives the same G-code; a copy that differs only in its probe gives no copy-differs warning; a
   single-toolpath export whose sibling failed to calculate shows no missing-from-the-program error for the sibling.
4. Validator: the builder's program, Mach4 (macro `M199`) and GRBL, with and without line numbers, with a custom footer and a
   custom pause template that start `G53 G0 Z0`, a pause, and a custom preamble that writes `G54` while `workOffset` is 2, has no coordinate-shift, incremental,
   unknown-G, unknown-M, garbage, unknown-Z, too-deep or spindle-off warnings and still catches a too-deep cut after the second tool;
   errors for: wrong `G10` value or `P`, a cut or the spot rapid in the wrong work offset, a `G53` X/Y move not after `topZ`, a `T`
   outside `parked`, `T2`, `G53 G0 Z0`, spot with no park or swap stop, no placement stop before the probe, no clear move or no
   removal stop before the spindle start, the spindle on at the swap or the probe, a probe on X or upward, probe longer or faster
   than allowed, a Mach4 probe unit without the zero macro or the recovery line, a
   `G55` after the placement stop with `workOffset` 1, a recovery line with the other arc word, a
   `G10 L20` on Mach4, a macro `P` that is not `plateZ`, a probe with no `G91` before it or no `G90` after it, `G91`/`G90` swapped, a
   probe block with `M3`, a probe outside `placed`, a zero outside `probed`, a descent at the spot after the removal stop (the
   re-entry's X/Y cross deleted), a park or spot that is not the computed one, a cut
   before `ready` (the first sequence deleted, and a later one with its `T` kept), a down move at the spot, an axis block with no
   motion word after the probe; limits exactly at the rounding edge pass; without a probe on the profile, today's warnings.
5. A post JSON carrying a `toolChangeProbe` key posts no sequence, with and without a machine; `applied(to:)` with probing off clears
   it; a post's encoded bytes are unchanged by the new field.
6. Preview: a probed two-tool program, GRBL and Mach4, gives two tool segments, no phantom plunge, Z = `plateZ` after `G10 L20` and
   after `M{macro} P…` and its recovery line; the Avid `T{T} M6` program and a
   program that pre-stages `T2` after `T1 M6` keep today's segments.
7. Machines: a machine with a probe round-trips at schema 1; `probeFeed` 10 in/min and `probeTravel` 1 in survive the units switch
   and post with an mm post; a 201 mm park on an inch post (7.913386 in) is written toward zero, `7.9133`, and passes; a probe edit in
   Preferences while the export, Save All or Check Toolpaths sheet is open makes it re-post, and Save refuses the old program; a
   `sheetToolpaths` that lacks the exported toolpaths refuses.
8. Goldens, samples and `scripts/check-samples.sh` unchanged; the full suite green.

## Risks

- **Mach4 probing.** `G31` does not alarm without contact; the program relies on the owner's check macro, confirmed by the
  air-probe procedure in TESTING.md: plate held under the bit; a no-contact run at full `probeTravel` over scrap with a hand on the
  E-stop, which must stop at the macro; a run started with the probe input already active (HYPOTHESIS: GRBL raises "probe fail";
  Mach4 unknown), which must stop too; bit over bare wood; after the zero, with the plate removed, a jog to work Z 0 puts the bit on the material
  top (a paper check), in both Z-zero modes and with every post the machine lists (inch and mm: `P` is in the program's units,
  and the macro must make the displayed Z read `P` in those units, as Help's reference macro does); a dry run to the park
  confirms that `G53 Z{topZ}` is near the top of travel, clear of the limit switch, that the longest bit at `topZ` clears the tallest
  stock and every clamp and fixture along the whole path from the park to the spot, and the `G53` signs. The feature is off by
  default and a Mach4 probe cannot post without the zero macro. Help and docs give a reference Lua macro.
- **A missed contact.** With the lead off or the plate not under the bit, the probe still runs its full travel with the spindle off.
  The travel limit (§2) keeps it at or above the material top, and the placement stop's continuity check (the probe light) makes it
  unlikely; on Mach4 the macro then stops the program.
- **The operator jogs.** The jog at the placement stop is by hand; a jog too low is a jog into the plate, and a jog in X or Y moves
  the plate off the checked spot. The stop says "Jog Z only".
- **`topZ` and tall stock.** Every traverse runs at `topZ`; software cannot check that it clears the stock (dry run above).
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

Coolant ships as its own commits first (model, stamping, builder, form). Then: 2. `ToolChangeProbe`, the never-coded wrapper,
`ProbeSetting`, `applied(to:)`, the installed-machine rule in `resolve` (units, copy-differs comparison) and the touch-off spot. 3. The sequence and the builder's refusals. 4. Validator states
and the preview reader. 5. `sheetToolpaths`, the whole-sheet spot check and the tiled refusal. 6. UI (Machines, Job Setup). 7. Docs
and the air-probe procedure.
