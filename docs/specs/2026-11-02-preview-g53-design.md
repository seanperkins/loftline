# The G-code preview after a G53 move (issue #120, item 4)

Status: draft, revision 1

## Problem

`GCodeReader` (the G-code file preview) skips a `G53` block (`case 53: nonModal = true`). The machine has moved, in
machine coordinates, but the preview keeps its old position. So the next move is drawn from where the tool was before.

The common case is a retract, `G53 G0 Z0` (to the top of the machine's Z). After a cut at Z-0.5, the next `G1 X2` is
then drawn at Z-0.5, through the stock, although the tool is at the top of Z. A `G53` that moves X or Y, such as a park
at the end, leaves the next move drawn from the wrong XY.

## Design

For a `G53` block with axis words:
- **Z named:** the preview's Z becomes `startZ`, the height the reader assumes before a program sets Z (the job's safe
  Z), and Z counts as known. A machine-coordinate Z move is a retract in every post that writes one, so drawing the tool
  above the stock is the honest picture. Its exact height is not knowable.
- **X or Y named:** they keep their old values, as today, and the block warns once per program:
  `"G53 moves X/Y in machine coordinates: the preview cannot follow it, and the next move is drawn from the last
  known point"`.
- **No axis words:** unchanged.

`G53` stays non-modal: the motion mode is not changed and nothing is drawn for the block itself.

The validator is not touched. It already treats `G53` as a coordinate shift that ends its depth and travel checks.

## Tests (PostCoreTests, `PostGCodeReaderTests`)

- **A Z retract.** `G1 Z-0.5 F10`, `G53 G0 Z0`, then `G1 X2 F10`: the last move's target Z is `startZ`, not -0.5.
- **An XY park.** `G53 G0 X0 Y0` warns once (two such blocks still give one warning). The next move is drawn from the
  last known XY.
- **A bare `G53`.** No change and no warning.
