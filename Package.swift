// swift-tools-version: 6.0
import PackageDescription

let swift5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

var products: [Product] = [
    .executable(name: "loftline-cli", targets: ["loftline-cli"]),
    .executable(name: "loftline-core", targets: ["loftline-core"]),
    .executable(name: "loftline-mcp", targets: ["loftline-mcp"]),
    .library(name: "CADCore", targets: ["CADCore"]),
    .library(name: "CAMCore", targets: ["CAMCore"]),
    .library(name: "PostCore", targets: ["PostCore"]),
    .library(name: "LoftLineKit", targets: ["LoftLineKit"]),
]

#if os(macOS)
let cadDependencies: [Target.Dependency] = ["CGeom"]
#else
let cadDependencies: [Target.Dependency] = ["CGeom", "CStb"]
#endif

// Apple Silicon fuses a multiply and an add in the C++ geometry code into one rounded step (FMA, clang's default contraction).
// x86-64 doesn't unless told to, and the difference moves a V-carve's medial axis: the sign sample differed by up to 0.007 in.
// With this, x86-64 posts the same bytes as the Mac. It needs a CPU with FMA (Haswell, 2013, or later), docs/PLATFORMS.md.
#if arch(x86_64)
let geometryFlags: [CXXSetting] = [.unsafeFlags(["-mfma", "-ffp-contract=on"])]
#else
let geometryFlags: [CXXSetting] = []
#endif

var targets: [Target] = [
    // Vendored Clipper2 (Boost Software License). Never edit — see THIRD_PARTY.md.
    .target(
        name: "Clipper2",
        path: "Vendor/Clipper2",
        exclude: ["LICENSE"],
        sources: ["src"],
        publicHeadersPath: "include",
        cxxSettings: [.unsafeFlags(["-w"])] + geometryFlags
    ),
    // C-compatible wrapper over Clipper2 + Boost.Polygon Voronoi.
    .target(
        name: "CGeom",
        dependencies: ["Clipper2"],
        path: "Sources/CGeom",
        cxxSettings: [
            .headerSearchPath("../../Vendor/Boost/include"),
            .headerSearchPath("../../Vendor/Clipper2/include"),
        ] + geometryFlags
    ),
    .target(name: "CADCore", dependencies: cadDependencies, swiftSettings: swift5),
    .target(name: "CAMCore", dependencies: ["CADCore", "CGeom"], swiftSettings: swift5),
    .target(name: "PostCore", dependencies: ["CADCore", "CAMCore"], swiftSettings: swift5),
    // Everything the app and the command line share that needs no window system.
    .target(name: "LoftLineKit", dependencies: ["CADCore", "CAMCore", "PostCore"], swiftSettings: swift5),
    // Update checking without AppKit: version comparison, the signed feed, signature verification, remembered state.
    .target(name: "UpdateCore", swiftSettings: swift5),
    .executableTarget(name: "loftline-cli", dependencies: ["LoftLineKit"], swiftSettings: swift5),
    // The desktop app's engine (desktop/): JSON over standard input and output.
    .executableTarget(name: "loftline-core", dependencies: ["LoftLineKit", "LoftLineMCP"], swiftSettings: swift5),
    // The MCP server for AI assistants: protocol, tools, allowed folders, the 2D picture (docs/superpowers/specs/2026-11-10-loftline-mcp-design.md).
    .target(name: "LoftLineMCP", dependencies: ["LoftLineKit", "CADCore", "CAMCore", "PostCore"], swiftSettings: swift5),
    .executableTarget(name: "loftline-mcp", dependencies: ["LoftLineMCP", "LoftLineKit"], swiftSettings: swift5),
    .testTarget(name: "UpdateCoreTests", dependencies: ["UpdateCore"], swiftSettings: swift5),
    .testTarget(name: "CGeomTests", dependencies: ["CGeom"], swiftSettings: swift5),
    .testTarget(name: "CADCoreTests", dependencies: ["CADCore"], swiftSettings: swift5),
    .testTarget(name: "CAMCoreTests", dependencies: ["CAMCore", "CADCore"], swiftSettings: swift5),
    .testTarget(name: "PostCoreTests", dependencies: ["PostCore", "CAMCore", "CADCore"], swiftSettings: swift5),
    .testTarget(name: "LoftLineKitTests", dependencies: ["LoftLineKit", "PostCore", "CAMCore", "CADCore"], swiftSettings: swift5),
    .testTarget(name: "LoftLineMCPTests", dependencies: ["LoftLineMCP", "LoftLineKit", "PostCore", "CAMCore", "CADCore"],
                swiftSettings: swift5),
]

#if os(macOS)
// The SwiftUI and AppKit app.
products.append(.executable(name: "LoftLine", targets: ["LoftLineApp"]))
targets += [
    .executableTarget(
        name: "LoftLineApp",
        dependencies: ["CADCore", "CAMCore", "LoftLineKit", "LoftLineMCP", "PostCore", "UpdateCore"],
        swiftSettings: swift5
    ),
    .testTarget(name: "LoftLineAppTests", dependencies: ["LoftLineApp", "LoftLineKit", "LoftLineMCP", "PostCore", "CAMCore", "CADCore", "UpdateCore"],
                swiftSettings: swift5),
]
#endif

#if !os(macOS)
// Images and fonts off the Mac, where ImageIO and CoreText are missing. Vendored stb (public domain) — see THIRD_PARTY.md.
targets.append(.target(name: "CStb", path: "Sources/CStb", cSettings: [.headerSearchPath("../../Vendor/stb")]))
#endif

let package = Package(
    name: "LoftLine",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    cxxLanguageStandard: .cxx17
)
