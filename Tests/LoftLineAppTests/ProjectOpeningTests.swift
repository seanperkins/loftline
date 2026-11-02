import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// Every place a file becomes a project that can be edited or posted refuses a post or machine copy it cannot read,
/// with the message, and never opens it with the installed post instead.
@Suite struct ProjectOpeningTests {
    enum Bad: CaseIterable {
        case newerPost, newerMachine, malformedMachine, nullPost, nullMachine
        // #123: two items on one id.
        case duplicateLayers, duplicateShapes, duplicateModels, duplicateZones, duplicateTools

        /// The file's bytes and a fragment of the message the user must be shown.
        func make() throws -> (data: Data, message: String) {
            let post = BuiltInPosts.avidMach4Inch, machine = BuiltInMachines.avidPRO6096
            var p = LoftLineProject(document: Document(name: "Bad"), postProfileID: post.id, machineID: machine.id)
            p.postSnapshot = try post.snapshot(); p.machineSnapshot = try machine.snapshot()
            func newer(_ v: JSONValue?) -> JSONValue? {
                guard case .object(var o)? = v else { return v }
                o["schemaVersion"] = .number(Double(PostProfile.currentSchemaVersion + 1))   // newer than any post or machine reader
                return .object(o)
            }
            var message = ""
            switch self {
            case .newerPost: p.postSnapshot = newer(p.postSnapshot); message = "made with a newer LoftLine. Update LoftLine to open it."
            case .newerMachine: p.machineSnapshot = newer(p.machineSnapshot); message = "made with a newer LoftLine. Update LoftLine to open it."
            case .malformedMachine: p.machineSnapshot = .object(["id": .string("only")]); message = "copy of its machine"
            case .nullPost, .nullMachine: break
            case .duplicateLayers:
                p.document.layers.append(p.document.layers[0]); message = "Two layers share the id"
            case .duplicateShapes:
                let s = AppTestSupport.rect(1, 1, 2, 1, layer: p.document.defaultLayerID)
                p.document.shapes += [s, s]; message = "Two shapes share the id"
            case .duplicateModels:
                let m = PlacedModel(name: "M", mesh: Mesh3D())
                p.document.models += [m, m]; message = "Two models share the id"
            case .duplicateZones:
                let z = KeepOutZone(name: "Clamp", outline: [Vec2(0, 0), Vec2(1, 0), Vec2(1, 1)], height: 0.5)
                p.document.keepOutZones = [z, z]; message = "Two keep-out zones share the id"
            case .duplicateTools:
                let t = ToolLibrary.seeded.tools[0]
                p.tools = [t, t]; message = "Two tools share the id"
            }
            var obj = try #require(JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
            if self == .nullPost { obj["postSnapshot"] = NSNull(); message = "copy of its post is empty" }
            if self == .nullMachine { obj["machineSnapshot"] = NSNull(); message = "copy of its machine is empty" }
            return (try JSONSerialization.data(withJSONObject: obj), message)
        }
    }

    private func expectRefused(_ bad: Bad, _ open: (Data) throws -> Any, sourceLocation: SourceLocation = #_sourceLocation) throws {
        let (data, message) = try bad.make()
        do {
            _ = try open(data)
            Issue.record("\(bad) was opened", sourceLocation: sourceLocation)
        } catch let e as ProjectOpenError {
            #expect(e.message.contains(message), "\(bad): \(e.message)", sourceLocation: sourceLocation)
            #expect(e.localizedDescription == e.message, sourceLocation: sourceLocation)
        } catch {
            Issue.record("\(bad): wrong error \(error)", sourceLocation: sourceLocation)
        }
    }

    @Test func theDocumentRefusesAnUnreadableCopy() throws {
        for bad in Bad.allCases {
            try expectRefused(bad) { try LoftLineDocument(opening: $0, toolLibrary: AppTestSupport.library()) }
        }
    }

    @Test func theDocumentOpensAGoodFile() throws {
        var p = LoftLineProject(document: Document(name: "Good"), postProfileID: BuiltInPosts.avidMach4Inch.id)
        p.postSnapshot = try BuiltInPosts.avidMach4Inch.snapshot()
        let doc = try LoftLineDocument(opening: p.encoded(), toolLibrary: AppTestSupport.library())
        #expect(doc.document.name == "Good" && doc.postProfile.id == BuiltInPosts.avidMach4Inch.id)
    }

    @Test func recoveryRefusesAnUnreadableCopy() throws {
        let store = RecoveryStore(directory: AppTestSupport.tempDir())
        for bad in Bad.allCases {
            try expectRefused(bad) { data in
                let id = UUID()
                try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
                try data.write(to: store.projectURL(id))
                return try store.project(for: id)
            }
        }
    }

    @Test func templatesRefuseAnUnreadableCopy() throws {
        let dir = AppTestSupport.tempDir()
        let store = JobTemplateStore(directory: dir)
        for bad in Bad.allCases {
            try expectRefused(bad) { data in
                let url = dir.appendingPathComponent("\(UUID().uuidString).loftline")
                try data.write(to: url)
                return try store.instantiate(JobTemplateStore.Entry(name: "t", url: url))
            }
        }
    }
}
