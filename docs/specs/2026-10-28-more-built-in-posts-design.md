# LoftLine: more built-in posts

Part 5, the last of the post-processor work. Parts 1–4 are on main at `b96ed4c`. Revision 4 (after the r3 panel; the last revision round, remaining points ruled in Decisions 1 and 6).

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
| tool change | `M5`, `(Change to Tool: {TOOL_NAME})`, `M0` (as `genericGRBLMM`) | `M5`, `(MSG, Change to Tool: {TOOL_NAME})`, `M0` | same |
| footer | `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, `M2` | same | same |
| arc tolerance | 0.0005 in | 0.0005 in | 0.01 mm |
| fallback limits (x, y, z, spoilboard cut) | 29.5, 29.5, 2.55, 0.039 in | 48, 48, 6, 0.05 in | 1219.2, 1219.2, 152.4, 1.27 mm |
| RPM | 0–30000 | 0–24000 | 0–24000 |
| rapid rate and max feed | 314.9 in/min | 200 in/min | 5080 mm/min |

The GRBL inch values are the GRBL mm post's, rounded down. The LinuxCNC pair is one machine, converted exactly. LinuxCNC's
screens show only `(MSG, …)` comments, so its tool-change comment uses that form (`{TOOL_NAME}` stays inside the parentheses).

The three footers share one constant, `m2Footer`; the LinuxCNC posts use `machPreamble` directly. `genericGRBLMM` is not edited.

## Decisions

1. **LinuxCNC tool change stops with `M0`, not `T{T} M6`.** M6 stops only when LinuxCNC is configured for a manual change
   (`hal_manualtoolchange`); a config that loops `tool-change` back to `tool-changed` completes it at once, and a `T` not in the
   tool table aborts the program. `M0` stops on every configuration and needs no tool table. Neither re-zeroes Z: at `M0`
   LinuxCNC stays in Auto, so the operator cannot touch off, and the program resumes at the old safe Z. That is the same as the
   GRBL post's `M0` today. Help (Machines) says: on LinuxCNC (and GRBL without a touch plate), post a job with more than one tool
   with Save All Toolpaths ▸ one file per tool; load that file's tool and touch off Z **before** starting it (the stop at the
   top of each file only confirms the tool, and Z cannot be set there). An owner with tool length offsets or a tool changer
   duplicates the post and edits the tool change. **Ruling:** a single multi-tool LinuxCNC file is still allowed, as it is for
   the GRBL post today; refusing or warning needs a new post field ("this tool change cannot re-zero Z") and is a follow-up.
2. **No Mach3 posts.** A Mach3 post would write the Avid posts' G-code byte for byte (same dialect, M30, `.tap`); its only
   difference would be the fallback limits, which a machine replaces. DECISIONS (not Help: nothing has run on Mach3) records that
   a Mach3 owner can list the Avid posts in a machine of their own, with Mach3's tool change set to stop, `G4 P` in seconds, and
   touch-plate tool changes **off** (LoftLine's Mach4 probe sequence calls a Mach4 macro).
3. **Probing.** `BuiltInPosts.probeController(for:)` maps `generic-grbl-inch` to GRBL. `ToolChangeProbe.defaults(for:)` chooses
   GRBL when any of the machine's listed post ids is a built-in that `probeController` maps to `.grbl`, so a machine listing only
   `generic-grbl-inch` gets GRBL defaults (today it checks `genericGRBLMM.id` alone, and would give Mach4 and then refuse). The
   LinuxCNC posts map to nothing, and LoftLine has no LinuxCNC probe sequence: touch-plate tool changes are for Mach4 and GRBL
   only (Help already says which).
4. **Built-in machines are unchanged** (their `postIDs` keep their bytes, so no project's machine copy starts to differ). The new
   posts appear under "other posts" for the built-in machines. The fallback limits apply only to a project with no machine:
   new projects get the default machine (the Avid), whose limits replace the post's. Help (Machines) says: with any post but the
   Avid or GRBL mm ones, make a machine for your controller (bed, feeds, RPM) and list the post in it; until then LoftLine checks
   the job against the selected machine.
5. **Order of `BuiltInPosts.all`**: the existing three first, unchanged, then `generic-grbl-inch`, `linuxcnc-inch`, `linuxcnc-mm`.
   The default post and every picker's first entries stay as they are.
6. **Out of scope:** mist coolant writes `M7`, which stock GRBL rejects. This already applies to the GRBL mm post, and the coolant
   form and Help already say "A stock GRBL controller has no M7: use Air there." The editor report checks LoftLine's own rules, not
   a controller's build options; "clean" means that.

## Tests

1. A table-driven test in `PostGoldenTests.swift` over the three posts, posting `PostFixtures.postJob()` and asserting literals
   written in the test (not derived from the profile): `G20` or `G21`; the preamble lines in order; the tool-change lines; the
   last four lines of the footer; one decimals check (`Z` with 4 decimals in inch, 3 in mm). A second table-driven test pins each
   post's `name`, `fileExtension`, `limits`, `rapidRate`, `maxFeed`, `minRPM`, `maxRPM` and `arcTolerance` against the table's
   literals (samples run with the Avid machine applied, so nothing else checks them). The whole output is pinned by
   `samples/expected/<id>/`.
2. `probeController`: `generic-grbl-inch` gives `.grbl`, the LinuxCNC posts give nil. `ToolChangeProbe.defaults(for:)` on a machine
   with `postIDs: ["generic-grbl-inch"]` gives the GRBL controller; on the Avid machine, Mach4 (unchanged).
3. `MachineConfigTests.orderedPostsPutsMachinePostsFirst` changes: the Avid machine's `other` is
   `[generic-grbl-mm, generic-grbl-inch, linuxcnc-inch, linuxcnc-mm]` in that order, and the no-machine count is `BuiltInPosts.all.count`.
4. Free, already looping over `BuiltInPosts.all`: `everyBuiltInIsClean` (editor report), `unchangedDuplicatesAreClean` (posts and
   validates the GRBL touch-plate sequence in G20 for the first time), `goldenProgramsPassTheValidator` (both Z modes),
   `builtInProfilesRoundTripJSON` (ids unique). A failure in any of them is a finding, not a test to adjust.
5. `scripts/check-samples.sh --update` adds three `samples/expected/<id>/` folders and changes no existing file (`git status`).

## Docs

- `docs/DECISIONS.md`: one `more-posts` entry (decisions 1–4, 6; that a user file with a new built-in's id keeps overriding it,
  by the existing rule).
- `README.md:117`: reword so it doesn't enumerate the posts.
- Help (`.machines` topic): which posts are proven on a machine; decision 1's one-file-per-tool sentence; decision 4's machine
  sentence.
- `TESTING.md`: a short "Other controllers" section after the Avid air cut, for the GRBL and LinuxCNC posts on their own
  machines: post one file per tool; load and touch off each tool before its file; air-cut each file and confirm it stops at the
  top and that the spindle dwell is seconds.
- No PARITY change (no new test file).
