# Post processors in open-source CAM: a comparison with LoftLine (2026-10-29)

How the open-source CAM programs that ship post processors do it, and where their dialect facts agree or disagree with the
rulings in `docs/DECISIONS.md` and the open post issues (#99, #109, #112, #113, #119, #120, #125). The findings are grouped
by issue, so whoever picks one up can start from it. Each claim cites the file and line at the commit listed under Scope.
Their code tells us what they emit, not what a controller accepts: a disagreement is something to check, not proof that
either side is wrong.

## Scope

| Project | What its posts are | Commit read | Last commit |
|---|---|---|---|
| FreeCAD CAM (`src/Mod/CAM`) | Python classes over a shared `PostProcessor` base, with a property schema and `.fcm` machine files; 22 new posts and 23 `*_legacy_post.py` | `a6d3cb5` | 2026-10-29 |
| Fabex (formerly BlenderCAM) | About 35 Python `Creator` classes from HeeksCNC's `nc` library (`nc.py:1-9`: Hirutso Enni, Dan Falck) | `9c68ed4` | 2026-10-16 |
| Kiri:Moto (GridSpace grid-apps) | JSON device files with template lines and `{name}` placeholders; 28 CAM devices | `d138275` | 2026-07-26 |
| FlatCAM Evo | Python "preprocessor" classes with one method per event; 26 preprocessors | `7d9fdd4` | 2026-10-29 |
| dxf2gcode | An INI file per post (configobj spec) with `%name` templates | `e6eddf0` | 2020-08-26 (stale) |
| pcb2gcode | One built-in dialect plus capability flags (`--nom6`, `--nog81`, `--nog91-1`, `--nog64`) | `418b4c4` | 2026-10-28 |
| Gcodetools (Inkscape) | `header`/`footer` files plus a regex "Postprocessor" pass | `36b38cd` | 2026-01-28 |
| OpenBuilds CAM | GRBL only; free-text start and end G-code | `7369478` | 2025-03-04 |
| PyCAM | A single LinuxCNC generator | `55e3129` | 2021-11-25 (stale) |
| Universal G-code Sender | Not CAM: rewrites a program as it streams it (strip M30, line length, decimals, comments) | `67d6265` | 2026-10-25 |

Not surveyed:

| Project | Reason |
|---|---|
| HeeksCNC | Dormant. Fabex carries its `nc` library. |
| CAMotics | A simulator with no posts. Its planner is already the Buildbotics dialect source (`onefinity-carbide-posts`). |
| LaserWeb4, bCNC, cncjs | Senders or laser tools. Their G-code fields are start/end text. |
| jscut, SolveSpace | Fixed G-code with no dialect choice. |
| F-Engrave, G-Code Ripper | Header and postscript text fields only. Not cloned. |
| FreeCAD/Machines repo | Holds the `.fcm` machine files. Not read. |
| Ondsel | A FreeCAD fork. |
| Fusion 360, SheetCam, Estlcam | Not open source. Autodesk's posts are already a LoftLine source. |
| Slicers (Cura, PrusaSlicer) | Their G-code flavours target 3D printers. |

None of these projects has a post for NcStudio/Weihong or RichAuto DSP. A grep for `ncstudio|weihong|richauto` across
every clone found nothing, so #109 and #112 get no help from open source.

## The approaches side by side

- **Code posts** (FreeCAD, Fabex, FlatCAM, PyCAM). A post is a subclass that overrides methods (`_convert_dwell`,
  `tool_change`, `dwell_code`). It can do anything, nothing checks what it writes, and a user changes one by editing
  Python. Fabex opens `post_processors/user.py` in Blender's text editor (`utilities/addon_utils.py:392-400`).
- **Template posts** (Kiri:Moto, dxf2gcode, OpenBuilds, Gcodetools' header/footer). A post is data, close to
  LoftLine's model, but with fewer placeholders and no check of the result. Kiri hides engine switches in the preamble as
  magic comments: `;; REWRITE-COMMENTS-PARENS`, `;; DECIMALS=`, `;; COMPACT-OUTPUT`, `;; SCALE {json}`, `;; AXISMAP`
  (`src/kiri/mode/cam/work/export.js:366-397`).
- **FreeCAD's new design** is moving toward LoftLine's: data settings (a property schema, `Path/Post/Processor.py:412-780`;
  machine output options, `Machine/models/machine.py:89-185`), with per-controller code only where data cannot say it.
- **What only LoftLine does.** No project surveyed reads its own output back. LoftLine runs `GCodeValidator` on every
  export and runs the editor's sample-job report on every post. FreeCAD's sanity checks look at the job, not the
  G-code: spindle speed, rotary axes, fixtures (`Processor.py:3135-3348`). LoftLine is also the only one that ties the
  dwell unit to the controller family and refuses the wrong unit (`dwell-ms`, `engine-prelude-units`).

## Findings by issue

### #99 item 1 / `dwell-ms`: the dwell unit (safety)

Nearly every project prints one unit for every controller.

| Project | What `G4 P` gets | Source |
|---|---|---|
| FreeCAD | Seconds with axis precision (`P3.000`) for every post. Only `fanuc_post` converts, with a `dwell_in_milliseconds` property (default on). | `Processor.py:1448-1471` (spin-up is `G4 P<toolhead_wait>`), `Processor.py:3659-3665`, `Machine/ui/editor/machine_editor.py:141` ("seconds"), `scripts/fanuc_post.py:33,200-210` |
| Fabex | `G04 P<seconds>` for every machine, from one base class | `post_processors/iso.py:243-244,306-307`, `gcode/gcode_export.py:273-274` |
| FlatCAM | `'G4 P' + str(dwelltime)` in every preprocessor | `preprocessors/default.py:259-263`, `GRBL_11.py:241-245` |
| Kiri:Moto | `{time}` is seconds and `{time_ms}` is milliseconds. The stock devices write `G4 P{time} ; dwell for {time}ms`, so the output is right for GRBL but the comment says the wrong unit. | `export.js:173-181`, `src/kiri/dev/cam/Any.Generic.Grbl.json` |
| pcb2gcode | Milliseconds (`asMillisecond`) in a LinuxCNC-style dialect. A 2 s spin-up prints `G04 P2000`, a 2,000 s wait on LinuxCNC. | `src/main.cpp:141,169,190`, `src/ngc_exporter.cpp:378`, `src/options.cpp:335` |
| OpenBuilds | `G4 P8` hard-coded (GRBL seconds) | `js/advanced-cam-gcode.js:196` |

**Conflict, MASSO.** FreeCAD's `masso_g3_post.py` does not override `_convert_dwell`, so a 3 s spin-up prints `G4 P3.000`.
That is 3 ms if MASSO's docs (milliseconds) are right, and LoftLine follows the docs. This is the failure #99 item 1
describes. It is evidence for LoftLine's ruling, not against it.

### MASSO preamble, G43 and G49 (`masso-uccnc-centroid-posts`)

**Conflict.** FreeCAD's MASSO post writes the preamble as one line, `G17 G54 G40 G49 G80 G90`, and writes `G43 H<n>` after
each tool change. Its tests require both (`scripts/masso_g3_post.py:97-99`, `CAMTests/TestMassoG3Post.py:115,127`).
LoftLine writes one word per line, with no G49 and no G43, from MASSO's statement that a line holding an invalid word is
skipped whole. If MASSO rejects G49, FreeCAD's whole preamble line is skipped: no G90, G17 or G54. If MASSO accepts both,
LoftLine gives up a tool length offset it could have had. FreeCAD's tests only check FreeCAD's own output, so this stays
the owner check in TESTING.md. One gap remains even if LoftLine is right: no MASSO user has confirmed that it fails.

### Tool changes that cannot stop (`ToolChangeZ`, `more-posts`)

| Project | GRBL tool change | Source |
|---|---|---|
| Fabex | `tool_change` is `pass`: a multi-tool file never stops and runs every tool with the first bit | `post_processors/grbl.py:51-52` |
| FreeCAD | M6 is turned into a comment by default ("grbl currently does not handle it") | `scripts/grbl_post.py:100-103` |
| FlatCAM | `M5`, `G00 Z`, `T{n}`, `M6`, `(MSG, …)`, `M0` | `preprocessors/GRBL_11.py:129-175` |
| Kiri:Moto | `M6 T{tool}` | `src/kiri/dev/cam/Any.Generic.Grbl.json` |
| LoftLine | `M0` stop, plus a `ToolChangeZ` warning to save one file per tool | `more-posts` |

LoftLine is the only one that tells the user Z is not set for the new bit. Fabex's silent drop is the failure that
warning exists to prevent.

Fabex's Mach3 class writes `G43H{id}` before `T{id} M6`, so the offset takes effect before the bit is swapped, the reverse of the usual order
(`post_processors/mach3.py:15-18`). LoftLine and FreeCAD write G43 after M6. Fabex's Centroid class writes `M25` (home Z) after `T` and then `G43 H` (`centroid1.py:120-126`), and
FreeCAD's Centroid post writes `M5`, `M25`, `G49 H0` (`scripts/centroid_post.py:72,199-203`). Both agree with #99 item 11:
on Centroid, Z goes home at a tool change.

### Touch-plate probing (`mach4-zero`, `probe-bounds`)

FlatCAM's `Toolchange_Probe_MACH3` writes `G31 Z<depth>` then `G92 Z<plate>`, twice (`preprocessors/Toolchange_Probe_MACH3.py:159-171`).
If the probe never touches, `G31` ends at the target depth and `G92` still declares that point the plate top: the
failure that `mach4-zero` avoids by calling the owner's macro. It also zeroes with G92, a shift that can persist after the program ends. No surveyed project has a probe-sequence checker like `ProbeSequenceChecker`.

### #99 item 14: unknown words

FreeCAD lets a post declare the words it emits. `supported_commands` and `ignored_commands` are post properties; a word
on the ignored list is dropped, and any other word not on the supported list is refused with `CAMValueError` at post time
(`Processor.py:457-475,3455-3489`). This answers "how a post lists the words it relies on": the inverse of LoftLine's
`postProblem` patterns, checked when the post builds. pcb2gcode does the same job with capability flags
(`--nom6`, `--nog81`, `--nog91-1`, `--nog64`; `src/main.cpp:391-396`, `src/drill.cpp:113`).

### #99 items 3, 4 and 9: line numbers, line endings, number format

| Setting | FreeCAD | dxf2gcode | Kiri:Moto | LoftLine |
|---|---|---|---|---|
| Line-number start and step | `line_number_start` 100, `line_increment` 10, `line_number_prefix` | `line_nrs_begin` 10, `line_nrs_step` 10 | none | fixed N10, step 10 |
| Line ending | `end_of_line_chars` | `win_line_endings` | always CRLF (`export.js:106`) | LF only |
| Decimal separator, padding, sign | precision only | `decimal_separator`, `pre_/post_decimal_zero_padding`, `signed_values` | `;; DECIMALS=` | `decimals`, `feedDecimals` |

Sources: `Machine/models/machine.py:114-121`, `dxf2gcode/postpro/postprocessorconfig.py:91-110`. Kiri writes CRLF to
every device, GRBL included, so CRLF is in everyday use on hobby controllers. That says nothing about MASSO, item 4's
open case.

### #99 item 5: comments and line length

- Comment styles: FreeCAD has `comments.symbol` (`machine.py:103-111`). Centroid uses `;` (`scripts/centroid_post.py:121-123`),
  OpenSBP uses `'` (`scripts/opensbp_post.py:233`), and Fabex's Centroid class also writes `;` (`centroid1.py:43-44`).
  These agree with LoftLine's Centroid post.
- Kiri can turn `;` comments into `( )` (`export.js:89-101`); LoftLine goes the other way, writing parentheses inside a
  `;` comment as brackets.
- Line length: UGS checks it at the sender (`CommandLengthProcessor`, with a configurable length). No CAM program
  checks it. LoftLine's validator could warn on lines past 256 characters (LinuxCNC, Mach3) or GRBL's 80.

### #99 item 7: UCCNC units

FreeCAD's UCCNC post says "G20/G21 are not supported by UC-CNC, units are configured in a program profile. In code
G20/G21 commands are silently ignored", and writes them anyway "to mirror the profile settings"
(`scripts/uccnc_legacy_post.py:212-230`). This is the same source #99 cites. LoftLine's warning on every export goes
further than FreeCAD, which says nothing at export.

### #99 item 12: machine-coordinate moves

pcb2gcode has a switch that makes the tool-change retract `G53 G00 Z` (`bZchangeG53`, `src/ngc_exporter.cpp:359`). That
is the case item 12 says a template cannot express. FreeCAD's Fanuc post can park the empty spindle (`M6 T0`) before the
postamble (`scripts/fanuc_post.py:22-45`).

### #111 / `shopbot-syntec-haas-posts`: the `%` and O-number wrapper

FreeCAD's Fanuc post writes `%` and an `O` program number (properties `wrap_in_percent` and `program_number`,
`scripts/fanuc_post.py:78,162-180,374-403`) and dwells in whole milliseconds. Both match LoftLine's Haas ruling.

### #113 and #99 item 15: ShopBot OpenSBP

- FreeCAD writes OpenSBP by converting each command: `CG,,x,y,i,j,T,dir,plunge` arcs, `TR,<rpm>` spindle,
  `&Tool=` then `PAUSE` for a manual change, `'` comments (`scripts/opensbp_post.py:455-520`). It also ships a reader,
  `scripts/opensbp_pre.py`, which turns SBP back into Path commands. That points to a third option for "validate before
  conversion, or write an SBP parser": write SBP from the validated moves, then read it back into the moves and compare.
- Fabex's ShopBot class (`shopbot_mtc.py:122-133`) writes `C7`, `&Tool=`, `JZ`, `J2`, `PAUSE`, `C2`, `C6`, `PAUSE 2`. This is
  a second public source for the tool-change macro sequence.
- Kiri's `ShopBot.Basic` device writes an OpenSBP preamble but G-code templates (`G4 P{time}`, `M6 T{tool}`) into the same
  `.sbp` file, and its exporter has no SBP path (only RML, `export.js:31,324`). It is not a usable reference.

### Schemas and files that change (`snapshot-schema`)

There are three ways to handle a post file written by another version:

- **dxf2gcode** refuses any version mismatch and tells the user to delete or edit the file
  (`postprocessorconfig.py:43-49,196-210`).
- **FreeCAD** loads the file and has a validator that warns when a key would be silently dropped ("a key that the loader
  no longer reads looks exactly like a key that works", `Machine/models/validate.py:1-30`).
- **LoftLine** refuses a newer schema before decoding and writes the lowest version a post needs.

LoftLine's rule is the strictest of the three and the only one tied to output.

### Things LoftLine might borrow

1. A declared word list per post, as in FreeCAD's `supported_commands`, refused at build. This covers #99 item 14, and
   #125 (placeholders outside comments) is the same kind of build-time refusal.
2. A line-length warning in `GCodeValidator` (#99 item 5).
3. Line-number start and step, and CRLF, as post fields (#99 items 3 and 4). Both FreeCAD and dxf2gcode settled on the
   same three or four fields.
4. A round trip for OpenSBP (#113): write SBP, read it back to moves, compare with the validated moves.
5. A `G53` tool-change retract option (#99 item 12), as in pcb2gcode.
