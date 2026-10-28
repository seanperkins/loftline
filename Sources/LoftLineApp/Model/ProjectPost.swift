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
        /// Whether a post / machine with the id that posts is installed on this Mac.
        var postInstalledHere = false
        var machineInstalledHere = false
    }

    /// The post id the project selects: `postProfileID`, else the default for its units (what `postProfile` uses today).
    /// A nil id is never written into the file, so "the default for the units" keeps its meaning.
    static func effectivePostID(_ p: LoftLineProject) -> String {
        p.postProfileID ?? PostProfileStore.defaultID(for: p.document.units)
    }

    /// The post copy, when it is readable and is still the selected post.
    static func postCopy(of p: LoftLineProject) -> PostProfile? {
        guard let v = p.postSnapshot, let post = try? PostProfile(snapshot: v), post.id == effectivePostID(p) else { return nil }
        return post.normalized   // an empty pause list would post no stop at all: it means the default pause
    }

    /// A project with no chosen machine whose file records that none was found for its post: no copy, and the marker.
    static func machineNoneRecorded(_ p: LoftLineProject) -> Bool {
        p.machineID == nil && p.machineSnapshot == nil && p.machineInferredFor == effectivePostID(p)
    }

    /// The machine copy, when it is readable and is still the selected machine. With no chosen machine the copy is
    /// what was inferred for one particular post, so it only holds for that post.
    static func machineCopy(of p: LoftLineProject) -> MachineDefinition? {
        guard let v = p.machineSnapshot, let m = try? MachineDefinition(snapshot: v) else { return nil }
        if let id = p.machineID { return m.id == id ? m : nil }
        return p.machineInferredFor == effectivePostID(p) ? m : nil
    }

    static let probeRefusalMessage = "This project was set up to probe tool changes on a machine that is not set up for it here."

    /// `copy` with the installed machine's probe settings, converted to the copy's units: they describe this shop's machine
    /// today (its park position, its plate), so a project's copy never posts its own. A copy that probes on a machine that is
    /// not installed here, or not set up to probe here, refuses instead.
    static func withInstalledProbe(_ copy: MachineDefinition, installed: MachineDefinition?) -> MachineDefinition {
        var m = copy
        if let probe = installed?.toolChangeProbe, let installed {
            m.toolChangeProbe = probe.scaled(by: installed.units.factor(to: copy.units))
        } else {
            m.toolChangeProbe = nil
            if copy.toolChangeProbe != nil { m.probeRefusal = probeRefusalMessage }
        }
        return m
    }

    /// The copy-differs warning compares the rest of the machine: its probe settings never post from the copy.
    private static func withoutProbe(_ m: MachineDefinition) -> MachineDefinition {
        var m = m
        m.toolChangeProbe = nil
        m.probeRefusal = nil
        return m
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
            let installed = machines.first(where: { $0.id == copy.id })
            machine = withInstalledProbe(copy, installed: installed); machineSource = .projectCopy
            if let installed, withoutProbe(installed) != withoutProbe(copy) { machineDiff = (copy, installed) }
        } else if machineNoneRecorded(p) {
            // The file says no machine was found for this post when it was set up: the post's own limits apply, whatever
            // machine this Mac has that lists the post (a travel check must not widen because of the Mac it is opened on).
            machine = nil; machineSource = nil
        } else if let installed = MachineResolver.machine(for: p, machines: machines) {
            machine = installed; machineSource = .installed
        } else {
            machine = nil; machineSource = nil
        }
        return Resolved(post: MachineResolver.effectiveProfile(base, machine: machine), machine: machine,
                        postSource: postSource, machineSource: machineSource,
                        postCopyDiffers: postDiff, machineCopyDiffers: machineDiff,
                        postInstalledHere: installedPost != nil,
                        machineInstalledHere: machine.map { m in machines.contains { $0.id == m.id } } ?? false)
    }

    // MARK: Keeping the copies in step

    /// Brings both copies in step with what the project selects, in memory. A copy that is missing, unreadable or no
    /// longer what the selection names is replaced by the installed definition the selection resolves to, or dropped when
    /// there is none; a copy that still matches is left alone, which is what "the file's copy wins" means. `postProfileID`
    /// and `machineID` are never touched: a nil id keeps meaning "the default for the units".
    static func syncing(_ p: LoftLineProject, profiles: [PostProfile], machines: [MachineDefinition]) -> LoftLineProject {
        var q = p
        let postID = effectivePostID(q)
        if postCopy(of: q) == nil {
            q.postSnapshot = profiles.first { $0.id == postID }.flatMap { try? $0.snapshot() }
        }
        if q.machineID != nil { q.machineInferredFor = nil }   // a chosen machine needs no marker
        if machineCopy(of: q) == nil, !machineNoneRecorded(q) {
            // What the selection names: the chosen machine if it is installed, else (no chosen machine) what
            // `MachineResolver` infers for the post. A chosen machine that is not installed gets no copy: the fallback
            // machine would not be what the project selected.
            let installed = q.machineID.map { id in machines.first { $0.id == id } } ?? MachineResolver.machine(for: q, machines: machines)
            q.machineSnapshot = installed.flatMap { try? $0.snapshot() }
            // No chosen machine: the marker records what was inferred, including that nothing was ("post limits only").
            q.machineInferredFor = q.machineID == nil ? postID : nil
        }
        return q
    }

    /// The same step, for a project that has just been opened or created.
    static func attaching(_ p: LoftLineProject, profiles: [PostProfile], machines: [MachineDefinition]) -> LoftLineProject {
        syncing(p, profiles: profiles, machines: machines)
    }

    /// "Update This Project": each copy is replaced with the installed definition that has the copy's own id; a copy with
    /// no installed counterpart is kept.
    static func updated(_ p: LoftLineProject, profiles: [PostProfile], machines: [MachineDefinition]) -> LoftLineProject {
        var q = p
        if let copy = postCopy(of: p), let installed = profiles.first(where: { $0.id == copy.id }),
           let snapshot = try? installed.snapshot() { q.postSnapshot = snapshot }
        if let copy = machineCopy(of: p), let installed = machines.first(where: { $0.id == copy.id }),
           let snapshot = try? installed.snapshot() { q.machineSnapshot = snapshot }
        return syncing(q, profiles: profiles, machines: machines)
    }

    // MARK: Notices

    /// An error when the selected post is neither carried nor installed (today's text); a warning for each copy that
    /// differs from the installed definition of the same id, and one for each copy that has no installed counterpart (its
    /// lines or limits then come from the file alone). They reach the export sheets through the document.
    static func issues(for p: LoftLineProject, profiles: [PostProfile], machines: [MachineDefinition],
                       includingPost: Bool = true) -> [GCodeIssue] {
        let r = resolve(p, profiles: profiles, machines: machines)
        var out = differenceWarnings(r, includingPost: includingPost)
        if includingPost, case .fallback = r.postSource, let id = p.postProfileID {
            out.insert(GCodeIssue(severity: .error, message:
                "The project's post \"\(id)\" is not installed; \"\(r.post.name)\" is shown instead. Pick a post before saving."), at: 0)
        }
        if includingPost, r.postSource == .projectCopy, !r.postInstalledHere {
            out.append(GCodeIssue(severity: .warning, message:
                "This project posts with its own copy of the post \"\(r.post.name)\", which is not installed on this Mac. "
                + "Check the program's setup, tool-change and ending lines before running it."))
        }
        if r.machineSource == .projectCopy, !r.machineInstalledHere, let m = r.machine {
            out.append(GCodeIssue(severity: .warning, message:
                "This project's machine \"\(m.name)\" (bed \(bed(m))) is not installed on this Mac, so its bed and travel limits come from the file, "
                + "not from a machine you set up. Pick your machine in Job Setup to check the program against it."))
        }
        return out
    }

    /// A warning for each copy that differs from the installed definition of the same id.
    private static func differenceWarnings(_ r: Resolved, includingPost: Bool) -> [GCodeIssue] {
        var out: [GCodeIssue] = []
        if includingPost, let d = r.postCopyDiffers {
            let versions = d.copy.version == d.installed.version ? "" : " v\(d.copy.version)"
            let installed = d.copy.version == d.installed.version ? "the installed one" : "the installed v\(d.installed.version)"
            out.append(GCodeIssue(severity: .warning, message:
                "This project posts with its own copy of \"\(d.copy.name)\"\(versions), which differs from \(installed). "
                + "Job Setup > Update This Project uses the installed one."))
        }
        if let d = r.machineCopyDiffers {
            let copyBed = bed(d.copy), installedBed = bed(d.installed)
            let sizes = copyBed == installedBed ? "" : " (copy \(copyBed), installed \(installedBed))"
            out.append(GCodeIssue(severity: .warning, message:
                "This project uses its own copy of the machine \"\(d.copy.name)\"\(sizes), which differs from the installed one. "
                + "Job Setup > Update This Project uses the installed one."))
        }
        return out
    }

    /// What Job Setup says about the copies: which ones post, and the difference warnings.
    struct Notice: Equatable {
        var lines: [String]
        var warnings: [String]
    }

    static func notice(for p: LoftLineProject, profiles: [PostProfile], machines: [MachineDefinition]) -> Notice {
        let r = resolve(p, profiles: profiles, machines: machines)
        var lines: [String] = []
        if r.postSource == .projectCopy {
            lines.append("Using this project's copy of \"\(r.post.name)\" v\(r.post.version)" + (r.postInstalledHere ? "" : " (not installed here)"))
        }
        if r.machineSource == .projectCopy, let m = r.machine {
            lines.append("Using this project's copy of the machine \"\(m.name)\"" + (r.machineInstalledHere ? "" : " (not installed here)"))
        }
        let warnings = differenceWarnings(r, includingPost: true).map(\.message)
        return Notice(lines: lines, warnings: warnings)
    }

    private static func bed(_ m: MachineDefinition) -> String {
        "\(RulerTicks.label(m.limits.xTravel)) × \(RulerTicks.label(m.limits.yTravel)) \(m.units.abbreviation)"
    }

    // MARK: Opening

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
    /// copy that is newer, damaged or `null`. Use this everywhere a file becomes a project that can be posted. Every
    /// failure is a `ProjectOpenError`, whose message is what the user should read.
    static func opening(from data: Data) throws -> LoftLineProject {
        do {
            try ProjectPost.rejectNullCopies(in: data)
            let project = try LoftLineProject.decode(from: data)
            try ProjectPost.validate(project)
            return project
        } catch {
            throw ProjectOpenError(error)
        }
    }
}

/// A project file that cannot be opened, with the sentence the user should read: the open dialog shows
/// `localizedDescription`, and the command line prints the message.
struct ProjectOpenError: Error, LocalizedError, Equatable {
    var message: String
    var errorDescription: String? { message }

    init(message: String) { self.message = message }

    init(_ error: Error) {
        switch error {
        case let e as ProjectOpenError: message = e.message
        case LoftLineIOError.unsupportedFormat(let m), LoftLineIOError.malformed(let m): message = m
        default: message = error.localizedDescription
        }
    }
}
