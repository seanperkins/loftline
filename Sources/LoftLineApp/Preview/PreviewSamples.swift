// Hand-built demo toolpaths for exercising the preview without the CAM generators.
import CADCore
import CAMCore
import Foundation
import LoftLineKit

enum PreviewSamples {
    /// 12 x 8 x 0.75 in job with a raster pocket, a circular profile, a V-bit zigzag and a
    /// ball-nose groove.
    static func demo(zZero: ZZeroMode = .materialTop) -> (Document, [Toolpath]) {
        var doc = Document()
        doc.job = JobSetup(width: 12, height: 8, thickness: 0.75, xyOrigin: .lowerLeft, zZero: zZero)
        let c = MachineCoordinates(job: doc.job)
        let lib = ToolLibrary.seeded.tools
        let endMill = lib.first { $0.kind == .endMill } ?? lib[0]
        let vbit = lib.first { $0.kind == .vBit } ?? lib[0]
        let ball = lib.first { $0.kind == .ballNose } ?? lib[0]

        // Raster pocket 1..5 x 1..5, two passes.
        var pocket: [Move] = [.rapid(to: c.machineAtSafeZ(Vec2(1.15, 1.15)))]
        for depth in [0.125, 0.25] {
            pocket.append(.linear(to: c.machine(Vec2(1.15, 1.15), depth: depth), feed: endMill.plungeRate))
            var y = 1.15, forward = true
            while y <= 4.85 + 1e-9 {
                let x = forward ? 4.85 : 1.15
                pocket.append(.linear(to: c.machine(Vec2(forward ? 1.15 : 4.85, y), depth: depth), feed: endMill.feedRate))
                pocket.append(.linear(to: c.machine(Vec2(x, y), depth: depth), feed: endMill.feedRate))
                y += endMill.diameter * 0.4
                forward.toggle()
            }
            pocket.append(.rapid(to: c.machineAtSafeZ(Vec2(1.15, 1.15))))
        }

        // Circle profile r = 1.5 around (8.5, 4), three helical passes.
        let center = c.machineXY(Vec2(8.5, 4))
        var profile: [Move] = [.rapid(to: c.machineAtSafeZ(Vec2(10, 4)))]
        profile.append(.linear(to: c.machine(Vec2(10, 4), depth: 0), feed: endMill.plungeRate))
        for depth in [0.15, 0.3, 0.45] {
            profile.append(.arcCCW(to: c.machine(Vec2(10, 4), depth: depth), center: center, feed: endMill.feedRate))
        }
        profile.append(.arcCCW(to: c.machine(Vec2(10, 4), depth: 0.45), center: center, feed: endMill.feedRate))
        profile.append(.rapid(to: c.machineAtSafeZ(Vec2(10, 4))))

        // V-bit zigzag with varying depth along y = 6.8.
        var vcarve: [Move] = [.rapid(to: c.machineAtSafeZ(Vec2(1, 6.8)))]
        for k in 0...20 {
            let x = 1 + Double(k) * 0.5
            let y = k % 2 == 0 ? 6.4 : 7.2
            let depth = 0.05 + 0.15 * Double(k) / 20
            vcarve.append(.linear(to: c.machine(Vec2(x, y), depth: depth), feed: vbit.feedRate))
        }
        vcarve.append(.rapid(to: c.machineAtSafeZ(Vec2(11, 7.2))))

        // Ball-nose ramped groove.
        let groove: [Move] = [
            .rapid(to: c.machineAtSafeZ(Vec2(1, 0.5))),
            .linear(to: c.machine(Vec2(1, 0.5), depth: 0), feed: ball.plungeRate),
            .linear(to: c.machine(Vec2(11, 0.5), depth: 0.2), feed: ball.feedRate),
            .rapid(to: c.machineAtSafeZ(Vec2(11, 0.5))),
        ]

        let tps = [
            Toolpath(name: "Pocket", kind: .pocket, tool: endMill, moves: pocket),
            Toolpath(name: "Profile", kind: .profile, tool: endMill, moves: profile),
            Toolpath(name: "V-Carve", kind: .vcarve, tool: vbit, moves: vcarve),
            Toolpath(name: "Groove", kind: .fluting, tool: ball, moves: groove),
        ]
        return (doc, tps)
    }
}
