# Tool change rules per controller (#99 item 11)

Status: revision 1.

## Problem

Every built-in tool change already meets its controller's rules (`BuiltInPosts.swift`): `M5` first, then a comment, then `M0`
(GRBL, LinuxCNC, Onefinity BB, UCCNC, ShopBot, NcStudio) or `T{T} M6` (Mach4, Othermill, Carbide Motion, MASSO, Centroid,
Syntec, Haas). Only Syntec and Haas write `G43` (`G0 G43 Z{APPROACH_Z} H{T}`, `approachToolLengthIDs`). A duplicated post
("copy") keeps the family's rules only where `PostProfile.postProblem` checks them (`PostProfile.swift:313`), and it checks
none of these:

- **MASSO** (docs.masso.com.au, M06 and T pages): "M06 must be preceded by M05 or unpredictable results may occur", and "Txx M06
  is correct and behaves differently to M06 Txx". A MASSO copy may drop the `M5` or write `M6 T{T}`; the validator's
  `toolchange-spindle-on` warning covers only the first, and only as a warning. MASSO has no `G43`/`G49` (#99), yet a copy may
  turn on the tool length line.
- **NcStudio** (Programming Manual, 6th ed.): `G43` takes `H00`-`H07`. The built-in has the tool length line off; a copy that
  turns it on writes `H{T}` for any tool number, so tool 8 writes `H8`, which NcStudio does not have.

## Design

1. **MASSO copies** (`BuiltInPosts.family(of:) == masso-g3-*`), in `postProblem`:
   - the tool length line on → "MASSO has no G43: turn off the tool length offset.";
   - in `toolChange`, every `M6` must come after an `M5` (on an earlier line, or earlier on its own line) and after a `T`
     word (likewise) → "MASSO needs M5 and then the T word before M6: write M5, then T{T} M6." The lines are read with
     `GCodeParser` in the post's comment style, word by word, so a comment's text never counts.
   A new id set, `BuiltInPosts.massoIDs`, names the family, like `ncstudioIDs`.
2. **NcStudio tool numbers**, in the builder (`ProgramBuilder`, beside the other refusals at `:41`): an NcStudio-family post
   with the tool length line on and a toolpath whose tool number is outside 0-7 throws `PostError.invalidPost("NcStudio's G43
   takes H00 to H07: give tool <name> a number from 1 to 7, or turn off the tool length offset.")`. It depends on the job's
   tools, so it cannot live in `postProblem`.

No built-in output changes: the samples and goldens stay byte-identical.

## The rest of item 11 (no change; for the #99 comment)

- **Where a macro leaves X/Y/Z**: after the `toolChange` lines the writer forgets position and modal state and climbs to the
  approach height before any XY move (`reenter`), so wherever a macro (Mach4's M6, Centroid's, MASSO's) leaves the machine, the
  next move is up, then across. **Centroid**'s "M6 moves Z to home before any other motion" leaves Z at the top, and `reenter`
  then comes down to the approach height at that X Y: no conflict.
- **LinuxCNC `tool.tbl`**: the LinuxCNC and Onefinity BB posts stop with `M0` and write no `T`, `M6` or `G43`, so no table
  entry is needed. **Carbide Motion**'s unique tool numbers are already checked (#105, `Tool.hasSameGeometry`).
- **FluidNC** `M5` before `M6`: FluidNC uses the GRBL posts, which stop with `M0` and have no `M6`.
- **UCCNC** `G43 H` above 20: unconfirmed (no source found), and the UCCNC posts write no `G43`; no rule.
- **MASSO tool numbers**: the M06 page lists tools 0-118 on the G3 and the T page 1-100 for the main spindle; the two disagree,
  and no LoftLine library reaches 100, so no rule now.

## Tests

- MASSO copy: tool length on → the MASSO message; tool change `["M5", "M6 T{T}"]`, `["T{T} M6"]` (no M5), `["T{T} M6", "M5"]`
  → the order message; `["M5", "T{T}", "M6"]` and the built-in's own → nil; a comment containing "M6" does not count.
- Non-MASSO copy (Mach4) with `["M6 T{T}"]` → no MASSO message.
- NcStudio copy with the tool length line on: tools 1 and 7 post; tool 8 throws the NcStudio message; with it off, tool 8
  posts.
- `scripts/check-samples.sh` with no `--update`: no change.

## Docs

DECISIONS `tool-change-rules`; #99 comment answering item 11.
