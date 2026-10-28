# LoftLine: more built-in posts

Part 5, the last of the post-processor work. Parts 1–4 are on main at `b96ed4c`.

## Why

LoftLine ships three posts: the Avid Mach4 posts (inch, mm), the only ones proven on a machine, and a GRBL post in mm. Someone
with a GRBL machine set up in inches, a LinuxCNC machine, or an older Mach3 machine has to duplicate one of these and edit it,
which part 3 now makes possible but which a new user should not need for the common controllers.

## Goals

- Five new built-in posts for the common hobby and small-shop controllers, each a small change from a post that already works.
- **Nothing about the existing posts changes**: their bytes, goldens and `samples/expected/` files stay identical; the new posts
  add new goldens and new `samples/expected/<id>/` folders.
- Each new post passes the post editor's report clean (part 3's rules and sample job) and the validator on every sample.
- The docs say what the posts are: Help and DECISIONS name the posts proven on a machine (the Avid Mach4 ones). `PostProfile` has
  no notes field and gains none; the G-code header line is unchanged.

## The posts

All use the dialect's plain codes (`G0 G1 G2 G3`, `M3 S{S}`, `M5`, `G4 P{SECONDS}`), incremental I J, modal output, parenthesised
comments, the standard footer shape, a 3 s spindle dwell, no tool length offset.

| id | name | units / decimals / feed decimals | preamble | tool change | footer end | ext | fallback limits | RPM | rapid & max feed |
|---|---|---|---|---|---|---|---|---|---|
| `generic-grbl-inch` | Generic GRBL (inch) | in / 4 / 1 | `G90 G17 G94` (as the GRBL mm post) | `M5`, comment, `M0` | `M2` | nc | 29.5 x 29.5 x 2.5 in | 0–30000 | 315 in/min |
| `linuxcnc-inch` | LinuxCNC (inch) | in / 4 / 1 | `G90 G91.1 G17 G40 G49 G80 G94` | `M5`, comment, `T{T} M6` | `M2` | ngc | 48 x 48 x 6 in | 0–24000 | 200 in/min |
| `linuxcnc-mm` | LinuxCNC (mm) | mm / 3 / 0 | as above | as above | `M2` | ngc | 1220 x 1220 x 150 mm | 0–24000 | 5080 mm/min |
| `mach3-inch` | Mach3 (inch) | in / 4 / 1 | the Avid preamble (Mach3 and Mach4 read it alike) | the Avid tool change | `M30` | tap | 48 x 48 x 6 in | 0–24000 | 200 in/min |
| `mach3-mm` | Mach3 (mm) | mm / 3 / 0 | as above | as above | `M30` | tap | 1220 x 1220 x 150 mm | 0–24000 | 5080 mm/min |

Each line is one preamble or footer line as the existing posts write them (one word per line for the Mach and LinuxCNC preambles,
as `machPreamble` does). The footer is `G0 Z{HOME_Z}`, `M5`, `G0 X{HOME_X} Y{HOME_Y}`, then the end code. Allowed spoilboard cut:
0.05 in / 1 mm. Arc tolerance: 0.0005 in / 0.01 mm.

## Decisions

1. **Probing.** `BuiltInPosts.probeController(for:)` maps `generic-grbl-inch` to GRBL (it is the GRBL post in inches). LinuxCNC
   and Mach3 posts map to nothing: LinuxCNC probes like GRBL but the editor's controller names would mislabel it, and Mach3's
   macros are not Mach4's Lua. Their owners can duplicate and declare a controller (part 3).
2. **Built-in machines are unchanged** (their `postIDs` keep their bytes, so no project's machine copy starts to differ). The new
   posts are listed under "other posts" for those machines; a machine of one's own lists them.
3. **Order of `BuiltInPosts.all`**: the existing three first, unchanged, then the new five, so the default post and every
   picker's first entries stay as they are.
4. **Not proven on a machine.** DECISIONS and Help say only the Avid Mach4 posts have run on a machine; TESTING's air cut applies
   before the first job with any other post.

## Tests

1. A golden program for each new post (the `PostFixtures.postJob()` job, as the existing goldens), reviewed by eye: the preamble,
   tool change and footer lines as the table says, `G20`/`G21`, the decimals.
2. Every built-in, old and new, passes `PostDraftReport.make` with no problem and no issue (part 3's test covers all of
   `BuiltInPosts.all`) and the validator on the golden job.
3. `probeController`: `generic-grbl-inch` → GRBL, the LinuxCNC and Mach3 posts → nil.
4. `scripts/check-samples.sh --update` adds `samples/expected/<new id>/` and changes no existing file (checked with `git status`).
5. The full suite green.

## Docs

`docs/DECISIONS.md` (`more-posts`), `docs/PARITY.md` (`io-post-processors`), Help (Machines and Post Processors), TESTING (the
air cut applies to the new posts), README if it lists the posts.
