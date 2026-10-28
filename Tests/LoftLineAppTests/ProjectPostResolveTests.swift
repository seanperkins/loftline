import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

@Suite struct ProjectPostResolveTests {
    let inch = BuiltInPosts.avidMach4Inch
    let mm = BuiltInPosts.avidMach4MM
    let avid = BuiltInMachines.avidPRO6096

    func project(post: String? = nil, machine: String? = nil, units: LengthUnit = .inch) -> LoftLineProject {
        LoftLineProject(document: Document(name: "T", units: units), postProfileID: post, machineID: machine)
    }

    func withCopies(_ p: LoftLineProject, post: PostProfile? = nil, machine: MachineDefinition? = nil,
                    inferredFor: String? = nil) throws -> LoftLineProject {
        var q = p
        if let post { q.postSnapshot = try post.snapshot() }
        if let machine { q.machineSnapshot = try machine.snapshot() }
        q.machineInferredFor = inferredFor
        return q
    }

    // MARK: resolve

    @Test func theCopyPostsWhenTheInstalledPostHasChanged() throws {
        var changed = inch
        changed.footer = ["M30", "(a different footer)"]; changed.version = "1.1"
        let p = try withCopies(project(post: inch.id), post: inch)
        let r = ProjectPost.resolve(p, profiles: [changed, mm], machines: [])
        #expect(r.postSource == .projectCopy)
        #expect(r.post == inch, "the copy's profile posts, not the installed one")
        #expect(r.postCopyDiffers?.copy == inch && r.postCopyDiffers?.installed == changed)
    }

    @Test func aCopyEqualToTheInstalledPostReportsNoDifference() throws {
        let p = try withCopies(project(post: inch.id), post: inch)
        let r = ProjectPost.resolve(p, profiles: [inch, mm], machines: [])
        #expect(r.postSource == .projectCopy && r.postCopyDiffers == nil)
    }

    @Test func anUninstalledPostWithACopyPostsWithoutError() throws {
        var ghost = inch
        ghost.id = "ghost"; ghost.name = "Ghost"
        let p = try withCopies(project(post: "ghost"), post: ghost)
        let r = ProjectPost.resolve(p, profiles: [inch, mm], machines: [])
        #expect(r.postSource == .projectCopy && r.post == ghost && r.postCopyDiffers == nil)
    }

    @Test func noCopyAndNoInstalledPostKeepsTheFallback() {
        let r = ProjectPost.resolve(project(post: "ghost"), profiles: [inch, mm], machines: [])
        #expect(r.postSource == .fallback(missingID: "ghost"))
        #expect(r.post == inch, "today's fallback: the default post")
    }

    @Test func aNilPostIDUsesTheDefaultForTheUnits() {
        #expect(ProjectPost.resolve(project(units: .inch), profiles: [inch, mm], machines: []).post == inch)
        #expect(ProjectPost.resolve(project(units: .millimeter), profiles: [inch, mm], machines: []).post == mm)
    }

    @Test func machineLimitsComeFromTheCopyWhenTheCatalogLacksTheMachine() throws {
        var small = avid
        small.limits = MachineLimits(xTravel: 10, yTravel: 12, zTravel: 2, maxSpoilboardCut: 0.1)
        let p = try withCopies(project(post: inch.id, machine: avid.id), machine: small)
        let r = ProjectPost.resolve(p, profiles: [inch, mm], machines: [])
        #expect(r.machine == small && r.machineSource == .projectCopy)
        #expect(r.post.limits.xTravel == 10 && r.post.limits.yTravel == 12, "the copy's bed is applied to the post")
        let installed = ProjectPost.resolve(p, profiles: [inch, mm], machines: [avid])
        #expect(installed.machine == small, "the copy still wins when the machine is installed")
        #expect(installed.machineCopyDiffers?.copy == small && installed.machineCopyDiffers?.installed == avid)
    }

    @Test func aCopyWhoseIDDoesNotMatchTheSelectionIsIgnored() throws {
        let p = try withCopies(project(post: inch.id, machine: avid.id), post: mm, machine: BuiltInMachines.genericGRBL)
        let r = ProjectPost.resolve(p, profiles: [inch, mm], machines: [avid])
        #expect(r.postSource == .installed && r.post.id == inch.id)
        #expect(r.machineSource == .installed && r.machine == avid)
    }

    @Test func aNilMachineIDCopyIsValidOnlyForThePostItWasInferredFor() throws {
        var second = avid
        second.id = "avid-second"; second.name = "Second"
        // Both machines support the inch and the mm post; the catalog order makes `avid` the inferred one.
        let machines = [avid, second]
        let forInch = try withCopies(project(post: nil), machine: second, inferredFor: inch.id)
        let kept = ProjectPost.resolve(forInch, profiles: [inch, mm], machines: machines)
        #expect(kept.machine == second && kept.machineSource == .projectCopy)

        let switched = try withCopies(project(post: mm.id), machine: second, inferredFor: inch.id)
        let again = ProjectPost.resolve(switched, profiles: [inch, mm], machines: machines)
        #expect(again.machine == avid && again.machineSource == .installed,
                "the post changed: inferred again (the first supporting machine), though `second` also supports it")
        let noMarker = try withCopies(project(post: nil), machine: second, inferredFor: nil)
        #expect(ProjectPost.resolve(noMarker, profiles: [inch, mm], machines: machines).machine == avid)
    }

    @Test func aMachineIDNamingAnUninstalledMachineResolvesAsToday() {
        let p = project(post: inch.id, machine: "gone")
        let r = ProjectPost.resolve(p, profiles: [inch, mm], machines: [avid])
        #expect(r.machine == MachineResolver.machine(for: p, machines: [avid]))
        #expect(r.machineSource == .installed)
    }

    // MARK: validate and opening

    private func data(_ p: LoftLineProject, editing change: (inout [String: Any]) -> Void = { _ in }) throws -> Data {
        var obj = try #require(try JSONSerialization.jsonObject(with: p.encoded()) as? [String: Any])
        change(&obj)
        return try JSONSerialization.data(withJSONObject: obj)
    }

    private func newer(_ v: JSONValue) -> JSONValue {
        guard case .object(var o) = v else { return v }
        o["schemaVersion"] = .number(Double(PostProfile.currentSchemaVersion + 1))   // newer than any post or machine reader
        return .object(o)
    }

    private let newerMessage = "This project was made with a newer LoftLine. Update LoftLine to open it."

    @Test func openingAcceptsCurrentCopiesAndVersionOneFiles() throws {
        let p = try withCopies(project(post: inch.id, machine: avid.id), post: inch, machine: avid)
        let opened = try LoftLineProject.opening(from: data(p))
        #expect(opened.postSnapshot == p.postSnapshot && opened.machineSnapshot == p.machineSnapshot)
        let v1 = try data(project(post: inch.id)) { $0["formatVersion"] = 1 }
        let old = try LoftLineProject.opening(from: v1)
        #expect(old.postSnapshot == nil && old.machineSnapshot == nil)
    }

    @Test func openingRefusesANewerPostOrMachineCopy() throws {
        var p = try withCopies(project(post: inch.id, machine: avid.id), post: inch, machine: avid)
        p.postSnapshot = p.postSnapshot.map(newer)
        #expect(throws: ProjectOpenError(message: newerMessage)) { try LoftLineProject.opening(from: data(p)) }
        var q = try withCopies(project(post: inch.id, machine: avid.id), post: inch, machine: avid)
        q.machineSnapshot = q.machineSnapshot.map(newer)
        #expect(throws: ProjectOpenError(message: newerMessage)) { try LoftLineProject.opening(from: data(q)) }
    }

    @Test func openingRefusesAMalformedCopy() throws {
        var p = project(post: inch.id)
        p.postSnapshot = .string("junk")
        do { _ = try LoftLineProject.opening(from: data(p)); Issue.record("opened") } catch let e as ProjectOpenError {
            let m = e.message
            #expect(m.contains("post"))
        } catch { Issue.record("wrong error \(error)") }
        var q = project(post: inch.id)
        q.machineSnapshot = .object(["id": .string("only")])
        do { _ = try LoftLineProject.opening(from: data(q)); Issue.record("opened") } catch let e as ProjectOpenError {
            let m = e.message
            #expect(m.contains("machine"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func openingRefusesACopyThatIsPresentButNull() throws {
        for (key, word) in [("postSnapshot", "post"), ("machineSnapshot", "machine")] {
            let d = try data(project(post: inch.id)) { $0[key] = NSNull() }
            do { _ = try LoftLineProject.opening(from: d); Issue.record("opened with a null \(key)") } catch let e as ProjectOpenError {
                let m = e.message
                #expect(m.contains(word), "\(key): \(m)")
            } catch { Issue.record("wrong error \(error)") }
        }
    }
}
