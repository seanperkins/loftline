import CADCore
import CAMCore
import Foundation
import Testing
@testable import PostCore

/// Coolant codes in the program: written only where the coolant changes, never two on at once, and off
/// before every tool change, pause and the program's end.
@Suite struct PostCoolantTests {
    func cut(_ name: String, tool: Tool = PostFixtures.endMill, from x: Double = 1, coolant: Coolant? = nil,
             pause: PauseStep? = nil, rpm: Double? = nil) -> Toolpath {
        let mc = MachineCoordinates(job: PostFixtures.job())
        let d = mc.z(depth: 0.1), safe = mc.safeZ
        var tp = Toolpath(name: name, kind: .profile, tool: tool, spindleRPM: rpm, moves: [
            .rapid(to: Vec3(x, 1, safe)),
            .linear(to: Vec3(x, 1, d), feed: 30),
            .linear(to: Vec3(x + 1, 1, d), feed: 100),
            .rapid(to: Vec3(x + 1, 1, safe)),
        ])
        tp.coolant = coolant
        tp.pauseAfter = pause
        return tp
    }

    func post(_ tps: [Toolpath]) throws -> [String] {
        let job = PostJob(name: "P", units: .inch, job: PostFixtures.job(), toolpaths: tps)
        return try TemplatePostProcessor(profile: BuiltInPosts.avidMach4Inch).post(job).split(separator: "\n").map(String.init)
    }

    func codes(_ lines: [String]) -> [String] { lines.filter { ["M7", "M8", "M9"].contains($0) } }

    @Test func codesOnlyWhereStateChanges() throws {
        let lines = try post([cut("A"), cut("B", from: 3, coolant: .mist), cut("C", from: 5, coolant: .mist),
                              cut("D", from: 7, coolant: .air)])
        // Off, then Mist once for B and C, then Air for D (Mist off first), then off before the footer.
        #expect(codes(lines) == ["M7", "M9", "M8", "M9"])
        let mist = try #require(lines.firstIndex(of: "M7"))
        let b = try #require(lines.firstIndex { $0.hasPrefix("( Toolpath: B") })
        #expect(mist < b)
    }

    @Test func mistToAirTurnsMistOffFirst() throws {
        let lines = try post([cut("A", coolant: .mist), cut("B", from: 3, coolant: .air)])
        let m7 = try #require(lines.firstIndex(of: "M7"))
        let m8 = try #require(lines.firstIndex(of: "M8"))
        let off = try #require(lines[m7...].firstIndex(of: "M9"))
        #expect(m7 < off && off < m8)
    }

    @Test func offBeforeToolChangePauseAndFooter() throws {
        let lines = try post([cut("A", coolant: .air, pause: PauseStep(message: "Look")), cut("B", from: 3, coolant: .air),
                              cut("C", tool: PostFixtures.vBit, from: 5, coolant: .air)])
        let stop = try #require(lines.firstIndex(of: "M0"))
        let change = try #require(lines.firstIndex { $0.hasPrefix("T") && $0.hasSuffix("M6") && lines.firstIndex(of: $0)! > stop })
        let end = try #require(lines.firstIndex(of: "M30"))
        for target in [stop, change, end] {
            let before = lines[..<target]
            let lastOn = before.lastIndex { $0 == "M8" }!
            #expect(before[lastOn...].contains("M9"), "coolant still on at line \(target)")
        }
    }

    @Test func toolpathAfterPauseTurnsItBackOn() throws {
        let lines = try post([cut("A", coolant: .mist, pause: PauseStep(message: "Look")), cut("B", from: 3, coolant: .mist)])
        #expect(codes(lines) == ["M7", "M9", "M7", "M9"])
    }

    @Test func coolantAfterSpindleStartWithoutRPMChange() throws {
        let lines = try post([cut("A"), cut("B", from: 3, coolant: .air)])
        #expect(lines.filter { $0.hasPrefix("M3 S") }.count == 1)
        let m8 = try #require(lines.firstIndex(of: "M8"))
        let b = try #require(lines.firstIndex { $0.hasPrefix("( Toolpath: B") })
        #expect(m8 < b)
    }

    @Test func coolantComesAfterTheSpindleStart() throws {
        let lines = try post([cut("A", coolant: .mist)])
        let m3 = try #require(lines.firstIndex { $0.hasPrefix("M3 S") })
        let m7 = try #require(lines.firstIndex(of: "M7"))
        #expect(m3 < m7)
    }

    @Test func allOffWritesNoCoolantCode() throws {
        let lines = try post([cut("A"), cut("B", from: 3, pause: nil), cut("C", tool: PostFixtures.vBit, from: 5)])
        #expect(codes(lines).isEmpty)
    }
}
