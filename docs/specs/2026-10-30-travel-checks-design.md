# Travel checks on every machine

Status: draft, revision 1. Issue: #119 (Sean, 2026-10-28: "I want the safety for all machines."). Replaces the Othermill-only
versions from #114 (`OthermillSetup.issues`).

## Goal

Two checks that today run only for the Othermill posts run for every post, through the export:

1. **XY: where the program goes, not only how wide it is.** A short cut far from the origin, or a Home X past the bed, is an
   error on a machine too small to reach it.
2. **Z: the stock plus the highest Z.** A warning when the stock's thickness plus the highest Z the program reaches (Safe Z,
   Home Z, the raised approach over a clamp, lift-overs) is more than the Z travel.

Goldens and `samples/expected` stay byte-identical (checks, not output); the samples still post clean on every built-in post
(they are posted with the Avid's limits, from the samples' machine). `GCodeValidator` is not weakened.

## What "on the bed" means: one rule for every origin

The program's X0 Y0 is where the operator sets the work zero (Job Setup's XY origin, moved by the datum offset): the operator
jogs there, or the controller is told where it is, so it is a point the machine reaches. Every move is measured from it. So the
program fits the machine only if **the origin and every move fit one travel-sized window**:

  `max(maxX, 0) − min(minX, 0) ≤ X travel`, and the same for Y.

That is the per-origin bound the issue asks for, without a table:

| XY origin | Moves (stock W × H, cuts on the stock) | Bound |
|---|---|---|
| lower left | 0 … W | the farthest move ≤ travel (Othermill's #114 rule, as before) |
| upper right | −W … 0 | the farthest move to the left ≤ travel |
| centre | −W/2 … W/2 | the moves' span ≤ travel (the old span rule) |
| any, with a datum offset | shifted | the zero point and the moves together |

The stock itself is not in the window: a sheet larger than the bed overhangs it. That stays the Check Toolpaths warning it is
today (`LayoutChecks.materialFits`). The work zero is: the rule assumes the zero is a point the machine reaches. Someone
cutting part of an oversized sheet puts the zero within reach with the XY origin or the datum offset, and Save Tiled G-code
already zeroes each tile at its own lower-left corner (`ToolpathTile.job`), with tiles no larger than the travel
(`TiledExport` defaults the tile to the post's travel), so a tile's moves and its zero fit one window as they fit the old span.

**Where.** `MotionChecker.finish()` (`Sources/PostCore/Validation/MotionChecker.swift`), which already compares the X and Y spans
with the travel, folds X0 and Y0 into the spans: the X and Y extents start at 0. One change covers the toolpath check, the
G-code check (which sees the footer's move home and every lift-over), imported G-code and the post editor's sample, in inch and
mm, in both Z-zero modes (XY does not depend on Z zero). `G53` moves stay out (the validator already treats them as
non-motion; the touch-plate sequence's park and traverses are `G53` and bounded by `ToolChangeProbe`'s own checks). The 0 is
folded in when `finish()` compares (`max(maxP.x, 0) − min(minP.x, 0)`), not seeded into `minP`/`maxP`, so a program with no
moves still reports nothing and `carryExtents` is unchanged. The Z span check is unchanged. The post editor's sample is posted
with limits widened to at least 100 in (`PostSampleJob.widened`), so drafts are not affected.

**Message** (keys `travel-X` / `travel-Y` unchanged, error as today; `MotionChecker.travelPrefix(axis)` is its opening):
`The program reaches X-0.1000 to X6.2000 from its zero (X0): 6.3000 in, more than the machine's X travel 5.5000 in. The zero
you set and every move must be within reach: move the XY origin or the datum offset in Job Setup, or save tiled G-code.`

**One error per axis at export.** `GCodeExporter.export` runs the validator on the toolpaths (document units, no move home) and
on the program (post units, with the move home), and `GCodeIssue.merged` folds only identical messages. When the program's
pass reports `travel-X` (or `-Y`), the export drops the toolpath pass's error for that axis (matched by
`MotionChecker.travelPrefix`): the program's pass sees the whole program. When posting fails, the toolpath pass's error stays.

**Severity.** An error, as the span check is today: no placement of the work zero on the bed reaches every move. Errors keep
Save Anyway in the app (the export sheet, Save All Toolpaths, Save Tiled G-code) and `--force` on the command line, so an owner
whose zero is set numerically outside the post's travel, or whose soft limits are wider than the post's numbers, can still
post.

## Z: the stock plus the highest Z

`MachineEnvelope.zIssue(job:units:moves:profile:approachHeight:) -> GCodeIssue?` (new, `Sources/PostCore/Validation/
MachineEnvelope.swift`), called by `GCodeExporter.export` with `checked` (the toolpaths after lift-overs, plus the move home) and
`approachHeight(document:)`, as `OthermillSetup.issues` is called today. In machine coordinates (`MachineCoordinates`, the one
Z-zero helper):

  `highest = max(coords.safeZ, coords.homeZ, coords.z(aboveTop: approachHeight) if any, the highest Z any move reaches)`
  `need = highest − coords.materialBottomZ`

and a warning when `need > Z travel + eps`. On material-top zero that is `thickness + highest above the top` (#114's formula);
on spoilboard zero it is the highest machine Z, measured from the spoilboard. The highest move Z reads arcs by their points
(`OthermillSetup.extents`, moved here as `MachineEnvelope.extents`).

**Message** (prefix `MachineEnvelope.zWarningPrefix = "The stock plus the highest Z"`, unchanged from #114):
`The stock plus the highest Z the program asks for (0.75 + 0.8 = 1.55 in) is more than the Z travel 1.35 in: lower Home Z and
Safe Z in Job Setup, and check clamp heights.` On spoilboard zero the numbers are the same quantities (thickness + height above
the top).

**Severity.** A warning: whether the tool tip must reach the spoilboard depends on the bit's stick-out, which the program does
not know; the warning names what to lower. Two-sided jobs: the exporter passes the side's own `job` (its own Z zero), as today.

## Othermill

`OthermillSetup.issues` keeps what is Othermill's own: material-top Z zero, lower-left origin, no datum offset (errors), and
the "limits larger than the Othermill's" warning. Its XY bound and Z envelope are removed (the general checks replace them, at
least as strictly: with a lower-left origin and no move left of X0 the bound is the same; a move left of X0 is now caught too).
`OthermillSetup.warningPrefixes` becomes `[limitsWarningPrefix]`. The samples test accepts no new prefix: the samples are
posted with the Avid's limits (8 in Z; 0.75 + 0.8 = 1.55 in), so the Z warning must not fire on any of them, and a sample
that starts to fire it should fail the test.

## Tests

`Tests/PostCoreTests/MachineEnvelopeTests.swift` (new) and `GCodeValidator` tests:

| Case | Expected |
|---|---|
| 5.5 in X travel, lower left, a 0.2 in cut at X6 | `travel-X` error (the span alone is 0.2 in) |
| same, cut ending at exactly X5.5 (and X5.5 + eps/2) | no error; at X5.5 + 2 eps, error — inch and mm |
| centre origin, moves −3 … 3 on 5.5 in | error (span 6) |
| upper-right origin, moves −5 … 0 on 5.5 in | clean |
| lower left, datum offset (2, 0), on 5.5 in: a cut over the stock's X 0 … 5 (program X −2 … 3) | clean (window −2 … 3 = 5) |
| same, a cut over the stock's X 0 … 6 (program X −2 … 4) | error (window 6) |
| Home X past the bed (G-code check, the footer's move home) | error |
| export (`GCodeExporter`) of a cut at X6 on 5.5 in | one `travel-X` error, the program pass's; Save Anyway still writes the program |
| tiled export of a 12 × 4 in job on a 5.5 × 4.5 in machine (default tiles), a pocket clear of the stock edges | no `travel-X`/`-Y` error on any tile (a profile on the stock's outer edge puts the cutter a radius outside the tile, which the old span rule already refused and still does) |
| no moves at all | no travel error |
| imported G-code (`validate(gcode:)`) with X0 never visited, moves X4 … X6 on 5.5 in | error |
| Z: 0.75 stock, Home Z 0.8, 0.1 V-carve, Z travel 1.35 | warning (1.55), material top and spoilboard |
| Z: the raised approach above Home Z sets the number | warning names it |
| Z: exactly at the travel | no warning, inch and mm |
| Othermill posts | still error on Z zero, origin, datum; still warn on larger limits; XY and Z come from the general checks (the #114 tests move here, not deleted) |
| every sample × every built-in post | unchanged (the samples test) |

## Docs

DECISIONS (`travel-checks-all-machines`: the window rule, why the origin and not the stock, the per-origin table, error vs
warning). TESTING: the air-cut section's travel note. PARITY: travel checks row.

## Not in this change

- Machine-coordinate soft limits (`G53`, homed machine zero): the program cannot see where the operator puts the work zero.
- Tool stick-out and gantry clearance: the Z check stays a warning.

## Rulings (drafting)

- **The window holds the work zero and the moves, not the stock.** Cost if wrong: an owner who sets the zero numerically at a
  point the machine cannot reach gets an error and uses Save Anyway; a stock edge off the bed is not caught at export (it is
  a Check Toolpaths warning today).
- **XY is an error, Z a warning**, as #114 chose for the Othermill. Cost if wrong: a Z warning ignored on a machine whose
  gantry is too low.
