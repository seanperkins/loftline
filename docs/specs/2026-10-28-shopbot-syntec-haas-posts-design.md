# ShopBot G-code, Syntec and Haas posts, with the engine options they need

Status: draft, revision 3 (review rounds 1 and 2 answered: see "Rulings" at the end). Issues: #106 (ShopBot G-code), #110 (Syntec),
#111 (Haas / Fanuc-style); engine gaps #99 items 2, 3, 7, 9 and 12. Follows
`2026-10-28-masso-uccnc-centroid-ncstudio-posts-design.md` (merged at 5258fb6). NcStudio (#109), RichAuto (#112) and OpenSBP
(#113) are not in this batch.

## Goal

Five new built-in posts, `shopbot-gcode-inch`, `syntec-inch`, `syntec-mm`, `haas-inch`, `haas-mm`, and the three engine
options they need that a template line cannot express: a program wrapper written before everything else (`%`, an O number),
the G70/G71 units words, and a dwell in seconds that always carries a decimal point. Every existing post's output, golden file
and sample stays byte-identical.

## Sources and their weight

| Dialect | Primary source | What rests on weaker ground |
|---|---|---|
| ShopBot G-code | ShopBot User Guide SBG 00142 (2015): supported G and M lists, `G4 P` seconds, `M03` = switch 1 on, `M08` = switch 3 on, no `M07`, `G02` "I,J relative always", "If the line does not begin with an N, G, M, X, Y, Z, F, or >, the line will be commented out!", "the first G-code on the line will be the one processed" | `.tap` (the guide's example only); the effect of an `S` word (unknown, so none is written) |
| Syntec | Mill Machine Program Manual v8.20 (2015): G70/G71 units ("the only differences with FANUC 0M are G70, G71 respective to G20, G21"), `G04` "X: specific time (decimal point permitted 0.001～9999.999s)" and "P: … (decimal point not permitted)", whole-number values in "the Min unit that system default", `M06 T1`, `G43 H` / `G49`, I/J start-relative | `%`/`O` wrapper and `.nc` (Autodesk's `syntec.cps`); comments (Autodesk writes parentheses); newer firmware's G20/G21 support |
| Haas | Haas's G04 and M06 pages refuse automated fetches (403, rechecked today); their search-result text: "G04 P10. is a dwell of 10 seconds; G04 P10 is a dwell of 10 milliseconds", "M06 also stops the spindle and coolant" | Everything else from Autodesk's Haas post: `%`, `O#####`, `T M6`, `G43 H` with Z, `.nc`, no `G90.1`/`G91.1` |

Every post says in a DECISIONS entry what it assumes; each issue keeps its owner check open.

## Engine part 2

### E1. Program wrapper (`prelude`, #99 item 2)

- New field `PostProfile.prelude: [String]?`: lines written **before** the header comments, the units code and the
  preamble. nil or empty = none; `normalized` maps empty to nil (as `pause`).
- Rendered with the preamble's placeholders (`PostDraftReport.base`) and the draft report's rules for them (a text placeholder
  only inside a comment). A new `PostDraftReport.Template.prelude`, labelled "Program start".
- Written through a new unnumbered path in `GCodeWriter` (`raw`), so **no** prelude line is numbered (`%`, `O1000`, a comment),
  whatever `lineNumbers` says.
- `GCodeWriter.append` also never numbers a line that is exactly `%`, so a footer's closing `%` is not written `N.. %`. No
  built-in writes such a line today. A user post with line numbers on and a `%` footer line loses the `N` on that line: the
  intended fix, noted in DECISIONS.
- Every check that walks a post's templates includes the prelude: the plain-ASCII check, the placeholder check, and
  `dwellProblem`'s "`{SECONDS}` elsewhere" rule (E3).
- The editor shows it as "Program start" above the preamble.

### E1b. `{APPROACH_Z}`

A new placeholder in every template that takes the base ones: the machine Z of the approach height (`ProgramBuilder.approachZ`,
never below safe Z). The tool length line of the Syntec and Haas posts is `G0 G43 Z{APPROACH_Z} H{T}`, so the offset's first
move goes no lower than the reentry that follows it (a `Z{SAFE_Z}` there would rapid down to safe Z at an unknown XY, under a
clamp taller than safe Z).

The parser already skips a `%` line, and an `O1000` block parses as an O word: the validator's plain-move rule treats it as not
a plain move (it only drops the remembered hole) and nothing else fires. A test pins this.

### E2. Units words (`unitsCodes`, #99 item 7)

- New field `PostProfile.unitsCodes: UnitsCodes?`, `enum UnitsCodes: String, Codable { case g70g71 }`. nil = G20/G21. One
  case only: nothing can write an explicit default, so value equality of built-ins cannot drift.
- `unitsCode` returns `G70`/`G71` for `.g70g71`. Every writer of the units word goes through it (`ProgramBuilder.build`,
  `recoveryLine`, `ProbeSequenceChecker`).
- `GCodeValidator.validate(gcode:)` reads G70/G71 as units, and does not call them unknown, **only** when the profile says
  `.g70g71`. For every other post they stay unknown words (on Haas and Fanuc lathes G70 is a cycle): the static `knownG` is not
  widened. `no-units` names the post's own words. This adds a reading; no check is weakened (DECISIONS says so, for the
  issues' acceptance line).
- `DeepestCut.find` gains the post's units and passes them as the reader's `assumedUnits`. A Syntec program states G70/G71,
  which the reader does not apply, so it reads the program in the post's own units. Without this, a G71 program read with an
  inch job's units reports the deepest cut 25.4 times too deep. No reader parameter is added.
- `GCodeReader.read` warns once when it meets G70 or G71 ("G70/G71 set inches/millimetres on a Syntec controller; not applied
  here, units assumed …"), so the preview of a Syntec file never shows a silent 25.4x scale.

### E3. Dwell in decimal seconds (`{DECIMAL_SECONDS}`)

- New dwell placeholder `{DECIMAL_SECONDS}`: seconds with exactly three decimals, always with a dot (3 s → `3.000`, 0.25 s →
  `0.250`). Syntec writes `G4 X{DECIMAL_SECONDS}`: X is the only dwell word the manual makes independent of a machine
  setting.
- `PostDraftReport`'s dwell rule accepts `G4 X{DECIMAL_SECONDS}` beside the two P forms; the dwell template's placeholders
  gain it.
- The validator and the reader already treat a G4 line's axis words as no move (`GCodeValidator.swift:201`,
  `GCodeReader.swift:95`); a test pins that `G4 X3.000` is neither a move to X3 nor a coordinate the bounds check sees. The
  reader's dwell for `G4 X` is X seconds as written: not scaled by the units factor and not put through the P>100 guess.
- `ProbeSequenceChecker` (line 231) clears its touch-off-spot gate on any block with an X or Y away from the spot. A G4
  block's X is a time, so G4 blocks no longer touch the gate (otherwise a `G4 X3.000` after the zero would switch off
  `spot-descent`).
- `dwellProblem` compares a family's dwell **form** with its built-in's: the word letter and the placeholder (`P{SECONDS}`,
  `P{MILLISECONDS}`, `X{DECIMAL_SECONDS}`), read from the template with spaces and leading zeros ignored, either order. A Syntec
  copy with `G4 P{SECONDS}`, `G4 P{MILLISECONDS}` or `G4 P{DECIMAL_SECONDS}` is refused ("This controller reads a whole P in
  its smallest time unit: write the dwell as G4 X{DECIMAL_SECONDS}"), including a copy read from a file, which never passes
  the editor. Any post whose dwell uses `{DECIMAL_SECONDS}` after a word other than X is refused. The "`{SECONDS}` elsewhere"
  rule covers any post whose dwell is not `{SECONDS}`, and walks the prelude.
- **A dwell that prints as zero is not written** (`GCodeWriter.dwell`): below 0.0005 s for `{DECIMAL_SECONDS}` (Syntec's X
  starts at 0.001 s) and `{MILLISECONDS}`. `{SECONDS}` prints any positive value. No existing golden or sample has such a
  dwell.

### E4. Schema version 3

`currentSchemaVersion = 3`. `requiredSchemaVersion` is 3 when `prelude` is non-empty, `unitsCodes` is set, or any template
contains `{DECIMAL_SECONDS}` or `{APPROACH_Z}`; else 2 for a `{MILLISECONDS}` dwell; else 1. A version 2 LoftLine refuses the file (and a
project carrying it, `ProjectPost.swift:248`) instead of dropping the `%`, writing G21 to a Syntec, or leaving the placeholder
text in the program. All new fields are optional, so every older file still reads. `SnapshotTests`' pinned version moves
to 3.

### E5. Not changed, with reasons (also posted on #99)

- **Item 3, line numbers:** start 10, step 10, header comments unnumbered, kept. ShopBot needs them on; its N limit is
  unknown (an owner check). Prelude and `%` lines are never numbered (E1).
- **Item 9, number formatting:** the Syntec and Haas posts use `feedDecimals: 1` in both units, so every F carries a dot;
  coordinates already do.
- **Item 12, machine-coordinate moves:** not needed. Haas's M06 moves Z itself; the footers lift in work coordinates like
  every other post. G53 stays out of these posts (the preview's G53 handling is #120 item 4).

## The posts

All five: parentheses comments, `incrementalIJ` with no `G90.1`/`G91.1`, `spindleDwellSeconds: 3`, generic limits (48 x 48 x 6
in / 1219.2 mm), decimals 4 (inch) / 3 (mm), `feedDecimals: 1`. None is in `optionalStopIDs` (an optional stop writes M0),
none declares a controller (no touch-plate probing). No built-in machine is added (see Rulings).

### shopbot-gcode-inch (#106)

| field | value |
|---|---|
| fileExtension | `tap` |
| lineNumbers | true |
| preamble | `G90` (only: G17, G40, G49, G80, G94, G91.1 are not on ShopBot's list) |
| toolChange | `M5`, `(Change to Tool: {TOOL_NAME})`, `M0` (no T, no M6) |
| spindleOn | `M3` (no S) |
| dwell | `G4 P{SECONDS}` |
| helicalArcs | false (the `G02` format has no Z) |
| footer | `othermillFooter` (`G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M30`) |
| RPM | 0 to 24,000 (the router's speed is set on the router) |
| rapid / feed | 360 / 240 in/min |

- No mm post: the feed unit under G21 is unknown (#106).
- **Spindle speed:** plain `M3`. A new `BuiltInPosts.noSpindleSpeedIDs` (the ShopBot family) is the only place it is
  allowed: `PostDraftReport`'s static rule accepts `M3` alone for that family, and its sample report allows the validator's
  `spindle-no-speed` warning for that family (beside `isAllowedLift`). The validator is unchanged, so every ShopBot export
  shows that warning: it is true (the operator sets the speed on the router).
- **One G word per line:** ShopBot runs only the first. The only multi-G line the builder writes is the probe sequence's;
  `ProgramBuilder.probeForBuild` refuses probing for the family (`BuiltInPosts.oneGWordIDs`), so a copy that declares a
  controller cannot write it. A test checks every line of the ShopBot sample for at most one G word.
- **Coolant:** in `noCoolantReasons`: "ShopBot's G-code has no M7, and M8 turns on output switch 3, which may be wired to
  anything". The editor's sample then carries no coolant (`PostSampleJob`).
- A second tool gets `ToolChangeZ`'s existing warning (no T, no M6, no offset).

### syntec-inch / syntec-mm (#110)

| field | value |
|---|---|
| fileExtension | `nc` |
| prelude | `%`, `O1000` |
| unitsCodes | `.g70g71` |
| preamble | `G17`, `G40`, `G49`, `G80`, `G90`, `G94`, `G54` |
| toolChange | `M5`, `(Change to Tool: {TOOL_NAME})`, `T{T} M6` |
| useToolLengthOffset | true, `G0 G43 Z{APPROACH_Z} H{T}` |
| spindleOn | `M3 S{S}` |
| dwell | `G4 X{DECIMAL_SECONDS}` |
| footer | `othermillFooter` + `%` |
| RPM | 0 to 24,000 |
| rapid / feed | 1,500 / 1,500 in/min (38,100 mm/min) |

### haas-inch / haas-mm (#111)

| field | value |
|---|---|
| fileExtension | `nc` |
| prelude | `%`, `O01000` (five digits, as Autodesk's post) |
| preamble | `G17`, `G40`, `G49`, `G80`, `G90`, `G94`, `G54` |
| toolChange | `M5`, `(Change to Tool: {TOOL_NAME})`, `T{T} M6` |
| useToolLengthOffset | true, `G0 G43 Z{APPROACH_Z} H{T}` |
| spindleOn | `M3 S{S}` |
| dwell | `G4 P{MILLISECONDS}` (a P with no dot is milliseconds; Autodesk's Haas post writes the same) |
| footer | `othermillFooter` + `%` |
| RPM | 0 to 12,000 |
| rapid / feed | 710 / 650 in/min (18,034 / 16,510 mm/min) |

- **G43 with a Z:** whether a bare `G43 H` moves Z at once is a setting on Fanuc-style controls. `G0 G43 Z{APPROACH_Z} H{T}`
  makes the offset's first move a stated rapid to the approach height (E1b).
- **Tool 0:** `G43 H0` applies no length offset and `T0` selects no tool. Export errors for the Syntec and Haas families on a
  toolpath whose tool is numbered 0 ("renumber T0").
- **Coolant:** Air writes `M8`, which on Haas and Syntec is flood coolant; Mist writes `M7` (Haas's shower option). Help says
  so; no check.
- The O number is fixed; it is not the job's.

## Tests

- **E1:** a prelude is written first and unnumbered with line numbers on (`%`, `O1000`, a comment line); a footer `%` is
  unnumbered; the validator raises nothing on `%` and `O1000`; an empty prelude normalises to nil; a prelude `G4 P{SECONDS}`
  in a millisecond post is a `dwellProblem`; non-ASCII in a prelude is refused.
- **E2:** a `.g70g71` post writes G70/G71; its validator reads them as units (no `no-units`, no `unknown-g`; a G71 in an inch
  post is `units-mismatch`) while a G20/G21 post still calls G70 unknown; `DeepestCut` of the inch Syntec program on a mm job
  equals that of the inch Haas program for the same job; the reader warns on G70.
- **E3:** `{DECIMAL_SECONDS}` prints `3.000`, `0.250`, `3600.000`; `G4 X3.000` is not a move (validator, reader) and the reader's
  dwell is 3 s, unscaled in a mm program; a Syntec copy with `G4 P{SECONDS}`, `G4 P{MILLISECONDS}` or `G4 P{DECIMAL_SECONDS}`
  is refused, also when read with `fromJSON`; an Avid copy with `G4 X{DECIMAL_SECONDS}` is refused; a 0.0004 s dwell writes no
  line in a Syntec or Haas program; `spot-descent` still fires after a `G4 X` block at the touch-off spot.
- **E1b:** `{APPROACH_Z}` renders the approach height (above safe Z when the job's approach height is) and safe Z otherwise;
  the Haas and Syntec tool length line never rapids below the approach height (a job with a 1.5 in approach height and 0.5 in
  safe Z).
- **E4:** `requiredSchemaVersion` is 3 for each new field or placeholder; a version 3 file is refused by a reader capped at 2;
  each built-in round-trips through `toJSON`/`fromJSON` equal to itself.
- **Posts:** both Z-zero modes in inch and mm (inch only for ShopBot); the dwell line per post (3 s → `G4 P3` ShopBot,
  `G4 X3.000` Syntec, `G4 P3000` Haas); `everyBuiltInIsClean` and `unchangedDuplicatesAreClean`; the ShopBot one-G-word test;
  probing refused for a ShopBot copy with a controller; coolant refused on ShopBot; T0 refused on Syntec and Haas.
- `goldenProgramsPassTheValidator` posts every built-in at 18,000 RPM: it posts each at `min(18000, maxRPM)` and allows
  `spindle-no-speed` for the `noSpindleSpeedIDs` family, as the editor's sample does.
- `LoftLineCLITests.everySampleWithEveryBuiltInPostIsTheCommittedProgram` accepts the `spindle-no-speed` warning on stderr for
  that family only, matched on its message.
- `scripts/check-samples.sh --update` adds `samples/expected/<id>/` for the five posts only; the diff is read by eye.

## Docs

DECISIONS (`engine-prelude-units`, `shopbot-syntec-haas-posts`), PARITY `io-post-processors`, Help's post list and the Air/Mist
note, TESTING owner checks (ShopBot: `S`, N limit, `.tap`; Syntec: G70/G71 on newer firmware, comments, `M5` before `M6`;
Haas: text before `%`, arc-centre mode, G43 with Z, the P rule), README post list. Comments on #106, #110, #111 with the nine
safety facts; #99 gets E5.

## Rulings (review round 1)

- **No built-in machines** (simplifier): the Haas listings are dealer figures, Laguna's rapid conflicts with a dealer's, and a
  project with no machine takes the first that lists its post, so a Mini Mill ahead of a VF-2 would hold every Haas project to
  16 x 12 in. The posts' generic limits apply; the issues' machine line stays open for owner figures.
- **ShopBot keeps plain `M3`** against the simplifier's `M3 S{S}`: the guide documents `M03` as a switch and lists no `S`, so
  an `S` word is the unverified choice.
- **Syntec dwell `G4 X{DECIMAL_SECONDS}`** (skeptic), not `G4 P{MILLISECONDS}`: a whole P is in the machine's smallest time
  unit, which can make a 3 s spin-up 0.3 s. Haas keeps `P{MILLISECONDS}`: its rule is a dot, not a setting, and a wrong reading
  fails long.
- **Probing refusal for ShopBot kept** (simplifier called it optional): a copy with a controller would write `G90 G92.1 G54`,
  of which ShopBot runs only `G90`.
- **`{APPROACH_Z}`, not `{SAFE_Z}`, in the G43 line** (skeptic, round 2): a tool change must not rapid below the approach
  height before the reentry.
- **The preview's P>100 heuristic** (auditor) stays, as ruled in the earlier batch: a file's dialect is unknown to the preview.
