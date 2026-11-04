import CADCore
import Foundation

/// Job notes (io-job-notes): free text saved in the .loftline file, optionally shown when the file
/// is opened, and printed on the job sheet.
extension Document {
    /// The notes with surrounding blank lines/spaces removed ("" = none).
    public var jobNotes: String {
        get { notes ?? "" }
        set {
            let t = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            notes = t.isEmpty ? nil : t
        }
    }

    /// Whether opening the file shows the notes.
    public var showsNotesOnOpen: Bool {
        get { showNotesOnOpen ?? false }
        set { showNotesOnOpen = newValue ? true : nil }
    }

    /// True when the notes should pop up as the document window opens.
    public var wantsNotesOnOpen: Bool { showsNotesOnOpen && !jobNotes.isEmpty }
}
