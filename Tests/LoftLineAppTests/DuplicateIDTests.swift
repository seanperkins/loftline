import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Issue #123: every item in a project is found by id, so two items on one id post whichever comes first. The app no
/// longer writes two operations on one id, repairs files that have them, and refuses any other clash.
@Suite struct DuplicateIDTests {
    static let endMill = ToolLibrary.seeded.tools[0]

    static func profile(_ name: String, depth: Double, enabled: Bool = true, id: UUID = UUID(), shapes: [UUID]) -> AnyOperation {
        var setup = OperationSetup(name: name, toolID: endMill.id, shapeIDs: shapes)
        setup.id = id
        setup.isEnabled = enabled
        return .profile(ProfileOperation(setup: setup, params: ProfileParameters(depth: DepthSettings(cutDepth: depth))))
    }

    static func ids(_ ops: [AnyOperation]) -> [UUID] {
        ops.flatMap { op -> [UUID] in
            if case .merge(let m) = op { return [op.id] + ids(m.params.children) }
            return [op.id]
        }
    }

    // MARK: The repair

    @Test func aRepeatedOperationIDGetsANewOneAndTheFirstKeepsIt() {
        let shared = UUID()
        let a = Self.profile("A", depth: 0.1, id: shared, shapes: []), b = Self.profile("B", depth: 0.1, shapes: [])
        let a2 = Self.profile("A copy", depth: 0.1, id: shared, shapes: [])
        let third = Self.profile("A again", depth: 0.1, id: shared, shapes: [])
        let fixed = [a, b, a2, third].givingRepeatedIDsNewOnes()
        #expect(fixed[0].id == shared && fixed[1].id == b.id)
        #expect(Set(fixed.map { $0.id }).count == 4)
    }

    /// A merge child and a later top-level operation on one id (merge, duplicate, split the duplicate): the top-level one
    /// keeps the id, so a formula linked to it still finds it.
    @Test func aTopLevelOperationKeepsItsIDOverAMergeChild() throws {
        let shared = UUID()
        let child = Self.profile("A", depth: 0.1, id: shared, shapes: [])
        let merge = try #require(MergeOperation.merging([child, Self.profile("B", depth: 0.1, shapes: [])], name: "M"))
        let topLevel = Self.profile("A′", depth: 0.1, id: shared, shapes: [])
        let fixed = [AnyOperation.merge(merge), topLevel].givingRepeatedIDsNewOnes()
        #expect(fixed[1].id == shared)
        #expect(Set(Self.ids(fixed)).count == 4)
    }

    // MARK: The app never writes a clash

    func twoProfiles() -> LoftLineProject {
        var p = AppTestSupport.project()
        let shapes = p.document.shapes.map(\.id)
        p.operations = [Self.profile("A", depth: 0.1, shapes: shapes), Self.profile("B", depth: 0.1, shapes: shapes)]
        return p
    }

    @MainActor
    @Test func duplicatingAMergeThenSplittingBothKeepsIDsUnique() throws {
        let doc = LoftLineDocument(project: twoProfiles(), toolLibrary: AppTestSupport.library())
        let merged = try #require(doc.project.operations.first?.id)
        doc.perform("Merge") { $0.mergeWithNext(merged) }
        let mergeID = try #require(doc.project.operations.first?.id)
        doc.duplicateOperation(mergeID)
        for id in doc.project.operations.map(\.id) { doc.perform("Split") { $0.splitMerged(id) } }
        #expect(doc.project.operations.count == 4)
        #expect(Set(Self.ids(doc.project.operations)).count == 4, "\(doc.project.operations.map(\.setup.name))")
    }

    @MainActor
    @Test func mergingAToolpathWithItsOwnDuplicateThenSplittingKeepsIDsUnique() throws {
        var p = twoProfiles()
        p.operations.removeLast()
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        func first() throws -> UUID { try #require(doc.project.operations.first?.id) }
        doc.duplicateOperation(try first())                        // A, A2
        let a = try first()
        doc.perform("Merge") { $0.mergeWithNext(a) }               // M(A, A2)
        let m = try first()
        doc.duplicateOperation(m)                                  // M, M′
        doc.perform("Merge") { $0.mergeWithNext(m) }               // M(A, A2, A′, A2′)
        let mm = try first()
        doc.perform("Split") { $0.splitMerged(mm) }                // back at the top level
        #expect(doc.project.operations.count == 4)
        #expect(Set(Self.ids(doc.project.operations)).count == Self.ids(doc.project.operations).count,
                "\(doc.project.operations.map(\.setup.name))")
    }

    // MARK: Refused clashes: the message

    func refusal(_ change: (inout LoftLineProject) -> Void) -> String? {
        var p = AppTestSupport.project()
        change(&p)
        do { try ProjectPost.rejectDuplicateIDs(in: p); return nil } catch { return ProjectOpenError(error).message }
    }

    @Test func theMessageNamesTheKindPositionsAndNames() throws {
        let m = try #require(refusal { p in
            p.document.shapes[1].name = "Hole"
            p.document.shapes.append(contentsOf: [AppTestSupport.rect(9, 1, 1, 1, layer: p.document.defaultLayerID),
                                                  p.document.shapes[1]])
        })
        #expect(m.contains("Two shapes share the id"), "\(m)")
        #expect(m.contains("the 2nd (\"Hole\") and the 4th (\"Hole\")"), "\(m)")
        #expect(m.contains("Every item in a project needs its own id; change or remove one of them."), "\(m)")
    }

    @Test func anUnnamedItemAndThreeOnOneID() throws {
        let m = try #require(refusal { p in
            p.document.shapes[0].name = ""
            p.document.shapes.append(p.document.shapes[0])
            p.document.shapes.append(p.document.shapes[0])
        })
        #expect(m.contains("the 1st (unnamed) and the 3rd (unnamed)"), "\(m)")
    }

    @Test func theEarlierKindIsReportedFirst() throws {
        let m = try #require(refusal { p in
            p.document.shapes.append(p.document.shapes[0])                // shapes
            p.document.layers.append(p.document.layers[0])                // layers come first
        })
        #expect(m.contains("Two layers share the id"), "\(m)")
    }

    @Test func aCleanProjectAndAProjectToolShadowingTheLibraryAreFine() {
        #expect(refusal { _ in } == nil)
        #expect(refusal { $0.tools = [Self.endMill] } == nil)
    }

    // MARK: Opening

    static func file(_ p: LoftLineProject) throws -> Data {
        try SampleFilesTests.withCopies(p, library: ToolLibrary.seeded).encoded()
    }

    /// The issue's file: a disabled 0.2 in profile, then an enabled 0.02 in one, on one id.
    static func issueFile() throws -> Data {
        var p = AppTestSupport.project()
        p.document.job.thickness = 0.75
        let shapes = p.document.shapes.map(\.id), shared = UUID()
        p.operations = [profile("Deep", depth: 0.2, enabled: false, id: shared, shapes: shapes),
                        profile("Shallow", depth: 0.02, id: shared, shapes: shapes)]
        return try file(p)
    }

    @Test func aFileWithRepeatedOperationIDsOpensRepaired() throws {
        let p = try LoftLineProject.opening(from: Self.issueFile())
        #expect(p.operations.map(\.setup.name) == ["Deep", "Shallow"])
        #expect(Set(p.operations.map(\.id)).count == 2)
    }

    @Test func theCLIPostsTheEnabledOperationAsItself() throws {
        let path = AppTestSupport.tempDir().appendingPathComponent("clash.loftline")
        try Self.issueFile().write(to: path)
        let r = LoftLineCLITests.run(["export", path.path, "--post", BuiltInPosts.avidMach4Inch.id, "--builtin-only",
                                      "--out", "-"])
        #expect(r.status == 0, "\(r.err)")
        let zs = r.out.split(separator: "\n").compactMap { line -> Double? in
            guard let z = line.split(separator: " ").first(where: { $0.hasPrefix("Z") }) else { return nil }
            return Double(z.dropFirst())
        }
        #expect(abs((zs.min() ?? 0) + 0.02) < 1e-9, "deepest Z \(zs.min() ?? 0)")
    }

    @Test func theCLIRefusesClashingShapes() throws {
        var p = AppTestSupport.project()
        p.document.shapes.append(p.document.shapes[0])
        let path = AppTestSupport.tempDir().appendingPathComponent("shapes.loftline")
        try Self.file(p).write(to: path)
        let r = LoftLineCLITests.run(["export", path.path, "--post", BuiltInPosts.avidMach4Inch.id, "--builtin-only", "--out", "-"])
        #expect(r.status == 2)
        #expect(r.err.contains("Two shapes share the id"), "\(r.err)")
    }
}
