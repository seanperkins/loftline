import SwiftUI
import LoftLineKit

/// A folder save held until the user agrees to replace the files already there.
struct ReplaceRequest {
    var set: GCodeFileSet
    var directory: URL
    /// The planned names already in the folder, which the user is asked about and which the write
    /// is then allowed to replace.
    var names: [String]
    /// Those of them that are symbolic links: the link is replaced, not the file it points to.
    var links: [String]
    /// What the document was made of when `set` was posted: the write is refused if it has changed since.
    var postedFrom: LoftLineDocument.PostedInputs?

    init(set: GCodeFileSet, directory: URL, postedFrom: LoftLineDocument.PostedInputs? = nil) {
        self.set = set
        self.directory = directory
        self.postedFrom = postedFrom
        names = set.existing(in: directory)
        links = set.links(in: directory)
    }

    /// The message for the alert: the first few names, a count for the rest, and a word about links.
    var summary: String {
        let shown = names.prefix(5).joined(separator: ", ")
        let more = names.count - min(names.count, 5)
        var text = "The folder already has \(more > 0 ? "\(shown) and \(more) more" : shown). Saving writes the whole set over \(names.count == 1 ? "it" : "them")."
        if !links.isEmpty {
            text += " \(links.count == 1 ? "\(links[0]) is a link" : "\(links.count) of them are links"): the link is replaced by a file, and what it pointed to is left as it is."
        }
        return text
    }
}

extension View {
    /// "Replace N files?" before a set writes over files already in the folder. Attach it to a view
    /// of its own (a view carries one alert), and the request is handed to the button so a dismissal
    /// that clears the binding cannot empty the action.
    func replaceFilesAlert(_ request: Binding<ReplaceRequest?>, onReplace: @escaping (ReplaceRequest) -> Void) -> some View {
        let n = request.wrappedValue?.names.count ?? 0
        return alert("Replace \(n) file\(n == 1 ? "" : "s")?",
                     isPresented: Binding(get: { request.wrappedValue != nil }, set: { if !$0 { request.wrappedValue = nil } }),
                     presenting: request.wrappedValue) { r in
            Button("Replace", role: .destructive) { onReplace(r) }
            Button("Cancel", role: .cancel) {}
        } message: { r in
            Text(r.summary)
        }
    }
}
