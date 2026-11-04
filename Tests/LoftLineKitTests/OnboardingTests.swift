import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineKit

@Suite struct OnboardingTests {
    @Test func samplesAreFoundInTheCheckout() throws {
        for s in SampleProjects.all {
            let url = try #require(SampleProjects.url(for: s), "\(s.fileName) not found")
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
        // The sign opens as a project with toolpaths ready to calculate.
        let url = try #require(SampleProjects.url(for: SampleProjects.sign))
        let project = try LoftLineProject.decode(from: Data(contentsOf: url))
        #expect(project.operations.count >= 4)
    }

    @Test func bundleFolderWinsOverCheckout() throws {
        let dir = AppTestSupport.tempDir()
        try Data("{}".utf8).write(to: dir.appendingPathComponent(SampleProjects.sign.fileName))
        let found = SampleProjects.url(for: SampleProjects.sign, in: [dir] + SampleProjects.searchDirectories())
        #expect(found?.deletingLastPathComponent().standardizedFileURL == dir.standardizedFileURL)
        #expect(SampleProjects.url(for: SampleProjects.sign, in: [AppTestSupport.tempDir()]) == nil)
    }

}
