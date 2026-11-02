# Controller settings a program cannot set (#99 item 13)

Status: revision 2, after the round 1 panel (two GPT-6 seats, an Opus skeptic, a Sonnet simplifier).

## Question

#99 item 13 lists settings that change how a controller reads a program but that no G-code line can set (NcStudio "Arc
Increment", Mach3's dwell switch and IJ mode, UCCNC "Measure dwell in seconds", Centroid Parameter 2 bit 2, grblHAL `$341`,
GRBL `$30`) and asks whether a profile should carry an `assumes` note, printed in the header and shown in the Export sheet.

## Each setting against the built-in posts

| Setting | Built-in posts | Matters? |
|---|---|---|
| NcStudio Arc Increment | `ncstudio-mm` writes arcs as lines; `postProblem` keeps a copy that way | no |
| Mach3 dwell switch, IJ mode | no Mach3 post (the Avid posts are Mach4 and write `G91.1`) | no |
| Mach4 milliseconds dwell | the Avid posts write seconds; DECISIONS (MASSO/UCCNC/Centroid/NcStudio posts) already rules that a Mach4 set to milliseconds needs a post under a new id; the Avid is the one post run on a machine | no (ruled) |
| grblHAL `$341` (tool change mode) | the GRBL posts stop with `M0`; Carbide Motion answers `T M6` itself with its prompt | no |
| GRBL `$30` (max spindle) | `S` is scaled against it: `S12000` with `$30=1000` is full power. Only the newer GRBL machines' notes mention it (`MachineDefinition.grblRPMNote`); the Generic GRBL router has none, and the machine editor has no RPM fields, so "set the copy's Max RPM" cannot be done | yes |
| GRBL `$32` (laser mode) | GRBL: "a G0 rapid motion mode ... will never turn on and always disable the laser", so a router spindle stops on every rapid and the next cut starts with no spin-up | yes, unsafe |
| UCCNC "Measure dwell in seconds" | the UCCNC posts write `G4 P` in milliseconds, the default; with it on, the 3 s spin-up lasts 3,000 s | yes, slow |
| Centroid Parameter 2 bit 2 | the Centroid posts write `G4 P` in seconds, the default; with it set (milliseconds), the 3 s spin-up lasts 3 ms and the bit plunges before the spindle is up to speed | yes, unsafe |

The help topic (`HelpTopics.swift:193`) and the owner checks (`TESTING.md`) state Centroid's setting; UCCNC's dwell setting and
GRBL's `$32` are named nowhere. The Export sheet reminds of one setting today (UCCNC's units, `DialectChecks.swift:60-64`, #108).

## Decision

No `assumes` field. The assumptions are per controller, so they live where the per-controller checks are: a `DialectChecks`
warning, shown in the Export sheet and by the CLI at every export, as UCCNC's units are (#108). A header comment would change
every sample's bytes and repeat the warning; a custom post for another controller can write its own note in its program-start
or preamble comment lines. The warnings are unconditional (every built-in of these families has a 3 s spin-up dwell).

1. **Centroid** (new): "CNC12 reads G4 P in seconds unless Parameter 2 bit 2 is set: check that it is clear, or a 3 s dwell
   lasts 3 ms." `public static let centroidDwellWarningPrefix = "CNC12 reads G4 P in seconds"`.
2. **UCCNC** (extended): the units sentence becomes "UCCNC takes units from its profile and may ignore G20/G21: set the
   profile to <units> before running this program, and leave \"Measure dwell in seconds\" off (LoftLine writes G4 P in
   milliseconds)." Same prefix, still one warning.
3. **GRBL** (new, the `generic-grbl-*` family): "GRBL scales S against $30 and stops the spindle on every G0 in laser mode: set
   $30 to <Max RPM> and $32=0." `<Max RPM>` is the profile's `maxRPM` at export (the machine's, when it sets one), written
   whole. `public static let grblSettingsWarningPrefix = "GRBL scales S against $30"`.
4. **Machine editor**: Min RPM and Max RPM fields (0 = the post's value), like Rapid rate, so a duplicated machine can carry
   the spindle range the GRBL notes and warning ask for.

No output changes.

## Tests

- `DialectChecks`: Centroid inch, mm and a copy → one warning with its prefix; UCCNC → still one warning, containing "Measure
  dwell in seconds"; GRBL inch, mm and a copy → one warning with its prefix containing "$30 to 30000" and "$32=0", and with a
  machine-applied `maxRPM` of 24000, "$30 to 24000".
- CLI samples test: the Centroid and GRBL prefixes are expected, and asserted present (not just allowed).
- Machine editor: a machine with `maxRPM` set round-trips (existing `MachineDefinition` codable tests) and the harness
  `preferences`/machines scenario shows the fields.

## Docs

Help topic: UCCNC's dwell setting and GRBL's `$32`. TESTING.md owner checks: UCCNC names "Measure dwell in seconds", GRBL
checks `$30` and `$32=0`. DECISIONS `controller-settings`; #99 comment answering item 13 (Buildbotics' `max-spin` is its
`$30`; its posts' notes are the Onefinity machine's).
