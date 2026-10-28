# Onefinity (Buildbotics) and Carbide Motion posts; GRBL-family machines (issues #104, #105, #100)

Revision 4, 2026-10-28 (final: rulings on round 3, the last review round, at the end). Part of the dialect roadmap (#98), approved by Sean ("go"; "keep moving through post processors";
"continue until they are all done"); owner checks deferred ("I am not gonna check those right now"). Revision 2 answers the
first review (executor, auditor, skeptic, simplifier): BB and Carbide Motion join one id set that fixes the optional stop
and the dwell unit; coolant on a post without it is one general check; semicolon comments bracket parentheses; machines are
appended, with published figures; every number is stated. Revision 3 answers round 2: Carbide Motion's duplicate tool
numbers become an export error; the generic GRBL machine is left untouched (the new GRBL machines list only the mm post);
every machine number is stated; the coolant message names each controller's reason.

## Goal

Built-in posts for two common woodworking routers' controllers, and built-in machines for the GRBL family, each writing only
codes its controller documents, and saying what it assumes where only an owner can confirm it. Nothing has run on these
machines; TESTING gets an owner check for each, as for the LinuxCNC and Othermill posts.

## Decisions

1. **Onefinity Original/Pro, Buildbotics controller (#104): `onefinity-bb-inch` "Onefinity Buildbotics (inch)",
   `onefinity-bb-mm` "Onefinity Buildbotics (mm)".** BB is the CAMotics planner (a LinuxCNC subset).
   - extension `ngc`; parentheses comments; decimals 4/1, 3/0; `incrementalIJ`; `arcTolerance` 0.0005 in / 0.01 mm;
     helical arcs on (CAMotics plans G2/G3 with Z).
   - preamble `G90`, `G91.1`, `G17`, `G49`, `G94` (each in the CAMotics source per #104). `G40` and `G80` are undocumented
     there, so they are left out.
   - tool change `linuxCNCToolChange` (`M5`, `(MSG, Change to Tool: {TOOL_NAME})`, `M0`), not `T M6`: users report they
     cannot jog while BB's M6 pause is up, so Z cannot be set there; with `M0` the `ToolChangeZ` warning tells the owner to
     save one file per tool.
   - dwell `G4 P{SECONDS}`, 3 s (seconds verified: staff "P1 = 1 Second Delay"; source `dwell(double seconds)`).
   - footer `m2Footer` (BB acts on `M2`; its `M30` handling is a TODO in source).
   - optional stop: the Onefinity firmware turns `M1` into an "Optional pause" that `Mach.py` resumes at once unless a flag is
     set, and the only control that sets it is hidden (`v-if="false"`, `control-view.pug`), so `M1` never stops; these posts
     write `M0` (Decision 3).
   - RPM 10,000–30,000 (the Makita RT0701C owners fit); limits the Woodworker's, converted exactly for mm: 32.125 × 32.125 ×
     5.25 in = 815.975 × 815.975 × 133.35 mm; rapid and max feed 400 in/min = 10,160 mm/min; spoilboard 0.05 in = 1.27 mm.
2. **Shapeoko through Carbide Motion (#105): `carbide-motion-inch` "Carbide Motion (inch)", `carbide-motion-mm` "Carbide
   Motion (mm)".** Carbide Motion (CM) rewrites G-code on the fly, so its supported-codes page is the dialect.
   - extension `nc`; **semicolon** comments (staff: parentheses lock up a Shapeoko 5 Pro under some senders); decimals 4/1,
     3/0; `incrementalIJ`; `arcTolerance` 0.0005 in / 0.01 mm; helical arcs on (GRBL plans them).
   - preamble `G90`, `G17`, `G40`, `G49`, `G54` (CM: "G40, G43, G49 (Accepted but ignored)", "G54-G59 (Accepted but
     ignored)"); no `G94`, `G80`, `G91.1` (not on the supported list).
   - tool change `M5`, `; Change to Tool: {TOOL_NAME}`, `T{T} M6`: CM prompts for the swap at `M6` and measures the new tool
     with a BitSetter (the 5 Pro includes one). The post assumes a BitSetter; Help says so, and the owner check asks where
     Z zero is after an `M6` without one.
   - dwell `G4 P{SECONDS}`, 3 s, assumed seconds: CM lists G4 without a unit, GRBL underneath is seconds, and Carbide staff
     wrote "P seems to be seconds". The owner check times it first.
   - footer `m2Footer`: its `G0 Z{HOME_Z}` and `G0 X{HOME_X} Y{HOME_Y}` lift and move home before `M2` ends the program
     (CM: `M30` "may return the machine to the machine origin", so it is avoided).
   - optional stop `M0` (Decision 3): CM lists `M1` as "Sleep (optional stop)" and documents nothing more about it, so whether
     it stops is unknown; `M0` always stops, which is the safe reading of a pause the operator asked for.
   - coolant: CM ignores `M7` ("accepted but ignored") and does not list `M8`, so coolant on these posts is an export error
     (Decision 4).
   - limits the Shapeoko 5 Pro 2×2's, from mm, rounded down for inch as the GRBL inch post is: 623 × 623 × 155 mm =
     24.5 × 24.5 × 6.1 in; spoilboard 1.0 mm / 0.039 in; feeds and RPM are the GRBL posts' (8000 mm/min, 314.9 in/min,
     0–30,000 rpm), kept on purpose because Carbide publishes neither; the machine leaves them unset.
   - tool numbers: CM wants a distinct number for each tool that needs a change. Today two different cutters sharing a
     number are only a pre-flight warning (`PreflightChecks`), and `ProgramBuilder` changes tools by id, so both would be
     `T1 M6`; if CM skips the prompt when `T` names the loaded tool, the second toolpath would cut with the first bit. For the
     Carbide Motion ids, two tools of different geometry sharing a number are an export **error** (Decision 4). Two library
     entries of the same geometry are the same cutter; a second `T1 M6` only prompts again, so they stay a warning. Numbers
     above 255 may fail if CM forwards `T` to GRBL: an owner check.
3. **One id set for the controllers' fixed behaviour.** `BuiltInPosts.secondsNoOptionalStopIDs`: the Othermill, BB and Carbide
   Motion ids, documented as "built-in posts whose controller reads `G4 P` in seconds and has no usable Optional Stop".
   `honoursOptionalStop` (M0 for an optional stop) and `dwellProblem` (no `{MILLISECONDS}`) read it, by id, so an edited copy
   that keeps the id keeps both rules. `OthermillSetup.postIDs` stays Othermill-only (its setup checks). The GRBL posts are
   not in it: their optional stop is judged by value or a declared controller (#115), unchanged; but `dwellProblem` also
   refuses `{MILLISECONDS}` for the two GRBL ids, so an edited GRBL copy that keeps its id cannot dwell in milliseconds.
4. **Dialect checks at export.** One `DialectChecks.issues(toolpaths:profile:)` beside `ToolChangeZ` in
   `GCodeExporter.export`, keyed by built-in id:
   - coolant where there is none (`BuiltInPosts.noCoolantIDs`: the Othermill and Carbide Motion ids): one error naming the
     toolpaths with coolant, with the controller's reason — Othermill: "its G-code reference lists M7, M8 and M9 as
     unsupported"; Carbide Motion: "Carbide Motion ignores M7 and does not support M8". The Othermill's coolant error moves out
     of `OthermillSetup` into it (with its test); `PostSampleJob` drops coolant for every id in the set.
   - for the Carbide Motion ids, one error naming each tool number shared by tools of different geometry.
   GRBL's `M7` stays out of scope as before (DECISIONS more-posts): stock GRBL rejects it, the coolant form warns, and some
   GRBL builds enable it.
5. **Semicolon comments bracket parentheses**, as parenthesis comments already do (`PostProfile.comment`), so a Carbide Motion
   program has no `(` anywhere (header names, tool names, job names). No built-in post used semicolons, so no sample moves;
   a user's semicolon post changes only inside comments. DECISIONS says so.
6. **GRBL family (#100).** grblHAL and FluidNC with #100's defaults take the GRBL posts' text unchanged, so no new posts.
   `BuiltInMachines.genericGRBL` is untouched (a changed built-in would make every saved project's copy "differ"). The new
   GRBL machines list only `generic-grbl-mm` (a mm post drives GRBL whatever the document's units), so no machine starts
   listing `generic-grbl-inch` and inference for saved and new projects is unchanged; `generic-grbl-mm` still infers
   `generic-grbl`, which comes first. Appended, in this order:
   - `genmitsu-3018-prover-v2` "Genmitsu 3018-PROVer V2": mm; 290 × 180 × 40 mm (SainSmart's V2 product page); spoilboard
     1.0 mm; rapid, feed and RPM unset (the post's 8000 mm/min and 0–30,000 rpm).
   - `longmill-mk2-30x30` "Sienci LongMill MK2 30×30": mm; 820 × 868 × 114 mm (Sienci's MK2 article and specs page); spoilboard
     1.0 mm; rapid and max feed 4,000 mm/min (Sienci's maximum cutting speed); RPM unset.
   Their notes: "Set Max RPM (Preferences > Machines) to your spindle's top speed and GRBL's $30 to the same value ($31 to its
   lowest), or every S word is scaled wrong." Maslow 4 is left out.
7. **Machines for the new posts**, appended after the GRBL machines:
   - `onefinity-woodworker` "Onefinity Woodworker (Buildbotics)": inch; 32.125 × 32.125 × 5.25 in; spoilboard 0.05 in; rapid
     and max feed 400 in/min; 10,000–30,000 rpm; lists the BB posts (#104's safety flag: an Elite runs MASSO, whose `P` is
     milliseconds, and is not this machine).
   - `shapeoko-5-pro-2x2` "Shapeoko 5 Pro 2×2 (Carbide Motion)": mm; 623 × 623 × 155 mm; spoilboard 1.0 mm; rapid, feed and
     RPM unset (the post's); lists the Carbide Motion posts.
   Posts are appended to `BuiltInPosts.all` after the Othermill posts in this order: BB inch, BB mm, Carbide Motion inch,
   Carbide Motion mm.
8. **Probing.** None of the new posts declares a controller, so park-and-probe refuses them.

## Tests

- Golden rows (`newPosts`, `newPostNumbers`) for the four posts, with the names and numbers above; a forbidden-codes loop
  (BB: no `G40`, `G80`, `M30`, `M1`; Carbide Motion: no `G94`, `G80`, `G91.1`, `M30`, `M1`, no `(` on any line) in both Z-zero
  modes, inch and mm; the dwell line `G4 P3`.
- Optional stop: BB and Carbide Motion write `M0` as built, machine-applied, and edited with the same id.
- Dwell: an edited BB or Carbide Motion post with `{MILLISECONDS}` is refused (`dwellProblem`).
- Coolant: Mist and Air on a Carbide Motion post, and coolant on an Othermill post, each give the one error with that
  controller's reason (the Othermill test moves from `OthermillSetupTests`); a BB post and a GRBL post give none; the editor
  sample has no coolant for every id in `noCoolantIDs`.
- Tool numbers: on a Carbide Motion post, two tools of different geometry numbered 1 give the error; two of the same
  geometry do not; on the Avid post neither does.
- Dwell: an edited GRBL post keeping its id with `{MILLISECONDS}` is refused.
- `ToolChangeZ`: a two-tool program warns on BB and does not on Carbide Motion.
- Semicolon comments: a tool name with `(2 flute)` is written `[2 flute]`.
- Machines: a table of the four new machines with every number above; `generic-grbl` is unchanged; inference pins
  `generic-grbl-mm` to `generic-grbl` and leaves an unmarked `generic-grbl-inch` project with no machine; `orderedPosts`' "other" list gains the four ids; park-and-probe on a new post refuses.
- `samples/expected` gains the four posts' folders (posted with the samples' own Avid machine, so the Avid's numbers); the
  existing folders stay byte-identical; the samples test's accepted warnings already cover BB's two-tool warning.

## Docs

DECISIONS (`onefinity-carbide-posts`: the assumptions with each figure's source, the id sets and why GRBL is judged apart, the
semicolon change, the grblHAL ruling, the GRBL machines' mm-only lists), doc comments (`honoursOptionalStop`, `OthermillSetup`,
`PostSampleJob`, `Toolpaths2DForms` and `JobSheet` controller lists), Help (Machines: the built-in list, "make a machine" now
for posts without one, BB's M0 tool change, the BitSetter assumption, `$30` and Max RPM; the pause text gains BB and Carbide
Motion; coolant names Carbide Motion), TESTING
(owner checks: Onefinity air cut, two-file job, `M1`; Carbide Motion: time the spin-up dwell, `M6` with and without a
BitSetter, `;` comments, a tool numbered above 255, the `M2` move back clears clamps; GRBL machines: `$30`), README and PARITY
lists, a comment on #100, #104 and #105 answering #98's nine safety facts.

## Rulings on round 3 (final; these override the text above where they differ)

1. **No Carbide Motion tool-number check.** `GCodeValidator.validate(toolpaths:)` already makes two different tools sharing a
   T number an export error for every post when their geometry differs (a warning when it is the same; `PostRobustnessTests`
   pins it). `DialectChecks` keeps only the coolant rule. The geometry test was too loose: it compared kind, diameter and
   angle only, so two cutters differing in tip diameter or cutter shape counted as one. One `Tool.hasSameGeometry(as:)`
   (CADCore) compares kind, diameter, angle, tip diameter and shape; the validator and `PreflightChecks` both use it. Tests:
   a tip-diameter or shape difference under one number is an error.
2. **Same-geometry duplicates** raise the validator's warning and nothing else; whether CM prompts again or not, the same cutter
   stays in.
3. **Owner checks added:** "`T1 M6` with T1 already loaded: does Carbide Motion prompt and run the BitSetter?" (one file per
   tool, or a second job, can start with a different bit numbered 1).
4. **The `$30` note** reads: "Duplicate this machine (Preferences > Machines), set the copy's Max RPM to your spindle's top speed
   and choose it in Job Setup; set GRBL's $30 to the same value ($31 to its lowest)." Built-in machines are read-only.
5. **Docs sweep adds** `ToolChangeZ`'s doc comment (BB stops with M0 too) and Help's note that a duplicated post under a new id
   loses the id-based rules (optional stop, dwell, coolant) of BB and Carbide Motion as of the Othermill.
