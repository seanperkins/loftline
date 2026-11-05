import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// The Tool Database editor commits each edit; switching tools must not lose one.
@MainActor
@Test func toolEditorEditsSurviveSwitchingSelection() throws {
    let lib = AppTestSupport.library()
    let first = try #require(lib.tools.first)
    let other = try #require(lib.tools.dropFirst().first)
    var edited = first
    edited.feedRate += 17
    edited.spindleRPM = 12345
    #expect(lib.commitEdit(edited))
    // Selecting another tool builds a new editor from the library; the edit is there.
    _ = lib.library.tool(id: other.id)
    #expect(lib.library.tool(id: first.id) == edited)
    // And it is on disk: a fresh model on the same store reads it back.
    let reloaded = ToolLibraryModel(store: lib.store)
    #expect(reloaded.library.tool(id: first.id)?.spindleRPM == 12345)
    // No-op commits and deleted tools do not write.
    #expect(!lib.commitEdit(edited))
    lib.delete(id: other.id)
    var ghost = other
    ghost.name = "ghost"
    #expect(!lib.commitEdit(ghost))
    #expect(lib.library.tool(id: other.id) == nil)
}
