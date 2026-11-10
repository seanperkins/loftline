# LoftLine on Windows and Linux: what matches and what doesn't

The Mac app is the reference. This file lists every known difference, and how far each platform has been checked.
Plan and rulings: `docs/specs/2026-11-03-windows-linux-design.md`. Status as of branch `feat/windows-linux`.

## How far each platform is checked

| Check | Mac | Linux arm64 | Linux x86-64 | Windows x86-64 |
|---|---|---|---|---|
| Cores and CLI build | yes | yes | yes | yes, in CI |
| Test suites (cores, kit, updates) | yes | yes | yes | yes, in CI, without the update signature tests |
| 48 sample programs byte for byte (`samples/expected`) | yes | yes | yes | yes, in CI |
| Desktop app builds | native app | yes | yes, in CI | yes, in CI |
| Desktop app opens a project | native app | yes, in Docker under Xvfb | **not run** | **not run** |
| Desktop end-to-end test (`desktop/tools/e2e.mjs`) | yes, in Chromium | yes, in Chromium | **not run** | **not run** |

**Save All on Windows works by path.** The Mac and Linux hold the folder open while they save, so a folder swapped mid-save can't redirect the files. Windows remembers which folder it opened and checks before every file operation, so a swap stops the save and the swapped-in folder is left alone. A swap in the instant between a check and its operation isn't caught, so save to folders you control.

**Windows has only run in CI.** There's no Windows machine or VM here, so `.github/workflows/platforms.yml` on GitHub's `windows-2022` runner is the
whole of the evidence. The desktop installer is built there but has never been opened or installed. The update signature tests are left out on Windows
because they run zsh scripts and OpenSSL, so its own SHA-256 and RSA code is unchecked there; in-app update isn't wired up, so nothing relies on it yet.

**Don't cut with a Windows or Linux build until** its samples check has passed on that machine, and the air cut in `TESTING.md` is done.

## G-code

| Item | Status |
|---|---|
| Program bytes | Identical in all 48 samples on Linux arm64, Linux x86-64 and Windows x86-64. Windows on Arm hasn't been checked. |
| x86-64 CPUs | Need FMA (Intel Haswell 2013, AMD Piledriver 2012, or later). Without it the geometry code crashes on an illegal instruction. |
| Why x86-64 needs `-mfma` | Apple Silicon fuses a multiply and an add in the C++ geometry code; x86-64 doesn't unless told to. Without it the sign's V-carve differed by up to 0.007 in. |
| Projects that hold live text | Stored outlines are used as they are, so opening and posting never changes the cut. Editing the text re-outlines it with a font on this computer. |

## The core

| Mac | Windows and Linux | Effect |
|---|---|---|
| CoreText text outlines | stb_truetype | No ligatures, no complex script shaping (Arabic, Devanagari…), no fallback to another font for a missing character. Kerning comes from the font's tables, so text spacing can differ slightly. |
| Mac system fonts (Helvetica…) | The fonts installed there. New text defaults to Liberation Sans or Arial | Editing a Mac project's Helvetica text on Linux reports the font as missing. Choose another; the shapes change. |
| ImageIO: PNG, JPEG, BMP, TIFF, GIF, WebP, HEIC | stb_image: PNG, JPEG, BMP, GIF | TIFF, WebP and HEIC can't be imported. |
| ImageIO reads a JPEG's size from JFIF or Exif | JFIF only | A camera JPEG with its density only in Exif has no stated size, so it can import at a different size. |
| Core Graphics grey conversion | Rec. 709 weights | Bitmap trace and PhotoVCarve can differ by a few grey levels, so those toolpaths may not be byte-identical to the Mac's. |
| Core Graphics PDF import | `PortablePDF.swift`, checked against Core Graphics on a file it wrote | JPEG 2000, LZW and CCITT streams and non-8-bit images are skipped. Encrypted files are refused, as on the Mac. |
| Core Graphics PDF export | Written directly | Same operators. The bytes differ. |
| CMYK images in PDFs | Plain formula | Colours differ from the Mac's colour-managed result. |
| Trash | A hidden `.trash` folder beside the file | A deleted post isn't in the system Recycle Bin or Trash. |
| Save All file operations | Linux: hard link, then unlink (`renameat2` isn't exported). Windows: `MoveFileEx` by path | On Windows a folder renamed mid-save isn't followed: the save fails and rolls back. |
| Update signature check | Own SHA-256 and RSA, tested against OpenSSL signatures | Behaves the same. In-app update isn't wired up (below). |

## The desktop app against the Mac app

Built on Tauri and web technology over `loftline-core`, so it looks like the Mac app but isn't native. It has no SwiftUI or AppKit behaviour by
inheritance, and each item below is one that hasn't been rebuilt yet.

**Done:** open, save, new; 2D view with rulers, grid, pan and zoom; select, move; rectangle, rounded rectangle, circle, ellipse, polygon, star, polyline
and text tools; layers; position and size; undo and redo; the Design menu's align, distribute, group, combine, boolean, offset, join, close, fillet,
chamfer, rotate, mirror and array commands; copy and paste; toolpath list, new toolpath, reorder, enable, calculate; forms for Profile, Pocket,
Drilling and V-Carve; the 3D material-removal preview with playback; Export G-code; Save All; Check Toolpaths; Job Setup; Tool Database; Job Sheet;
Help; Connect an AI Assistant… (the MCP server `loftline-mcp` ships beside `loftline-core` and works the same on all three); light and dark.

**Different on purpose**

| Mac | Here | Why |
|---|---|---|
| System menu bar | Menu bar in the window | Normal on Windows and Linux. |
| ⌘ shortcuts | Ctrl shortcuts | Same. |
| Traffic-light title bar, toolbar in it | Native title bar, toolbar below | Same. |
| SF Symbols icons | Drawn line icons | SF Symbols are Mac-only. |
| SceneKit | three.js, same mesh from the core | Lighting differs a little. Needs WebGL, and says so without it. |
| Several document windows | One project per window | One core process per window, and one window so far. |

**Partly done**

| Feature | What's missing |
|---|---|
| Other toolpath forms (Engrave, Chamfer, Hole Milling, Prism, Facing, Fluting, Texture, Moulding, 3D Relief) | A plain list of the core's number and on/off settings, with labels from their keys. Enums and nested settings can't be edited yet. All of them calculate and post correctly from a file made on the Mac. |
| Profile form | Tab placement on the canvas, lead in/out, last pass, order, sharp corners. |
| Pocket form | Clearance tools, raster angle and profile pass. |
| Tool Database | Editing the common fields. No add, delete, import, feeds calculator or per-material data. |
| Job Setup | The main fields. No two-sided, multi-sheet, variables or touch-off settings. Those settings a project already has are kept and convert with its units. |
| Two-sided jobs | View > Show Bottom Side picks the side that shows in 2D and posts, as on the Mac, and the status bar and Export say which. A job can't be made two-sided here, and the layer and toolpath lists show both sides. |
| Multiple sheets | A Mac project with several sheets posts the sheet it was saved on, and the status bar and Export name it. There's no way to change sheet, and the 2D view draws every sheet's vectors. |
| SVG import | An SVG with no stated size imports at the guessed scale. The Mac asks. |
| 3D preview | No material choice, camera images, measuring or per-toolpath scope. |
| Check Toolpaths | The list and the validator's findings. No clickable lines into a G-code view. |

**Not built yet.** Their data still round-trips, and the checks still run: a project with keep-out zones is still checked on export.

- **Editing:** node editing, trim, extend, guides, snapping to objects, dimensions and measuring, kerning on the canvas, text on a curve, envelope distort, vector texture, trace bitmap, fit curves, dog-bones, straight inlay offsets, validate vectors.
- **Layout:** nesting, multiple sheets, part labels, production plates, clamps and fixture holes, keep-out zone editor, tiling. The job sheet lists and draws
  every clamp and screw, as on the Mac, but the canvas doesn't name them and the 3D preview doesn't show them.
- **Toolpaths:** merge, toolpath templates, inlay wizard, G-code preview pane, time estimate settings.
- **Files:** recovery after a crash, clipart browser, gadgets (JavaScriptCore), 3D model placement and parts import, Print, thumbnails, job notes, document variables and `=` expressions in fields.
- **App:** Preferences, Machines and Post Processors editors, welcome window, in-app updates. The Tauri updater would do the install step, and the signed feed format carries over.
- **Accessibility:** the Mac's VoiceOver names exist only as ARIA labels on the main controls. Not tested with a screen reader.
- **Command line:** complete, the same `loftline-cli` as the Mac's.
