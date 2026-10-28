# Onefinity (Buildbotics) and Carbide Motion posts; GRBL-family machines (issues #104, #105, #100)

Revision 1, 2026-10-28. Part of the dialect roadmap (#98), approved by Sean ("go", then "keep moving through post processors";
owner checks deferred: "I am not gonna check those right now").

## Goal

Built-in posts for two common woodworking routers' controllers, and built-in machines for the GRBL family, each writing only
codes its controller documents, and saying what it assumes where only an owner can confirm it. Nothing has run on these
machines; TESTING gets an owner check for each, as for the LinuxCNC and Othermill posts.

## Decisions

1. **Onefinity Original/Pro, Buildbotics controller (#104): `onefinity-bb-inch`, `onefinity-bb-mm`.** BB is the CAMotics
   planner (a LinuxCNC subset).
   - extension `ngc`; parentheses comments; decimals 4/1, 3/0.
   - preamble `G90`, `G91.1`, `G17`, `G49`, `G94` (each verified in the CAMotics source per #104; `G40` and `G80` are not
     documented there, so they are left out: a word the planner rejects stops the program).
   - tool change `M5`, `(MSG, Change to Tool: {TOOL_NAME})`, `M0`. Not `T M6`: users report they cannot jog while BB's M6
     pause is up and staff call the stock tool-change field unusable, so Z cannot be set there; `M0` makes the existing
     `ToolChangeZ` warning tell the owner to save one file per tool (as for GRBL and LinuxCNC).
   - dwell `G4 P{SECONDS}`, 3 s (seconds verified: staff "P1 = 1 Second Delay"; source `dwell(double seconds)`).
   - footer `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M2` (BB acts on `M2`; its `M30` handling is a TODO in source).
   - RPM 10,000–30,000 (the Makita RT0701C owners fit); limits the Woodworker's (32.125 × 32.125 × 5.25 in, rapid and max
     feed 400 in/min).
2. **Shapeoko through Carbide Motion (#105): `carbide-motion-inch`, `carbide-motion-mm`.** Carbide Motion (CM) rewrites G-code
   on the fly, so its supported-codes page is the dialect.
   - extension `nc`; **semicolon** comments (staff: parentheses lock up a Shapeoko 5 Pro under some senders); decimals 4/1, 3/0.
   - preamble `G90`, `G17`, `G40`, `G49`, `G54` (CM: "G40, G43, G49 (Accepted but ignored)", "G54-G59 (Accepted but
     ignored)"); no `G94`, `G80`, `G91.1` (not on the supported list).
   - tool change `M5`, `; Change to Tool: {TOOL_NAME}`, `T{T} M6`: CM prompts for the swap at `M6` and, with a BitSetter,
     measures the tool. Tool numbers must be unique (staff); the existing duplicate-tool-number check covers it.
   - dwell `G4 P{SECONDS}`, 3 s. Assumed seconds: CM lists G4 without a unit, GRBL underneath is seconds, and Carbide staff
     wrote "P seems to be seconds". The owner check times it first.
   - footer `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M2` (CM: `M30` "may return the machine to the machine origin";
     `M2` lifts and moves back).
   - optional stop: CM lists `M1` as "Sleep (optional stop)", so these posts write `M0` for it, like the Othermill
     (`honoursOptionalStop` false by id). The id list becomes one `BuiltInPosts.noOptionalStopIDs` (Othermill and Carbide
     Motion), read by `honoursOptionalStop`.
   - RPM 0–30,000 and limits the Shapeoko 5 Pro 2×2's (623 × 623 × 155 mm, 24.5 × 24.5 × 6.1 in); feeds UNKNOWN, so the GRBL
     posts' 314.9 in/min (8000 mm/min), which a machine replaces.
3. **GRBL family (#100).** grblHAL and FluidNC with the defaults #100 lists take the GRBL posts' text unchanged (`M0` tool
   change, seconds dwell, `M2`), so no new posts: a `grblhal` post would write the GRBL posts' bytes. Built-in machines, each
   listing `generic-grbl-mm` and `generic-grbl-inch`: Genmitsu 3018-PROVer (290 × 180 × 40 mm, 3,000–9,000 rpm) and Sienci
   LongMill MK2 30×30 (820 × 872 × 114 mm, 15,000–25,000 rpm); feeds UNKNOWN (the post's). Maslow 4 is left out (forum claim
   only).
4. **Machines.** `onefinity-woodworker` (BB posts), `shapeoko-5-pro-2x2` (Carbide Motion posts), `genmitsu-3018-prover`,
   `longmill-mk2-30x30` (GRBL posts). Each lists only the posts that drive it (#104's safety flag: a Onefinity Elite runs
   MASSO, whose `P` is milliseconds; it is not this machine).

## Tests

- Golden rows (`newPosts`, `newPostNumbers`) for the four posts: units code, preamble, tool change, footer tail, numbers.
- Carbide Motion: every comment line starts with `;` (header, toolpath comments, tool change); no `(`; an optional stop
  writes `M0`; the GRBL and Othermill posts' optional stop behaviour unchanged.
- Onefinity: a two-tool program warns (`ToolChangeZ`).
- Machines: each lists the right posts with the numbers above.
- `samples/expected` gains the four posts' folders; the existing folders stay byte-identical.

## Docs

DECISIONS (`onefinity-carbide-posts`, with the assumptions and the `grblhal` ruling), Help (Machines: the built-in list),
TESTING (owner checks: Onefinity air cut and two-file job; Carbide Motion: time the spin-up dwell, `M6` prompt, `;` comments
load, `M2` move back clears clamps), README and PARITY lists, a comment on #100, #104, #105 with the nine facts.
