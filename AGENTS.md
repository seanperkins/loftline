# AGENTS.md

Guidance for coding agents working on LoftLine. Read [README.md](README.md) for what the app does.

## Commands

```sh
scripts/build.sh                     # debug build (swift build; works in a sandboxed agent shell)
scripts/test.sh                      # full swift-testing suite (~1,200 tests, ~70 s)
scripts/test.sh --filter Ops2D       # subset
scripts/bundle.sh                    # release build → dist/LoftLine.app (ad-hoc signed)
scripts/run.sh                       # debug bundle + launch
swift run loftline-cli export samples/sign.loftline --out .tmp/out   # post a project headless (see README "Command line")
scripts/check-samples.sh             # post every sample with every built-in post, diff against samples/expected/ (--update after an intended change)
scripts/check-bundle.sh              # release-mode bundles: version, channel, signing, update helper, smoke test (a few minutes)
scripts/check-release-workflow.sh    # structural check of .github/workflows/release.yml (also run by the test suite)
scripts/ui.sh main --light           # UI harness: screenshots + accessibility tree, no permissions (docs/UI-HARNESS.md)
LOFTLINE_UPDATE_GOLDEN=1 scripts/test.sh # regenerate golden G-code after an intended output change
LOFTLINE_WRITE_SAMPLES=1 scripts/test.sh --filter SampleFiles   # regenerate samples/
LOFTLINE_WRITE_SAMPLES=1 scripts/test.sh --filter HarnessProjects   # then, in a separate run, the harness projects (they embed the sample's ids)
```

Done means `scripts/build.sh` and `scripts/test.sh` are both green (the suite includes the samples check; a change that moves
a byte of any sample's G-code needs `scripts/check-samples.sh --update` and a look at the diff). Judge a test run by its
`Test run with N tests ... passed` line, not the exit code.

## Toolchain rules

- SwiftPM only. The project must build with Command Line Tools alone: no `.xcodeproj`,
  no `xcodebuild`, no `.metal` files (compile Metal shader source at runtime if needed).
- Tests use swift-testing (`import Testing`, `@Test`, `#expect`), not XCTest. Always run
  them through `scripts/test.sh`, which adds the framework paths a CLT-only machine needs.
- Build and test through the scripts, not bare `swift build` / `swift test`: SwiftPM's own
  `sandbox-exec` cannot nest inside an agent shell's sandbox, and `scripts/swiftpm-env.sh` adds
  `--disable-sandbox` only when that is the case.
- Don't write a source file and run tests in the same shell command; the test helper can
  hang. If a run sits at 0% CPU, kill `swift-test` / `swiftpm-testing-helper` and retry once.
- Swift tools 6.0, macOS 14+, Apple Silicon.

## Layout

| Module | Role |
|---|---|
| `Sources/CGeom` | C++ wrapper over vendored Clipper2 (offsets, booleans) and Boost.Polygon Voronoi (medial axis). Never edit `Vendor/`; wrap here. |
| `Sources/CADCore` | Geometry, `Document` model, importers/exporters (SVG, DXF, EPS, PDF, STL/OBJ/DAE), text outlines. |
| `Sources/CAMCore` | Toolpath operations (pure functions of shapes + tool + parameters), simulation, time estimates. |
| `Sources/PostCore` | Template-driven post processor (JSON `PostProfile`s) and `GCodeValidator`. |
| `Sources/LoftLineApp` | SwiftUI/AppKit app: document, canvas, inspector, dialogs, 3D preview. |

Each module has a matching test target in `Tests/`. Fixtures and golden `.tap` files live in
`Tests/Fixtures/`.

## Machine safety

This software drives a real router (the Avid PRO6096, Mach4, 60×96 in). Treat G-code
changes as safety-critical:

- All depth → machine-Z conversion goes through the single Z-zero helper so the
  material-top and spoilboard modes both stay correct. Test both modes for any Z-related change.
- Every program must pass `GCodeValidator`. Don't weaken a validator check to make a test pass.
- Changing post output means regenerating the golden files on purpose and reviewing the diff.
- Retract to safe Z before XY rapids; keep-out zones and the move home are checked on export.

## Checking UI changes

Run a harness scenario (`scripts/ui.sh <scenario> [--light|--dark] [--size WxH]`, see
[docs/UI-HARNESS.md](docs/UI-HARNESS.md)) and look at the PNG and the `.ax.txt` tree instead of
launching the app and driving it by hand. It runs in its own HOME, which keeps its tools and recovery files apart
from yours, but not its preferences (docs/UI-HARNESS.md). Add a scenario in `harness/scenarios/` for a state you need to see.

## Docs to keep current

- `docs/PARITY.md`: feature status against VCarve Pro. Update it when you add or finish a feature.
- `docs/DECISIONS.md`: append a short entry for each non-obvious design decision.
- `TESTING.md`: the manual test script and air-cut procedure.
- `THIRD_PARTY.md`: any new vendored code and its licence.

## Commits

Conventional commits (`feat(cam): …`, `fix(post): …`), one logical change per commit, with
build and tests green. Never commit the Vectric `*.exe` installers (they're gitignored).
