import CADCore
import PostCore
import SwiftUI

/// Post picker listing the machine's own posts first, then any others.
struct PostProfilePicker: View {
    var title: String
    @Binding var selection: String
    var machine: MachineDefinition?
    /// The project's own post when it is carried in the file but not installed here, so the selection still shows.
    var carried: PostProfile?
    @ObservedObject private var posts = PostProfileCatalog.shared

    /// The entries: the installed posts split by machine, and the carried post when it is not among them.
    static func entries(installed: [PostProfile], carried: PostProfile?, machine: MachineDefinition?)
        -> (compatible: [PostProfile], other: [PostProfile], carried: (id: String, title: String)?) {
        let split = MachineResolver.orderedPosts(installed, machine: machine)
        let extra = carried.flatMap { c in installed.contains { $0.id == c.id } ? nil : (id: c.id, title: "\(c.name) (not installed here)") }
        return (split.compatible, split.other, extra)
    }

    var body: some View {
        let split = Self.entries(installed: posts.profiles, carried: carried, machine: machine)
        Picker(title, selection: $selection) {
            if let extra = split.carried { Text(extra.title).tag(extra.id) }
            ForEach(split.compatible) { Text($0.name).tag($0.id) }
            if !split.other.isEmpty {
                Divider()
                ForEach(split.other) { Text($0.name + " (other machine)").tag($0.id) }
            }
        }
    }
}
