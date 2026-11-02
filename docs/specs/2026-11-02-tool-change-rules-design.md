# MASSO tool change order (#99 item 11)

Status: revision 2, after the round 1 panel (two GPT-6 seats, an Opus skeptic, a Sonnet simplifier). Revision 1 proposed
three rules; two already exist as export errors in `DialectChecks` (MASSO's missing G43, NcStudio's T1-T7 with G43, both #107
and #109), so only the gap below is left.

## Problem

MASSO (docs.masso.com.au, M06 and T pages): "M06 must be preceded by M05 or unpredictable results may occur", and "Txx M06 is
correct and behaves differently to M06 Txx". The built-in MASSO posts write `M5`, a comment, `T{T} M6`
(`BuiltInPosts.swift:161`). A copy is held to neither rule:

- the post editor's stop check (`PostDraftReport.changeIsSafe`, `PostDraftReport.swift:274`) accepts `M6 T{T}`;
- the validator reports an `M6` with the spindle running only as a warning (`GCodeValidator.swift:256-260`), so a copy read
  from a file (which never passes the editor) exports a tool change with the spindle on after a warning;
- a block-delete line (`/…`) is parsed as code (`GCodeParser.swift:65-69`); with Block Delete on, MASSO skips it, so an `M5`,
  `T` or `M6` there may not run.

## Design

One rule in `GCodeValidator.validate(gcode:)`, on the written program (so `{T}` is already a number, and a probed tool change
or an `M6` in any template is covered), for the MASSO family (`DialectChecks.massoIDs`, made visible to the validator):

1. An `M6` while the spindle is on (the last of `M3`/`M4`/`M5` before it, in its block or earlier, was not `M5`) is an
   error: "MASSO needs the spindle stopped (M5) before M6." (instead of the `toolchange-spindle-on` warning).
2. An `M6` needs the tool number before it: a `T` word earlier in its own block, or on an earlier block after the previous
   `M6`. A `T` only after the `M6` in its block, or none, is an error: "MASSO reads the tool number before M6 (T5 M6), not
   after it (M6 T5): write T{T} M6."
3. An `M5`, `T` or `M6` on a block-delete line is an error: "MASSO skips a block-delete line when Block Delete is on: take
   the / off the tool change." 

The editor's sample is validated (`PostDraftReport.swift:204-210`), so a draft breaking these cannot be saved; an export
error is overridable (Save Anyway, CLI `--force`), like every `DialectChecks` error. Other posts are unchanged.

No built-in output changes: the samples and goldens stay byte-identical.

## Tests

On `validate(gcode:)` with the MASSO inch profile (and a MASSO copy id), each case a full small program:
- `M5` / `T1 M6` → no error; `M5` / `T1` / `M6` → none; the built-in's own export of the fixture job → none.
- `M3 S18000` / `T1 M6` → the spindle error; `M5` / `M3 S18000` / `T1 M6` → the spindle error.
- `M5` / `M6 T1` → the order error; `M5` / `M6` → the order error; `T1 M6` then later `M5` / `M6` (no new T) → the order
  error on the second.
- `M5` / `/T1 M6` → the block-delete error; `/M5` / `T1 M6` → the block-delete error.
- The Mach4 profile with `M3 S18000` / `M6 T1` → only the existing warning.

## Docs

DECISIONS `masso-tool-change`; #99 comment answering item 11 with the "no change" findings: wherever a macro leaves the
machine, the writer climbs to the approach height before moving in X Y (`ProgramBuilder.reenter`), though a controller macro
that left `G91` on cannot be seen from the program; LinuxCNC, Onefinity BB and GRBL/FluidNC stop with `M0` and write no
`T`, `M6` or `G43`; Carbide Motion: tools of different geometry sharing a number are an error, same geometry a warning
(`GCodeValidator.swift:55`); NcStudio T1-T7 with G43 and MASSO's T1-T100 and missing G43 are `DialectChecks` export errors;
UCCNC's G43 H limit of 20 is unconfirmed and its posts write no G43.
