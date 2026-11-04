import CADCore
import CAMCore
import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

@Suite struct JoinVectorsTests {
    private func approx(_ a: Double, _ b: Double, _ tol: Double = 1e-9) -> Bool { abs(a - b) <= tol }

    /// The four sides of a 10 square as separate open shapes; the last side stops `gap` short of the first.
    func square(gap: Double) -> (LoftLineProject, [UUID]) {
        var p = LoftLineProject(document: Document())
        let layer = p.document.defaultLayerID
        let sides = [
            [Vec2(0, 0), Vec2(10, 0)], [Vec2(10, 0), Vec2(10, 10)], [Vec2(10, 10), Vec2(0, 10)], [Vec2(0, 10), Vec2(0, gap)],
        ]
        var ids: [UUID] = []
        for pts in sides {
            let s = Shape(name: "Side", layerID: layer, paths: [Path(points: pts, closed: false)])
            p.document.add(s)
            ids.append(s.id)
        }
        return (p, ids)
    }

    @Test func previewSaysWhatAToleranceWouldDo() throws {
        let (p, ids) = square(gap: 0.0004)
        let pre = try #require(DesignCommands.joinPreview(ids, tolerance: 0.001, in: p))
        #expect(pre.openPieces == 4 && pre.closedAfter == 1 && pre.openAfter == 0)
        #expect(approx(pre.largestGapClosed, 0.0004, 1e-9))
        #expect(pre.nextGap == nil)
    }

    @Test func previewOffersTheNextGapWhenTheToleranceIsTooSmall() throws {
        let (p, ids) = square(gap: 0.004)
        let small = try #require(DesignCommands.joinPreview(ids, tolerance: 0.001, in: p))
        #expect(small.closedAfter == 0 && small.openAfter == 1)
        #expect(approx(try #require(small.nextGap), 0.004, 1e-9))
        let text = small.lines(units: .inch)
        #expect(text.contains { $0.contains("0.004 in") && $0.contains("Raise the tolerance") })
        let big = try #require(DesignCommands.joinPreview(ids, tolerance: 0.005, in: p))
        #expect(big.closedAfter == 1 && big.openAfter == 0)
        #expect(approx(big.largestGapClosed, 0.004, 1e-9))
    }

    @Test func previewIsNilWithNothingToJoin() {
        var (p, ids) = square(gap: 0.0004)
        #expect(DesignCommands.joinPreview([], tolerance: 0.001, in: p) == nil)
        for i in p.document.shapes.indices { p.document.shapes[i].isLocked = true }
        #expect(DesignCommands.joinPreview(ids, tolerance: 0.001, in: p) == nil)
        let rect = Shape(name: "Rect", layerID: p.document.defaultLayerID,
                         paths: [ShapeFactory.rectangle(Rect2(x: 0, y: 0, width: 1, height: 1))])
        p.document.add(rect)
        ids = [rect.id]
        #expect(DesignCommands.joinPreview(ids, tolerance: 0.001, in: p) == nil)
    }

    @Test func linesReadNaturally() {
        let joined = JoinPreview(openPieces: 4, closedAfter: 1, openAfter: 0, largestGapClosed: 0.0004, nextGap: nil)
        #expect(joined.lines(units: .inch) == [
            "1 vector from 4 open pieces: 1 closed, 0 still open.",
            "Ends within this tolerance move to meet; the largest move is 0.0004 in.",
        ])
        let touching = JoinPreview(openPieces: 2, closedAfter: 0, openAfter: 1, largestGapClosed: 0, nextGap: nil)
        #expect(touching.lines(units: .millimeter)[1] == "The joined ends already touch.")
        let apart = JoinPreview(openPieces: 2, closedAfter: 0, openAfter: 2, largestGapClosed: 0, nextGap: 0.3)
        #expect(apart.lines(units: .millimeter) == [
            "2 vectors from 2 open pieces: 0 closed, 2 still open.",
            "No ends meet within this tolerance.",
            "Closest ends still apart: 0.3 mm. Raise the tolerance above that to join them.",
        ])
    }

    @Test func joinUsesTheToleranceItIsGiven() throws {
        let (p, ids) = square(gap: 0.004)
        var narrow = p
        let a = try #require(DesignCommands.join(ids, tolerance: 0.001, in: &narrow))
        #expect(narrow.document.shape(id: a)?.paths.allSatisfy(\.isClosed) == false)
        var wide = p
        let b = try #require(DesignCommands.join(ids, tolerance: 0.005, in: &wide))
        #expect(wide.document.shape(id: b)?.paths.allSatisfy(\.isClosed) == true)
    }

    @Test func theDefaultToleranceKeepsTheOldBehavior() {
        #expect(DesignCommands.defaultJoinTolerance(.inch) == 0.001)
        #expect(DesignCommands.defaultJoinTolerance(.millimeter) == 0.025)
    }
}
