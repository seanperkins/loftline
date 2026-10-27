import CADCore
import CAMCore
import Foundation
import PostCore

/// Which post and machine a project posts with. A `.loftline` file carries a copy of both (`postSnapshot`,
/// `machineSnapshot`), so the same file posts the same G-code on any Mac whether or not the post it was made with is
/// installed there. This is pure: the document and the command line both resolve through it, with the installed posts
/// and machines passed in.
///
/// The copy wins while it is still what the project selects (its id matches), and the installed definition is only used
/// to compare against and when the user picks something else. A copy that no longer matches the selection is ignored,
/// so a stale copy can never post.
enum ProjectPost {
    enum Source: Equatable {
        /// The copy the file carries.
        case projectCopy
        /// The post or machine installed on this Mac.
        case installed
        /// The selected post is neither carried nor installed: the default post stands in (today's behaviour).
        case fallback(missingID: String)
    }

    struct Resolved {
        /// The post to write with, the machine's limits already applied (`MachineResolver.effectiveProfile`).
        var post: PostProfile
        var machine: MachineDefinition?
        var postSource: Source
        /// nil = no machine (the post's own limits apply, as in files saved before machines existed).
        var machineSource: Source?
        /// Set when the copy is used and an installed post of the same id differs from it.
        var postCopyDiffers: (copy: PostProfile, installed: PostProfile)?
        var machineCopyDiffers: (copy: MachineDefinition, installed: MachineDefinition)?
    }

    /// The post id the project selects: `postProfileID`, else the default for its units (what `postProfile` uses today).
    /// A nil id is never written into the file, so "the default for the units" keeps its meaning.
    static func effectivePostID(_ p: LoftLineProject) -> String {
        p.postProfileID ?? PostProfileStore.defaultID(for: p.document.units)
    }

    /// The post copy, when it is readable and is still the selected post.
    static func postCopy(of p: LoftLineProject) -> PostProfile? {
        guard let v = p.postSnapshot, let post = try? PostProfile(snapshot: v), post.id == effectivePostID(p) else { return nil }
        return post
    }

    /// The machine copy, when it is readable and is still the selected machine. With no chosen machine the copy is
    /// what was inferred for one particular post, so it only holds for that post.
    static func machineCopy(of p: LoftLineProject) -> MachineDefinition? {
        guard let v = p.machineSnapshot, let m = try? MachineDefinition(snapshot: v) else { return nil }
        if let id = p.machineID { return m.id == id ? m : nil }
        return p.machineInferredFor == effectivePostID(p) ? m : nil
    }

    static func resolve(_ p: LoftLineProject, profiles: [PostProfile], machines: [MachineDefinition]) -> Resolved {
        let id = effectivePostID(p)
        let installedPost = profiles.first { $0.id == id }
        let base: PostProfile
        let postSource: Source
        var postDiff: (copy: PostProfile, installed: PostProfile)?
        if let copy = postCopy(of: p) {
            base = copy; postSource = .projectCopy
            if let installed = installedPost, installed != copy { postDiff = (copy, installed) }
        } else if let installed = installedPost {
            base = installed; postSource = .installed
        } else {
            base = profiles.first { $0.id == PostProfileStore.defaultProfileID } ?? BuiltInPosts.avidMach4Inch
            postSource = .fallback(missingID: id)
        }

        let machine: MachineDefinition?
        let machineSource: Source?
        var machineDiff: (copy: MachineDefinition, installed: MachineDefinition)?
        if let copy = machineCopy(of: p) {
            machine = copy; machineSource = .projectCopy
            if let installed = machines.first(where: { $0.id == copy.id }), installed != copy { machineDiff = (copy, installed) }
        } else if let installed = MachineResolver.machine(for: p, machines: machines) {
            machine = installed; machineSource = .installed
        } else {
            machine = nil; machineSource = nil
        }
        return Resolved(post: MachineResolver.effectiveProfile(base, machine: machine), machine: machine,
                        postSource: postSource, machineSource: machineSource,
                        postCopyDiffers: postDiff, machineCopyDiffers: machineDiff)
    }

    /// Throws when a copy the file carries cannot be read: written by a newer LoftLine, or damaged. The project is then
    /// refused, never opened with the installed post instead. Messages are the ones the open dialog shows.
    static func validate(_ p: LoftLineProject) throws {
        try check(p.postSnapshot, as: "post") { _ = try PostProfile(snapshot: $0) }
        try check(p.machineSnapshot, as: "machine") { _ = try MachineDefinition(snapshot: $0) }
    }

    private static func check(_ copy: JSONValue?, as what: String, _ read: (JSONValue) throws -> Void) throws {
        guard let copy else { return }
        do { try read(copy) } catch SnapshotError.newerSchema {
            throw LoftLineIOError.unsupportedFormat("This project was made with a newer LoftLine. Update LoftLine to open it.")
        } catch SnapshotError.malformed(let why) {
            throw LoftLineIOError.malformed("This project's copy of its \(what) could not be read (\(why)).")
        }
    }

    /// A key that is present but `null` is a damaged copy, not an absent one; synthesized `Codable` reads it as nil.
    static func rejectNullCopies(in data: Data) throws {
        struct Probe: Decodable {
            var postIsNull = false, machineIsNull = false
            enum Keys: String, CodingKey { case postSnapshot, machineSnapshot }
            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: Keys.self)
                postIsNull = try c.contains(.postSnapshot) && c.decodeNil(forKey: .postSnapshot)
                machineIsNull = try c.contains(.machineSnapshot) && c.decodeNil(forKey: .machineSnapshot)
            }
        }
        // A file that is not a JSON object is reported by the decode that follows.
        guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return }
        if probe.postIsNull { throw LoftLineIOError.malformed("This project's copy of its post is empty.") }
        if probe.machineIsNull { throw LoftLineIOError.malformed("This project's copy of its machine is empty.") }
    }
}

extension LoftLineProject {
    /// Reads a `.loftline` file that is going to be opened, edited or posted: `decode`, then refuses a post or machine
    /// copy that is newer, damaged or `null`. Use this everywhere a file becomes a project that can be posted.
    static func opening(from data: Data) throws -> LoftLineProject {
        try ProjectPost.rejectNullCopies(in: data)
        let project = try LoftLineProject.decode(from: data)
        try ProjectPost.validate(project)
        return project
    }
}
