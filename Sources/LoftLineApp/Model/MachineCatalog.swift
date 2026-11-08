import CADCore
import CAMCore
import Combine
import Foundation
import LoftLineKit
import PostCore

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
