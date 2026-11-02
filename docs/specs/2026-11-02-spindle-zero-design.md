# A spindle started at S0 (#99 item 10)

Status: revision 2, after the round 1 panel (two GPT-6 seats, an Opus skeptic, a Sonnet simplifier).

## Problem

`{S}` is the toolpath's RPM written with `%.0f` (`ProgramBuilder.swift:134`, `NumberFormat.swift:10`), which rounds half to
even: anything below 1 that is not above 0.5, including 0.5 itself, prints `S0`. Nothing stops that:

- the builder's range check (`ProgramBuilder.swift:33`) passes any RPM from `minRPM`, and 18 of the 24 built-in posts have
  `minRPM: 0` (the GRBL, LinuxCNC, Carbide Motion, MASSO, UCCNC, Centroid, ShopBot, Syntec, Haas and NcStudio posts); a NaN RPM
  fails both comparisons and posts on every post;
- the app's tool warning (`OperationWarnings.rpmProblem`, `OperationWarnings.swift:248`) uses the same range;
- the validator checks `S` only against the range (`MotionChecker.swift:120`), so `M3 S0` passes on those 18 posts (the other
  six already get `rpm-range`); its cut check (`MotionChecker.swift:102`) knows only M3/M5, so a cut after `M3 S0`, or after
  `M3 S18000` and a later `S0`, is not a cut with the spindle off.

A tool's RPM can be 0: the tool editors take any number (`ToolDatabaseView.swift:318`, `ToolDataSections.swift:165`) and a CSV
import reads `rpm` as written (`ToolLibraryExchange.swift:120`). On GRBL `S0` gives the spindle no power (its PWM code disables
it at zero), on the Onefinity Buildbotics controller `M3` does nothing until `S` is above zero (Onefinity forum), and the other
RPM controllers read it as a stopped spindle. The program then plunges a bit that is not turning.

## Design

One floor, `PostProfile.minSpindleRPM = 1`, judged as `!(rpm >= 1)` everywhere so NaN fails too.

1. **The builder refuses it.** Before the range check (`ProgramBuilder.swift:33`), a toolpath whose `spindleRPM` is not at
   least 1 throws `PostError.spindleStopped(toolpath:)`, for every post. ShopBot writes `M3` alone and never prints `S`, but a
   ShopBot copy may write `M3 S{S}` (`PostDraftReport.swift:123`) and the RPM also drives the time estimate and chip load, so
   one rule is kept: a ShopBot user with a 0 RPM tool sets any speed. `GCodeExporter.export` gets its own catch: "<toolpath>
   has no spindle speed (below 1 RPM): set the tool's spindle speed."
2. **The validator reports it.** `MotionChecker.rpm` checks the floor before the range: `spindle-zero-speed`, an error,
   "Spindle speed S0 leaves the spindle stopped", and returns (no second `rpm-range` error). It is reached for `S` on an
   `M3`/`M4` block, as now. The validator also keeps the modal speed (`speed: Double?`, nil until a block sets `S`) and passes
   the cut check `spindleOn && !(speed known and below 1)`, so a cut after `M3 S0` or after a later `S0` is the existing
   `spindle-off` error. Unknown is not zero: ShopBot's plain `M3` still cuts with the spindle on, and its `spindle-no-speed`
   warning (#106) is unchanged. A footer's `S0` after the last cut reports nothing.
3. **The app warns before export.** `OperationWarnings.rpmProblem` returns "The spindle speed must be at least 1 RPM." for an
   RPM below the floor, before the range message, whatever the post.

No post output changes: every sample and golden uses a positive RPM, so `samples/expected` and the goldens stay byte-identical.

## The rest of item 10 (no change; for the #99 comment)

- **Whole-number RPM** (`ProgramBuilder.swift:134`): every built-in controller reads `S` as RPM; none needs decimals.
- **Percent or analog scale**: Marlin (PWM 0-255 by default, or percent), Duet (percent on older firmware) and FluidNC (its
  `speed_map`) map `S` by a setting; none is a built-in target except FluidNC through the GRBL posts, where the machine's
  `$30`/speed map must match Max RPM: a controller setting a program cannot set, item 13.
- **Controllers that ignore `S`**: ShopBot (`M3` is a switch, #106, `BuiltInPosts.noSpindleSpeedIDs`); DSP controllers
  (RichAuto) wait with #112.
- **Onefinity**: Buildbotics maps `S` linearly between its `min-spin` and `max-spin` settings; the BB posts' `minRPM` is
  10,000, so the builder already refuses a lower speed.
- **The `spindle-no-speed` warning for a plain `M3`**: only ShopBot writes one; every ShopBot export warns by design (#106: the
  operator sets the router's dial) and the editor's sample filters it (`PostDraftReport.isNoSpeed`).

## Tests

- PostCore builder: every built-in post refuses a toolpath at 0, 0.5, 0.99 and NaN RPM with `.spindleStopped`; a custom copy
  of the GRBL post (`minRPM: 0`) at 1 RPM posts `S1`.
- Validator (GRBL profile): `M3 S0` → `spindle-zero-speed` and no `rpm-range`; on the Avid profile the same, only one error;
  `M3 S0` then a cut → also `spindle-off`; `M3 S18000`, `S0`, a cut → `spindle-off`; `G1 Z-0.1 S0` after `M3 S18000` →
  `spindle-off`; `M3 S18000`, a cut, `S0`, `M5`, `M30` → no error; plain `M3` (no `S`) then a cut → only the existing warning.
- App: `rpmProblem(0, avid)`, `rpmProblem(0.5, grbl)` and `rpmProblem(.nan, grbl)` give the floor message; exporting a 0 RPM
  tool fails with the message above.

## Docs

DECISIONS `spindle-zero` (including the ShopBot ruling); #99 comment answering item 10.
