# Onefinity (Buildbotics) and Carbide Motion posts; GRBL-family machines (issues #104, #105, #100)

Revision 2, 2026-10-28. Part of the dialect roadmap (#98), approved by Sean ("go"; "keep moving through post processors";
"continue until they are all done"); owner checks deferred ("I am not gonna check those right now"). Revision 2 answers the
first review (executor, auditor, skeptic, simplifier): BB and Carbide Motion join one id set that fixes the optional stop
and the dwell unit; coolant on a post without it is one general check; semicolon comments bracket parentheses; machines are
appended, with published figures; every number is stated.

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
   - footer `m2Footer` (CM: `M30` "may return the machine to the machine origin"; `M2` lifts and moves back).
   - optional stop `M0` (Decision 3): CM lists `M1` as "Sleep (optional stop)".
   - coolant: CM ignores `M7` ("accepted but ignored") and does not list `M8`, so coolant on these posts is an export error
     (Decision 4).
   - limits the Shapeoko 5 Pro 2×2's, from mm, rounded down for inch as the GRBL inch post is: 623 × 623 × 155 mm =
     24.5 × 24.5 × 6.1 in; spoilboard 1.0 mm / 0.039 in; feeds and RPM are the GRBL posts' (8000 mm/min, 314.9 in/min,
     0–30,000 rpm), kept on purpose because Carbide publishes neither; the machine leaves them unset.
   - tool numbers: CM wants a distinct number for each tool that needs a change; the validator already makes two different
     tools sharing a number an error (a same-geometry duplicate is the same cutter, no change, a warning). Numbers above 255
     may fail if CM forwards `T` to GRBL: an owner check.
3. **One id set for the controllers' fixed behaviour.** `BuiltInPosts.secondsNoOptionalStopIDs`: the Othermill, BB and Carbide
   Motion ids, documented as "built-in posts whose controller reads `G4 P` in seconds and has no usable Optional Stop".
   `honoursOptionalStop` (M0 for an optional stop) and `dwellProblem` (no `{MILLISECONDS}`) read it, by id, so an edited copy
   that keeps the id keeps both rules. `OthermillSetup.postIDs` stays Othermill-only (its setup checks).
4. **Coolant where there is none.** `BuiltInPosts.noCoolantIDs` (the Othermill and Carbide Motion ids) and one check,
   `UnsupportedCoolant.issue(toolpaths:profile:)` beside `ToolChangeZ` in `GCodeExporter.export`: one error naming the
   toolpaths with coolant, saying the controller has none. The Othermill's coolant error moves out of `OthermillSetup` into
   it; `PostSampleJob` drops coolant for every id in the set.
5. **Semicolon comments bracket parentheses**, as parenthesis comments already do (`PostProfile.comment`), so a Carbide Motion
   program has no `(` anywhere (header names, tool names, job names). No built-in post used semicolons, so no sample moves;
   a user's semicolon post changes only inside comments. DECISIONS says so.
6. **GRBL family (#100).** grblHAL and FluidNC with #100's defaults take the GRBL posts' text unchanged, so no new posts.
   `BuiltInMachines.genericGRBL` now lists `generic-grbl-inch` too, so a project on either GRBL post infers the generic
   machine as before (for the mm post) or instead of none (for the inch post, whose own envelope is the same machine's
   rounded down). New machines are appended after the existing ones: `genmitsu-3018-prover-v2` "Genmitsu 3018-PROVer V2"
   (290 × 180 × 40 mm, SainSmart's V2 figures; RPM left unset), `longmill-mk2-30x30` "Sienci LongMill MK2 30×30"
   (820 × 868 × 114 mm, Sienci; max feed 4,000 mm/min; 15,000–25,000 rpm), both listing both GRBL posts, with notes that
   GRBL's `$30` must equal the machine's max RPM (`$31` its min) or every `S` word clamps. Maslow 4 is left out.
7. **Machines for the new posts**, appended: `onefinity-woodworker` "Onefinity Woodworker (Buildbotics)" (BB posts; #104's
   safety flag: an Elite runs MASSO, whose `P` is milliseconds, and is not this machine) and `shapeoko-5-pro-2x2` "Shapeoko 5
   Pro 2×2 (Carbide Motion)" (Carbide Motion posts).
8. **Probing.** None of the new posts declares a controller, so park-and-probe refuses them.

## Tests

- Golden rows (`newPosts`, `newPostNumbers`) for the four posts, with the names and numbers above; a forbidden-codes loop
  (BB: no `G40`, `G80`, `M30`, `M1`; Carbide Motion: no `G94`, `G80`, `G91.1`, `M30`, `M1`, no `(` on any line) in both Z-zero
  modes, inch and mm; the dwell line `G4 P3`.
- Optional stop: BB and Carbide Motion write `M0` as built, machine-applied, and edited with the same id.
- Dwell: an edited BB or Carbide Motion post with `{MILLISECONDS}` is refused (`dwellProblem`).
- Coolant: Mist and Air on a Carbide Motion post, and coolant on an Othermill post, each give the one error; a BB post and a
  GRBL post give none; the editor sample for a Carbide Motion post has no coolant.
- `ToolChangeZ`: a two-tool program warns on BB and does not on Carbide Motion.
- Semicolon comments: a tool name with `(2 flute)` is written `[2 flute]`.
- Machines: a table of the six new or changed machines with their numbers; inference pins `generic-grbl-mm` and
  `generic-grbl-inch` to `generic-grbl`; `orderedPosts`' "other" list gains the four ids; park-and-probe on a new post refuses.
- `samples/expected` gains the four posts' folders; the existing folders stay byte-identical.

## Docs

DECISIONS (`onefinity-carbide-posts`: the assumptions, the id sets, the semicolon change, the grblHAL ruling), Help (Machines:
the built-in list, the BitSetter assumption, `$30`; the pause text's controller list gains BB and Carbide Motion), TESTING
(owner checks: Onefinity air cut, two-file job, `M1`; Carbide Motion: time the spin-up dwell, `M6` with and without a
BitSetter, `;` comments, a tool numbered above 255, the `M2` move back clears clamps; GRBL machines: `$30`), README and PARITY
lists, a comment on #100, #104 and #105 answering #98's nine safety facts.
