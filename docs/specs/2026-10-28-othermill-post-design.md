# Othermill Pro posts (issue #114)

Revision 4, 2026-10-28 (final: rulings on round 3, the last review round). Approved for work by Sean ("go", 2026-10-28) as the next item after #115.
Revision 2 answers the first review (executor, auditor, skeptic, simplifier): the setup rules are export errors, not a
thrown refusal; the datum offset is checked; recognition is by id; the sample-check change is dropped; the evidence table
now says what the vendor posts actually write. Revision 3 answers round 2 (auditor, skeptic): the material must fit the
bed, the Z envelope counts the stock, the machine warning covers speed and feed, and one home for the ids and limits.
Revision 4 rules on round 3 (auditor, skeptic): the XY and Z checks measure every commanded move (approach, lift-overs and
the move home included); the golden validator loop checks the Othermill rows on a machine big enough for its fixture.

## Goal

Built-in posts and machines for the Othermill Pro and the original Othermill, which run G-code through the Bantam Tools
Milling Machine Software (formerly Otherplan) on a Synthetos TinyG board. A file LoftLine writes must load in that software
with no skipped lines, sit on the stock where the operator expects, and ask the machine for no code it cannot run.

Not in scope: the Bantam Tools Desktop PCB/CNC machines as named machines (same software, specs not collected); `R`-format
arcs (#99 item 8); the dwell-unit work in #99 item 1 (the Othermill's `G4 P` is seconds).

## Sources

**vendor**: Bantam or Other Machine Co. documentation, read through search-result text (support.bantamtools.com refuses
automated fetches with HTTP 403). **issue**: the research in #114 (Bantam G-code Reference, Troubleshooting, File Support;
TinyG wiki). **vendor-CAM**: Autodesk's `othermill.cps` ("Othermill (Otherplan)") and `bantam tools.cps`, revision 44229 of
2026-06-12, from cam.autodesk.com, read here as reference only (nothing copied). **retailer**: Adafruit.

## The nine safety facts (#98)

| # | Fact | Answer | Evidence |
|---|---|---|---|
| 1 | `G4` unit | seconds | issue ("G4 Dwell P: Pause for P seconds"); vendor-CAM (`G4 P` in seconds, 4 s after spindle start) |
| 2 | arc centres | incremental I/J; `G90.1`/`G91.1` on no supported list. `othermill.cps` writes I/J with arcs up to 180° and allows helices; `bantam tools.cps` writes `R` with arcs up to 120° (90° in its R mode) and disallows helices. LoftLine follows `othermill.cps`: an I/J arc up to 180° is unambiguous, and the tighter limit belongs to R-format, where a half circle has two centres | issue; vendor-CAM |
| 3 | `M6` / `T` | `T{T} M6` on one block. The software pauses, prompts for the swap and touches the tool off; the firmware's `M6` is a no-op. **Weakest fact:** both vendor posts leave M6 off by default (`othermill.cps` then writes only `T1` and refuses a second tool; `bantam tools.cps` writes only `T1`); with it on, both write `T{n} M6`. The prompt-and-touch-off behaviour rests on Bantam's Troubleshooting text ("The G-code required to initiate a tool change is: M6 T1") | issue; vendor-CAM |
| 4 | `G43` / `G49` | not recognised ("G40-G51 … TinyG does not recognize those commands"); the touch-off sets the length | issue |
| 5 | program end | `M30` | issue; vendor-CAM |
| 6 | spindle | `M3 S{S}`, clockwise only; Pro 8,500–26,000 rpm, original 7,000–16,500 | issue; retailer; vendor (original Getting Started PDF) |
| 7 | unknown words, comments | unsupported commands may stop a file loading or skip lines with no error; `( )` comments are stripped, `(msg …)` is echoed | issue |
| 8 | work offset, home | `G55` (Bantam: "Coordinate systems other than G55 are not supported"; `othermill.cps` forces G55; `bantam tools.cps` allows G54–G59). LoftLine writes no `G28`/`G53` for these posts (no probing); the vendor posts' `G53` retract is their default safe-position method, not needed here | issue; vendor-CAM |
| 9 | feed mode | `G94`, `F` modal | issue; vendor-CAM |

Also: `M1` equals `M0` ("Optional program stop switch is not implemented so M1 is equivalent to M0", TinyG, issue). Coolant:
Bantam's G-code Reference lists `M7`–`M9` among the commands the milling machine does not support, since it has no coolant;
both vendor posts write them anyway when a tool asks.

**Z zero and origin.** Bantam's Fusion 360 workflow sets the work origin at "the top, front, left box point on your stock",
and the software aligns files "to the front, top left corner of the stock" by default (vendor, search text). So file X0 Y0
Z0 is the front-left corner of the material's top: in LoftLine, Z zero at the material top, XY origin lower left (+Y is away
from the operator) and no datum offset.

## Decisions

1. **Posts.** `othermill-inch` and `othermill-mm`:
   - extension `gcode`; parentheses comments; no line numbers; decimals 4/1 (inch), 3/0 (mm); `arcTolerance` 0.0005 in /
     0.01 mm
   - preamble `G90`, `G94`, `G17`, `G55` (after the units code LoftLine always writes); no `G40`, `G49`, `G80`, `G91.1`
   - tool change `M5`, `(Change to Tool: {TOOL_NAME})`, `T{T} M6`; no tool length offset
   - spindle `M3 S{S}`, dwell 4 s; footer `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M30`
   - `helicalArcs: false`; incremental I/J. Every arc LoftLine writes comes from `ArcFitter` (`ToolpathBuilder`; tiling
     copies those arcs), whose `maximumSweep` is 180°, the `othermill.cps` limit
   - limits and rates (the Pro's; a machine replaces them): inch 5.5 × 4.5 × 1.35 in, spoilboard 0.01 in, rapid and max feed
     100 in/min; mm 139.7 × 114.3 × 34.29 mm, spoilboard 0.254 mm, 2540 mm/min; RPM 7,000–26,000 (spans both machines,
     each of which sets its own)
2. **Setup checks at export (`OthermillSetup.issues(job:units:moves:toolpaths:profile:)`, in PostCore beside `ToolChangeZ`,
   where `PostProfile.honoursOptionalStop` can read its id list; `moves` are the exporter's `checked` toolpaths, which include
   the raised approach, the lift-overs and the move home).** Beside `ToolChangeZ.warning` in
   `GCodeExporter.export` (the one path the app, the command line, batch, tiled export and the validation report all use),
   for a post whose id is in `OthermillSetup.postIDs` (the one list of the two ids; `honoursOptionalStop` reads it too). The
   Othermill's own numbers come from `BuiltInPosts.profile(id:)` of that id, converted to the document's units, so no
   limit is written twice. Tolerances: lengths 0.0005 in / 0.01 mm (`LayoutChecks.materialFits`'s), feeds the same per
   minute, RPM exact.
   - **error** when the job's Z zero is not the material top, when its XY origin is not the lower left, or when its datum
     offset is non-zero (`(datumOffset ?? .zero) != .zero`, so a tiled export, which sets it to nil, passes), each saying what
     the Bantam software assumes and to set Job Setup to match;
   - **error** when any commanded move, the move home included, goes beyond the effective X or Y travel measured from the
     stock's front-left corner (X0 Y0); the span-only travel check misses a short path far from the origin and a Home X past
     the bed. Moves at negative X/Y (an outside profile, by the tool radius) are the operator's to place on the bed, and the
     Bantam preview shows them; the owner list asks about it. An oversize job also gets the existing "material does not fit"
     warning in Check Toolpaths; no second material message is added;
   - **error**, one issue naming every toolpath with coolant on ("the Othermill has no coolant; its G-code reference lists
     M7–M9 as unsupported");
   - **warning** when the stock plus the highest Z any commanded move reaches (material-top zero, so that Z is the height
     above the stock) does not fit the Z travel: `thickness + maxZ > zTravel` with the effective limits ("lower Home Z and
     Safe Z in Job Setup, and check clamp heights"); the travel check measures only the program's own span, which leaves out
     the stock below Z0, and Safe Z and Home Z are not always the highest (a tall clamp raises the approach);
   - **warning** when the effective numbers exceed the built-in post's in any travel axis, the max feed or the rapid rate,
     or the spindle range reaches outside 7,000–26,000 rpm: "the travel, feed and speed checks used limits larger than the
     Othermill's (X 24 in …); choose the Othermill machine in Job Setup". It names the numbers, not a machine (the project's
     machine copy is not always the one applied), so it also covers a user file that reuses the id with bigger limits.
   Job-level issues repeat once per operation in Check Toolpaths, as `modelsDeeperThanStock` already does; accepted.
   Errors leave Save Anyway, as every validator error does: the Z-zero convention is the vendor's documented default but is
   not confirmed for imported G-code, and an owner who set the software's offsets differently must be able to post. Nothing
   in `PostCore`'s post processor changes, so the post editor's sample job (which turns Mist on) and the golden loops that
   post every built-in in both Z-zero modes are untouched as to refusals. Their travel is not: `goldenProgramsPassTheValidator`
   validates `PostFixtures.postJob` (a 12 × 8 in job) against each post's own limits, which the Othermill's 5.5 × 4.5 in bed
   fails (X span 6.0, Y span 5.0). Ruling: that loop validates the Othermill rows against `BuiltInMachines.avidPRO6096.applied(to:)`,
   as the post editor's sample already widens limits (`PostSampleJob.widened`); the output bytes are the same, and a separate
   fixture that fits 5.5 × 4.5 × 1.35 in checks the Othermill's own limits. The shared fixture stays, since shrinking it would
   move every post's golden bytes. A two-sided job exports one side at a time, so the bottom side's
   own Z zero is what is checked.
3. **Recognised by id.** The checks and Decision 4 key on the id, which a project's copy of the post keeps (`postSnapshot`),
   so a later change to the built-in's text cannot switch them off for saved projects. A user file that reuses the id gets the
   checks too (they are overridable errors and an `M0`, both conservative). A duplicate under a new id loses them; Help says
   so. A LoftLine older than this change has no checks for these posts at all; DECISIONS records it (no schema bump: the
   G-code itself is the same either way except Decision 4's stop code, which on TinyG behaves the same).
4. **Optional stop.** TinyG has no Optional Stop and treats M1 as M0, so an optional stop writes `M0`: the owner check covers
   one stop code, and the header, job sheet and pause form say the stop always happens instead of calling it optional. This
   is a labelling and one-code decision, not a safety fix (unlike #115). `PostProfile.honoursOptionalStop` is false for the
   Othermill ids, by id (an edited post that keeps the id still writes M0, unlike an edited GRBL post, which is judged by
   value; DECISIONS names the asymmetry). The GRBL-only wording from #115 becomes one neutral phrase in the four places that
   name GRBL (`Toolpaths2DForms` label and help, `JobSheet`, `HelpTopics`) and their doc comments: "this controller has no
   Optional Stop, so this post writes M0: the machine always stops here" (no "ignores M1", which is false for TinyG). The
   one test that asserts the old text (`PauseStepTests`) changes with it. The program header keeps "the machine waits for
   Cycle Start" for every post (Bantam's button is Resume; changing it moves every post's golden bytes for a synonym).
5. **Several tools in one file are allowed** (fact 3: `M6` prompts and touches off), against `othermill.cps`'s default, which
   refuses a second tool. DECISIONS records the dissent; TESTING's owner check covers a two-tool file first. `ToolChangeZ`
   stays quiet for a tool change that calls `M6`.
6. **Machines.** `othermill-pro` first (inference takes the first machine listing a post): 5.5 × 4.5 × 1.35 in (with the
   spoilboard; a manufacturer-derived spec table and a university lab page, both search text, UNVERIFIED against Bantam),
   8,500–26,000 rpm, rapid and max feed 100 in/min (Adafruit), spoilboard 0.01 in. `othermill`: 5.5 × 4.5 × 1.25 in,
   7,000–16,500 rpm, 60 in/min (original Getting Started PDF), spoilboard 0.01 in. Both list both posts.
7. **Samples.** No change to `check-samples.sh` or the sample set. The command line posts each sample with its own machine
   (the Avid), and both samples are lower-left, material-top and coolant-free, so `--update` adds `othermill-inch/` and
   `othermill-mm/` holding `sign.gcode` and `faced-board.gcode`; the existing folders stay byte-identical. These are
   regression bytes, not runnable Othermill files (24 × 12 in material checked against the Avid); DECISIONS says so. The CLI
   prints the machine warning for these pairs on stderr (and the Z-envelope warning when it applies); `LoftLineCLITests`'
   samples test accepts exactly the `OthermillSetup` warning prefixes (constants on `OthermillSetup`), and only for the two
   Othermill ids, so a stray message on another post still fails. No Othermill error fires for them: both samples are
   lower-left, material-top, offset-free and coolant-free, and their material fits the Avid's travel. The command line
   writes nothing and exits 1 on any error without `--force`, so an error here would fail the check, as intended.
8. **Probing.** No controller is declared, so park-and-probe refuses these posts (the software does the touch-off).

## Tests

- Golden (`NewPost` rows plus one loop): `G55`, the units code, `T{n} M6` after `M5`, `G4 P4`, `M30`; none of `G40`, `G49`,
  `G91.1`, `G43`, `G53`, `G28`, `M7`, `M8`, `M9`, `M4`. A fixture with a helical arc (start Z ≠ end Z) posts as `G1` lines
  only. No `G2`/`G3` in the posted samples sweeps more than 180°.
- `goldenProgramsPassTheValidator`: the Othermill rows pass on the Avid-applied post; a fitting fixture passes the
  Othermill's own limits with no issues.
- `OthermillSetup`: spoilboard Z zero, each non-lower-left origin, a non-zero datum offset, material larger than the Pro's
  bed (X 6 on the Pro), a Home X of 6 with 5 in stock, and a coolant toolpath (one issue naming both of two toolpaths) each give
an error, inch and mm; moves reaching exactly 5.5 × 4.5 give none, in an inch document with the mm post and a mm document with
the inch post; the plain setup gives
  none; a nil datum offset and a tiled export pass; another post gives none; a machine-applied Othermill post, a project copy
  and an edited post keeping the id are still checked; the Avid machine gives the machine warning, the Pro and the original
  Othermill machines give none (equality boundary, both units), and a user machine sized like the Pro but with 30,000 rpm or
  600 in/min, a rapid of 200 in/min alone, or a minimum of 6,000 rpm alone gives it; 0.75 in stock with Home Z 0.8 gives the
Z-envelope warning, 0.25 in with 0.5 does not, 0.75 + 0.6 = 1.35 exactly does not, a 0.6 in clamp raising the approach to
0.7 in over 0.75 in stock with Safe Z 0.2 and Home Z 0.5 does (1.45 > 1.35), and the mm cases match; the bottom
  side of a two-sided job is checked with its own Z zero.
- Through `GCodeExporter.export`: the errors appear as issues and a program is still produced (Save Anyway).
- Optional stop on an Othermill post writes `M0`, as built, machine-applied and edited with the same id, inch and mm.
- An Othermill machine with park-and-probe on refuses export ("cannot probe tool changes").
- `LoftLineCLITests`' samples test: the Othermill warning prefixes are accepted for the Othermill ids only.
- Machines: both list both posts, Pro first; the original Othermill's spoilboard allowance is 0.01 in; a job whose Z span
  exceeds 1.35 in on the Pro gets the existing travel error.

## Docs

`BuiltInMachines`' doc comment ("their limits match the built-in posts") is corrected for the original Othermill. DECISIONS
(`othermill-post`, with the M6 dissent, the by-id recognition and its asymmetry with GRBL's by-value rule, the
older-LoftLine gap, the kept "Cycle Start" header, and that the Othermill sample programs are regression bytes); Help (Machines: the
built-in list; set Material Size and Home Z first in Job Setup, since the defaults (24 × 18 in, Home Z 0.8) do not fit; what
to enter in the Bantam software: Material Size X/Y/Z equal to Job Setup's, origin front-left top; that a
duplicated post loses the checks; Coolant: no coolant on the Othermill); TESTING (an Othermill owner check); PARITY
`io-post-processors`; README's post list.

## What only an owner can confirm (TESTING lists them; the post assumes the bracketed answer)

Z zero for imported G-code [material top]; whether the software places a file by its origin or by its toolpaths' bounding
box [origin; by bounding box, a profile outside the part would shift by the tool radius]; whether 1.35 in is the axis travel
or the clearance under the collet [axis travel]; that `T1 M6` prompts and touches off, including at program start with T1 loaded
[it does]; a two-tool file [works]; how a stop resumes [the software's Resume]; whether `(MSG, …)` pause text shows
[echoed, perhaps with the comma]; long header comments with `:`, `[`, `]` [load]; the Pro's real travel [1.35 in Z].
