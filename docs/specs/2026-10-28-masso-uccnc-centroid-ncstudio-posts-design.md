# MASSO, UCCNC and Centroid posts (issues #107, #108, #103)

Revision 2, 2026-10-28. Part of the dialect roadmap (#98), approved by Sean ("go"; "keep moving through post processors";
"continue until they are all done"); owner checks deferred. Revision 2 answers the first review (executor, auditor, skeptic,
simplifier): NcStudio (#109) and the apostrophe comment style move to their own later change; the Stepcraft machine is cut;
Centroid and UCCNC arcs are written as lines; the dwell rule reads the built-in's own template; the optional-stop list is
inverted so a new built-in defaults to `M0`; MASSO joins the tool-change-Z warning; every number is stated.

## Goal

Built-in posts for three more controllers, two of which read `G4 P` in milliseconds, each writing only codes its manual
documents. Where the manual documents a default, the post follows it; where a setting is the owner's and undocumented, the
post takes the reading that fails safe (a long wait, a refused program or a warning, never an early plunge or an unseen move).
Nothing has run on these machines; TESTING gets an owner check for each, marked "before the first cut" where a setting decides
safety.

## Decisions

1. **MASSO G3 (#107): `masso-g3-inch` "MASSO G3 (inch)", `masso-g3-mm` "MASSO G3 (mm)".** Source: docs.masso.com.au.
   - extension `nc`; parentheses comments; decimals 4/1 and 3/1 (the vendor post's feed has one decimal); incremental I/J
     ("I/J/K are always incremental on MASSO"), no `G91.1`; arc tolerance 0.0005 in / 0.01 mm.
   - preamble one word per line: `G90`, `G17`, `G40`, `G80`, `G94` (MASSO ignores a whole line holding an invalid word); no
     `G49` (MASSO has no `G43`/`G49`).
   - tool change `M5`, `(Change to Tool: {TOOL_NAME})`, `T{T} M6` (MASSO: "Always stop the spindle with M05 before M06, and
     always put the T value before M06"). Nothing cited says MASSO's `M6` applies the new tool's length, so the MASSO ids are
     in `toolChangeKeepsZIDs`: a second tool warns (one file per tool). MASSO's `M6` routine is relied on to lift before the
     change; the owner check confirms it.
   - spindle `S{S} M3`; footer `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M30`.
   - dwell `G4 P{MILLISECONDS}`, 3 s (MASSO: "Dwell time in milliseconds"; its Vectric post disagrees, and milliseconds fail
     safe: read as seconds it is a long wait).
   - tool numbers: MASSO gives T0 to the dry-run laser and T1–T100 to the main spindle (higher numbers select other heads), so
     a posted tool numbered outside 1–100 is an export error (`DialectChecks`), counting only toolpaths that post.
   - limits (a controller on many machines; a machine replaces them): 48 × 48 × 6 in, spoilboard 0.05 in, rapid and max feed
     200 in/min; mm 1219.2 × 1219.2 × 152.4 mm, spoilboard 1.27 mm, 5,080 mm/min; 0–24,000 rpm. No built-in machine.
2. **UCCNC (#108): `uccnc-inch` "UCCNC (inch)", `uccnc-mm` "UCCNC (mm)".** Source: UCCNC manual v1.0047.
   - extension `nc`; parentheses comments; decimals 4/1, 3/0.
   - preamble `G90`, `G17`, `G40`, `G49`, `G80`, `G94`.
   - arcs **linearised** (`arcOutput: .linearize`, 0.0005 in / 0.01 mm): the manual does not say whether I/J are incremental,
     and a wrong reading cuts a large arc at feed.
   - tool change `M5`, `(Change to Tool: {TOOL_NAME})`, `M0`: UCCNC can be set to "Ignore tool change code (M6)", which would
     run on with the wrong bit; `M0` always stops, and `ToolChangeZ` warns on a second tool.
   - dwell `G4 P{MILLISECONDS}`, 3 s (milliseconds by default; the other reading is a long wait).
   - units: UCCNC takes units from its profile and may ignore `G20`/`G21`; an mm program on an inch profile moves 25.4 times too
     far. Every UCCNC export carries a warning naming the units the profile must be in (`DialectChecks`), Help says so, and
     the owner check is "before the first cut". No UCCNC machine is built in (a machine would pick a post by the document's
     units, not the profile's).
   - footer the standard one with `M30`; optional stop `M0`; limits and numbers as MASSO's; no built-in machine.
3. **Centroid Acorn / CNC12 (#103): `centroid-inch` "Centroid CNC12 (inch)", `centroid-mm` "Centroid CNC12 (mm)".** Source:
   CNC12 router operator manual v5.42+.
   - extension `nc`; semicolon comments with parentheses bracketed (parentheses are not documented as comments); decimals 4/1,
     3/0.
   - preamble `G90`, `G17`, `G40`, `G49`, `G80`, `G94`; one M word per line, as every built-in template keeps.
   - arcs **linearised** (0.0005 in / 0.01 mm): Parameter 2 bit 0 ("Arc centers I, J, K are absolute in G90 mode?") has an
     unknown shipped value.
   - tool change `M5`, `; Change to Tool: {TOOL_NAME}`, `T{T} M6`; without `G43 H` the new length is not applied, so the
     Centroid ids are in `toolChangeKeepsZIDs` (one file per tool, or a copy with Tool Length Offset on).
   - dwell `G4 P{SECONDS}`, 3 s: seconds is the documented default; milliseconds (`P3000`) would be outside CNC12's 0.01–327.67 s
     range and refused on every default machine. A machine with Parameter 2 bit 2 set reads `P3` as 3 ms: the owner check
     "before the first cut" reads bit 2, and Help says so. This is the one place the post follows a documented default
     against the fail-safe reading; DECISIONS records it.
   - spindle `S{S} M3`; footer the standard one with `M30`; optional stop `M0`; the operator message stays a `;` comment (a
     `:` line is not a comment to LoftLine's parser, which would read the message as G-code words).
   - limits and numbers as MASSO's; no built-in machine (a retrofit controller).
4. **The id sets.** In `BuiltInPosts`:
   - `optionalStopIDs`: the posts known to honour `M1` with a switch (the Avid and LinuxCNC posts). Any other built-in id writes
     `M0` for an optional stop (`honoursOptionalStop`), so a future built-in defaults to the safe reading; GRBL stays judged by
     value or a declared controller (#115), and user ids behave as today. `secondsNoOptionalStopIDs` goes.
   - the dwell unit of a built-in id is its own template's: `dwellProblem` refuses a post whose id is a built-in's and whose
     dwell template's unit (`{MILLISECONDS}` or not) differs from the built-in's, in either direction; the declared-GRBL rule
     stays. `grblIDs` goes.
   - `toolChangeKeepsZIDs`: MASSO and Centroid; `ToolChangeZ.setsZ` does not count their `M6`.
   - `noCoolantReasons: [String: String]`: the Othermill and Carbide Motion ids with their reasons (replacing `noCoolantIDs`);
     `DialectChecks` and `PostSampleJob` read it.
5. **DialectChecks** keeps the coolant rule and adds, independently of it: MASSO tool numbers outside 1–100 (an error naming
   the tools) and the UCCNC units warning ("UCCNC takes units from its profile: set the profile to <units> before running
   this program"). The samples test accepts that warning's prefix for the UCCNC ids.

## Tests

- Golden rows (`newPosts`, `newPostNumbers`) for the six posts with every number above; a forbidden-codes loop in both Z-zero
  modes on a job holding an optional-stop pause, a dwell, an arc and a tool name with `(` (MASSO: no `G91.1`, `G49`, `G43`, no
  preamble line with two words; UCCNC: no `G91.1`, `M6`, `G2`, `G3`; Centroid: no `G91.1`, `G2`, `G3`, no `(`, no line with two
  M words); `G4 P3000` (MASSO, UCCNC), `G4 P3` (Centroid).
- Dwell rule: edited copies keeping their ids of MASSO with `{SECONDS}`, Centroid with `{MILLISECONDS}`, and the Avid with
  `{MILLISECONDS}` are refused; every built-in passes.
- Optional stop: `M0` on every built-in not in `optionalStopIDs`, as built and edited with the same id; `M1` on the Avid.
- `ToolChangeZ`: a two-tool program warns on MASSO, UCCNC and Centroid.
- `DialectChecks`: MASSO T0 and T101 error, T1 and T100 do not, an empty toolpath with T101 does not; UCCNC warns with its units;
  coolant reasons per controller unchanged.
- Schema: every built-in encodes its `requiredSchemaVersion` (2 for MASSO and UCCNC, 1 for the rest).
- Park-and-probe refuses every built-in without a controller.
- `samples/expected` gains six folders; the existing ones stay byte-identical.

## Docs

DECISIONS (`masso-uccnc-centroid-posts`: each choice and source, Centroid's documented-default exception, the inverted
optional-stop list), Help (Machines: the posts, dwell units, UCCNC profile units, Centroid's Parameter 2 bits, MASSO tool
numbers; a duplicated post under a new id loses the id-based rules), TESTING (owner checks, "before the first cut" for the
dwell unit and UCCNC units), README and PARITY, a comment on #103, #107, #108, and on #109 that it moves to its own change.
