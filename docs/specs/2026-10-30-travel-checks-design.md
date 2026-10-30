# Travel checks on every machine

Status: revision 2 (round 1 answered: see "Rulings" at the end). Issue: #119 (Sean, 2026-10-28: "I want the safety for all
machines."). Replaces the Othermill-only versions from #114 (`OthermillSetup.issues`).

## Goal

What exists (skeptic, round 1): the program pass already counts X0 Y0 for most posts, by accident. A posted program's first
motion is a Z-only rapid; with X and Y not yet known the validator visits it at X0 Y0 (`GCodeValidator.swift:289`,
`Vec3(tx ?? 0, ty ?? 0, …)`), so the span check there already bounds `max(maxX, 0) − min(minX, 0)` for every post except a
touch-plate one, whose sequence sets X Y without visiting. This change makes the rule deliberate and complete, closes the
touch-plate gap, and adds the Z warning for every post:

1. **XY: where the program goes, not only how wide it is.** A short cut far from the origin, or a Home X past the bed, is an
   error on a machine too small to reach it.
2. **Z: the stock plus the highest Z.** A warning when the stock's thickness plus the highest Z the program reaches (Safe Z,
   Home Z, the raised approach over a clamp, lift-overs, the touch-plate clearance), together with any cut below the stock,
   is more than the Z travel.

Goldens and `samples/expected` stay byte-identical (checks, not output); the samples still post clean on every built-in post
(they are posted with the Avid's limits, from the samples' machine). `GCodeValidator` is not weakened: every check it makes
today on an exported program it still makes, on the same or a larger set of moves.

## Where: the written program

`GCodeExporter.export` runs the validator twice: on the toolpaths (`validate(toolpaths:)`, document units, without the move
home) and on the posted program (`validate(gcode:)`, post units, with everything the post writes). Check Toolpaths goes through
`GCodeExporter.export` too (`ValidationReport.make`), and nothing else calls `validate(toolpaths:)` in the app. The program pass
sees every move the machine makes in work coordinates: the toolpaths, lift-overs, the raised approach after a tool change, the
touch-plate clearance (`ProgramBuilder`'s `G0 Z` over the plate) and the footer's move home.

So the travel checks move to the program pass: `MotionChecker` gains `checksTravel: Bool`, true in `validate(gcode:)` (both
places it makes a checker, including after a units change) and false in `validate(toolpaths:)`. The toolpath pass keeps every
per-move rule (depth, rapids, feeds, spindle); it stops comparing spans, which the program pass compares over a superset of its
moves. One error per axis reaches the export sheet, with no merging rule.

## XY: one window for every origin

The program's X0 Y0 is where the operator sets the work zero (Job Setup's XY origin, moved by the datum offset): the operator
jogs there, or the controller is told where it is, so it is a point the machine reaches. Every move is measured from it. The
program fits the machine only if **the zero and every move fit one travel-sized window**:

  `max(maxX, 0) − min(minX, 0) ≤ X travel + eps`, and the same for Y.

| XY origin | Moves (stock W × H, cuts on the stock) | Bound |
|---|---|---|
| lower left | 0 … W | the farthest move ≤ travel (#114's Othermill rule) |
| upper right | −W … 0 | the farthest move to the left ≤ travel |
| lower right, upper left | mixed signs per axis | per axis, as the two rows above |
| centre | −W/2 … W/2 | the moves' span ≤ travel (the old span rule) |
| any, with a datum offset | shifted | the zero point and the moves together |

The stock itself is not in the window: a sheet larger than the bed overhangs it, which stays the Check Toolpaths warning it is
today (`LayoutChecks.materialFits`). The work zero is in the window: someone cutting part of an oversized sheet puts the zero
within reach with the XY origin or the datum offset, and Save Tiled G-code already zeroes each tile at its own lower-left corner
(`ToolpathTile.job`) with tiles no larger than the travel (`TiledExport` defaults the tile to the post's travel).

`finish()` folds the 0 in when it compares; it does not seed `minP`/`maxP`, so a program with no moves still reports nothing
and `carryExtents` is unchanged. The `?? 0` at `GCodeValidator.swift:289` is then no longer what the rule rests on (DECISIONS
says so, so nobody "fixes" one believing the other depends on it).

**The touch-plate sequence.** `ProbeSequenceChecker` consumes the sequence's blocks and hands back the positions they leave
(`Effect.xy`, the touch-off spot; `Effect.z`, the clearance over the plate), which the validator records without visiting
(`GCodeValidator.swift:162-169`). They are work-coordinate moves the machine makes, so both now count in the extents:
`MotionChecker.include(x:y:z:)` adds whichever coordinates are known to the extents only (no depth or rapid rule: the
sequence has its own checker). `TouchOffSpotCheck` bounds the spot to the material, not the travel; this bounds it to the
travel. `G53` moves stay out (the validator treats them as non-motion; the touch-plate sequence's park
and traverses are `G53` and bounded by `ToolChangeProbe`'s own checks). The post editor's sample is posted with limits widened
to at least 100 in (`PostSampleJob.widened`), so drafts are not affected.

**Message** (keys `travel-X` / `travel-Y`, error as today; today's sentence kept, which `PostValidatorTests` asserts, with
where the program goes appended; the checker also serves imported G-code and the editor's sample, so it names no Job Setup
field):
`X travel 6.0000 in exceeds the machine's X travel 5.5000 in (the program's zero and its moves span X0.0000 to X6.0000)`.
The ends printed are the window's (`min(minX, 0)`, `max(maxX, 0)`), so they add up to the width. The Z span message keeps its
old form (it has no zero to fold in).

**Severity.** An error, as the span check is today. Errors keep Save Anyway in the app (the export sheet, Save All Toolpaths,
Save Tiled G-code) and `--force` on the command line.

## Z: the stock plus the highest Z

In the same `finish()`, with the checker's `coords` (the one Z-zero helper) and the Z extents it already keeps (arcs by their
points, every visited move):

  `bottom = min(minP.z, coords.materialBottomZ)`
  `need = maxP.z − bottom`

and a warning when `need > Z travel + eps`. On material-top zero with no cut below the stock that is `thickness + the highest Z
above the top` (#114's formula); on spoilboard zero it is the highest machine Z measured from the spoilboard; a through-cut
below the stock adds its depth (executor, round 1). The program's own Z span stays the error it is (`travel-Z`); this warning
is the larger question of fitting the stock under the spindle, which depends on the bit's stick-out and gantry clearance, so it
stays a warning, as #114 chose. When the `travel-Z` error fires, the warning is not added (one Z message, the stronger).

**Message** (key `z-envelope`, prefix `MotionChecker.zEnvelopePrefix = "The stock plus the highest Z"`, the #114 prefix):
`The stock plus the highest Z the program reaches (Z-0.7500 to Z0.8000: 1.5500 in) is more than the machine's Z travel
1.3500 in: lower Home Z and Safe Z in Job Setup, and check clamp and touch-plate heights.`

## Coordinate shifts

After `G10`, `G92` (and the other shifts the validator already names) later coordinates are in a frame the validator cannot
see. It warns today that "depth checks no longer apply"; that warning now reads "depth and travel checks no longer apply"
(auditor, round 1: `G92 X0` lets a program travel past the bed while the recorded extents stay small). LoftLine's own programs
write no XY shift; the touch-plate sequence's Z offset is handled by `ProbeSequenceChecker` as today.

## Othermill

`OthermillSetup.issues` keeps what is Othermill's own: material-top Z zero, lower-left origin, no datum offset (errors), and the
"limits larger than the Othermill's" warning. Its XY bound, its Z envelope, `OthermillSetup.extents` and the parameters it no
longer uses (`moves`, `toolpaths`, `approachHeight`) are removed; the general checks replace them (with a lower-left origin and
no move left of X0 the bound is the same; a move left of X0, a through-cut and the touch-plate positions are now counted too).
One difference: the validator samples arcs at its own tolerance (`eps`, 0.0005 in) where #114 sampled at 0.0001 in, so an arc
can overshoot by up to about 0.001 in before it is reported, as it already can for every other post. `OthermillSetup.warningPrefixes` becomes
`[limitsWarningPrefix]`; `OthermillSetup.zEnvelopeWarningPrefix` is removed. The samples test accepts no new prefix: the
samples are posted with the Avid's limits (8 in Z; 0.75 + 0.8 = 1.55 in), so neither check fires on them, and a sample that
starts to fire one should fail the test.

## Tests

`GCodeValidator` tests (`Tests/PostCoreTests/PostValidatorTests.swift`) on `validate(gcode:)`, written as G-code moves (the
checker never reads `xyOrigin`: the origin rows are the moves each origin produces), and export tests. Every XY row is written
so it fails on today's code: its first motion block names X and Y (`G0 X4 Y1 Z0.5`), so nothing is visited at X0 Y0 by
accident, or it is a touch-plate program.

| Case | Expected |
|---|---|
| 5.5 in X travel, lower left, a 0.2 in cut at X6 | `travel-X` error (the span alone is 0.2 in) |
| a cut ending at exactly X5.5, and at X5.5 + eps/2 | no error; at X5.5 + 2 eps an error; inch and mm |
| centre origin, moves −3 … 3 on 5.5 in | error (window 6) |
| upper-right origin, moves −5 … 0 on 5.5 in | clean |
| lower left, datum offset (2, 0): a cut over the stock's X 0 … 5 (program X −2 … 3) on 5.5 in | clean (window 5) |
| same, a cut over the stock's X 0 … 6 (program X −2 … 4) | error (window 6) |
| Home X past the bed (the footer's move home) | error |
| moves X4 … X6, X0 never visited, on 5.5 in | error (window 0 … 6) |
| no moves | no travel error |
| `validate(toolpaths:)` on the cut at X6 | no travel error (the program pass owns it) |
| Z: 0.75 stock, Home Z 0.8, Z travel 1.35 | warning (1.55), material top and spoilboard |
| Z: a through-cut 0.05 below the stock, highest Z 0.55, Z travel 1.33 | warning (0.75 + 0.05 + 0.55 = 1.35) |
| Z: a touch-plate tool change whose clearance (plate 0.5 + Safe Z 0.2) is the highest Z | warning counts 0.7 |
| Z: exactly at the travel | no warning, inch and mm |
| `G0 X0`, `G0 X5`, `G92 X0`, `G0 X5` | the shift warning names travel checks |
| moves X4 … X6, the message | `X travel 6.0000 in exceeds … (the program's zero and its moves span X0.0000 to X6.0000)` |
| touch-plate post, moves X0 … 3, spot at X5 on 5.5 in | clean; spot at X6: `travel-X` error |
| touch-plate post, clearance over the plate is the highest Z | the Z warning counts it |
| G20 moves X4 … X5, then G21 moves X140 … X150 on 5.5 in | error (window 0 … 5.906 in; the span alone, 1.906, would pass) |
| lower-right origin (X −5 … 0, Y 0 … 4) and upper-left (X 0 … 5, Y −4 … 0), move home at X0 Y0, on 5.5 × 4.5 | clean |
| `PostDraftReport.make` of the Avid and of the Othermill inch post | still no problems |
| export of a cut at X6 on 5.5 in | one `travel-X` error; Save Anyway still writes the program |
| tiled export of an 11 × 4.5 in job on a 5.5 × 4.5 in machine (tiles exactly 5.5 wide), a pocket across the tile edge | no travel error on either tile (column 0 reaches exactly X5.5) |
| Othermill | Z zero, origin, datum still errors; larger limits still a warning; the #114 XY and Z tests move here, not deleted |
| every sample × every built-in post | unchanged |

## Docs

DECISIONS (`travel-checks-all-machines`: the window rule, why the zero and not the stock, the per-origin table, the program
pass, error vs warning). TESTING: the air-cut section's travel note. PARITY: the travel checks row.

## Not in this change

- Machine-coordinate soft limits (`G53`, homed machine zero): the program cannot see where the operator puts the work zero.
- Tool stick-out and gantry clearance: the Z check stays a warning.
- Tracking the frame after an XY coordinate shift: the warning says the checks no longer apply.

## Rulings

- **Round 1: "imported G-code" dropped from the coverage claim** (skeptic m-1): `validate(gcode:)` runs only on programs
  LoftLine writes (the export and the editor's sample); the preview reads G-code without validating it.
- **Round 1: the touch-off spot and the plate clearance count** (skeptic M-2, auditor).
- **The window holds the work zero and the moves, not the stock.** Cost if wrong: an owner who sets the zero numerically at a
  point the machine cannot reach gets an error and uses Save Anyway; a stock edge off the bed is not caught at export (a Check
  Toolpaths warning today).
- **XY is an error, Z a warning**, as #114 chose for the Othermill. Cost if wrong: a Z warning ignored on a machine whose
  gantry is too low.
- **Round 1: the checks run on the written program only** (auditor's touch-plate height; the move home; no duplicate errors).
  Cost if wrong: a program that fails to post shows no travel error, but it writes nothing either.
- **Round 1: a cut below the stock counts in the Z warning** (executor).
- **Round 1: a coordinate shift is a warning that names travel, not an error** (auditor asked for frame tracking or an error).
  LoftLine writes no XY shift; an imported program that does is the operator's frame. Cost if wrong: an imported program with
  `G92 X` travels further than the check sees, with a warning that says so.
