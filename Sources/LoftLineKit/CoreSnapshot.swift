import CADCore
import CAMCore
import Foundation
import PostCore

/// What a tool needs from a window to run on a copy of it (spec 2, "Architecture"): the project, its saved state and file, the
/// side on show, the window's own library, posts and machines, and only the results the window calls fresh. A session made from
/// it takes them as they are, so its stale check agrees with the window's.
public struct CoreSnapshot {
    public var project: LoftLineProject
    public var savedProject: LoftLineProject
    public var fileURL: URL?
    public var activeSide: JobSide
    public var designRevision: Int
    public var library: ToolLibrary
    public var profiles: [PostProfile]
    public var machines: [MachineDefinition]
    public var results: [UUID: ToolpathResult]
    /// The review marker's count, so a check on the copy warns as the window's Check Toolpaths does.
    public var assistantChanges: Int

    public init(project: LoftLineProject, savedProject: LoftLineProject, fileURL: URL?, activeSide: JobSide, designRevision: Int,
                library: ToolLibrary, profiles: [PostProfile], machines: [MachineDefinition], results: [UUID: ToolpathResult],
                assistantChanges: Int = 0) {
        self.project = project
        self.savedProject = savedProject
        self.fileURL = fileURL
        self.activeSide = activeSide
        self.designRevision = designRevision
        self.library = library
        self.profiles = profiles
        self.machines = machines
        self.results = results
        self.assistantChanges = assistantChanges
    }
}
