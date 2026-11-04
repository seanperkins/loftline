import CADCore
import CAMCore
import SwiftUI
import LoftLineKit

/// Design > Layout > Clamps and Fixture Holes…
struct FixturesSheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case clamps = "Clamps", holes = "Fixture holes"
        var id: String { rawValue }
    }

    @ObservedObject var document: LoftLineDocument
    @Environment(\.dismiss) private var dismiss
    @State private var mode: Mode = .clamps
    @State private var clamps: ClampOptions
    @State private var holes: HoleOptions

    init(document: LoftLineDocument) {
        self.document = document
        _clamps = State(initialValue: ClampOptions.defaults(for: document.units))
        _holes = State(initialValue: HoleOptions.defaults(for: document.units))
    }

    var body: some View {
        let u = document.units
        VStack(alignment: .leading, spacing: 12) {
            Text("Clamps and Fixture Holes").font(.title3.bold())
            Picker("", selection: $mode) { ForEach(Mode.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            switch mode {
            case .clamps:
                Text("Clamp footprints go on the \"Clamps\" keep-out layer. Toolpaths that enter them, or rapid over "
                     + "them below the clamp height, are errors; nesting keeps parts clear of them.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Form {
                    IntField("Clamps on left and right edges", value: $clamps.perSideEdge, range: 0...20)
                    IntField("Clamps on bottom and top edges", value: $clamps.perEndEdge, range: 0...20)
                    LengthField("Clamp length (along the edge)", value: $clamps.length, units: u)
                    LengthField("Reach onto the material", value: $clamps.reach, units: u)
                    LengthField("Overhang outside the material", value: $clamps.outside, units: u)
                    LengthField("End clamps from the corners", value: $clamps.endInset, units: u)
                    LengthField("Clamp height above the material", value: $clamps.height, units: u,
                                help: "Rapids must stay above this; raise safe Z in Job Setup if needed")
                }
            case .holes:
                Text("A grid of holes over the material: screws holding the work down (keep-out zones), or holes "
                     + "to drill, e.g. for dowels.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Form {
                    Picker("Holes are", selection: $holes.keepOut) {
                        Text("Screws to keep clear of").tag(true)
                        Text("Holes to drill").tag(false)
                    }
                    LengthField(holes.keepOut ? "Keep-out diameter" : "Hole diameter", value: $holes.diameter, units: u)
                    LengthField("Spacing X", value: $holes.spacingX, units: u)
                    LengthField("Spacing Y", value: $holes.spacingY, units: u)
                    LengthField("Inset from the edges", value: $holes.inset, units: u)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func add() {
        var ids: [UUID] = []
        switch mode {
        case .clamps:
            let o = clamps
            document.perform("Add Clamps") { ids = FixtureCommands.addClamps(o, in: &$0) }
        case .holes:
            let o = holes
            document.perform("Add Fixture Holes") { ids = FixtureCommands.addHoles(o, in: &$0) }
        }
        if !ids.isEmpty { document.setSelection(ids) }
        dismiss()
    }
}
