# LoftLine on Windows and Linux: design

Status: Sean's instruction of 2026-11-03: "get this running on windows and linux. We had a plan for that, work through it on
a windows and linux branch. No questions, match what we have as close as possible and make notes when something doesn't
match."

The plan is the answer given on 2026-11-02 (session b51e6c6e, "if we wanted to run this on windows and linux, what changes
would you make?" and "would rust be a good option?"). Its content is kept here because it existed only in that conversation.
Differences from today's code are marked as rulings.

## Goal

The Mac app's work runs on Windows and Linux: the same projects, the same toolpaths, and byte for byte the same G-code. Where
something can't match, `docs/PLATFORMS.md` says so.

## What ports and what doesn't (checked against main 74608d7)

| Module | Blocks a port |
|---|---|
| `CGeom` (C++17, Clipper2, Boost Voronoi) | Nothing |
| `PostCore` | Nothing |
| `CAMCore` | `PhotoImageLoader` (ImageIO) |
| `CADCore` | 7 files: text outlines and kerning (CoreText, CoreGraphics), PDF import and export (CoreGraphics), bitmap tracing and raster codec (ImageIO, UniformTypeIdentifiers) |
| `UpdateCore` | `UpdateSignature` (CryptoKit, Security); the update helper is Mac-only |
| `LoftLineApp` | SwiftUI and AppKit throughout, SceneKit and Metal for the 3D preview. The CLI lives in this target too |

## Steps

1. **`LoftLineKit` library.** The exporter, validation report, preflight checks, job sheet, project persistence and the CLI
   move out of `LoftLineApp`. `loftline-cli` becomes its own executable target with no AppKit dependency. This is the gate for
   everything else.
2. **Mac-only services in CADCore get a portable implementation.** The Mac keeps its implementation unchanged.
   - Text outlines: FreeType plus HarfBuzz was the plan; see the ruling below.
   - Images: vendored `stb_image`, in the `CGeom` pattern.
   - PDF: export written directly, since it is only vector paths. Import uses PDFium, or stays Mac-only; see the ruling below.
3. **UpdateCore:** `swift-crypto` replaces CryptoKit, with the same API; see the ruling below. The signed feed carries over. The install step is per
   platform.
4. **Build and CI:** Ubuntu and Windows jobs run `swift build` and `swift test`. Scripts get a cross-platform path. `Darwin`
   imports are guarded.
5. **Windows file-system details:** case-insensitive paths, reserved file names (`CON`, `PRN`) in `suggestedFileName`, tests
   that use `mkfifo`. CRLF was on the original list and already shipped (#99 item 4, `4ad13b4`).
6. **The GUI:** a cross-platform front end over the Swift core as a sidecar process that speaks JSON: a project in; toolpaths,
   issues and G-code out. Rust for the shell (Tauri or egui plus wgpu). The Mac app stays native. The CAM core is not rewritten.

## Rules

- **G-code comes only from the Swift core**, through the existing posts and `GCodeValidator`. The front end never builds program
  text. This is the reason for a sidecar.
- **The 48 programs in `samples/expected` must post byte for byte on Linux and Windows.** A difference is a bug or a note in
  `docs/PLATFORMS.md`. It is never a regenerated golden.
- **The Mac app doesn't change.** Its services stay on CoreText, ImageIO and CryptoKit, behind `#if canImport(...)`.
- **The Mac build stays SwiftPM-only** with Command Line Tools (AGENTS.md). The front end lives in its own directory
  (`desktop/`) and `scripts/build.sh` never touches it.

## Rulings

Decisions taken without asking, as instructed. Each says what it costs if wrong.

- **One branch, `feat/windows-linux`.** Almost all the work is shared. Cost if wrong: splitting it later by path.
- **The GUI shell is Tauri with a web front end, not egui.** The instruction is to match the Mac app as closely as possible.
  HTML and CSS can reproduce its layout, and egui's own look cannot. A web UI can also be screenshotted headless in Docker, the
  way `scripts/ui.sh` checks the Mac UI. Cost if wrong: the Rust shell is thin, so most of the cost is in the web UI.
- **Windows can't be run here.** No local VM, `desktop-apgpe0g` is offline, and GitHub Actions needs a push, which waits for Sean.
  Windows code and a CI job are written but stay marked unverified until that CI runs. Cost if wrong: Windows-only fixes after
  the first CI run.
- **stb, no swift-crypto, and a PDF reader in Swift.** stb_truetype replaced FreeType and HarfBuzz. swift-crypto's RSA can't verify from the hex digest
  the update feed carries, so SHA-256 and RSA verification are written out and tested against OpenSSL. PDF import is a reader in Swift rather than PDFium
  or Mac-only, so Mac projects' PDF workflows carry over (`docs/DECISIONS.md`, portable-services and portable-pdf). Cost if wrong: maintaining both.
- **Only Docker is used for Linux.** `bitwarden` and `el-duro-1` run other workloads and aren't build hosts.
