import Foundation

/// The vector formats File ▸ Export Vectors writes. The exporter picks the format from the file
/// extension, so the save panel's format menu works by rewriting the extension.
public enum VectorExportFormat: String, CaseIterable, Identifiable {
    case svg, dxf, pdf, eps, ai

    public var id: String { rawValue }
    public var fileExtension: String { rawValue }

    public var title: String {
        switch self {
        case .svg: return "SVG"
        case .dxf: return "DXF"
        case .pdf: return "PDF"
        case .eps: return "EPS"
        case .ai: return "Adobe Illustrator (AI)"
        }
    }

    public init?(fileName: String) {
        guard let ext = fileName.split(separator: ".").last.map({ String($0).lowercased() }),
              fileName.contains("."), let f = VectorExportFormat(rawValue: ext) else { return nil }
        self = f
    }

    /// `name` with its vector extension (if it has one) replaced by this format's.
    public func fileName(from name: String) -> String {
        let base = VectorExportFormat(fileName: name) != nil ? (name as NSString).deletingPathExtension : name
        return base + "." + fileExtension
    }
}
