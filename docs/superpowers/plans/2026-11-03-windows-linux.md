# LoftLine on Windows and Linux Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use ml:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** LoftLine's core, command line and a desktop app run on Linux and Windows, posting the same G-code as the Mac app.

**Architecture:** The UI-free code moves to a `LoftLineKit` library. Mac-only services get portable versions behind `#if canImport`. A `loftline-core` sidecar speaks JSON to a Tauri front end in `desktop/`. All G-code comes from the Swift core.

**Tech Stack:** Swift 6.4, SwiftPM, C++17, vendored stb, swift-crypto (off the Mac only), Rust + Tauri 2, TypeScript, Playwright for headless UI checks, Docker for Linux.

**Spec:** `docs/specs/2026-11-03-windows-linux-design.md`

## Global Constraints

- The Mac app doesn't change: same frameworks, same output, and no new package dependency on the Mac.
- `samples/expected` is never regenerated for a platform difference. A difference is a bug or a line in `docs/PLATFORMS.md`.
- `GCodeValidator` checks are never weakened.
- `scripts/build.sh` builds with Command Line Tools alone and never touches `desktop/`.
- Linux builds run in Docker with `--scratch-path .build-linux`. `bitwarden` and `el-duro-1` aren't used.
- Windows stays marked unverified until its CI job runs. Nothing is pushed without Sean's say-so.
- One logical change per commit, conventional commits, no attribution lines.

## Review Focus

1. A G-code byte differing on Linux from the Mac (number formatting, sort order, float rounding): `scripts/check-samples-linux.sh` compares all 48.
2. A Windows checkout turning fixtures into CRLF: `.gitattributes` pins them.
3. A project opened on Linux whose text can't be re-outlined because the font is missing: stored outlines stay, and the failure is reported, never silently redrawn.
4. The front end building program text itself: `desktop/` has no G-code strings, and export returns the core's bytes.
5. A sidecar crash or malformed reply mid-export: the UI reports it and writes no file.

---

### Task 1: LoftLineKit and a separate CLI target

**Files:** Create `Sources/LoftLineKit/*` (moved), `Sources/loftline-cli/main.swift`. Modify `Package.swift`, app and test imports.

**Interfaces:** Produces `LoftLineCLI.run(_:output:)`, `GCodeExporter`, `ToolpathCalculator`, `MachineStore`, `PostProfileStore`, `ImportService` as public API of `LoftLineKit`.

- [ ] Move UI-free model files; split out the types that need Combine or AppKit.
- [ ] Run `scripts/build.sh`. Expected: builds.
- [ ] Run `scripts/test.sh`. Expected: 2,279 tests pass, same as main.
- [ ] Run `scripts/check-samples.sh`. Expected: 48 match.
- [ ] Commit `refactor(app): LoftLineKit holds what needs no window system`.

### Task 2: Move the tests that need only the kit

**Files:** Create `Tests/LoftLineKitTests/` from the `LoftLineAppTests` files that compile without `LoftLineApp`. Modify `Package.swift`.

- [ ] Move each test file that needs nothing from `LoftLineApp`.
- [ ] Run `scripts/test.sh`. Expected: the same total as Task 1.
- [ ] Commit `test(kit): the kit's tests run without the app`.

### Task 3: Package.swift builds off the Mac

**Files:** Modify `Package.swift`, `.gitattributes`, `Sources/LoftLineKit/GCodeFileSet.swift`, `Sources/LoftLineKit/PostProfileStore.swift`. Create `scripts/linux.sh`.

- [ ] `#if os(macOS)` around `LoftLineApp` and its tests. swift-crypto only off the Mac.
- [ ] Guard Darwin calls: Linux uses `renameat2(RENAME_NOREPLACE)`, Windows uses CreateFile and MoveFileEx.
- [ ] `.gitattributes`: fixtures, goldens and samples are `-text`.
- [ ] Commit `build: the package resolves off the Mac`.

### Task 4: Portable images (`CStb`)

**Files:** Create `Vendor/stb/`, `Sources/CStb/`, `Sources/CADCore/IO/PortableRaster.swift`. Modify `RasterCodec`, `BitmapTracer`, `PhotoImageLoader`, `THIRD_PARTY.md`.

**Interfaces:** Produces `RasterCodec.png(fromEncoded:)`, `RasterCodec.info(of:)`, `RasterCodec.gray(from:)` on every platform.

- [ ] Test: a PNG and a JPEG decode to the expected size and grey values, on Linux.
- [ ] Implement with stb_image and stb_image_write.
- [ ] Note TIFF, WebP and HEIC as Mac-only in `docs/PLATFORMS.md`.
- [ ] Commit `feat(cad): images decode off the Mac`.

### Task 5: Portable text

**Files:** Create `Sources/CADCore/Geometry/PortableFont.swift`. Modify `TextOutliner`, `TextKerning`, `TextOnPath`.

**Interfaces:** Same public `TextOutliner` API. `availableFontNames()` scans the system font folders.

- [ ] Test: a bundled-free test skips with a named reason when no font is installed; with DejaVu in the Docker image, "H" has the requested cap height and "o" has a counter wound opposite to its outside.
- [ ] Implement with stb_truetype: family, full and PostScript names; kerning from `kern` and GPOS.
- [ ] Note in `docs/PLATFORMS.md`: no ligatures, no complex script shaping, Mac fonts absent.
- [ ] Commit `feat(cad): text outlines off the Mac`.

### Task 6: Portable PDF

**Files:** Modify `Sources/CADCore/IO/PDFExporter.swift`, `PDFImporter.swift`. Create `Sources/CADCore/IO/PortablePDF.swift`.

- [ ] Test: the exported bytes parse and hold the expected paths.
- [ ] Write PDF export directly. Import is Mac-only unless a small parser proves enough; note it.
- [ ] Commit `feat(cad): PDF export off the Mac`.

### Task 7: UpdateCore off the Mac

**Files:** Modify `Sources/UpdateCore/UpdateSignature.swift`.

- [ ] swift-crypto and `_CryptoExtras` replace CryptoKit and Security off the Mac. The update tests pass on Linux.
- [ ] Commit `feat(update): signature checks off the Mac`.

### Task 8: Linux gate

**Files:** Create `scripts/check-samples-linux.sh`, `docs/PLATFORMS.md`.

- [ ] Run all cores' tests on Linux in Docker. Expected: pass, or each exception named in `docs/PLATFORMS.md`.
- [ ] Post all 48 sample programs on arm64 and amd64. Expected: byte-identical to `samples/expected`.
- [ ] Commit `test(linux): samples post byte for byte on Linux`.

### Task 9: Windows paths and CI

**Files:** Modify `.github/workflows/samples.yml`, `suggestedFileName`, tests using `mkfifo`. Create `scripts/check-samples.ps1`.

- [ ] Test: `CON`, `PRN`, `AUX`, `NUL`, `COM1`, `LPT1` get a safe name on every platform.
- [ ] Add Ubuntu and Windows CI jobs. They stay unverified here.
- [ ] Commit `ci: Linux and Windows jobs`.

### Task 10: The sidecar

**Files:** Create `Sources/loftline-core/`, `Sources/LoftLineKit/CoreService.swift`, tests.

**Interfaces:** One JSON request per line on stdin, one reply per line on stdout. Methods: `open`, `save`, `edit`, `calculate`, `toolpaths`, `export`, `posts`, `machines`, `tools`, `fonts`, `import`, `text`.

- [ ] Test: `export` returns the same bytes as `samples/expected` for the sign sample; a malformed request gets an error reply, not a crash.
- [ ] Implement over `LoftLineKit`.
- [ ] Commit `feat(core): loftline-core speaks JSON`.

### Task 11: The Tauri front end

**Files:** Create `desktop/`.

- [ ] Slices, in order: open a project, 2D view, toolpath list, calculate, export through the core, 3D preview, drawing, inspector, job setup, tools.
- [ ] Each slice has a headless Playwright screenshot in Docker, compared by eye with `scripts/ui.sh` on the Mac.
- [ ] Every difference goes in `docs/PLATFORMS.md`.
- [ ] One commit per slice, `feat(desktop): …`.

### Task 12: Docs and final review

- [ ] README, AGENTS.md, `docs/DECISIONS.md`, `THIRD_PARTY.md`, `TESTING.md` updated.
- [ ] Final `debate:run` on the branch against `main`; one fix pass.
