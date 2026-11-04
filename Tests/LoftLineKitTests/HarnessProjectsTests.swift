import Foundation
import Testing

/// The UI harness and the README reels open five variants of the sample sign. Each is the sample with one small change, so
/// when the sample is regenerated the variants are regenerated from it and cannot drift:
/// `LOFTLINE_WRITE_SAMPLES=1 scripts/test.sh --filter HarnessProjects` (after `--filter SampleFiles`; both write fresh ids).
@Suite("Harness projects", .serialized)
struct HarnessProjectsTests {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static var writeSamples: Bool { ProcessInfo.processInfo.environment["LOFTLINE_WRITE_SAMPLES"] == "1" }

    /// One step of a path into decoded JSON.
    enum Key { case key(String), index(Int) }

    /// Returns `node` with the value at `path` replaced by `value`; nil removes the dictionary key or array element.
    static func set(_ node: Any, _ path: ArraySlice<Key>, _ value: Any?) -> Any {
        guard let head = path.first else { return value as Any }
        let rest = path.dropFirst()
        switch head {
        case .key(let key):
            var dict = node as! [String: Any]
            dict[key] = rest.isEmpty ? value : set(dict[key]!, rest, value)
            return dict
        case .index(let i):
            var array = node as! [Any]
            if rest.isEmpty {
                if let value { array[i] = value } else { array.remove(at: i) }
            } else {
                array[i] = set(array[i], rest, value)
            }
            return array
        }
    }

    static func edit(_ project: inout [String: Any], _ path: [Key], to value: Any?) {
        project = set(project, path[...], value) as! [String: Any]
    }

    static func tabs(of operation: Int) -> [Key] {
        [.key("operations"), .index(operation), .key("profile"), .key("_0"), .key("params"), .key("tabs"), .key("isEnabled")]
    }

    /// The five variants, by JSON path into the decoded sample.
    static var patches: [(file: String, apply: (inout [String: Any]) -> Void)] {
        let dropDrill: (inout [String: Any]) -> Void = { edit(&$0, [.key("operations"), .index(2)], to: nil) }
        return [
            ("sign-loose", { edit(&$0, tabs(of: 3), to: false) }),
            ("sign-overcut", {
                // A through cut 0.02 past the bottom: the project derives the cut depth from the overcut.
                edit(&$0, [.key("operations"), .index(3), .key("profile"), .key("_0"), .key("params"), .key("depth"),
                           .key("cutDepth")], to: 0.77)
                edit(&$0, [.key("operations"), .index(3), .key("profile"), .key("_0"), .key("params"), .key("depth"),
                           .key("overcut")], to: 0.02)
            }),
            ("sign-pause", {
                edit(&$0, [.key("operations"), .index(0), .key("pocket"), .key("_0"), .key("setup"), .key("pauseAfter")],
                     to: ["isOptionalStop": false, "message": "Flip the part and clamp the far edge"] as [String: Any])
            }),
            ("reel-sign", dropDrill),
            ("reel-loose", { dropDrill(&$0); edit(&$0, tabs(of: 2), to: false) }),
        ]
    }

    static func load(_ relative: String) throws -> [String: Any] {
        let data = try Data(contentsOf: root.appendingPathComponent(relative))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func harnessProjectsAreTheSampleWithOnePatchEach() throws {
        let sample = try Self.load("samples/sign.loftline")
        for patch in Self.patches {
            var project = sample
            patch.apply(&project)
            let url = Self.root.appendingPathComponent("harness/projects/\(patch.file).loftline")
            if Self.writeSamples {
                try JSONSerialization.data(withJSONObject: project, options: [.prettyPrinted, .sortedKeys]).write(to: url)
            }
            let committed = try Self.load("harness/projects/\(patch.file).loftline")
            #expect(NSDictionary(dictionary: project).isEqual(to: committed),
                    "\(patch.file).loftline is not the sample plus its patch; regenerate with LOFTLINE_WRITE_SAMPLES=1")
        }
    }

    /// A regenerated sample with a different operation order would apply a patch to the wrong operation.
    @Test func patchesTargetTheExpectedOperations() throws {
        let operations = try #require(try Self.load("samples/sign.loftline")["operations"] as? [[String: Any]])
        #expect(operations.count == 4)
        #expect(operations[0]["pocket"] != nil)
        #expect(operations[2]["drill"] != nil)
        #expect(operations[3]["profile"] != nil)
    }
}
