import Foundation

/// What each tool is over the live link, and so how a window runs it (spec 2, "Tool kinds"). The link classifies every call
/// before a host sees it; a host switches on the kind and never compares tool names itself.
public enum LinkToolKind: Equatable, Sendable {
    case edit, calculate, read, writeFiles, save, never

    static let table: [String: LinkToolKind] = [
        "set_job": .edit, "add_shapes": .edit, "edit_shapes": .edit, "import_file": .edit, "edit_layers": .edit,
        "add_toolpath": .edit, "update_toolpath": .edit, "delete_toolpath": .edit,
        "calculate": .calculate,
        "describe_project": .read, "list_library": .read, "check": .read, "preview": .read, "help": .read,
        "post_gcode": .writeFiles, "job_sheet": .writeFiles,
        "save_project": .save,
        "new_project": .never, "open_project": .never, "undo": .never,
    ]

    /// The kind of a known tool; nil for any other name, which the link refuses.
    public static func of(_ tool: String) -> LinkToolKind? { table[tool] }

    /// The Undo step an edit becomes. Built from this table's names only, never from text off the socket.
    public static func undoName(_ tool: String) -> String {
        precondition(table[tool] != nil, "not a tool")
        return "Assistant: \(tool)"
    }
}
