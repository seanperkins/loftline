# A spindle started at S0 (#99 item 10)

Status: revision 1.

## Problem

`{S}` is the toolpath's RPM rounded to a whole number (`ProgramBuilder.swift:134`). Nothing stops it from being `0`:

- the builder's range check (`ProgramBuilder.swift:33`) passes any RPM from `minRPM`, and 18 of the 26 built-in posts have
  `minRPM: 0` (the GRBL, LinuxCNC, Carbide Motion, MASSO, UCCNC, Centroid, ShopBot, Syntec, Haas and NcStudio posts); on
  those an RPM of 0, or any RPM below 0.5 (it rounds to `S0`), posts; a NaN RPM fails both comparisons and posts on every
  post (as `S` of a NaN);
- the app's tool warning (`OperationWarnings.rpmProblem`, `OperationWarnings.swift:248`) uses the same range;
- the validator warns only when no `S` was ever set (`GCodeValidator.swift:268-270`); `M3 S0`, or `S0` and then a plain `M3`,
  passes with no issue.

A tool's RPM can be 0: the tool editors take any number (`ToolDatabaseView.swift:318`, `ToolDataSections.swift:165`) and a CSV
import reads `rpm` as written (`ToolLibraryExchange.swift:120`). On GRBL `S0` turns the spindle off (its PWM code disables the
spindle at zero), on the Onefinity Buildbotics controller `M3` does nothing until `S` is above zero (Onefinity forum), and the
other RPM controllers read it as a stopped spindle. The program then plunges a bit that is not turning.

## Design

1. **The builder refuses a speed that would print as `S0`.** Before the range check, a toolpath whose `spindleRPM` is not at
   least 0.5 (so NaN too) throws `PostError.spindleStopped(toolpath:)`. Every post, including ShopBot (which writes `M3`
   alone): a 0 RPM tool is a mistake there too, and one rule is simpler than an exception.
   The export reports: "<toolpath> runs the spindle at 0 RPM, and S0 leaves the spindle stopped: set the tool's spindle
   speed."
2. **The validator makes a stopped start an error.** It tracks the modal speed (`S` on any block sets it, as on the
   controllers) and reports `spindle-zero-speed`, an error, when `M3` or `M4` runs with that speed below 0.5:
   "Spindle started (M3/M4) at S0, which leaves it stopped". The existing `spindle-no-speed` warning (no `S` ever set) is
   unchanged, so ShopBot's plain `M3` still warns as #106 decided.
3. **The app warns before export.** `OperationWarnings.rpmProblem` returns "The spindle speed 0 RPM leaves the spindle
   stopped: set a speed." for an RPM below 0.5, whatever the post's range.

No post output changes: every sample and golden uses a positive RPM, so `samples/expected` and the goldens stay byte-identical.

## The rest of item 10 (no change)

- **Whole-number RPM** (`ProgramBuilder.swift:134`): every built-in controller reads `S` as RPM; none needs decimals.
- **Percent or analog scale**: Marlin (PWM 0-255 by default, or percent), Duet (percent on older firmware) and FluidNC (its
  `speed_map`) map `S` by a setting; none is a built-in target except FluidNC through the GRBL posts, where the machine's
  `$30`/speed map must match Max RPM. That is a controller setting a program cannot set: item 13.
- **Controllers that ignore `S`**: ShopBot (`M3` is a switch, #106, `BuiltInPosts.noSpindleSpeedIDs`); DSP controllers
  (RichAuto) wait with #112.
- **Onefinity**: Buildbotics maps `S` linearly between its `min-spin` and `max-spin` settings; the BB posts' `minRPM` is
  10,000, so the builder already refuses a lower speed. Design 1 covers `S0` for every post.
- **The `spindle-no-speed` warning for a plain `M3`**: only ShopBot writes one; every ShopBot export warns by design (#106: the
  operator sets the router's dial) and the editor's sample filters it (`PostDraftReport.isNoSpeed`).

## Tests

- PostCore: every built-in post refuses a toolpath at 0, 0.4 and NaN RPM with `.spindleStopped`; 0.5 rounds to `S1` and posts
  where the range allows it (a custom copy with `minRPM: 0`).
- Validator: `M3 S0` → `spindle-zero-speed` error; `S0` then `M3` → error; `S18000` then `M3` → no issue; `M5 S0` → no issue;
  a plain `M3` with no `S` → the existing warning only.
- App: `rpmProblem(0, avid)` and `rpmProblem(0.4, grbl)` give the stopped message; the export of a 0 RPM tool fails with the
  message above.
- `scripts/check-samples.sh` with no `--update`: no change.

## Docs

DECISIONS `spindle-zero`; #99 comment answering item 10.
