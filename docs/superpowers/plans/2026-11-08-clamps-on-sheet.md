# Clamps and screws on the job sheet, canvas and 3D preview (#134) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The operator sees every clamp and screw the export checks, by name and position, on the printed job sheet, the canvas and the 3D preview.

**Architecture:** One list in LoftLineKit (`ClampList`) merges keep-out layer shapes (`Fixtures.zones`, hidden layers included) and
`Document.keepOutZones`, numbers shared names, and words each position from the material's edges. The job sheet, the canvas labels and the
3D blocks all read it, so "Clamps 3" is the same clamp everywhere. The sidecar's `jobSheet` renders the same HTML, so Windows and Linux get
the sheet; their canvas and 3D view are a line in `docs/PLATFORMS.md`.

**Tech Stack:** Swift 6, swift-testing, SceneKit (3D preview), Core Graphics (canvas).

**Spec:** GitHub issue #134 (https://github.com/seanperkins/loftline/issues/134).

## Global Constraints

- No G-code change: `scripts/check-samples.sh` matches 48 programs.
- Lengths in the document's units, formatted with `JobSheet.fmt`. Positions measured from the material's edges, never from X0 Y0.
- A project with no keep-outs gets no new section, table or style on its job sheet.
- `Fixtures.zones` names stay as they are (export messages and their tests use them).
- New tests in `Tests/LoftLineKitTests` so Linux and Windows CI run them.

## Review Focus

1. A clamp that crosses a material edge and reaches past the 4% preview pad: the SVG must show all of it.
2. Two-sided bottom side and multi-sheet projects: the sheet must show the zones the export checks for that output project.
3. A zone at a corner, spanning the full width, or entirely off the material: worded without a wrong edge.
4. Printed in greyscale: the zone fill must still read as a zone.
5. Shared names across layer zones and Keep-Out Zones: numbered across both, in one order.

---

### Task 1: `ClampList`

**Files:** Create `Sources/LoftLineKit/ClampList.swift`; modify `Sources/CADCore/Layout/Fixtures.swift` (Zone gains `layerID: UUID?`, default nil);
test `Tests/LoftLineKitTests/ClampListTests.swift`.

**Produces:** `ClampItem { name, loops: [[Vec2]], height, layerID: UUID?, bounds: Rect2 }`; `ClampList.items(in: Document) -> [ClampItem]`;
`ClampList.position(of:job:units:) -> String`; `ClampList.heightText(of:units:) -> String`.

- [ ] Tests: hidden keep-out layer included; `keepOutZones` with outline > 2 included, shorter skipped; unnamed shape uses the layer name; shared
  names numbered in list order ("Clamps 1", "Clamps 2"), unique names untouched; left-edge clamp worded "left edge, centre 12 in from the bottom,
  reaches 1 in onto the material"; each of the four edges; corner and inside zones worded as ranges from the left and bottom edges; off-material
  zone prefixed "off the material"; mm document gives mm text; height 0 is "flush with the top".
- [ ] Watch them fail, implement, watch them pass. Commit `feat(layout): one named list of every clamp and keep-out`.

### Task 2: Job sheet

**Files:** Modify `Sources/LoftLineKit/JobSheet.swift`; test `Tests/LoftLineKitTests/JobSheetClampTests.swift`.

**Produces:** `JobSheet.Clamp { name, position, height }`, `JobSheet.clamps: [Clamp]`, `JobSheet.zones: [ClampItem]`.

- [ ] Tests: nested project shows the zones on every sheet's SVG; a hidden keep-out layer is listed and drawn; `keepOutZones` listed and drawn;
  inch and mm positions; no keep-outs means no "Clamps and screws" text and no hatch pattern; a visible keep-out layer's shapes are not also
  drawn as plain outlines; a zone past the material edge widens the viewBox.
- [ ] Implement: build from `project.document` (the output project); a "Clamps and screws" table with a checkbox per item after Setup; hatched,
  red-dashed, even-odd zones with names in each sheet's SVG.
- [ ] `scripts/test.sh` green; commit `feat(layout): the job sheet shows and lists every clamp and screw`.

### Task 3: Canvas names

**Files:** Modify `Sources/LoftLineApp/Canvas/CanvasLayoutDrawing.swift`, `Sources/LoftLineApp/Panels/KeepOutZonesSheet.swift`; add
`harness/scenarios/clamps.json`.

- [ ] Draw each drawn zone's `ClampList` name at its bounds' centre. Check with `scripts/ui.sh clamps --light`. Commit `feat(canvas): clamp names`.

### Task 4: 3D preview blocks

**Files:** Modify `Sources/LoftLineApp/Preview/StockScene.swift`, `SimulationPreviewModel.swift`, `SimulationPreviewView.swift`.

- [ ] Clamps as extruded blocks from the stock top to their height (a thin slab when flush), a "Clamps" toggle in the Show menu, on by default.
  Test the block geometry's heights in the app tests; check with the harness. Commit `feat(preview): clamps as blocks`.

### Task 5: Docs

- [ ] `docs/PLATFORMS.md` (desktop canvas and 3D don't show clamps), `docs/DECISIONS.md` (edge wording, numbering, names not changed in export
  messages), `TESTING.md` (check the sheet's clamp list against the clamps before cutting), `docs/PARITY.md` if it lists the job sheet.
  Commit `docs: clamps on the job sheet`.
