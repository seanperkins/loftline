import LoftLineKit
import CADCore

/// `Shape` means the CAD vector shape throughout the app (SwiftUI also exports a `Shape`
/// protocol; module-level declarations win over imports).
typealias Shape = CADCore.Shape
/// Likewise for `Path` (SwiftUI.Path).
typealias Path = CADCore.Path
/// And `Document` (the macOS 27 SDK adds a SwiftUI.Document protocol).
typealias Document = CADCore.Document

/// `Measurement` is the app's (LoftLineKit), not Foundation's.
typealias Measurement = LoftLineKit.Measurement
