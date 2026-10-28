# Othermill Pro posts (issue #114)

Revision 1, 2026-10-28. Approved for work by Sean ("go", 2026-10-28) as the next item after #115.

## Goal

Built-in posts and machines for the Othermill Pro and the original Othermill, which run G-code through the Bantam Tools
Milling Machine Software (formerly Otherplan) on a Synthetos TinyG board. A file LoftLine writes must load in that software
with no skipped lines, sit on the stock where the operator expects, and never ask the machine for a code it cannot run.

Not in scope: the Bantam Tools Desktop PCB/CNC machines as named machines (same software, specs not collected); `R`-format
arcs (#99 item 8); the dwell-unit work in #99 item 1 (the Othermill's `G4 P` is seconds, so it does not need it).

## Sources

Evidence labels as in #98: **vendor** (Bantam or Other Machine Co. documentation, read through search-result text, since
support.bantamtools.com refuses automated fetches with HTTP 403), **vendor-CAM** (Autodesk's `othermill.cps`, "Othermill
(Otherplan)", and `bantam tools.cps`, both revision 44229 of 2026-06-12, downloaded from cam.autodesk.com and read here; the
Othermill post's long description says it "also works with Bantam Tools desktop milling machines"), **issue** (the research
in #114, itself from the Bantam G-code Reference, Troubleshooting and File Support pages), **retailer**.

## The nine safety facts (#98)

| # | Fact | Answer | Evidence |
|---|---|---|---|
| 1 | `G4` unit | seconds; `G4 P4` after the spindle starts | issue ("G4 Dwell P: Pause for P seconds"); vendor-CAM (`onDwell(4)`, `"P" + secFormat`) |
| 2 | arc centres | incremental I/J; no `G90.1`/`G91.1` (on no supported list); the Othermill post writes I/J by default and allows helical moves, the newer Bantam post writes `R` and disallows helical moves | issue; vendor-CAM |
| 3 | `M6` / `T` | `M6 T{T}` makes the software pause, prompt for the swap and touch the tool off; the firmware treats `M6` as a no-op, the software acts on it. Spindle stopped first (`M5`) | issue (Troubleshooting: "The G-code required to initiate a tool change is: M6 T1"; "will pause your job, prompt you to swap out your tool, and perform a tool touch off") |
| 4 | `G43` / `G49` | not recognised ("G40-G51 … TinyG does not recognize those commands"); the touch-off sets the length | issue |
| 5 | program end | `M30` (`M2` also ends); no `%` | issue; vendor-CAM (`M30`) |
| 6 | spindle | `M3 S{S}`, clockwise only (`M4` unsupported); Pro 8,500–26,000 rpm, original 7,000–16,500 | issue; retailer (Adafruit), vendor (original Getting Started PDF) |
| 7 | unknown words, comments | a file with unsupported commands "may be unable to load, or lines may be skipped", with no error ("the spindle doesn't turn on"); `( )` comments are stripped, `(msg …)` is shown to the operator | issue |
| 8 | work offset, home | `G55` only ("Coordinate systems other than G55 are not supported"); no `G28`/`G53` park | issue; vendor-CAM ("Otherplan only uses G55") |
| 9 | feed mode | `G94`, `F` modal | issue; vendor-CAM (`G94`) |

**Z zero and origin.** Bantam's Fusion 360 workflow says to set the work origin at "the top, front, left box point on your
stock", and the software aligns files "to the front, top left corner of the stock" by default (vendor, search-result text).
So file X0 Y0 Z0 is the front-left corner of the material's top. LoftLine's matching setup is Z zero at the material top and
the XY origin at the lower left (LoftLine's +Y is away from the operator, so lower left is front left).

## Decisions

1. **Posts.** `othermill-inch` and `othermill-mm`:
   - extension `gcode` (vendor-CAM; the software also loads `.nc` and `.tap`)
   - parentheses comments, no line numbers, 4/1 decimals (inch), 3/0 (mm)
   - preamble `G90`, `G94`, `G17`, `G55` (units first, as LoftLine always writes them); no `G40`, `G49`, `G80`, `G91.1`
   - tool change `M5`, `(MSG, Change to Tool: {TOOL_NAME})`, `M6 T{T}`; no tool length offset
   - spindle `M3 S{S}`, dwell 4 s; footer the standard `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M30`
   - `helicalArcs: false` (helices linearised: the newer vendor post disallows them, and a line segment is safe on both
     firmwares); incremental I/J arcs, at most 180° each (LoftLine's `ArcFitter.maximumSweep`, the Othermill post's limit)
   - limits and rates are the Othermill Pro machine's (Decision 5)
2. **Setup the post requires.** Posting with an Othermill post refuses, with the reason, when the job's Z zero is not the
   material top, when its XY origin is not the lower left, or when any toolpath turns coolant on (`M7`–`M9` are not
   supported). The refusal is thrown by the post processor (`PostError.setup`), so the app, the command line and the samples
   check all stop the same way; there is no Save Anyway. Recognising an Othermill post uses the dialect rule #115 introduced
   (an unchanged built-in by value, with the fields a machine replaces put back), moved into `BuiltInPosts` so both rules
   share it. A custom post copied from an Othermill post loses the requirement; Help says so.
3. **No Optional Stop switch.** TinyG treats `M1` as `M0`. `PostProfile.honoursOptionalStop` is false for the Othermill posts
   too, so an optional stop writes `M0`, and the pause form and job sheet say "this controller has no Optional Stop" instead
   of naming GRBL. Text that named GRBL alone becomes controller-neutral.
4. **Several tools in one file are allowed**, because `M6` makes the software prompt and touch off (fact 3); `ToolChangeZ`
   already stays quiet for a tool change that calls `M6`. Autodesk's Othermill post refuses a second tool unless its
   "tool changer" property is set: recorded in DECISIONS as the dissent, and TESTING's check covers a two-tool file.
5. **Machines.** `othermill-pro`: 5.5 × 4.5 × 1.35 in travel (with the spoilboard: a manufacturer-derived spec table and a
   university lab page, both search text; UNVERIFIED against Bantam), spindle 8,500–26,000 rpm, rapid and max feed 100 in/min
   (Adafruit "Max XYZ traverse speed"), spoilboard allowance 0.01 in. `othermill`: 5.5 × 4.5 × 1.25 in, 7,000–16,500 rpm,
   60 in/min (original Getting Started PDF). Both list `othermill-inch` and `othermill-mm`.
6. **Samples check.** A sample posts with every built-in post whose machine travel holds its material; the check prints each
   skipped pair and fails when a post is paired with no sample at all. A new small sample, `samples/nameplate.loftline`
   (4 × 3 × 0.25 in, lower-left origin, material-top zero, a profile and a V-carve, no coolant, safe and home Z low enough
   for 1.35 in of travel), gives the Othermill posts something to post, and every other post posts it too.
7. **Probing.** The Othermill posts declare no controller, so park-and-probe refuses them (the touch-off is the software's).

## Tests

- Golden: each Othermill post writes `G55`, no `G40`/`G49`/`G91.1`/`G43`/`G53`/`G28`/`M7`–`M9`/`M4`, `M6 T{n}` after `M5`,
  `G4 P4`, `M30`, and no helical `G2`/`G3` (Z changes only on `G0`/`G1`).
- Refusal: spoilboard Z zero, a centre XY origin and coolant each refuse, in inch and mm, with the post as built and after a
  machine is applied; an edited copy does not refuse.
- Optional stop on an Othermill post writes `M0`.
- Machines: both list both posts; a job taller than 1.35 in of Z span is refused by the existing travel check.
- Samples: `samples/expected/othermill-inch/` and `othermill-mm/` hold `nameplate.gcode` only; the existing folders gain
  `nameplate.*` and are otherwise byte-identical.

## Docs

DECISIONS (`othermill-post`), Help (Machines topic: what the operator enters in the Bantam software: Material Size X/Y/Z equal
to Job Setup's, origin at the front-left top), TESTING (an Othermill air cut, including a two-tool file, the material-size
entry and the preview's collision warnings), PARITY `io-post-processors`, README's post list.

## What only an owner can confirm (stated in TESTING, the post assumes the answer in brackets)

Z zero for imported G-code [material top, per the Fusion workflow]; `M6 T{T}` order [vendor docs' order]; how `M0` resumes
[the software's Resume]; the Pro's real travel [1.35 in Z]; helical arcs [not used].
