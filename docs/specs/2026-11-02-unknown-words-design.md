# Words a controller may not know (#99 item 14)

Status: revision 1.

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

**No separate word list.** A built-in's own templates are the words it relies on, and the words its controller is known to
read. A copy that writes a G or M code its built-in's templates never write gets an export warning that names the codes and
says what that controller does with a word it does not know. The owner may know that their controller reads the code, so this
is a warning, not an error.

- **Words compared**: the G and M codes in the templates: prelude, preamble, tool change, tool length line (the copy's only
  when it is on; the built-in's always, since its family documents it), spindle on and off, dwell, footer, and the pause lines.
  Each line is read with `GCodeParser` in the post's comment style, after every `{NAME}` placeholder is replaced by `1`, so
  comments never count and `T{T}` reads as a word. The builder's own words (motion, units, coolant, `G90`/`G91.1`) are the
  same for a copy and its built-in, so they are not compared.
- **Message**: "<post name> writes <codes>, which the built-in <built-in name> post does not: <consequence> Check that your
  controller reads <it/them>." The codes are in first-seen order, for example "G64, M7".
  - MASSO: "MASSO skips a whole line with a word it does not know."
  - Centroid: "CNC12 cancels the job at a word it does not know (error 502)."
  - UCCNC: "UCCNC runs, skips or stops at a word it does not know, as its Unknown g-codes setting says."
  - any other family: "A controller may ignore, skip or refuse a word it does not know."
- **Where**: `DialectChecks.issues(toolpaths:profile:)`, which runs at every export and in the CLI. A built-in itself
  (`family == id`) is not checked.

No output changes.

## Tests

- A MASSO copy whose preamble adds `G64 P0.01`: one warning, naming G64, with MASSO's consequence.
- A Centroid copy adding `M7` in its tool change, and a UCCNC copy adding `G28` in its footer: each gets its own consequence.
- A Mach4 copy adding `G64`: the general consequence.
- A copy whose only change is a comment containing "G64": no warning. A copy identical to its built-in: none. A copy that
  re-orders the built-in's own words: none.
- An NcStudio copy that turns on its tool length line (`G43`): no unknown-word warning (the built-in's line counts).
- Every built-in: no warning.

## Docs

DECISIONS `unknown-words`; help topic (one sentence where duplicated posts are described); #99 comment answering item 14.
