# MASSO, UCCNC, Centroid and NcStudio posts (issues #107, #108, #103, #109)

Revision 1, 2026-10-28. Part of the dialect roadmap (#98), approved by Sean ("go"; "keep moving through post processors";
"continue until they are all done"); owner checks deferred.

## Goal

Built-in posts for four more controllers, three of which read `G4 P` in milliseconds, each writing only codes its manual
documents and choosing, where the manual leaves a setting to the owner, the reading that fails safe (a long wait or a refused
program, never an early plunge or an unseen move). Nothing has run on these machines; TESTING gets an owner check for each.

## Decisions

1. **MASSO G3 (#107): `masso-g3-inch` "MASSO G3 (inch)", `masso-g3-mm` "MASSO G3 (mm)".** Source: docs.masso.com.au.
   - extension `nc`; parentheses comments; decimals 4/1 and 3/1 (the vendor post's feed has one decimal); incremental I/J ("I/J/K
     are always incremental on MASSO"), no `G91.1` (not in its code index).
   - preamble one word per line: `G90`, `G17`, `G40`, `G80`, `G94`. MASSO ignores a whole line that holds an invalid word, so
     no line carries two words that could each fail. No `G49` (MASSO has no `G43`/`G49`).
   - tool change `M5`, `(Change to Tool: {TOOL_NAME})`, `T{T} M6` (MASSO: "Always stop the spindle with M05 before M06, and
     always put the T value before M06"); spindle `S{S} M3`; footer `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M30`.
   - dwell `G4 P{MILLISECONDS}`, 3 s. MASSO's G04 page says "Dwell time in milliseconds"; its own Vectric post disagrees.
     Milliseconds fail safe: if MASSO read seconds, `P3000` would wait 50 minutes; seconds read as milliseconds would plunge
     after 3 ms. The owner check times it first.
   - optional stop `M0` (MASSO's `M01` "pauses the machine until Cycle Start"; no switch is documented).
   - tool numbers 0–118 on the G3: a higher number is an export error (`DialectChecks`).
   - limits: MASSO is a controller on many machines; the posts carry a 48 × 48 × 6 in envelope (1219.2 × 1219.2 × 152.4 mm),
     0–24,000 rpm, 200 in/min, the LinuxCNC posts' generic numbers, which a machine replaces. No built-in machine: the
     MASSO machines found (Onefinity Elite) have no published travel.
2. **UCCNC (#108): `uccnc-inch` "UCCNC (inch)", `uccnc-mm` "UCCNC (mm)".** Source: UCCNC manual v1.0047.
   - extension `nc`; parentheses comments; decimals 4/1, 3/0; incremental I/J, no `G91.1` (absent from the manual).
   - preamble `G90`, `G17`, `G40`, `G49`, `G80`, `G94`. Units: LoftLine writes `G20`/`G21` as always; UCCNC takes units from
     its profile, and an unknown code is either ignored ("Ignore") or stops the program ("Don't run"), so the line fails safe;
     the owner check confirms the profile's units match the post's.
   - tool change `M5`, `(Change to Tool: {TOOL_NAME})`, `M0`. Not `T M6`: UCCNC can be set to "Ignore tool change code (M6)",
     which would run on with the wrong bit; `M0` always stops, and the `ToolChangeZ` warning says one file per tool.
   - dwell `G4 P{MILLISECONDS}`, 3 s: milliseconds by default ("Measure dwell in seconds instead of msec" flips it), and the
     wrong reading of milliseconds is a long wait.
   - footer the standard one with `M30`; optional stop `M0` (UCCNC's `M1` switch is undocumented).
   - limits generic as for MASSO; machine: `stepcraft-d840` "Stepcraft D.840 (UCCNC)": 594 × 833 × 132 mm, max feed 3,000
     mm/min (Stepcraft), RPM unset, listing both UCCNC posts.
3. **Centroid Acorn / CNC12 (#103): `centroid-inch` "Centroid CNC12 (inch)", `centroid-mm` "Centroid CNC12 (mm)".** Source:
   CNC12 router operator manual v5.42+.
   - extension `nc`; **semicolon** comments (parentheses are not documented as comments; brackets in comment text, as for
     Carbide Motion); decimals 4/1, 3/0; incremental I/J ("I, J, and K are the incremental distances"), no `G91.1`.
   - preamble `G90`, `G17`, `G40`, `G49`, `G80`, `G94`; one M word per line ("Only one M-function per line is permitted"),
     which every built-in template already keeps.
   - tool change `M5`, `; Change to Tool: {TOOL_NAME}`, `T{T} M6` ("M6 moves the Z-axis to the home position … it prompts the
     Operator to insert the tool"). Without `G43 H` the new tool's length is not applied, so a second tool resumes at the old
     Z: the Centroid ids count as a tool change that does not set Z (`ToolChangeZ`), and the warning says one file per tool,
     or a copy of the post with Tool Length Offset on and the Offset Library set up.
   - dwell `G4 P{SECONDS}`, 3 s: seconds by default (Parameter 2 bit 2 flips it; the owner check reads it).
   - spindle `S{S} M3`; footer the standard one with `M30`; optional stop `M0`.
   - the operator message stays a `;` comment, not a `:` line: LoftLine's parser does not treat `:` as a comment, so a message
     there would be read as G-code words by the validator.
   - limits generic; no built-in machine (Centroid is a retrofit controller).
4. **NcStudio (Weihong) (#109): `ncstudio-mm` "NcStudio (mm)" only** (inch feed is not understood). Source: NcStudio
   Programming Manual R6.1.
   - extension `nc`; **apostrophe comments** (Decision 5); decimals 3/0.
   - preamble `G90`, `G17` (`G94` is not in the manual and a user reports it errored; `G40`/`G49`/`G80` are not documented).
   - arcs **linearised** (`arcOutput: .linearize`, tolerance 0.01 mm): I/J are start-relative only when the controller
     parameter "Arc Increment" is Yes, which a program cannot set, so no arc is written.
   - tool change `M5`, `' Change to Tool: {TOOL_NAME}`, `M0` (the editions disagree about `M06`; `M0` always stops; the
     `ToolChangeZ` warning applies). No tool length offset (H00–H07 only).
   - dwell `G4 P{MILLISECONDS}` ("P_: the dwell time, with unit ms"; no decimal point; the integer placeholder has none).
   - spindle `M3 S{S}`, 6,000–24,000 rpm; footer the standard one with `M30`; optional stop `M0`.
   - coolant: undocumented, so coolant is an export error (`noCoolantIDs`).
   - limits: 1300 × 2500 × 200 mm (the 1325 class), rapid and max feed 20,000 mm/min; no built-in machine (none confirmed to
     run NcStudio).
5. **Apostrophe comments.** `PostProfile.CommentStyle.apostrophe`: a comment is `' text`, parentheses bracketed; the default
   pause is `M5`, `' {MESSAGE}`, `{STOP}`. `GCodeParser` ends a line at `'` outside parentheses, as it does at `;` (no other
   dialect uses `'` in a word, so this only adds comments). The post editor treats `'` like `;` for "text only inside a
   comment" and offers the style. A post with this style is written with schema version 2 (`requiredSchemaVersion`), since
   an older LoftLine cannot read the style.
6. **The id sets, by meaning.** Revision of `BuiltInPosts.secondsNoOptionalStopIDs` into:
   - `noOptionalStopIDs`: Othermill, BB, Carbide Motion, MASSO, UCCNC, Centroid, NcStudio (an optional stop writes `M0`);
   - `secondsDwellIDs`: Othermill, BB, Carbide Motion, Centroid, and the GRBL ids (no `{MILLISECONDS}`);
   - `millisecondsDwellIDs`: MASSO, UCCNC, NcStudio (the dwell template must use `{MILLISECONDS}`: a `G4 P{SECONDS}` there
     would be a 3 ms spin-up); `dwellProblem` refuses either mismatch, by id;
   - `toolChangeKeepsZIDs`: Centroid (its `M6` does not count as setting Z in `ToolChangeZ`);
   - `noCoolantIDs`: Othermill, Carbide Motion, NcStudio.
   `honoursOptionalStop`, `dwellProblem`, `ToolChangeZ`, `DialectChecks` and `PostSampleJob` read them.
7. **DialectChecks** adds: on the MASSO ids, a tool number above 118 is an error naming the tools.

## Tests

- Golden rows for the seven posts (names, numbers, preamble, tool change, footer, dwell line); a forbidden-codes loop in both
  Z-zero modes (MASSO: no `G91.1`, `G49`, `G43`, no line with two G words in the preamble; UCCNC: no `G91.1`, no `M6`;
  Centroid: no `G91.1`, no `(`, no line with two M words; NcStudio: no `G94`, `G2`, `G3`, no `(`).
- Dwell: `G4 P3000` on MASSO, UCCNC, NcStudio; `G4 P3` on Centroid; an edited MASSO copy with `G4 P{SECONDS}` and an edited
  Centroid copy with `{MILLISECONDS}` are each refused.
- Optional stop `M0` on all seven, as built, machine-applied and edited.
- `ToolChangeZ`: a two-tool program warns on UCCNC, Centroid and NcStudio, not on MASSO.
- `DialectChecks`: MASSO with tool 119 errors, 118 does not; coolant on NcStudio errors.
- Apostrophe: `comment("a (b)")` is `' a [b]`; `GCodeParser` reads `G1 X1 ' Z-5` as `G1 X1` only; the editor refuses
  `{TOOL_NAME}` outside an apostrophe comment and accepts it inside; a post with the style encodes schema 2.
- Machine: Stepcraft D.840 with its numbers; inference unchanged for every existing post.
- `samples/expected` gains seven folders; the existing ones stay byte-identical.

## Docs

DECISIONS (`ms-centroid-posts`: each fail-safe choice and its source), Help (Machines: the posts; the dwell unit; UCCNC's
profile units; Centroid's tool length), TESTING (owner checks: time each dwell; MASSO tool numbers and `G94`; UCCNC profile
units and M6 mode; Centroid Parameter 2 bits 0 and 2 and `M6`; NcStudio `'` comments and linearised arcs), README and PARITY,
a comment on #103, #107, #108 and #109.
