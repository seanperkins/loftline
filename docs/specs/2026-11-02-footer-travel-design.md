# The footer's travel is modelled from its moves (#132)

Status: revision 2, after the round 1 panel (two GPT-6 seats, an Opus skeptic, a Sonnet simplifier).

## Problem

`GCodeExporter.homeTravel` models the end of the program from the footer's tokens: up to safe Z (the builder's
retract), then to Home Z if the footer text contains `{HOME_Z}`, then to home XY if it contains `{HOME_X}`/`{HOME_Y}`,
always Z first. Both keep-out checks (`keepOutIssues` and `LayoutChecks.keepOut` for clamps) and lift-over routing
(`linkHomeOverKeepOutZones`) run on that model.

A custom footer that moves any other way is not modelled. A literal `G28 X6 Y6` rapids to X6 Y6 at the current Z before
it goes to the reference point. Since #129 the validator checks that move for travel, depth and rapids into the stock,
but nothing checks it against keep-out zones or clamps. The same gap covers a literal `G0 X0 Y0`, and a footer whose
XY move comes before its Z move (modelled Z first, so a zone between safe Z and Home Z is missed).

A second gap, found in review: `KeepOut.violations` assumes the post climbs to safe Z before any XY rapid that starts
below it (`KeepOut.swift:43-46`). The program's own moves do, but footer lines are written verbatim
(`ProgramBuilder.swift:94`). So a footer, or a built-in footer with Home Z below safe Z in a project that did not pass
the Job Setup form, crosses a check-only zone that the check looks at from safe Z.

## Design

### 1. PostCore renders and walks the footer

New `PostCore/Processor/FooterTravel.swift`:

```swift
public struct FooterTravel: Sendable, Equatable {
    /// Machine frame, job units: the builder's retract, then each modelled move. Empty when the footer makes no
    /// modelled move.
    public var points: [Vec3]
    /// The footer line the walk stopped at, when it stopped before the footer's end (or its M2/M30): the machine's
    /// moves from that line on are not modelled.
    public var unmodelledFrom: String?
    public static func model(profile: PostProfile, job: PostJob, from end: Vec3) -> FooterTravel
}
```

- `ProgramBuilder` gets an internal `renderedFooter() -> [String]` = `render(profile.footer)`, and `build()` uses
  it, so the walked footer and the posted one cannot drift. `{APPROACH_Z}` resolves from `job.approachHeight`, so the
  export builds its `PostJob` (with `approachHeight(document:)`) before the checks and passes it.
- The rendered lines are parsed with `GCodeParser.parse(_, comments: profile.parserComments)`. The walk runs in output
  units; `end` is converted in and every point out with `job.units.factor(to: profile.units)`.
- Start: `(end.xy, max(end.z, safeZ))` (the builder's retract), G90 (the program's moves are absolute; a post with no
  G90 already gets the validator's `no-absolute` warning), and no known motion mode.
- `points` starts with the retract point when the walk records at least one move; otherwise it is empty, as today.
  A zero-length move is dropped.

### 2. The walk is an allowlist

| Block | Effect |
|---|---|
| G0/G1 with axis words (or axis words while G0/G1 is the motion mode) | A move to the resolved point (G90 absolute, G91 added to the current point) |
| G90, G91 | Sets the distance mode |
| G28/G30 with axis words | A move to the resolved intermediate point, then the walk stops at this line (the machine then goes to a stored position LoftLine cannot see) |
| M2, M30 | The walk ends; nothing after it runs |
| G4, G17, G40, G80, G90.1, G91.1, G94, the post's own units code (`profile.unitsCode`, so G20/G21 or G70/G71), M3, M4, M5, M7, M8, M9, and F, S, T, N words | No effect |
| Anything else: G2/G3, a bare G28/G30, G53, G43/G49, G92, a work offset, a canned cycle, M0/M1, M6, M98, any other code; axis words with no known motion mode; a line with unparsed text; a block-delete (`/`) line | The walk stops at this line |

### 3. Stopping early is reported

When `unmodelledFrom` is set and the job has keep-out zones or clamps, the export adds a warning:
`Keep-out zones and clamps are not checked from the footer's line "<line>" on: LoftLine cannot tell where the machine
goes from there.` A warning, not an error: the commonest cause is a return to the machine's own stored reference, which
the operator sets up, and an error would make every such post need Save Anyway.

### 4. The footer's travel is checked as written

- `homeTravel` is removed. `homeMove(after:document:profile:job:)` builds the one rapid-only "Move home (end of
  program)" toolpath from `FooterTravel.points`, with the last toolpath's tool, and marks it
  `metadata[KeepOut.asWrittenKey] = "1"`.
- `KeepOut.violations` skips its climb-before-XY rewrite for a toolpath with that mark. `LayoutChecks.keepOut` has no
  such rewrite.
- `linkHomeOverKeepOutZones` routes through all the points, as today. Lift routing needs no extra rule: `export`
  re-models the footer from the lifted route's end (`homeMove(after: toolpaths)` runs on the linked list), so if the
  footer moves again on replay, that replay is what gets checked.
- The clamp message rewrite becomes "raise safe Z" → "raise Home Z or change the post's footer".

## Tests

PostCore (`FooterTravelTests`):
- every built-in post: points equal today's (retract, Home Z, home XY) within output rounding; with Home Z equal to
  safe Z the Z move is dropped; `unmodelledFrom` nil;
- `G28 X6 Y6` before `G0 Z{HOME_Z}`: the G28 move at safe Z, then the walk stops at the G28 line;
- `G91 G28 Z0` / `G28 X0 Y0` / `G90`: no points, stops at the first line;
- XY before Z, and separate X and Y lines: points in footer order;
- a mm post on an inch job: points in inches;
- `G53 G0 Z0`, G2, M6, M0, `/G0 Z1`, axis words before any G0/G1: each stops the walk at its line;
- moves after M30 are not modelled and do not set `unmodelledFrom`;
- `X1` after `G91` is incremental.

CAMCore: a rapid-only toolpath marked as written, from Z below safe Z across a zone, is a violation; unmarked, it is
not (today's behaviour).

App (`KeepOutZoneTests`), both Z-zero modes:
- a check-only zone on the G28 move: an error naming "Move home (end of program)", plus the stop warning;
- a clamp on the G28 move: the clamp error with "change the post's footer";
- a built-in post with Home Z below safe Z (set in the project, not through the form) and a check-only zone between
  the last cut and home, taller than Home Z but lower than safe Z: now an error;
- no warning without zones or clamps;
- `keepOutHomeMoveIsCheckedAndLifted` unchanged and passing, plus a pinned copy of the lifted program's footer-end
  lines captured from main before the change; `scripts/check-samples.sh` shows no byte moved.

## Docs

DECISIONS: a `footer-travel` entry; amend "fix round 3" (line 597, "a custom footer that does something else is not
modelled") and `g28-intermediate-point` (keep-out zones on the intermediate move are now modelled).

## Out of scope

The stored G28/G30 position and anything after it, G28.1/G30.1, and the validator's own handling (unchanged).
