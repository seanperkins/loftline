# The G-code preview after a G53 retract (issue #120, item 4)

Status: approved, revision 2 (after debate:all round 1)

## Problem

`GCodeReader` (the G-code file preview, and `DeepestCut`) skips a `G53` block (`case 53: nonModal = true`). The machine has
moved, in machine coordinates, but the preview keeps its old position. The usual case is a retract to the top of Z,
`G53 G0 Z0`. After a cut at Z-0.5, the next `G1 X2` is then drawn at Z-0.5, through the stock.

## Design

- **A retract.** A `G53` block whose Z word is 0 or above, the top of the machine's Z (machine Z is 0 at the top and
  negative downward on Mach, LinuxCNC and GRBL), emits a rapid straight up from the current XY to a stand-in height:
  `max(startZ, the highest Z the program has reached)`. The position is then at that height.
  - So the retract is drawn, and the next move starts above the stock. The renderer draws every move from the previous
    target, so moving the position without drawing would still connect the old point to the next one.
  - The real height is not knowable from the file. The stand-in is drawn at or above everything the program has done,
    so a file written in the other Z-zero mode is not drawn inside its own stock.
  - It is in output units. `startZ` and the program's Z values are already converted.
- **Any other `G53`:** a machine Z below 0 (the probe sequence's park descent `G53 G0 Z<parkZ>`, or a move to a tool
  setter), or X and Y only (the park). This is today's behaviour: nothing is drawn, the position is unchanged, and there is
  no warning. LoftLine's own probe sequence parks and descends off the stock and re-enters with an explicit Z, so nothing
  it writes is drawn wrong. Warning on the park would put a note on every probed program for a point that is never drawn
  stale.
- **Before anything has moved** (no position yet), a `G53` changes nothing.
- **The motion mode.** `G53` itself is non-modal, but a `G0` or `G1` on its block still sets the modal motion, as today.
- **The comment at `GCodeReader.swift:135` is updated.**

Not changed:
- **The validator.** It keeps the old Z after `G53`, so a rapid across after `G53 G0 Z0` from depth can be reported as
  in the material: a false alarm on the safe side.
- **`G28` and `G30` in the preview.** They are still "not previewed".

## Tests (PostCoreTests, `ProbedProgramReaderTests`)

- **A retract.** `G0 X0 Y0 Z0.2`, `G1 Z-0.5 F10`, `G53 G0 Z0`, `G1 X2 F10`, read with `startZ` 0.2.
  - The moves after the cut are a rapid to `(0, 0, 0.2)`, then the feed to `(2, 0, 0.2)`.
  - There are no warnings.
- **The highest Z wins.** The same, with an earlier `G0 Z1.5`: the retract goes to Z1.5.
- **Not a retract.** `G53 G0 Z-3` and `G53 G0 X0 Y0` emit nothing and leave the position unchanged.
- **Units.** A G21 program with `startZ` 0.2 in, read into inches: the retract goes to 0.2.
- **Both Z-zero modes, end to end.** A probed program from the existing two-tool fixture still gives two segments, no
  moves below the deepest cut, and no "not previewed" or `G53` warning.

## Docs

- **DECISIONS:** a new entry, `preview-g53-retract`. Also update the "Not yet" note at `:1020`, which still lists #120
  item 4.
