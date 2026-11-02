# The validator checks a G28/G30 intermediate point (issue #129)

Status: approved, revision 2 (after debate:all round 1)

## Problem

`GCodeValidator.validate(gcode:)` treats `G28` and `G30` as non-motion (`case 4, 28, 30: nonMotion = true`),
so it never checks the axis words on those blocks. On LinuxCNC, Mach and GRBL, `G28 X6` first makes a rapid
to X6 in work coordinates, in the current distance mode, before the named axes go on to the stored position.
That leaves two holes:
- **Travel.** A custom post whose footer is `G28 X6`, on a 5.5 in X-travel machine, exports with no travel
  error.
- **Plunge.** `G28 Z-1` makes a rapid into the stock with no warning.

No built-in post writes `G28` or `G30`, so only a user's post can reach this.

## Design

A block with `G28` or `G30` and at least one axis word is checked as a `G0` to its intermediate point:
- **It is checked like a rapid.** It goes through the same code as a `G0` block:
  - the same `resolve` (absolute, or added to the current position under `G91`);
  - the same start, target and `xyMove` rules;
  - `check.rapid(from:to:xyMove:line:)`, so the travel window, rapid-in-material, rapid-below-safe and
    rapid-plunge checks all apply;
  - the same one-time `no-absolute` warning before the first `G90`.
- **The modal motion is unchanged.** `G28` and `G30` are non-modal: a `G1` in force stays in force for the
  bare axis words on later blocks. The rapid is chosen for this block only (`intermediate ? 0 : motion`).
- **No motion mode is needed.** A `G28 X…` before any `G0` or `G1` is checked, and does not warn
  `no-motion-mode`.
- **The position after it is the intermediate point,** as after a `G0`. The real machine then goes on to its
  stored position, which the validator cannot see. Keeping the intermediate point is a deliberate
  approximation:
  - every later check keeps a known start: rapid-plunge, rapid-in-material, and the two-line `G91 G28 Z0` /
    `G28 X0 Y0` ending;
  - forgetting the position would switch those checks off, because `rapid-plunge` needs a known start;
  - a stored position is normally the top of Z, so reasoning from the intermediate point errs towards more
    warnings, not fewer.
- **Two motion codes on one block are an error.** `G28` or `G30` on the same block as `G0`, `G1`, `G2` or `G3`
  gives `"G28/G30 and a motion code on one block"`. LinuxCNC rejects it, and which motion the controller
  would make is ambiguous.
- **No axis words, no change.** A `G28` or `G30` with no axis words is still non-motion, and the position is
  kept, as today.

## Not in scope

- **The stored position.** It lives in the controller's parameters.
- **A rapid from an unknown Z at the start of a program**, which `rapid-plunge` cannot judge without a start
  (`MotionChecker.rapid`). That is the existing behaviour; this change never makes a position unknown.
- **The probe-sequence checker.** It does not model `G28`/`G30`, and gives an error for one inside the
  probed tool-change sequence. That is existing and fails safe.
- **`G28.1` and `G30.1`.** They still get the unknown-code warning. Mach's `G28.1` (reference axes) is not
  modelled.
- **Keep-out zones and clamps.** The export's zone checks model the footer's move home only from its
  `{HOME_*}` tokens. A `G28` intermediate move in a custom footer is not checked against zones.

## Tests (PostCoreTests)

**In `TravelWindowTests`:**
- **`G28 X6`** at the end of a program on a 5.5 in X-travel post gives `travel-X`. `G28 X2` does not.
- **`G30 X6`** gives the same result.

**In `PostValidatorTests`, in both Z-zero modes:**
- **Plunge.** `G28 Z-1` from safe Z, over the stock, gives `rapid-plunge`. Other issues may appear too.
- **XY at depth.** With the tool at depth 0.1, `G28 X1 Y1` gives `rapid-in-material`.
- **Incremental ending.** `G91 G28 Z0` then `G28 X0 Y0`, both at safe Z, gives no rapid issue.
- **Before any motion mode.** `G28 X6` (6 > 5.5 travel) is checked, and there is no `no-motion-mode`.
- **`G1` stays modal.** `G1 X1 F10`, then `G28 Z0.5`, then `X2` is a feed: no `rapid-*` issue, and
  `feed-missing` is not raised.
- **Two motion codes.** `G1 G28 X1` gives the error.
- **Millimetres.** A G21 program ending `G28 X200`, on a 5.5 in X-travel post, gives `travel-X`.
- **Unchanged test.** `anyCodeOtherThanAPlainMoveForgetsTheHole` still passes, including `G28` and `G30 X1 Y1`.

## Docs

DECISIONS entry `g28-intermediate-point`. It records:
- that the intermediate point is checked as a rapid;
- why the position is kept rather than forgotten;
- the motion-code conflict error.
