import CAMCore
import LoftLineKit
import PostCore

extension JobSetupForm {
    /// With the installed posts.
    init(project: LoftLineProject, machines: [MachineDefinition]) {
        self.init(project: project, machines: machines, profiles: PostProfileCatalog.shared.profiles)
    }
}
