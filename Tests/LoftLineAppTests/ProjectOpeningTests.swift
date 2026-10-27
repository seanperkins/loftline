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

        /// The file's bytes and a fragment of the message the user must be shown.
        func make() throws -> (data: Data, message: String) {
            let post = BuiltInPosts.avidMach4Inch, machine = BuiltInMachines.avidPRO6096
            var p = LoftLineProject(document: Document(name: "Bad"), postProfileID: post.id, machineID: machine.id)
            p.postSnapshot = try post.snapshot(); p.machineSnapshot = try machine.snapshot()
            func newer(_ v: JSONValue?) -> JSONValue? {
                guard case .object(var o)? = v else { return v }
                o["schemaVersion"] = .number(2)
                return .object(o)
            }
            var message = ""
            switch self {
            case .newerPost: p.postSnapshot = newer(p.postSnapshot); message = "made with a newer LoftLine. Update LoftLine to open it."
            case .newerMachine: p.machineSnapshot = newer(p.machineSnapshot); message = "made with a newer LoftLine. Update LoftLine to open it."
            case .malformedMachine: p.machineSnapshot = .object(["id": .string("only")]); message = "copy of its machine"
            case .nullPost, .nullMachine: break
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
