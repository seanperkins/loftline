import CADCore
import CAMCore
import Foundation
import PostCore

/// The deepest cut a G-code program makes, read back from the program text so the Export sheet
/// shows what is in the file (users of other CAM tools report toolpath summaries that disagree
/// with the G-code by a start depth, a wrong post or a different zero, and are told to open the
/// file and read the first plunge).
struct DeepestCut: Equatable {
    /// Machine Z of the lowest feed move, in the document's units.
    var machineZ: Double
    /// How far below the material top that is (through `MachineCoordinates`, so both Z-zero modes agree).
    var depthBelowTop: Double
    /// How far below the material bottom: positive cuts into the spoilboard, negative stops short.
    var belowBottom: Double

    /// The lowest non-rapid move in `gcode`, or nil when the program never cuts. `postUnits`: the units of the post that wrote
    /// it, assumed until the program states G20/G21 (a Syntec program states G70/G71, which the reader does not apply).
    /// `comments`: the post's (`PostProfile.parserComments`), so the program is read as the validator reads it.
    static func find(in gcode: String, job: JobSetup, units: LengthUnit, postUnits: LengthUnit? = nil,
                     comments: GCodeParser.Comments = .any) -> DeepestCut? {
        let coords = MachineCoordinates(job: job)
        let program = GCodeReader.read(gcode, units: units, assumedUnits: postUnits, startZ: coords.safeZ, comments: comments)
        var lowest: Double?
        for segment in program.segments {
            for move in segment.moves where !move.isRapid {
                guard let z = move.target?.z else { continue }
                if lowest == nil || z < lowest! { lowest = z }
            }
        }
        guard let z = lowest else { return nil }
        let depth = coords.depth(ofMachineZ: z)
        return DeepestCut(machineZ: z, depthBelowTop: depth, belowBottom: depth - job.thickness)
    }

    /// "Z -0.77 in (0.02 in below the material bottom)".
    func text(units: LengthUnit) -> String {
        func f(_ v: Double) -> String { DepthText.number(v) }
        let u = units.abbreviation
        let tolerance = units == .inch ? 0.0005 : 0.01
        let relative: String
        if belowBottom > tolerance {
            relative = "\(f(belowBottom)) \(u) below the material bottom"
        } else if belowBottom < -tolerance {
            relative = "\(f(-belowBottom)) \(u) above the material bottom"
        } else {
            relative = "at the material bottom"
        }
        return "Z \(f(machineZ)) \(u) (\(relative))"
    }
}
