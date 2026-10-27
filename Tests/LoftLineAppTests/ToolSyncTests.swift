import CADCore
import CAMCore
import Foundation
import PostCore
import Testing
@testable import LoftLineApp

/// A project carries the tools its operations use and posts with them; the library supplies only what it does not carry.
@Suite struct ToolSyncTests {
    /// A project with one profile toolpath, and the seeded tool it uses (not yet carried).
    func projectWithAProfile() throws -> (project: LoftLineProject, tool: Tool) {
        var p = AppTestSupport.project()
        let op = try #require(OperationFactory.make(kind: .profile, project: p, library: .seeded, shapeIDs: [p.document.shapes[0].id]))
        p.upsertOperation(op)
        return (p, try #require(ToolLibrary.seeded.tool(id: op.setup.toolID)))
    }

    @Test func theProjectsToolWinsOverADifferingLibraryTool() throws {
        let (p, tool) = try projectWithAProfile()
        var carried = p
        var edited = tool
        edited.feedRate = 55
        carried.tools = [edited]
        #expect(carried.mergedTools(with: .seeded).tool(id: tool.id)?.feedRate == 55, "the file's tool, not the library's")
        let other = ToolLibrary.seeded.tools.first { $0.id != tool.id }!
        #expect(carried.mergedTools(with: .seeded).tool(id: other.id) == other, "the library supplies what the project lacks")
    }

    @Test func carryingAddsAReferencedToolAndDropsAnUnreferencedOne() throws {
        var (p, tool) = try projectWithAProfile()
        let stray = ToolLibrary.seeded.tools.first { $0.id != tool.id }!
        p.tools = [stray]
        let carried = ToolSync.carrying(p, library: .seeded)
        #expect(carried.tools == [tool], "the used tool is added from the library, the unused one dropped")
        #expect(ToolSync.carrying(carried, library: .seeded) == carried, "idempotent")
    }

    @Test func carryingKeepsADifferingCarriedToolAndSkipsOneNobodyHas() throws {
        var (p, tool) = try projectWithAProfile()
        var edited = tool
        edited.feedRate = 55
        p.tools = [edited]
        #expect(ToolSync.carrying(p, library: .seeded).tools == [edited])
        #expect(ToolSync.carrying(p, library: ToolLibrary(tools: [])).tools == [edited])
        p.tools = []
        #expect(ToolSync.carrying(p, library: ToolLibrary(tools: [])).tools.isEmpty)
    }

    @Test func savingNoLongerOverwritesTheFilesToolFromTheLibrary() throws {
        var (p, tool) = try projectWithAProfile()
        var edited = tool
        edited.feedRate = 55
        p.tools = [edited]
        p.refreshToolSnapshot(from: .seeded)
        #expect(p.tools == [edited])
    }

    @Test func aCarriedCopyThatWasInStepFollowsALibraryEdit() throws {
        var (p, tool) = try projectWithAProfile()
        p.tools = [tool]
        let old = ToolLibrary.seeded
        var changed = tool
        changed.diameter = 0.375; changed.feedRate += 10
        var new = old
        new.upsert(changed)
        let followed = ToolSync.applyingLibraryChange(old: old, new: new, to: p)
        #expect(followed.tools == [changed])
        #expect(ToolSync.applyingLibraryChange(old: old, new: old, to: p) == p, "nothing changed in the library")
    }

    @Test func aCopyThatHadDivergedDoesNotFollowALabelOnlyEdit() throws {
        var (p, tool) = try projectWithAProfile()
        var diverged = tool
        diverged.diameter = 0.5
        p.tools = [diverged]
        let old = ToolLibrary.seeded
        var renamed = tool
        renamed.name = "Renamed in the library"
        var new = old
        new.upsert(renamed)
        let after = ToolSync.applyingLibraryChange(old: old, new: new, to: p)
        #expect(after.tools == [diverged], "a rename cannot swap the diameter of a copy that already differed")
    }

    @Test func followingKeepsTheCarriedNotesAndGroup() throws {
        var (p, tool) = try projectWithAProfile()
        var mine = tool
        mine.notes = "my note"; mine.group = "My folder"
        p.tools = [mine]
        let old = ToolLibrary.seeded
        var changed = tool
        changed.diameter = 0.375; changed.notes = "library note"; changed.group = "Library folder"
        var new = old
        new.upsert(changed)
        let after = try #require(ToolSync.applyingLibraryChange(old: old, new: new, to: p).tools.first)
        #expect(after.diameter == 0.375 && after.notes == "my note" && after.group == "My folder")
    }

    @Test func theComparisonIgnoresNotesAndGroupButNotTheName() {
        let tool = ToolLibrary.seeded.tools[0]
        var other = tool
        other.notes = "x"; other.group = "y"
        #expect(tool.samePostingFields(as: other))
        other.name = "Another name"
        #expect(!tool.samePostingFields(as: other), "the name is written into the tool-change comment")
        other = tool
        other.diameter += 0.01
        #expect(!tool.samePostingFields(as: other))
    }

    @Test func theWarningNamesTheToolAndWhatDiffers() throws {
        var (p, tool) = try projectWithAProfile()
        var edited = tool
        edited.diameter = 0.5
        p.tools = [edited]
        let issues = ToolSync.issues(for: p, library: .seeded)
        let issue = try #require(issues.first)
        #expect(issues.count == 1 && issue.severity == .warning)
        #expect(issue.message.contains(tool.name) && issue.message.contains("diameter")
                && issue.message.contains("0.5") && issue.message.contains("0.25") && issue.message.contains("Update This Project"))
        p.tools = [tool]
        #expect(ToolSync.issues(for: p, library: .seeded).isEmpty)
        var notesOnly = tool
        notesOnly.notes = "different"
        p.tools = [notesOnly]
        #expect(ToolSync.issues(for: p, library: .seeded).isEmpty)
        #expect(ToolSync.issues(for: p, library: ToolLibrary(tools: [])).isEmpty, "no library counterpart: nothing to compare")
    }

    @Test func updateReplacesToolsThatHaveACounterpartAndKeepsTheOthers() throws {
        var (p, tool) = try projectWithAProfile()
        var edited = tool
        edited.diameter = 0.5; edited.notes = "carried note"
        var orphan = ToolLibrary.seeded.tools.first { $0.id != tool.id }!
        orphan.name = "Only in the file"; orphan.id = UUID()
        p.tools = [edited, orphan]
        let updated = ToolSync.updated(p, library: .seeded)
        #expect(updated.tools.first { $0.id == tool.id } == tool, "the library's tool, whole")
        #expect(updated.tools.contains(orphan), "a tool with no library counterpart is kept")
    }
}
