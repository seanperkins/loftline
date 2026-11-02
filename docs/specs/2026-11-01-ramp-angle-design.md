# Ramps keep their maximum angle (issue #124)

Status: draft, revision 2 (after the debate:all round 1)

## Problem

`PassShaping.pass` builds each pass's entry ramp. A ramp must never go down steeper than
`RampSettings.maxAngle`. Four cases break that:

1. **Spiral.** The helix always takes exactly one lap (`fromDepth + drop * (s - s0) / L`). A loop
   shorter than `drop / tan(maxAngle)` descends too steeply. Example: the inside of a 1/2 in hole with a
   1/4 in mill is 0.785 in round, and a 0.25 in pass descends at 17.7° against a 10° limit.
2. **Smooth.** Since #96 the ramp goes round more than once, but its length is capped at
   `maxSmoothLaps` (200) laps. Past the cap the ramp is steeper, and nothing reports it.
3. **Zig-zag.** Legs are capped at `maxZigzagLegs` (200). Past the cap each leg is steeper, and nothing
   reports it.
4. **Angle floor.** The angle is clamped to 0.5°–89.5° (`PassShaping.swift:40`), and the field has no
   range. A maximum below 0.5° silently ramps at 0.5°.

Cases 2 and 3 need a vector about 0.007 in long for a 0.25 in pass at 10°. A last pass at full depth
gives a deeper drop, which reaches the cap on longer vectors. These cases are rare, but they must not be
silent.

## Design

### One descent length for spiral and smooth

Add `private static func descent(asked: Double, L: Double, drop: Double, tanA: Double) -> (length: Double, capped: Bool)`.
- `length = min(max(asked, drop / tanA), L · maxRampLaps)`.
- `capped = drop / tanA > L · maxRampLaps`.
- `maxSmoothLaps` is renamed `maxRampLaps`; its doc comment says it caps both ramps.

**Smooth** calls it with `asked = min(ramp.length, L)`. That is exactly today's expression at
`PassShaping.swift:61`, so smooth output does not change.

**Spiral** calls it with `asked = L`.
- The helix runs from `s0` to `s0 + length`, at depth `fromDepth + drop · (s − s0) / length`.
- On the last pass (`spiralFinish`), the flat lap `L + overcut` follows from `s0 + length`.
- `endS` is `s0 + length`, plus `L + overcut` on the last pass.
- The length is continuous, not whole laps, so no `ceil` and no rounding edge. A loop with
  `drop / tanA ≤ L` gets `length = L` exactly, the same points as today.
- On a short loop the spiral now ends part-way round a lap, as the smooth ramp already does.

### Zig-zag

- Compute the legs wanted in `Double` before any `Int` conversion: `wanted = max(2, ceil(drop / perLeg − 1e-9))`.
- `capped = wanted > maxZigzagLegs`.
- `legs = Int(min(wanted, maxZigzagLegs))`, then rounded up to even as today.
- Converting after the cap removes the overflow trap on a vanishing `perLeg`.

### The flag

- `ChainPass` gains `public var isSteeperThanMaxAngle: Bool = false`.
- It is true when the ramp ran and either:
  - the cap made it steeper, or
  - `ramp.maxAngle < 0.5`, so the floor made it steeper.
- `TabLayout.apply` copies the pass (`var out = pass`), so the flag survives tabs.

### The warning

There is one message, `PassShaping.steepRampWarning(_ ramp: RampSettings) -> String`:

`"ramps go down steeper than the <a>° maximum angle on some passes (the vector is too short, or the angle is under 0.5°); use a plunge, a steeper maximum angle, or a shallower pass depth"`

- `<a>` is `String(format: "%g", ramp.maxAngle)`, so 7.5 prints `7.5` and 10 prints `10`.
- It is a sentence, not a count. A count of chain-passes ("36 passes") is not something a user can act on.
- A steeper maximum angle is listed because it is the remedy that always works. A last pass at full
  depth ramps the whole cut depth, and a shallower pass depth does not change that.

**Profile.**
- `TabNotes` is renamed `CutNotes` and gains `var steepRamp = false`.
- Both `PassShaping.pass` call sites in `cut(...)` set it: the open-vector branch and the closed-loop
  branch. That also covers the last-pass loops, which go through the same `cut`.
- The warning is appended to the `warnings` list with the other notes.

**Pocket.**
- `emit` returns whether any pass was flagged: `-> (toolpath: Toolpath, steepRamp: Bool)`.
- A clearance toolpath with flagged passes gets the warning in its own `metadata["warning"]`. Clearance
  toolpaths carry no other warning.
- For the finish toolpath, the warning is appended to `warnings` before line 74's single assignment, so
  it is never overwritten.

**Callers with `RampSettings()`.** These are moulding, prism and the pocket linking lap, plus the profile
wrappers that build `ProfileParameters` without a ramp. Their ramp is disabled, so they never set the
flag and are unchanged.

## Not in scope

- **A validator check of ramp angles.** The validator sees G-code, not the ramp settings.
- **Splitting a pass instead of adding length.** Adding length keeps the user's pass depths, and the
  smooth ramp already does it.
- **The hole mill's helix.** It already holds its angle and warns.
- **Rejecting an angle under 0.5°.** That would make an existing document fail to build. It warns instead.

## Tests

**PassShaping** (CAMCore, beside `Ops2DSmoothRampAngleTests`; reuse its steepest-segment measurement):
- **Spiral never steeper.** Spiral never goes down steeper than the maximum angle, over radii 0.125, 0.5
  and 4 and drops 0.25 and 0.6. It reaches the pass depth. With `spiralFinish`, one whole lap follows at depth.
- **Spiral unchanged on a long loop.** On a radius 4 loop, every station of the new spiral pass (`xy`, `s`,
  `depth`) equals the old one-lap formula. Check with and without `spiralFinish`, and with overcut 0.1. This
  is the regression guard for unchanged G-code: no sample or golden file enables a ramp.
- **Spiral ends.** Without `spiralFinish` the pass ends at `s0 + length` at `toDepth`. With it and overcut 0.1,
  `endS == s0 + length + L + 0.1`.
- **Capped sets the flag.** `@Test(arguments: [RampType.spiral, .smooth, .zigzag])`: a loop too short even at
  the cap sets the flag. Use a 0.005 in square, drop 0.25 at 10°.
- **Floor sets the flag.** The same arguments with `maxAngle: 0.2` set the flag on a normal loop.
- **Normal loop.** The same arguments at 10° on a radius 1 loop leave it false.

**Operations:**
- **Profile on a tiny loop.** A profile "On" a closed circle 0.02 in across, with a spiral ramp at
  `maxAngle: 0.5`: the warning needs `0.125 / tan 0.5° = 14.3 in` of descent, more than `200 · 0.063 in`.
  The toolpath's `metadata["warning"]` contains the exact sentence. The `%g` format is pinned by the
  format test below, not here: reaching the cap at 7.5° needs a loop under 0.003 in, too close to the
  0.0005 in tolerance to be a stable fixture.
- **Profile on a short open vector.** A 0.05 in line with a zig-zag ramp at `maxAngle: 0.5` warns.
- **Pocket.** A pocket with `maxAngle: 0.2` (the floor) and a second region too small for the tool keeps
  both warnings on the finish toolpath.
- **Both Z-zero modes.** A profile with a spiral ramp on the 0.25 in radius inside loop, in material-top and
  spoilboard modes: the machine-Z descent per XY distance between consecutive feed moves never exceeds
  `tan 10°`. Model it on `ops2DProfileSmoothRampAvoidsVerticalPlunges`.
- **Format.** `steepRampWarning` prints `7.5°` for 7.5 and `10°` for 10.

## Docs

- **DECISIONS, new entry `ramp-angle-laps`.** Ramps add length rather than split passes; a capped or
  floored ramp warns. It supersedes the spiral line at DECISIONS:110 ("one helical lap per pass") and the
  note at :843 ("the spiral ramp … is still unbounded"), and adds to :598 (zig-zag capped at 200 legs) that
  a capped ramp now warns.
- **HelpTopics.**
  - "Ramp type" (:497): "spiral circles down, going round as often as the maximum angle needs".
  - "Max angle" (:460): "Steepest allowed ramp angle; a vector too short to keep it gets a warning".
- **PassShaping comments.** Move the misplaced `pass(...)` parameter doc block from above
  `maxZigzagLegs` to above `pass`.
