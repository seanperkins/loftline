# Ramps keep their maximum angle (issue #124)

Status: draft, revision 1

## Problem

`PassShaping.pass` builds each pass's entry ramp. A ramp must never go down steeper than
`RampSettings.maxAngle`. Three cases break that:

1. **Spiral**: the helix always takes exactly one lap (`fromDepth + drop * (s - s0) / L`). A loop
   shorter than `drop / tan(maxAngle)` descends too steeply. Example: the inside of a 1/2 in hole with a
   1/4 in mill is 0.785 in round, and a 0.25 in pass descends at 17.7° against a 10° limit.
2. **Smooth**: fixed in #96 for short loops, but the ramp length is still capped at
   `maxSmoothLaps` (200) laps. Past the cap the ramp is steeper, and nothing reports it.
3. **Zig-zag**: legs are capped at `maxZigzagLegs` (200). Past the cap each leg is steeper, and
   nothing reports it.

Cases 2 and 3 need a vector about 0.007 in long for a 0.25 in pass at 10°. They are rare, but they
must not be silent.

## Design

**Spiral takes as many laps as the angle needs.**
- Laps `n = max(1, ceil(drop / (L · tan(maxAngle))))`, capped at `maxSmoothLaps`.
- The helix runs from `s0` to `s0 + n·L`, at depth `fromDepth + drop · (s − s0) / (n·L)`.
- On the last pass the flat finishing lap follows the helix as before. `endS` is
  `s0 + n·L` (plus the flat lap and overcut on the last pass).
- A loop long enough for one lap is ramped exactly as today, so most programs' G-code doesn't change.

**A capped ramp says so.**
- `ChainPass` gains `public var isSteeperThanMaxAngle: Bool`, default `false`.
- It is set when a cap forced the ramp steeper:
  - spiral or smooth: the needed length `drop / tan(maxAngle)` exceeds `maxSmoothLaps · L`;
  - zig-zag: the legs needed exceed `maxZigzagLegs`.
- Callers that pass a user's ramp (profile, open profile vectors, pocket) count the flagged passes and
  add one warning to the toolpath:
  `"<n> pass(es) ramp steeper than the <angle>° maximum: the vector is too short for the ramp; use a plunge or a shallower pass depth"`.
  The angle is formatted like the field (no trailing `.0`).
- Callers that pass `RampSettings()` (ramp disabled: moulding, prism, the pocket linking lap) can
  never set it and are unchanged.

**Not in scope.**
- The validator does not check ramp angles. The ramp is built by the program, so a test of
  `PassShaping` covers it. A post-time angle check would need the ramp's settings in the G-code.
- Splitting a pass into several shallower passes instead of extra laps. More laps keeps the pass
  depths the user chose and is what the smooth ramp already does.
- The hole mill's own helix (`HoleMillOperation`). It already holds its angle and warns.

## Tests (CAMCore)

- Spiral never goes down steeper than the maximum angle. Use radii 0.125, 0.5 and 4 and drops 0.25
  and 0.6, the same grid as the smooth test. It still reaches the pass depth. With `spiralFinish` it
  then cuts one whole lap at depth.
- Spiral on a loop long enough for one lap is unchanged: the helix ends at `s0 + L`.
- Spiral without `spiralFinish` ends at `s0 + n·L` at `toDepth`. That is where the next pass starts.
- A loop too short even at the cap sets `isSteeperThanMaxAngle`, for each of spiral, smooth and zig-zag.
  A normal loop leaves it false.
- A profile on a tiny closed loop with a ramp carries the warning in `metadata["warning"]`. So does a
  pocket.
- `scripts/check-samples.sh` is unchanged, or each diff it shows is a spiral ramp that now takes more laps.

## Docs

- DECISIONS: `ramp-angle-laps`: ramps add laps rather than split passes, and a capped ramp warns.
- HelpTopics, "Ramp type": "spiral circles down, as many laps as the maximum angle needs".
