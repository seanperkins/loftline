# ShopBot G-code, Syntec and Haas posts, with the engine options they need

Status: draft, revision 1. Issues: #106 (ShopBot G-code), #110 (Syntec), #111 (Haas / Fanuc-style); engine gaps #99 items 2,
3, 7, 9 and 12. Follows `2026-10-28-masso-uccnc-centroid-ncstudio-posts-design.md` (merged at 5258fb6). NcStudio (#109),
RichAuto (#112) and OpenSBP (#113) are not in this batch.

## Goal

Five new built-in posts, `shopbot-gcode-inch`, `syntec-inch`, `syntec-mm`, `haas-inch`, `haas-mm`, and the two engine
options they need that a template line cannot express: a program wrapper written before everything else (`%`, an O number),
and the G70/G71 units words. Each existing post, golden file and sample stays byte-identical.

## Sources and their weight

| Dialect | Primary source | What rests on weaker ground |
|---|---|---|
| ShopBot G-code | ShopBot User Guide SBG 00142 (2015): supported G and M lists, `G4 P` seconds, `M03` = switch 1 on, `G02` "I,J relative always", line rule ("If the line does not begin with an N, G, M, X, Y, Z, F, or >, the line will be commented out!"), "the first G-code on the line will be the one processed" | `.tap` extension (the guide's example only); the effect of an `S` word (unknown, so none is written) |
| Syntec | Mill Machine Program Manual v8.20 (2015): G70/G71 units ("the only differences with FANUC 0M are G70, G71 respective to G20, G21"), `G04 P2500;//delay 2.5 sec`, `M06 T1`, `G43 H` / `G49`, I/J start-relative | `%`/`O` wrapper and `.nc` (Autodesk's `syntec.cps`); comments (Autodesk writes parentheses); newer firmware's G20/G21 support |
| Haas | Haas's own G04 and M06 pages refuse automated fetches (403, rechecked today); their search-result text: "G04 P10. is a dwell of 10 seconds; G04 P10 is a dwell of 10 milliseconds", "M06 also stops the spindle and coolant" | Everything else from Autodesk's Haas post: `%`, `O#####`, `T M6`, `G43 H`, `.nc`, no `G90.1`/`G91.1` |

Every post says in a DECISIONS entry what it assumes; each issue keeps its owner check open.

## Engine part 2

### E1. Program wrapper (`prelude`, #99 item 2)

- New field `PostProfile.prelude: [String]?`: lines written **before** the header comments, the units code and the
  preamble. nil or empty = none; `normalized` maps empty to nil (as `pause`).
- Rendered with the preamble's placeholders (`PostDraftReport.base`); the draft report's placeholder rules apply (text
  placeholders only inside a comment).
- Never numbered, whatever `lineNumbers` says.
- `GCodeWriter` never numbers a line that is exactly `%` (after trimming), so a footer's closing `%` is not written `N.. %`.
  Today no post writes such a line, so no output changes.
- The editor lists it as "Program start" above the preamble.

The parser already skips a `%` line, and an `O1000` block is parsed as an O word: the validator's plain-move rule treats it as
not a plain move (it only drops the remembered hole) and no other check fires. A test pins this.

### E2. Units words (`unitsCodes`, #99 item 7)

- New field `PostProfile.unitsCodes: UnitsCodes?`, `enum UnitsCodes: String, Codable { case g20g21, g70g71 }`.
  nil = `g20g21`; `normalized` maps an explicit `.g20g21` to nil, so a built-in recognised by value never drifts.
- `unitsCode` returns `G70`/`G71` for `.g70g71`. Every writer of the units word already goes through it (`ProgramBuilder.build`,
  `recoveryLine`, `ProbeSequenceChecker`).
- `GCodeValidator.validate(gcode:)` reads G70/G71 as units **only** when the profile says `.g70g71`. Elsewhere they stay
  unknown words (on Haas and Fanuc lathes G70 is a cycle): `knownG` is not widened. `no-units` names the post's own words.
- `GCodeReader.read` gains `unitsCodes: UnitsCodes = .g20g21`; `DeepestCut.find` passes the post's (a G71 program read as
  "never sets units" with the job's inches would report the deepest cut 25.4 times too shallow on the Export sheet). The
  G-code preview of an arbitrary file keeps G20/G21.
- The editor gets a "Units words" picker (G20 / G21, G70 / G71).

### E3. Schema version 3

`currentSchemaVersion = 3`. `requiredSchemaVersion` is 3 when `prelude` is non-empty or `unitsCodes == .g70g71`, else 2 for
a `{MILLISECONDS}` dwell, else 1. A LoftLine at version 2 refuses the file instead of dropping the `%` or writing G21 to a
Syntec. Both new fields are optional, so every older file still reads.

### E4. Not changed, with reasons (answers to #99)

- **Item 3, line numbers:** start 10, step 10, header comments unnumbered, kept. ShopBot needs them on and has no documented
  limit; no built-in with numbers on writes a program near N99999 in tests. `%` lines are never numbered (E1).
- **Item 9, number formatting:** the Syntec and Haas posts use `feedDecimals: 1` in both units, so every F carries a dot;
  coordinates already do. No engine change.
- **Item 12, machine-coordinate moves:** not needed. Haas's M06 moves Z itself; the footers lift in work coordinates like
  every other post. G53 moves stay out of these posts (the preview's G53 handling is #120 item 4).
- **A forced-dot seconds placeholder:** not added. Syntec's manual example and Haas's page both make a whole `P` milliseconds,
  which `{MILLISECONDS}` already writes. `G4 X` (Syntec seconds) is not used: X on a G4 line would read as a move to every
  reader here.

## The posts

All five: parentheses comments, `incrementalIJ` with no `G90.1`/`G91.1`, `spindleDwellSeconds: 3`, generic limits (48 x 48 x 6
in / 1219.2 mm), decimals 4 (inch) / 3 (mm), `feedDecimals: 1`. None is in `optionalStopIDs` (an optional stop writes M0),
none declares a controller (no touch-plate probing).

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
- **Spindle speed:** every program starts the spindle with plain `M3`, so the validator's `spindle-no-speed` warning stands
  at export (it is true: the operator sets the speed). The post editor's sample report allows that one warning for the
  ShopBot family only (`BuiltInPosts.noSpindleSpeedIDs`), beside `isAllowedLift`; the validator is unchanged.
- **One G word per line:** ShopBot runs only the first. The builder's own multi-G line is the probe sequence's; probing
  refuses for this family (`ProgramBuilder.probeForBuild`, a new `BuiltInPosts.oneGWordIDs`), so a copy that declares a
  controller cannot write it. A test checks every line of the ShopBot sample for at most one G word.
- **Coolant:** M7 is not on ShopBot's list, M8/M9 are. Export errors on mist (M7) for the family ("ShopBot's G-code list has
  no M7: use Air or turn coolant off for …"); air stays.
- A second tool gets `ToolChangeZ`'s existing warning (no T, no M6, no offset).

### syntec-inch / syntec-mm (#110)

| field | value |
|---|---|
| fileExtension | `nc` |
| prelude | `%`, `O1000` |
| unitsCodes | `.g70g71` |
| preamble | `G17`, `G40`, `G49`, `G80`, `G90`, `G94` |
| toolChange | `M5`, `(Change to Tool: {TOOL_NAME})`, `T{T} M6` |
| useToolLengthOffset | true, `G43 H{T}` |
| spindleOn | `M3 S{S}` |
| dwell | `G4 P{MILLISECONDS}` |
| footer | `othermillFooter` + `%` |
| RPM | 0 to 24,000 |
| rapid / feed | 1,500 / 1,500 in/min (38,100 mm/min) |

- **Tool 0:** `G43 H0` applies no length offset and `T0` selects no tool. Export errors for the Syntec and Haas families on a
  tool numbered 0 ("renumber T0").
- `O1000` is fixed; the program number is not the job's.

### haas-inch / haas-mm (#111)

| field | value |
|---|---|
| fileExtension | `nc` |
| prelude | `%`, `O01000` (five digits, as Autodesk's post) |
| preamble | `G17`, `G40`, `G49`, `G80`, `G90`, `G94` |
| toolChange | `M5`, `(Change to Tool: {TOOL_NAME})`, `T{T} M6` |
| useToolLengthOffset | true, `G43 H{T}` |
| spindleOn | `M3 S{S}` |
| dwell | `G4 P{MILLISECONDS}` (a P with no dot is milliseconds; Autodesk's Haas post writes the same) |
| footer | `othermillFooter` + `%` |
| RPM | 0 to 12,000 (machines narrow it) |
| rapid / feed | 710 / 650 in/min (18,034 / 16,510 mm/min) |

Ruling on the dwell: milliseconds without a dot fails long if the reading is wrong (a 3,000 s wait the operator can stop);
seconds with a forced dot fails short (3 ms, then a plunge into a bit not at speed). Milliseconds is the fail-safe choice.

### Machines (appended to `BuiltInMachines.all`)

| id | name | units | travel | posts | rapid / feed | RPM |
|---|---|---|---|---|---|---|
| `shopbot-desktop` | ShopBot Desktop (G-code mode) | inch | 25 x 20 x 5 | shopbot-gcode-inch | 360 / 240 | — |
| `laguna-smartshop-2-pro-4x8` | Laguna SmartShop II Pro 4x8 (Syntec) | inch | 49 x 97 x 13 | syntec ×2 | 1,500 / 1,500 | 5,000-24,000 |
| `haas-mini-mill` | Haas Mini Mill | inch | 16 x 12 x 10 | haas ×2 | 600 / 600 | 0-6,000 |
| `haas-vf-2` | Haas VF-2 | inch | 30 x 16 x 20 | haas ×2 | 710 / 650 | 0-8,100 |

`maxSpoilboardCut` 0.05 in. Notes carry the source and the conflict (Laguna's 1,500 against a dealer's 1,800 IPM; the
Desktop's cutting volume 24 x 18 x 3.5 in inside its movement).

## Tests

- **E1:** a prelude is written first, unnumbered with line numbers on; a footer `%` is unnumbered; the validator raises
  nothing on `%` and `O1000`; empty prelude normalises to nil; every existing golden and sample is unchanged.
- **E2:** a `.g70g71` post writes G70/G71; the validator reads them as units for that post (no `no-units`, a G71 in an inch
  post is `units-mismatch`) and still calls G70 unknown for a G20/G21 post; `DeepestCut` of an inch Syntec program on a mm job
  equals that of the same job through the inch Haas post; explicit `.g20g21` normalises to nil.
- **E3:** `requiredSchemaVersion` is 3 for each new field; a version 3 file is refused by a reader capped at 2 (as the
  existing version 2 test); a built-in round-trips through `toJSON`/`fromJSON` equal to itself.
- **Posts:** both Z-zero modes in inch and mm (inch only for ShopBot); the dwell unit golden per post (3 s → `G4 P3` ShopBot,
  `G4 P3000` Syntec and Haas); `everyBuiltInIsClean` and `unchangedDuplicatesAreClean` pass; the ShopBot one-G-word test;
  probing refused for a ShopBot copy with a controller; mist refused on ShopBot; T0 refused on Syntec and Haas.
- `scripts/check-samples.sh --update` adds `samples/expected/<id>/` for the five posts only; the diff is read by eye.

## Docs

DECISIONS (`engine-prelude-units`, `shopbot-syntec-haas-posts`), PARITY `io-post-processors`, Help's post list, TESTING owner
checks, README post list. Issue comments on #106, #110, #111 with the nine safety facts; #99 gets the answers above.
