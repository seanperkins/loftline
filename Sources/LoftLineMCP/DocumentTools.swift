import Foundation

/// list_open_documents and use_open_document: the live link into the open app (spec 2, "The server").
enum DocumentTools {
    static func all(link: DocumentMode) -> [AssistantTool] {
        let list = AssistantTool(
            name: "list_open_documents",
            description: "Lists the documents open in LoftLine (name, id, unsaved changes, whether another assistant holds it), so one "
                + "can be picked with use_open_document. Needs LoftLine running with \"Let assistants edit open documents\" on.",
            inputSchema: Schema.object([:])) { _ in
                let docs: [LinkDocument]
                do { docs = try link.documents() } catch { return ToolOutput(text: (error as? LocalizedError)?.errorDescription ?? "\(error)") }
                let rows = docs.map { ["name": $0.name, "id": $0.id, "unsaved": $0.unsaved] as [String: Any] }
                return Reply.output("\(docs.count) open document\(docs.count == 1 ? "" : "s").", ["documents": rows])
            }
        let use = AssistantTool(
            name: "use_open_document",
            description: "Works on a document open in LoftLine, by its name or id: the user clicks Allow in its window the first time. "
                + "Every later call reads or changes that window (each change is one Undo step there) until open_project or new_project. "
                + "Undo stays the user's.",
            inputSchema: Schema.object(["document": Schema.string("The window's name or id, from list_open_documents.")],
                                       required: ["document"])) { raw in
                let reference = try Args(raw).requireString("document")
                let name = try link.use(reference)
                return ToolOutput(text: "Working on \(name), open in LoftLine. Later calls go to that window until open_project or new_project.")
            }
        return [list, use]
    }
}
