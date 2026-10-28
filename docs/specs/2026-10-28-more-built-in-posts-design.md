# LoftLine: more built-in posts

Part 5, the last of the post-processor work. Parts 1–4 are on main at `b96ed4c`. Revision 2 (after the r1 panel).

## Why

LoftLine ships three posts: the Avid Mach4 posts (inch, mm), the only ones proven on a machine, and a GRBL post in mm. Someone
with a GRBL machine set up in inches, or a LinuxCNC machine, has to duplicate one of these and edit it, which part 3 makes
possible but which a new user should not need for the common controllers.

## Goals

- Three new built-in posts: `generic-grbl-inch`, `linuxcnc-inch`, `linuxcnc-mm`, each a small change from a post that works.
- **Nothing about the existing posts changes**: their bytes, goldens and `samples/expected/` files stay identical; the new posts
  add new `samples/expected/<id>/` folders.
- Each new post passes the post editor's report clean (part 3's rules and sample job) and the validator on every sample.
- Help and DECISIONS name the posts proven on a machine (the Avid Mach4 ones). `PostProfile` has no notes field and gains none.

## The posts

All three use the plain codes (`G0 G1 G2 G3`, `M3 S{S}`, `M5`, `G4 P{SECONDS}`), incremental I J, modal output, parenthesised
comments, a 3 s spindle dwell, no tool length offset. Each preamble, tool-change and footer entry below is one line.

| | `generic-grbl-inch` | `linuxcnc-inch` | `linuxcnc-mm` |
|---|---|---|---|
| name | Generic GRBL (inch) | LinuxCNC (inch) | LinuxCNC (mm) |
| units / decimals / feed decimals | in / 4 / 1 | in / 4 / 1 | mm / 3 / 0 |
| file extension | `nc` | `ngc` | `ngc` |
| preamble | `G90`, `G17`, `G94` (as `genericGRBLMM`) | `machPreamble`: `G90`, `G91.1`, `G17`, `G40`, `G49`, `G80`, `G94` | same |
| tool change | `M5`, `(Change to Tool: {TOOL_NAME})`, `M0` | same as GRBL | same |
| footer | `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M2` | same | same |
| arc tolerance | 0.0005 in | 0.0005 in | 0.01 mm |
| fallback limits (x, y, z, spoilboard cut) | 29.5, 29.5, 2.55, 0.039 in | 48, 48, 6, 0.05 in | 1219.2, 1219.2, 152.4, 1.27 mm |
| RPM | 0–30000 | 0–24000 | 0–24000 |
| rapid rate and max feed | 314.9 in/min | 200 in/min | 5080 mm/min |

The GRBL inch values are the GRBL mm post's converted and rounded **down** (750 mm = 29.53 in, 65 mm = 2.56 in, 1 mm = 0.0394 in,
8000 mm/min = 314.96 in/min), so the inch post never allows more than the mm one. The LinuxCNC pair is one machine, converted exactly.

The three footers share one constant, `m2Footer`; the LinuxCNC posts use `machPreamble` directly. `genericGRBLMM` is not edited.

## Decisions

1. **LinuxCNC tool change stops with `M0`, not `T{T} M6`.** M6 stops only when LinuxCNC is configured for a manual change
   (`hal_manualtoolchange`); a config that loops `tool-change` back to `tool-changed` completes it at once, and a `T` not in the
   tool table aborts the program. `M0` stops on every configuration and needs no tool table. The post uses no tool length offset,
   so nothing is lost; an owner with a tool changer duplicates the post and edits the tool change.
2. **No Mach3 posts.** A Mach3 post would write the Avid posts' G-code byte for byte (same dialect, M30, `.tap`); its only
   difference would be the fallback limits, which a machine replaces. Help says a Mach3 owner can use the Avid posts' G-code (set
   Mach3's tool change to stop, and check `G4 P` is in seconds) by listing them in a machine of their own.
3. **Probing.** `BuiltInPosts.probeController(for:)` maps `generic-grbl-inch` to GRBL. `ToolChangeProbe.defaults(for:)` chooses
   GRBL when any of the machine's listed post ids is a built-in that `probeController` maps to `.grbl`, so a machine listing only
   `generic-grbl-inch` gets GRBL defaults (today it checks `genericGRBLMM.id` alone, and would give Mach4 and then refuse). The
   LinuxCNC posts map to nothing: the editor's controller names would mislabel them. An owner can duplicate and declare one.
4. **Built-in machines are unchanged** (their `postIDs` keep their bytes, so no project's machine copy starts to differ). The new
   posts appear under "other posts" for the built-in machines. The fallback limits apply only to a project with no machine:
   new projects get the default machine (the Avid), whose limits replace the post's. Help (Machines) says: with any post but the
   Avid or GRBL mm ones, make a machine for your controller (bed, feeds, RPM) and list the post in it; until then LoftLine checks
   the job against the selected machine.
5. **Order of `BuiltInPosts.all`**: the existing three first, unchanged, then `generic-grbl-inch`, `linuxcnc-inch`, `linuxcnc-mm`.
   The default post and every picker's first entries stay as they are.
6. **A user file with a new built-in's id keeps winning** (the existing rule in `PostProfileStore`: a user post overrides the
   built-in with its id). Recorded in DECISIONS, no code.
7. **Known limitation, not fixed here:** mist coolant writes `M7`, which GRBL builds without `ENABLE_M7` reject. This already
   applies to the GRBL mm post. Help (Machines) says so; a fix (a per-post coolant code) is a follow-up.

## Tests

1. `NewBuiltInPostTests` (PostCoreTests), table-driven over the three posts, posting `PostFixtures.postJob()` and asserting
   literals written in the test (not derived from the profile): `G20` or `G21`; the preamble lines in order; the tool-change lines;
   the last four lines of the footer; one decimals check (`Z` with 4 decimals in inch, 3 in mm). The whole output is pinned by
   `samples/expected/<id>/`.
2. `probeController`: `generic-grbl-inch` gives `.grbl`, the LinuxCNC posts give nil. `ToolChangeProbe.defaults(for:)` on a machine
   with `postIDs: ["generic-grbl-inch"]` gives the GRBL controller; on the Avid machine, Mach4 (unchanged).
3. `MachineConfigTests.orderedPostsPutsMachinePostsFirst` changes: the Avid machine's `other` is
   `[generic-grbl-mm, generic-grbl-inch, linuxcnc-inch, linuxcnc-mm]` in that order, and the no-machine count is `BuiltInPosts.all.count`.
4. Free, already looping over `BuiltInPosts.all`: `everyBuiltInIsClean` (editor report), `goldenProgramsPassTheValidator` (both Z
   modes), `builtInProfilesRoundTripJSON` (ids unique).
5. `scripts/check-samples.sh --update` adds three `samples/expected/<id>/` folders and changes no existing file (`git status`).

## Docs

- `docs/DECISIONS.md`: one `more-posts` entry (decisions 1–4, 6, 7).
- `README.md:117`: reword so it doesn't enumerate the posts.
- Help (`.machines` topic): the proven posts, decision 4's machine sentence, decision 2's Mach3 sentence, decision 7's M7 line.
- `docs/PARITY.md`: `io-post-processors` test list only if a test file is added (it is: `NewBuiltInPostTests`).
- No TESTING change: its air cut already applies before the first real cut with any post.
