import AppKit
import CADCore
import CAMCore
import Foundation
import SwiftUI
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite @MainActor struct IOJobNotesTests {
    @Test func notesAreSavedWithTheFile() throws {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        #expect(!doc.document.wantsNotesOnOpen)
        doc.setJobNotes("  Face side down.\nClamp at the corners.\n\n", showOnOpen: true)
        #expect(doc.document.jobNotes == "Face side down.\nClamp at the corners.")
        let back = try LoftLineProject.decode(from: doc.project.encoded())
        #expect(back.document.notes == "Face side down.\nClamp at the corners.")
        #expect(back.document.wantsNotesOnOpen)
        // Blank notes are stored as nothing; older files without notes decode.
        doc.setJobNotes("   ", showOnOpen: false)
        #expect(doc.document.notes == nil && doc.document.showNotesOnOpen == nil)
    }

    @Test func notesOpenAutomaticallyOnlyWhenAsked() async throws {
        var p = AppTestSupport.project()
        p.document.jobNotes = "Use the 1/4 in downcut."
        let quiet = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        quiet.showJobNotesOnOpenIfNeeded()
        p.document.showsNotesOnOpen = true
        let loud = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        loud.showJobNotesOnOpenIfNeeded()
        // The sheet is presented on a later main-queue turn; poll instead of trusting one fixed wait.
        for _ in 0..<200 where loud.sheet == nil {
            await Task.yield()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(quiet.sheet == nil)
        #expect(loud.sheet == .io(.jobNotes(openedWithFile: true)))
    }

    @Test func jobSheetPrintsTheNotes() {
        let doc = LoftLineDocument(project: AppTestSupport.project(), toolLibrary: AppTestSupport.library())
        doc.setJobNotes("Spoilboard surfaced <today> & level", showOnOpen: false)
        let js = doc.makeJobSheet(settings: TimeEstimateSettings())
        #expect(js.notes == "Spoilboard surfaced <today> & level")
        let html = JobSheetHTML.render(js)
        #expect(html.contains("<h2>Notes</h2>"))
        #expect(html.contains("Spoilboard surfaced &lt;today&gt; &amp; level"))
        doc.setJobNotes("", showOnOpen: false)
        #expect(!JobSheetHTML.render(doc.makeJobSheet(settings: TimeEstimateSettings())).contains("<h2>Notes</h2>"))
    }

    @Test func notesSheetRenders() throws {
        var p = AppTestSupport.project()
        p.document.jobNotes = "Hello"
        let doc = LoftLineDocument(project: p, toolLibrary: AppTestSupport.library())
        let host = NSHostingView(rootView: JobNotesSheet(document: doc, openedWithFile: true))
        host.frame = NSRect(x: 0, y: 0, width: 480, height: 400)
        #expect(AppTestSupport.looksDrawn(try #require(AppTestSupport.png(of: host))))
    }
}
