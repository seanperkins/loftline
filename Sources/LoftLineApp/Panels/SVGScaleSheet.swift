import CADCore
import SwiftUI
import LoftLineKit

/// "Scale of file.svg": shown when an SVG does not state its size, so its units have to be read as pixels
/// at some number per inch. The scale the file's program is known to use is selected, and the size the
/// drawing comes out at is shown for the choice.
struct SVGScaleSheet: View {
    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    let request: SVGScaleRequest
    @State private var pixelsPerInch: Double
    /// The drawing's size at each choice, measured once when the sheet opens; nil while that runs.
    @State private var sizes: [Double: Vec2]?

    init(document: LoftLineDocument, request: SVGScaleRequest) {
        self.document = document
        self.request = request
        _pixelsPerInch = State(initialValue: request.guess.pixelsPerInch)
    }

    private var why: String {
        if let program = request.guess.generator {
            return "It looks like it came from \(program), which draws at \(Int(request.guess.pixelsPerInch)) pixels per inch, so that is selected."
        }
        return "Nothing in the file says which program wrote it, so 96, the web default, is selected."
    }

    private var sizeText: String {
        guard let sizes else { return "Measuring…" }
        guard let size = sizes[pixelsPerInch] else { return "The size could not be measured: the file holds no vectors or could not be read." }
        // In the units the sizes were measured in: the document's may have changed while the sheet waited.
        let u = request.units.abbreviation
        return "Comes in \(RulerTicks.label((size.x * 1000).rounded() / 1000)) × \(RulerTicks.label((size.y * 1000).rounded() / 1000)) \(u)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scale of \(request.fileName)").font(.title2.bold())
            Text("This SVG does not say how big it is, so its units are read as pixels at some number per inch. \(why)")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Pixels per inch", selection: $pixelsPerInch) {
                ForEach(SVGScaleRequest.choices, id: \.self) { Text("\(Int($0))").tag($0) }
            }
            .pickerStyle(.segmented)
            Text(sizeText).font(.body.monospacedDigit())
            Text("72: Adobe Illustrator. 90: Inkscape 0.91 and older. 96: Inkscape 0.92 and newer, browsers and most other programs.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    document.importSVG(request, pixelsPerInch: pixelsPerInch)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .task {
            let request = request
            sizes = await Task.detached { request.drawingSizes() }.value
        }
    }
}
