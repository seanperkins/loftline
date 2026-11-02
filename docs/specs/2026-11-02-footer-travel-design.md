# The footer's travel is modelled from its moves (#132)

Status: draft, revision 1.

## Problem

`GCodeExporter.homeTravel` models the end of the program from the footer's tokens: up to safe Z (the builder's
retract), then to Home Z if the footer text contains `{HOME_Z}`, then to home XY if it contains `{HOME_X}`/`{HOME_Y}`,
always Z first. Both keep-out checks (`keepOutIssues` and `LayoutChecks.keepOut` for clamps) and lift-over routing
(`linkHomeOverKeepOutZones`) run on that model.

A custom footer that moves any other way is not modelled. A literal `G28 X6 Y6` rapids to X6 Y6 at the current Z before
it goes to the reference point. Since #129 the validator checks that move for travel, depth and rapids into the stock,
but nothing checks it against keep-out zones or clamps. The same gap covers a literal `G0 X0 Y0`, and a footer whose
XY move comes before its Z move (modelled Z first, so a zone between safe Z and Home Z is missed).

## Design

### 1. PostCore renders and walks the footer

New `PostCore/Processor/FooterTravel.swift`:

```swift
public struct FooterTravel: Sendable, Equatable {
    public enum Kind: Sendable { case move, reference }   // reference = a G28/G30 intermediate move
    public struct Leg: Sendable, Equatable { public var to: Vec3; public var kind: Kind }
    /// Machine frame, job units. Empty when the footer makes no modelled move.
    public var legs: [Leg]
    /// True when lift-over routing may replace this travel (see 3).
    public var liftable: Bool
    public static func model(profile: PostProfile, job: PostJob, from end: Vec3) -> FooterTravel
}
```

- The footer is rendered by `ProgramBuilder` with its own values table (a new internal `renderedFooter()`), so
  `{HOME_Z}`, `{SAFE_Z}`, `{APPROACH_Z}` and the others resolve exactly as in the posted program, in output units.
  It is parsed with `GCodeParser.parse(_, comments: profile.parserComments)`.
- `end` is converted to output units, the walk runs in output units, and every leg is converted back to job units.
- The walk starts at `(end.xy, max(end.z, safeZ))`, the builder's retract, in G90 with G0 modal.
- `legs` starts with that retract point whenever the walk finds at least one move; otherwise it is empty, as today.

### 2. Rules of the walk

Each rule matches the validator (`GCodeValidator.validate(gcode:)`, #129) where the validator has one.

| Block | Effect |
|---|---|
| G0/G1 (or modal) with axis words | A `.move` leg to the resolved point (G90 absolute, G91 added to the current position) |
| G90 / G91 | Sets the distance mode |
| G28/G30 with axis words | A `.reference` leg to the resolved intermediate point. Then the named axes go to the stored position: a named X or Y ends the walk; a named Z keeps the last known Z |
| G28/G30 with no axis words | Ends the walk (straight to the stored position) |
| G53 with axis words | No leg. A named X or Y ends the walk; a named Z keeps the last known Z |
| G2/G3, G10, G38.x, G43, G52, G54–G59.x, G92, M6, a units code other than the post's | Ends the walk |
| Anything else (M-codes, G4, G17–19, G40, G49, G80, G94, G90.1/G91.1, the post's own units code, comments) | No effect |

A zero-length leg is dropped. "Keeps the last known Z" can raise a false alarm (the machine is really at its reference,
higher), never miss one, the same stance as #120.

Built-in footers (`G0 Z{HOME_Z}` / `M5` / `G0 X{HOME_X} Y{HOME_Y}` / `M2|M30` [/ `%`]) give exactly today's points.

### 3. Lift-over routing only for a replay-safe footer

`KeepOutAvoidance.linkTravel` appends the lifted route to the last toolpath, and the footer then runs in full from the
route's end. That is safe only when replaying the footer from its own end point moves nowhere. `liftable` is true when
the legs after the retract are at most one absolute Z-only `.move` followed by at most one absolute XY `.move` (the
built-in shape). Otherwise the travel is checked but not lifted, so a lift-over zone in its way is an error.

### 4. Export

- `GCodeExporter.homeTravel` is removed. `homeMove(after:document:profile:)` becomes `homeMoves`, returning rapid-only
  toolpaths: consecutive `.move` legs form "Move home (end of program)", and each `.reference` leg forms
  "Footer G28/G30 move (end of program)" (`GCodeExporter.footerReferenceMoveName`), so a message names the move that
  hits the zone. Each keeps the last toolpath's tool.
- `linkHomeOverKeepOutZones` routes only a `liftable` travel.
- The clamp message rewrite ("raise safe Z" → "raise Home Z") stays for the home move. For the G28/G30 move it reads
  "change the post's footer".
- `checked = toolpaths + homeMoves(...)`, so `keepOutIssues` and `LayoutChecks.keepOut` see every leg.

## Tests

PostCore (`FooterTravelTests`):
- every built-in post: legs equal today's `homeTravel` points, `liftable` true;
- `G28 X6 Y6` before `G0 Z{HOME_Z}`: the reference leg is at safe Z;
- `G91 G28 Z0` / `G28 X0 Y0` / `G90`: no leg beyond the retract point, nothing after;
- a mm post on an inch job: legs in inches;
- `G53 G0 Z0` then `G0 X0 Y0`: the XY leg at the last known Z;
- G2, G92, M6 end the walk; bare `G28` ends it; `X1` after `G91` is incremental.

App (`KeepOutZoneTests`), both Z-zero modes:
- a check-only zone on the G28 leg: an error naming the footer's G28/G30 move;
- a clamp on the G28 leg: the clamp error, "change the post's footer";
- a lift-over zone on the G28 leg: still an error, and the program is not re-routed;
- `keepOutHomeMoveIsCheckedAndLifted` unchanged and passing; `scripts/check-samples.sh` shows no byte moved.

## Docs

DECISIONS: a `footer-travel` entry; amend "fix round 3" (line 597, "a custom footer that does something else is not
modelled") and `g28-intermediate-point` (keep-out zones on the intermediate move are now modelled).

## Out of scope

The stored G28/G30 position and anything after it, G28.1/G30.1, and the validator's own handling (unchanged).
