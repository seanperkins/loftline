# Ramps keep their maximum angle (issue #124)

Status: draft, revision 3 (after debate:all rounds 1 and 2)

## Problem

`PassShaping.pass` builds each pass's entry ramp. A ramp must never go down steeper than
`RampSettings.maxAngle`. Four cases break that:

1. **Spiral.** The helix always takes exactly one lap (`fromDepth + drop * (s - s0) / L`). A loop
   shorter than `drop / tan(maxAngle)` descends too steeply. Example: the inside of a 1/2 in hole with a
   1/4 in mill is 0.785 in round, and a 0.25 in pass descends at 17.7° against a 10° limit.
2. **Smooth.** Since #96 the ramp goes round more than once, but its length is capped at
   `maxSmoothLaps` (200) laps. Past the cap it is steeper, and nothing reports it.
3. **Zig-zag.** Legs are capped at `maxZigzagLegs` (200). Past the cap each leg is steeper, and nothing
   reports it.
4. **Angle floor.** The angle is clamped to 0.5°–89.5° (`PassShaping.swift:40`), and the field has no
   range. A maximum below 0.5° can ramp at 0.5°.

Cases 2 and 3 need a vector about 0.007 in long for a 0.25 in pass at 10°. A last pass at full depth
drops further, which reaches the cap on longer vectors. These cases are rare, but they must not be silent.

## Design

### One descent length for spiral and smooth

- Add `private static func descentLength(asked: Double, L: Double, drop: Double, tanA: Double) -> Double`,
  which returns `min(max(asked, drop / tanA), L · maxRampLaps)`.
- `maxSmoothLaps` is renamed `maxRampLaps`. Its doc comment now says it caps both ramps.

**Smooth.** It calls the helper with `asked = min(ramp.length, L)`. That is exactly today's expression at
`PassShaping.swift:61`, so smooth output does not change.

**Spiral.** It calls the helper with `asked = L`.
- The helix runs from `s0` to `s0 + length`, at depth `fromDepth + drop · (s − s0) / length`.
- On the last pass (`spiralFinish`), the flat lap `L + overcut` follows from `s0 + length`.
- `endS` is `s0 + length`, plus `L + overcut` on the last pass.
- The length is continuous, not whole laps, so there is no `ceil` and no rounding edge.
- A loop with `drop / tanA ≤ L` gets `length = L` exactly, which gives the same points as today.
- On a short loop the spiral now ends part-way round a lap, so the next pass starts there. The smooth
  ramp already does this, and tabs handle it, since they work on the unwrapped parameter.

### Zig-zag

- Compute the legs wanted in `Double`: `wanted = max(2, ceil(drop / perLeg − 1e-9))`.
- Cap them as `legs = Int(min(wanted, Double(maxZigzagLegs)))`, then round up to even as today.
- Capping before the `Int` conversion removes the overflow trap on a vanishing `perLeg`.

### The flag: measured, not inferred

- `ChainPass` gains `public var isSteeperThanMaxAngle: Bool = false`.
- When a ramp runs (the guard at `:42` passed), the flag is set from the slope the ramp actually has:
  `isSteeperThanMaxAngle = slope > requested · (1 + 1e-9)`.
- `slope` is `drop / length` for spiral and smooth, and `(drop / legs) / lz` for zig-zag.
- `requested` is `tan(min(maxAngle, 89.5)°)`, or 0 when `maxAngle ≤ 0`.

One rule covers both the caps and the floor. A ramp that is gentler than asked never warns, even when the
asked-for angle is under 0.5°. For example, a spiral on a long loop with a small drop at a 0.2° maximum
takes one lap at 0.11° and does not warn.

`TabLayout.apply` copies the pass (`var out = pass`), so the flag survives tabs.

### The warning

There is one message, `PassShaping.steepRampWarning(_ ramp: RampSettings) -> String`:

`"ramps go down steeper than the <a>° maximum angle on some passes (the vector is too short, or the angle is under 0.5°); use a plunge, a steeper maximum angle, or a shallower pass depth"`

- `<a>` is `String(format: "%g", ramp.maxAngle)`, so 7.5 prints `7.5` and 10 prints `10`.
- The warning is a sentence, not a count. A count of chain-passes ("36 passes") is not something a user
  can act on.
- "A steeper maximum angle" is offered because it always works. A last pass at full depth ramps the whole
  cut depth, so a shallower pass depth does nothing for it.
- The warning is appended after an operation's existing warnings, so it is always last.

**Profile.**
- `TabNotes` becomes `CutNotes`, with a new field `var steepRamp = false`.
- The variable and the argument labels become `cutNotes`, at `ProfileOperation.swift` :60, :120, :138,
  :150–155, :204, :259, :264, :274 and :300–301.
- The doc comment at :186–188 is rewritten to cover the steep ramp.
- `cut(...)` has two `PassShaping.pass` call sites, the open-vector branch and the closed-loop branch.
  Both set `steepRamp`, which also covers the last-pass loops, since they go through the same `cut`.
- The warning is appended last to `warnings`.

**Pocket.**
- `emit` returns `(toolpath: Toolpath, steepRamp: Bool)`.
- A clearance toolpath with flagged passes gets the warning in its own `metadata["warning"]`. Clearance
  toolpaths carry no other warning.
- For the finish toolpath, the warning is appended last to `warnings`, before line 74's single
  assignment, so nothing overwrites it.

**Callers with `RampSettings()`.** Moulding, prism, the pocket linking lap, and the profile wrappers that
build `ProfileParameters` without a ramp all have the ramp disabled. They never set the flag and are
unchanged.

## Not in scope

- **A validator check of ramp angles.** The validator sees G-code, not the ramp settings.
- **Splitting a pass instead of adding length.** Adding length keeps the user's pass depths, and the
  smooth ramp already does it.
- **The hole mill's helix.** It already holds its angle and warns.
- **Rejecting an angle under 0.5°.** That would make an existing document fail to build. It warns instead,
  and only when the ramp is actually steeper.

## Tests

### PassShaping (CAMCore)

These go beside `Ops2DSmoothRampAngleTests`, and share its steepest-segment measurement as a file-level
helper. They compare `Double`s with `abs(a − b) < 1e-9`. `descentLength` is private, so the tests
recompute the length themselves.

- **Spiral never steeper.** Over radii 0.125, 0.5 and 4 and drops 0.25 and 0.6, the spiral is never
  steeper than the maximum angle. It reaches the pass depth, and with `spiralFinish` one whole lap follows
  at depth.
- **Spiral unchanged on a long loop.** On a radius 4 loop, with `s0` = 0 and `s0` = 0.37, every station
  (`xy`, `s`, `depth`) equals the old one-lap formula. This holds with and without `spiralFinish`, and with
  overcut 0.1. It is the regression guard for unchanged G-code, since no sample or golden file enables a ramp.
- **Spiral ends.** Without `spiralFinish`, `endS` is `s0 + length` at `toDepth`. With it and overcut 0.1,
  `endS` is `s0 + length + L + 0.1`.
- **A capped ramp sets the flag.** Using `@Test(arguments: [RampType.spiral, .smooth, .zigzag])`, a 0.0015 in
  square (`L = 0.006`) with drop 0.25 at 10° sets the flag:
  - spiral and smooth need 1.418 in, more than the 1.2 in cap;
  - zig-zag wants 237 legs, more than 200.
- **The floor sets the flag.** With the same arguments, `maxAngle: 0.2` on a radius 1 loop with drop 0.25
  sets the flag. Spiral and smooth descend at 0.5°, and zig-zag at about 0.38°.
- **A gentle ramp leaves it false.** With the same arguments, the flag stays false in two cases: at 10° on
  a radius 1 loop, and with `maxAngle: 0.2` on a radius 4 loop with drop 0.05 and `ramp.length` 25.
- **Tabs keep the flag.** A flagged pass passed through a `TabLayout` that has centres stays flagged.
- **Format.** `steepRampWarning` prints `7.5°` for 7.5 and `10°` for 10.

### Operations

- **A profile on a tiny loop.** Profile "On" a closed circle 0.02 in across with a spiral ramp at
  `maxAngle: 0.5`, using the helper's depth 0.5, stated explicitly, at 0.125 per pass. The loop is about
  0.062 in round, so the cap is 12.4 in against 14.3 in needed. The toolpath's warning ends with the exact
  sentence.
- **A profile on a short open vector.** A 0.05 in line, `side: .on`, with a zig-zag ramp at `maxAngle: 0.5`,
  warns. It wants 286 legs, more than 200.
- **Pocket.** A pocket with a clearance tool and `maxAngle: 0.2` at a 0.25 in drop per pass. The clearance
  toolpath carries the warning. The finish toolpath carries it after "region(s) too small for the tool",
  from a second region too small for the tool. Each sentence is checked with `contains`.
- **Both Z-zero modes.** An inside profile of a 3/8 in circle with the 1/4 in mill: the tool-centre loop is
  about 0.39 in round, so today's one-lap spiral descends at 17.7° on a 0.125 pass. With a spiral ramp at
  10°, in material-top and spoilboard modes, no descending feed move is steeper than 10°. This is modelled
  on `ops2DProfileSmoothRampAvoidsVerticalPlunges`.

## Docs

- **DECISIONS, new entry `ramp-angle-laps`.**
  - Ramps add length rather than split passes.
  - A ramp steeper than its maximum, from the caps or the 0.5° floor, warns.
  - The spiral now ends part-way round a lap on a short loop.
  - It supersedes :108 (the smooth ramp, which has had the 200-lap cap since #96) and :110 ("one helical
    lap per pass").
  - It supersedes the note at :843 ("the spiral ramp … is still unbounded").
  - It adds to :598 (zig-zag capped at 200 legs) that a capped ramp now warns.
- **HelpTopics.**
  - "Ramp type" (:497) reads "spiral circles down, going round as often as the maximum angle needs".
  - "Max angle" (:460) reads "Steepest allowed ramp angle; a vector too short to keep it, or an angle
    under 0.5°, gets a warning".
- **`CommonParameters.swift:25`.** The `maxAngle` doc comment mentions the warning and the 0.5° floor.
- **PassShaping comments.** Move the misplaced `pass(...)` parameter doc block from above `maxZigzagLegs` to
  above `pass`.
