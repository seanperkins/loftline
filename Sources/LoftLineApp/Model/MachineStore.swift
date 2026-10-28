import CADCore
import CAMCore
import Combine
import Foundation
import PostCore

/// Built-in machines plus user machines stored as JSON in
/// ~/Library/Application Support/LoftLine/machines/*.json (a user file with a built-in's id overrides it).
struct MachineStore {
    var directory: URL
    /// False = the built-ins only, whatever is in `directory` (the command line's `--builtin-only`).
    var readsUserFiles = true

    init(directory: URL = ToolLibraryStore.supportDirectory.appendingPathComponent("machines", isDirectory: true)) {
        self.directory = directory
    }

    func userMachines() -> [MachineDefinition] {
        guard readsUserFiles else { return [] }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension.lowercased() == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                // A machine names its own file: an id that is not a plain file name, or a file named for another id, could
                // make Save or Delete reach outside this folder (#122).
                guard let m = try? MachineDefinition.fromJSON(Data(contentsOf: url)), PostProfileStore.isSafeID(m.id),
                      url.deletingPathExtension().lastPathComponent == m.id else { return nil }
                return m
            }
    }

    func allMachines() -> [MachineDefinition] {
        let user = userMachines()
        let userIDs = Set(user.map(\.id))
        return BuiltInMachines.all.filter { !userIDs.contains($0.id) } + user
    }

    func fileURL(for id: String) -> URL { directory.appendingPathComponent(id).appendingPathExtension("json") }

    struct UnsafeID: LocalizedError {
        var id: String
        var errorDescription: String? { "The machine id \"\(id)\" is not a plain file name." }
    }

    @discardableResult
    func save(_ machine: MachineDefinition) throws -> URL {
        guard PostProfileStore.isSafeID(machine.id) else { throw UnsafeID(id: machine.id) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = fileURL(for: machine.id)
        try machine.toJSON().write(to: url, options: .atomic)
        return url
    }

    func delete(id: String) throws {
        guard PostProfileStore.isSafeID(id) else { return }
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// True when `id` is stored as a user file (editable/deletable).
    func isUserMachine(_ id: String) -> Bool {
        PostProfileStore.isSafeID(id) && FileManager.default.fileExists(atPath: fileURL(for: id).path)
    }
}

/// Which machine a project uses, and the post profile with that machine's limits applied. Pure.
enum MachineResolver {
    /// The project's chosen machine; else the first machine that lists the project's post; else nil
    /// (the post's own limits apply, as in files saved before machines existed).
    static func machine(for project: LoftLineProject, machines: [MachineDefinition]) -> MachineDefinition? {
        if let id = project.machineID, let m = machines.first(where: { $0.id == id }) { return m }
        let post = project.postProfileID ?? PostProfileStore.defaultID(for: project.document.units)
        return machines.first { $0.supports(postID: post) }
    }

    static func effectiveProfile(_ profile: PostProfile, machine: MachineDefinition?) -> PostProfile {
        machine?.applied(to: profile) ?? profile
    }

    /// Sets the machine and, if the current post does not drive it, switches to its default post.
    static func select(machine: MachineDefinition, in project: inout LoftLineProject, profiles: [PostProfile]) {
        project.machineID = machine.id
        let current = project.postProfileID ?? PostProfileStore.defaultID(for: project.document.units)
        let next = post(afterSelecting: machine, current: current, units: project.document.units, profiles: profiles)
        if next != current { project.postProfileID = next }
    }

    /// The post to use after choosing `machine`: `current` if the machine lists it, else the
    /// machine's default post for `units` (or `current` if it has none).
    static func post(afterSelecting machine: MachineDefinition, current: String, units: LengthUnit,
                     profiles: [PostProfile]) -> String {
        if machine.supports(postID: current) { return current }
        return machine.defaultPostID(for: units, available: profiles) ?? current
    }

    /// Posts for a picker: the machine's own posts first, then the rest.
    static func orderedPosts(_ profiles: [PostProfile], machine: MachineDefinition?) -> (compatible: [PostProfile], other: [PostProfile]) {
        guard let machine else { return (profiles, []) }
        let compatible = machine.postIDs.compactMap { id in profiles.first { $0.id == id } }
        let ids = Set(compatible.map(\.id))
        return (compatible, profiles.filter { !ids.contains($0.id) })
    }

    /// Problems with fitting `job` on the machine bed (empty = fits).
    static func fitProblems(job: JobSetup, units: LengthUnit, machine: MachineDefinition?) -> [String] {
        guard let m = machine else { return [] }
        let f = m.units.factor(to: units)
        var out: [String] = []
        let x = m.limits.xTravel * f, y = m.limits.yTravel * f, z = m.limits.zTravel * f
        let eps = 1e-6
        if job.width > x + eps || job.height > y + eps {
            out.append("The material (\(RulerTicks.label(job.width)) x \(RulerTicks.label(job.height)) \(units.abbreviation)) is larger than the \(m.name) bed (\(RulerTicks.label(x)) x \(RulerTicks.label(y)) \(units.abbreviation)).")
        }
        if job.thickness > z + eps {
            out.append("The material is thicker than the machine's Z travel (\(RulerTicks.label(z)) \(units.abbreviation)).")
        }
        return out
    }
}

/// App-wide list of machines (built-ins + user JSON). `reload()` re-reads the folder.
final class MachineCatalog: ObservableObject {
    static let shared = MachineCatalog()
    @Published private(set) var machines: [MachineDefinition]
    let store: MachineStore

    init(store: MachineStore = MachineStore()) {
        self.store = store
        machines = store.allMachines()
    }

    func reload() { machines = store.allMachines() }

    func machine(id: String?) -> MachineDefinition? { machines.first { $0.id == id } }

    func machine(for project: LoftLineProject) -> MachineDefinition? {
        MachineResolver.machine(for: project, machines: machines)
    }

    func save(_ machine: MachineDefinition) throws {
        try store.save(machine)
        reload()
    }

    func delete(id: String) throws {
        try store.delete(id: id)
        reload()
    }

    /// A fresh, unique id for a copy of `base`.
    func newID(from base: String) -> String {
        let ids = Set(machines.map(\.id))
        var n = 1
        while ids.contains("\(base)-custom-\(n)") { n += 1 }
        return "\(base)-custom-\(n)"
    }
}
