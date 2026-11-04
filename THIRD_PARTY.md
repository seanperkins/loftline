# Third-party code

| Component | Version | Location | Licence |
|---|---|---|---|
| Clipper2 (Angus Johnson) | 1.5.4 (commit ef88ee97) — `CPP/Clipper2Lib` include + src | `Vendor/Clipper2/` | Boost Software License 1.0 (`Vendor/Clipper2/LICENSE`) |
| Boost.Polygon — Voronoi headers only (`voronoi_builder.hpp`, `voronoi_diagram.hpp`, `voronoi_geometry_type.hpp`, `detail/voronoi_*.hpp`) | Boost 1.86.0 | `Vendor/Boost/include/boost/polygon/` | Boost Software License 1.0 (`Vendor/Boost/LICENSE_1_0.txt`) |
| Boost.Config (`boost/config.hpp`, `boost/config/`, `boost/cstdint.hpp`, `boost/limits.hpp`) — required by the Voronoi headers | Boost 1.86.0 | `Vendor/Boost/include/boost/` | Boost Software License 1.0 |
| stb_image 2.30, stb_image_write 1.16, stb_truetype 1.26 (Sean Barrett; commit d14d46f6) | `Vendor/stb/`, built only off the Mac | Public domain or MIT |

Vendored files are unmodified. Do not edit them; wrap behaviour in `Sources/CGeom/`.

The desktop app (`desktop/`, Windows and Linux only) also uses, through npm and Cargo and not vendored: Tauri (MIT or Apache-2.0), three.js (MIT), and their
dependencies. `desktop/package-lock.json` and `desktop/src-tauri/Cargo.lock` pin them.
