# Words a controller may not know (#99 item 14)

Status: revision 2, after the round 1 panel (two GPT-6 seats, an Opus skeptic, a Sonnet simplifier): compare written programs, not templates.

## Question

#99 item 14: the first batch of controllers treats a word it does not know differently. Centroid cancels the job (error
502), MASSO skips the whole line, UCCNC follows its "Unknown g-codes" setting, and Mach3 "generally ignores" errors. A skipped
or ignored `G91.1`, `M5` or units line changes what the machine does with no error. Item 14 asks how a post lists the words it
relies on, and whether the Export sheet should say so.

## What exists

- Each built-in post writes only words its controller documents. Each dialect issue (#103-#111) checked this, for example
  the Onefinity preamble drops `G40` and `G80`, and MASSO's drops `G49` (`BuiltInPosts.swift`).
- The validator warns on a G or M code LoftLine itself does not model (`unknown-g`, `unknown-m`, `GCodeValidator.swift:200,
  261`), and the post editor refuses text outside a comment that is not a word. It cannot know which words a given controller
  lacks.
- A duplicated post (a copy, `<id>-custom-<n>`) keeps its family's rules (`BuiltInPosts.family(of:)`) and may add any
  template line. MASSO's missing `G43` is already an export error (`DialectChecks.swift:55`).
- The UCCNC owner check sets "Unknown g-codes" to "Don't run" while testing (`TESTING.md:234`).

## Decision

**No separate word list.** The program a built-in writes holds the words it relies on, the words its controller is known to
read. A post of a built-in family (a copy, or a file or project copy that carries the built-in's id) whose program writes a G
or M code the built-in's program for the same job does not, gets an export warning naming the codes and what that controller
does with a word it does not know. The owner may know that their controller reads it, so it is a warning, not an error.

- **Compared on written programs**, so every word the builder writes counts: coolant, units, `G90.1` (absolute arcs),
  rendered stops (`{STOP}`), the tool length line as written, a probed tool change. `UnknownWords.issues(text:job:profile:)`
  (PostCore) takes the exported text, the `PostJob` and the post. The reference is the built-in post given the copy's units,
  limits, rapid rate, max feed, spindle range and probe setting (what a machine applies, `MachineDefinition.applied(to:)`), so
  only the dialect differs. It is posted with the same job; if that throws, it is posted again without the probe setting (a
  built-in that cannot probe); if that throws too, the check is silent (no false warning).
- **Words**: the G and M codes of each program, read with `GCodeParser` in each post's comment style. Units words
  (`G20`, `G21`, `G70`, `G71`) are left out (`postProblem` already keeps a family's units words, and the reference has the
  copy's units). A code the validator does not model is left out too: it already gets `unknown-g`/`unknown-m`.
- **Message**: "<post name> writes <codes>, which the built-in <built-in name> post does not: <consequence> Check that your
  controller reads them." Codes in first-seen order, `NumberFormat.compact` (G64, G90.1, M7).
  - MASSO: "MASSO skips a whole line with a word it does not know." (the same claim as the G43 error, #107)
  - Centroid: "CNC12 cancels the job at a word it does not know (error 502)." (#99's research)
  - UCCNC: "UCCNC runs, skips or stops at a word it does not know, as its Unknown g-codes setting says." (#99; TESTING's
    UCCNC check)
  - any other family: "A controller may ignore, skip or refuse a word it does not know."
- **Where**: `GCodeExporter.export`, after posting, beside `validate(gcode:)`; the CLI goes through it. Not in the post editor:
  its sample report blocks Save on any issue, and this is a warning the owner may accept.
- A post equal to its built-in by value skips the work.

No output changes.

## Tests

- A MASSO copy whose preamble adds `G64 P0.01`: one warning naming G64, with MASSO's consequence.
- A MASSO copy set to absolute arcs: the warning names G90.1.
- A Centroid copy adding `M7` to its tool change, on a job with no coolant: warned; the built-in Centroid post on a job with
  mist coolant: no unknown-word warning (the built-in writes M7 itself).
- A UCCNC copy adding `G28` to its footer: UCCNC's consequence; a Mach4 copy adding `G64`: the general one.
- A copy whose only change is a comment containing "G64", a copy changed to the other units, a copy whose pause is a manual
  M0, and the Avid post with a machine's probe setting: no unknown-word warning.
- A user post carrying `masso-g3-inch` as its id with `G64` added: warned.
- A code the validator does not model (`M98`) in a copy: only the existing `unknown-m` warning.

## Docs

DECISIONS `unknown-words`; #99 comment answering item 14.
