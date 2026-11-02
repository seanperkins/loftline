# Controller settings a program cannot set (#99 item 13)

Status: revision 1.

## Question

#99 item 13 lists settings that change how a controller reads a program but that no G-code line can set (NcStudio "Arc
Increment", Mach3's dwell switch and IJ mode, UCCNC "Measure dwell in seconds", Centroid Parameter 2 bit 2, grblHAL `$341`,
GRBL `$30`) and asks whether a profile should carry an `assumes` note, printed in the header and shown in the Export sheet.

## Each setting against the built-in posts

| Setting | Built-in posts | Matters? |
|---|---|---|
| NcStudio Arc Increment | `ncstudio-mm` writes arcs as lines; `postProblem` keeps a copy that way | no |
| Mach3 dwell switch, IJ mode | no Mach3 post (the Avid posts are Mach4 and write `G91.1`) | no |
| grblHAL `$341` (tool change mode) | the GRBL posts stop with `M0` and write no `M6` | no |
| GRBL `$30` (max spindle) | the GRBL machines' notes say to match it to Max RPM (`MachineDefinition.grblRPMNote`) | covered |
| UCCNC "Measure dwell in seconds" | the UCCNC posts write `G4 P` in milliseconds, the default; with it on, the 3 s spin-up lasts 3,000 s | yes, slow |
| Centroid Parameter 2 bit 2 | the Centroid posts write `G4 P` in seconds, the default; with it set (milliseconds), the 3 s spin-up lasts 3 ms and the bit plunges before the spindle is up to speed | yes, unsafe |

The help topic (`HelpTopics.swift:193`) already states each built-in's assumptions, the two above included. The Export sheet
reminds of one (UCCNC's units, `DialectChecks.swift:60-64`, #108).

## Decision

No `assumes` field. The assumptions are per controller, so they live where the per-controller checks are: a `DialectChecks`
warning, shown in the Export sheet and by the CLI at every export, as UCCNC's units are (#108). A header comment would change
every sample's bytes and repeats what the warning says; a custom post for another controller can write its own note in
its program-start or preamble comment lines.

1. **Centroid** (new): a warning when the program dwells (the spindle start's dwell, `spindleDwellSeconds > 0`, or any dwell
   move): "CNC12 reads G4 P in seconds unless Parameter 2 bit 2 is set (milliseconds): check that it is clear, or a 3 s dwell
   lasts 3 ms." The number is the post's spin-up dwell when it has one. Prefix constant `DialectChecks.centroidDwellWarningPrefix
   = "CNC12 reads G4 P in seconds"`.
2. **UCCNC** (extended): the units warning gains ", and leave \"Measure dwell in seconds\" off: this program's G4 P is in
   milliseconds" when the program dwells. Same prefix, still one warning.

No output changes. The CLI samples test lists the Centroid prefix beside UCCNC's.

## Tests

- `DialectChecks` with `centroid-inch` and `centroid-mm`: one warning with the prefix; with `spindleDwellSeconds = 0` and no
  dwell moves, none; a copy (`centroid-inch-custom-1`) warns too.
- UCCNC: the warning contains "Measure dwell in seconds"; with no dwell, it does not; still exactly one warning.
- Other posts: no new warning.
- CLI samples test: Centroid's warning expected.

## Docs

DECISIONS `controller-settings`; #99 comment answering item 13.
