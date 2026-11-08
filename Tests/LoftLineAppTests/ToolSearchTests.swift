import CADCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The Tool Database's search box, and names made from a tool's geometry (issue #18).
@Suite struct ToolSearchTests {
    func tool(_ name: String, kind: ToolKind = .endMill, number: Int = 1, diameter: Double = 0.25, units: LengthUnit = .inch,
              flutes: Int = 2, angle: Double? = nil, tip: Double = 0, notes: String = "", group: String? = nil,
              materials: [String] = [], shape: CutterShape? = nil) -> Tool {
        Tool(name: name, kind: kind, units: units, number: number, diameter: diameter, flutes: flutes, angle: angle, tipDiameter: tip,
             stepdown: 0.1, stepover: 0.1, feedRate: 100, plungeRate: 30, notes: notes, group: group,
             materials: materials.isEmpty ? nil : materials.map { MaterialCuttingData(material: $0, spindleRPM: 18000, feedRate: 100, plungeRate: 30, stepdown: 0.1, stepover: 0.1) },
             shape: shape)
    }

    func found(_ query: String, in tools: [Tool]) -> [String] { ToolSearch.filter(tools, query: query).map(\.name) }

    @Test func anEmptyQueryKeepsEveryTool() {
        let tools = ToolLibrary.seeded.tools
        #expect(ToolSearch.filter(tools, query: "").count == tools.count)
        #expect(ToolSearch.filter(tools, query: "   ").count == tools.count)
    }

    @Test func wordsMatchTheNameTheDescriptionTheGroupTheTypeTheShapeAndTheMaterials() {
        let a = tool("Downcut spiral", notes: "Compression bit for plywood\nsecond line", group: "End Mills/Compression", materials: ["Birch plywood"])
        let b = tool("V 60", kind: .vBit, number: 2, angle: 60)
        let c = tool("Radius", number: 3, shape: .bullNose(cornerRadius: 0.05))
        let all = [a, b, c]
        #expect(found("downcut", in: all) == ["Downcut spiral"])
        #expect(found("DOWNCUT", in: all) == ["Downcut spiral"])
        #expect(found("plywood", in: all) == ["Downcut spiral"])                 // the description (all of it) and a material
        #expect(found("second", in: all) == ["Downcut spiral"])
        #expect(found("compression", in: all) == ["Downcut spiral"])             // the group
        #expect(found("v-bit", in: all) == ["V 60"])                              // the type
        #expect(found("bull", in: all) == ["Radius"])                             // the shape
        #expect(found("birch", in: all) == ["Downcut spiral"])
        #expect(found("zzz", in: all).isEmpty)
    }

    @Test func everyWordHasToMatchSomething() {
        let a = tool("Spiral", notes: "plywood"), b = tool("Spiral", number: 2, notes: "foam"), c = tool("Straight", number: 3, notes: "plywood")
        #expect(found("spiral plywood", in: [a, b, c]) == ["Spiral"])
        #expect(ToolSearch.filter([a, b, c], query: "spiral plywood").map(\.number) == [1])
        #expect(ToolSearch.filter([a, b, c], query: "plywood spiral").map(\.number) == [1])
    }

    @Test func theNumberMatchesWholeWithOrWithoutTheT() {
        let t3 = tool("A", number: 3), t30 = tool("B", number: 30), t4 = tool("C", number: 4, notes: "see T3")
        #expect(ToolSearch.filter([t3, t30], query: "3").map(\.name) == ["A"])             // not T30
        #expect(ToolSearch.filter([t3, t30], query: "T3").map(\.name) == ["A"])
        #expect(ToolSearch.filter([t3, t30, t4], query: "T3").map(\.name) == ["A", "C"])   // C names "T3" in its description
        #expect(ToolSearch.filter([t3, t30, t4], query: "t30").map(\.name) == ["B"])
    }

    @Test func theDiameterMatchesAsADecimalAFractionOrWithAUnit() {
        let quarter = tool("A", number: 1, diameter: 0.25), eighth = tool("B", number: 2, diameter: 0.125)
        let six = tool("C", number: 3, diameter: 6, units: .millimeter), inchInMM = tool("D", number: 4, diameter: 6.35, units: .millimeter)
        let all = [quarter, eighth, six, inchInMM]
        #expect(found("0.25", in: all) == ["A"] && found(".25", in: all) == ["A"])
        #expect(found("1/4", in: all) == ["A"] && found("1/4in", in: all) == ["A", "D"])    // D is a 1/4 in bit in millimetres
        #expect(found("1/4\"", in: all) == ["A", "D"])
        #expect(found("1/8", in: all) == ["B"])
        #expect(found("6mm", in: all) == ["C"] && found("6", in: all) == ["C"])             // bare: the tool's own units
        #expect(found("6.35mm", in: all) == ["A", "D"])                                       // A is 0.25 in, which is 6.35 mm
        #expect(found("0.126", in: all).isEmpty)
    }

    @Test func theAngleMatchesForAngledBits() {
        let v = tool("V", kind: .vBit, number: 11, angle: 60), e = tool("Engraver", kind: .engraving, number: 12, angle: 30, tip: 0.01)
        #expect(found("60", in: [v, e]) == ["V"] && found("60°", in: [v, e]) == ["V"] && found("30°", in: [v, e]) == ["Engraver"])
    }

    @Test func descriptionsAndPickerLabelsUseTheFirstLineOfTheNotes() {
        #expect(ToolSearch.description(of: tool("A", notes: "\n  Roughing, upcut \nsecond")) == "Roughing, upcut")
        #expect(ToolSearch.description(of: tool("A", notes: " \n ")) == nil)
        #expect(ToolSearch.pickerLabel(tool("A", number: 3)) == "T3 · A")
        #expect(ToolSearch.pickerLabel(tool("A", number: 3, notes: "Roughing")) == "T3 · A — Roughing")
        let long = tool("A", notes: String(repeating: "x", count: 60))
        #expect(ToolSearch.pickerLabel(long).hasSuffix("…") && ToolSearch.pickerLabel(long).count == "T1 · A — ".count + 40)
    }

    @Test func namesComeFromTheGeometry() {
        #expect(ToolNaming.name(for: tool("")) == "1/4 in 2-flute end mill")
        #expect(ToolNaming.name(for: tool("", diameter: 0.375, flutes: 3)) == "3/8 in 3-flute end mill")
        #expect(ToolNaming.name(for: tool("", diameter: 1.25, flutes: 1)) == "1 1/4 in 1-flute end mill")
        #expect(ToolNaming.name(for: tool("", diameter: 0.3, flutes: 2)) == "0.3 in 2-flute end mill")
        #expect(ToolNaming.name(for: tool("", diameter: 6, units: .millimeter)) == "6 mm 2-flute end mill")
        #expect(ToolNaming.name(for: tool("", diameter: 3.175, units: .millimeter)) == "3.175 mm 2-flute end mill")
        #expect(ToolNaming.name(for: tool("", kind: .ballNose, diameter: 0.125)) == "1/8 in 2-flute ball nose")
        #expect(ToolNaming.name(for: tool("", kind: .vBit, diameter: 0.5, angle: 60)) == "60° V-bit 1/2 in")
        #expect(ToolNaming.name(for: tool("", kind: .vBit, diameter: 0.5)) == "V-bit 1/2 in")
        #expect(ToolNaming.name(for: tool("", kind: .engraving, diameter: 0.125, angle: 30, tip: 0.01)) == "30° engraving bit 0.01 in tip")
        #expect(ToolNaming.name(for: tool("", kind: .drill, diameter: 0.25)) == "1/4 in drill")
        #expect(ToolNaming.name(for: tool("", diameter: 0.25, shape: .bullNose(cornerRadius: 0.05))) == "1/4 in 2-flute bull nose end mill")
        #expect(ToolNaming.name(for: tool("", kind: .ballNose, diameter: 0.25, shape: .taperedBallNose(tipRadius: 0.02, halfAngle: 5))) == "1/4 in tapered ball nose")
    }

    @Test func aHugeOrOddDiameterIsNamedAsADecimalWithoutTrapping() {
        // An imported file can carry any number; the fraction search must stay inside Int.
        for d in [2e17, 1e12 / 64, 1e30, 0.0, -0.25, Double.nan, Double.infinity] {
            let name = ToolNaming.name(for: tool("", diameter: d))
            #expect(name.hasSuffix("2-flute end mill"), "\(d): \(name)")
        }
        #expect(ToolNaming.name(for: tool("", diameter: 2e17)).hasPrefix("200000000000000000 in"))
        #expect(ToolNaming.length(1.0 / 64, in: .inch) == "1/64 in" && ToolNaming.length(0, in: .inch) == "0 in")
    }

    @Test func aToolWithoutANameIsNamedWhenItIsSaved() throws {
        let lib = AppTestSupport.library()
        var t = try #require(lib.tools.first)
        let original = t.name
        t.name = "   "
        lib.update(t)
        #expect(lib.library.tool(id: t.id)?.name == ToolNaming.name(for: t))
        #expect(lib.library.tool(id: t.id)?.name != original)
        // An import of a nameless tool is named too, and a named one is left alone.
        var nameless = tool("", diameter: 0.5), named = tool("Mine", number: 20)
        nameless.id = UUID(); named.id = UUID()
        lib.importTools([nameless, named])
        #expect(lib.library.tool(id: nameless.id)?.name == "1/2 in 2-flute end mill")
        #expect(lib.library.tool(id: named.id)?.name == "Mine")
    }

    @Test func aToolsJSONWithoutAnyOfThisStillDecodes() throws {
        // The notes already existed and no field was added: a saved library of the earlier shape decodes as it was.
        let data = try JSONEncoder().encode(ToolLibrary.seeded)
        let back = try JSONDecoder().decode(ToolLibrary.self, from: data)
        #expect(back == ToolLibrary.seeded)
    }
}
