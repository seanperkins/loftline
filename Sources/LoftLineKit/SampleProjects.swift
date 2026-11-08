import Foundation

/// Sample files shipped in LoftLine.app/Contents/Resources/samples (copied by scripts/bundle.sh).
/// When running unbundled (swift run), the repository's samples/ folder is used instead.
public enum SampleProjects {
    public struct Sample: Identifiable, Equatable {
        public var id: String { fileName }
        public var fileName: String
        public var title: String
        public var detail: String
        /// Opens as a document (.loftline); otherwise it is imported into a new document.
        public var isProject: Bool { fileName.hasSuffix(".loftline") }
    }

    public static let sign = Sample(fileName: "sign.loftline", title: "Sign",
                             detail: "24 x 12 in sign with pocket, V-carve, drilling and profile toolpaths ready to calculate")
    public static let all: [Sample] = [
        sign,
        Sample(fileName: "bracket-plate.dxf", title: "Bracket plate (DXF)",
               detail: "8 x 5 in plate with bolt holes, a slot and a bore, to practice profiles and drilling"),
        Sample(fileName: "relief.stl", title: "Relief model (STL)",
               detail: "75 mm square relief for the 3D roughing and finishing toolpaths"),
    ]

    /// Folders searched in order: the app bundle's samples, then the source checkout's.
    public static func searchDirectories(bundle: Bundle = .main, sourceFile: String = #filePath) -> [URL] {
        var dirs: [URL] = []
        if let res = bundle.resourceURL { dirs.append(res.appendingPathComponent("samples", isDirectory: true)) }
        // Sources/LoftLineApp/Model/SampleProjects.swift → repository root.
        let repo = URL(fileURLWithPath: sourceFile).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        dirs.append(repo.appendingPathComponent("samples", isDirectory: true))
        return dirs
    }

    public static func url(for sample: Sample, in dirs: [URL] = searchDirectories()) -> URL? {
        dirs.map { $0.appendingPathComponent(sample.fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The quick-start steps shown on the Welcome window.
    public static let quickStart: [(title: String, detail: String)] = [
        ("Set up the job", "Material size, thickness, XY origin and Z zero (Design ▸ Job Setup, ⇧⌘J)."),
        ("Pick the machine", "Choose the machine and post processor in Job Setup too."),
        ("Draw or import vectors", "Use the tool palette, or File ▸ Import… for SVG, DXF, EPS and STL."),
        ("Add toolpaths", "Select vectors, then Toolpaths ▸ New Toolpath, and set the tool and depths."),
        ("Calculate and preview", "Calculate All (⌘R), then check the 2D overlay and the 3D preview."),
        ("Check and export", "Check Toolpaths (⇧⌘K), Export G-code (⇧⌘E), and air-cut before the real cut."),
    ]
}
