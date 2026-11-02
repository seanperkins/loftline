# The validator checks a G28/G30 intermediate point (issue #129)

Status: draft, revision 1

## Problem

`GCodeValidator.validate(gcode:)` treats `G28` and `G30` as non-motion (`case 4, 28, 30: nonMotion = true`),
so it never looks at the axis words on those blocks. On LinuxCNC, Mach and GRBL, `G28 X6` first makes a rapid
to X6 in work coordinates, using the current distance mode, then moves on to the stored home position in
machine coordinates.

This leaves two holes:
- A custom post whose footer is `G28 X6`, on a machine with 5.5 in of X travel, exports with no travel error.
- `G28 Z-1` makes a rapid into the stock with no warning.

There is also a quieter one. After a `G28`/`G30`, the validator keeps the position it had before, even though
the machine is now at its stored position, so later rapids are judged from the wrong start.

No built-in post writes `G28` or `G30`, so only a user's post can reach this.

## Design

In `validate(gcode:)`, a block with `G28` or `G30`:
1. **With any axis word.** It is checked as a `G0` to the intermediate point:
   - each word is resolved in the current distance mode, as `G0` resolves it (absolute, or added to the
     current position under `G91`);
   - axes the block does not name keep their current values;
   - it goes through `check.rapid(from:to:xyMove:line:)` with the same start, target and `xyMove` rules as a
     `G0` block, so the travel window, rapid-in-material, rapid-below-safe and rapid-plunge checks all apply.
2. **In every case, with or without axis words.** Afterwards the position is unknown (`x`, `y` and `z` are
   nil). The move to the stored position is in machine coordinates, which the validator cannot see.
   - The next rapid is then judged as a program's first one: an XY rapid before Z is known warns
     `rapid-unknown-z`, which tells a post that moves again after `G28` to retract first.
   - Any `G0` or `G1` that names Z makes it known again.
3. **The motion mode is unchanged.** `G28`/`G30` are non-modal, so a later block with bare axis words keeps
   the motion mode it had before.

`G28.1` and `G30.1` (set the stored position) are not in `knownG`, so they still get the unknown-code
warning. That is unchanged.

The G-code preview (`GCodeReader`) already says "G28 is not previewed" and draws nothing for the block.
That is unchanged.

## Not in scope

- **Checking the stored position itself.** It lives in the controller's parameters.
- **The incremental idiom `G91 G28 Z0`.** It is already handled: in `G91`, Z0 resolves to the current Z, so the
  intermediate point is where the tool already is, and no issue is raised.

## Tests (PostCoreTests, beside `TravelWindowTests`)

- **Travel.** A program that ends `G28 X6` on a machine with 5.5 in of X travel gives the `travel-X` error.
  - The same program ending `G28 X2` gives no travel error.
- **Plunge.** `G28 Z-1` from Z0.2, over the stock, gives the `rapid-plunge` warning.
- **XY at depth.** `G28 X1 Y1` while the tool is at Z-0.1 gives `rapid-in-material`.
- **Incremental.** `G91 G28 Z0` at safe Z gives no rapid warning.
- **Unknown afterwards.**
  - `G28` alone, then `G0 X1 Y1`, gives `rapid-unknown-z`.
  - `G28`, then `G0 Z0.5`, then `G0 X1 Y1`, gives none.
- **`G30`.** It behaves like `G28`: one travel case is enough.

## Docs

- **DECISIONS:** a new entry, `g28-intermediate-point`.
- **HelpTopics:** none. The Check Toolpaths paragraph already covers rapids and travel.
