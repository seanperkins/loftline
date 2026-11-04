import Foundation
import Testing
@testable import CADCore

@Suite struct DrawingKerningTests {
    func box(_ p: [Path]) -> Rect2 { Rect2(points: p.flatMap { $0.flattened() }) }

    @Test func zeroAdjustmentMatchesNormalLayout() throws {
        for font in [testFont, StrokeFont.name] {
            var spec = TextSpec(string: "AV\nTo", fontName: font, size: 1, alignment: .center, anchor: Vec2(3, 3))
            let plain = try TextOutliner().outlines(for: spec)
            spec.letterAdjustments = [TextSpec.LetterAdjustment(index: 0)]
            let kerned = try TextOutliner().outlines(for: spec)
            let a = box(plain), b = box(kerned)
            #expect(a.min.isApproximatelyEqual(to: b.min, tolerance: 1e-6) && a.max.isApproximatelyEqual(to: b.max, tolerance: 1e-6))
            #expect(try TextKerning.letterCount(spec) == 4)
        }
    }

    @Test func moveAndRotateOneLetter() throws {
        var spec = TextSpec(string: "AB", fontName: testFont, size: 1)
        let base = try TextOutliner().outlines(for: spec)
        spec.letterAdjustments = [TextSpec.LetterAdjustment(index: 1, offset: Vec2(0, 2))]
        let moved = try TextOutliner().outlines(for: spec)
        #expect(abs(box(moved).max.y - box(base).max.y - 2) < 1e-6)
        spec.letterAdjustments = [TextSpec.LetterAdjustment(index: 0, rotation: 90)]
        let turned = try TextOutliner().outlines(for: spec)
        #expect(box(turned) != box(base))
        // Old specs without adjustments still decode.
        let json = try JSONEncoder().encode(TextSpec(string: "A", fontName: testFont, size: 1))
        #expect(!String(decoding: json, as: UTF8.self).contains("letterAdjustments"))
    }

    @Test func lettersHitAndDrag() throws {
        let spec = TextSpec(string: "A B\nC", fontName: testFont, size: 1, anchor: Vec2(10, 10))
        let letters = try TextKerning.letters(for: spec)
        #expect(letters.count == 4)
        #expect(letters.map(\.line) == [0, 0, 0, 1])
        #expect(letters[1].paths.isEmpty) // the space
        let b = letters[2].bounds
        #expect(TextKerning.letter(at: b.center, in: letters, tolerance: 0)?.index == 2)
        #expect(TextKerning.letter(at: Vec2(0, 0), in: letters, tolerance: 0.01) == nil)
        // Moving letter 2 by +1 in X shifts only its outline.
        let moved = TextKerning.moving(spec, letters: [2], byDocumentDelta: Vec2(1, 0))
        let after = try TextKerning.letters(for: moved)
        #expect(after[2].bounds.min.isApproximatelyEqual(to: b.min + Vec2(1, 0), tolerance: 1e-6))
        #expect(after[0].bounds == letters[0].bounds)
        // Moving it back drops the adjustment entirely.
        #expect(TextKerning.moving(moved, letters: [2], byDocumentDelta: Vec2(-1, 0)).letterAdjustments == nil)
    }

    @Test func dragFollowsScaledRotatedText() throws {
        var spec = TextSpec(string: "AB", fontName: testFont, size: 1)
        spec.transform = Transform2D.scale(2, 2).concatenating(.rotation(.pi / 2))
        let before = try TextKerning.letters(for: spec)[1].bounds
        let moved = TextKerning.moving(spec, letters: [1], byDocumentDelta: Vec2(0, 3))
        #expect(moved.letterAdjustments?.first?.offset.isApproximatelyEqual(to: Vec2(1.5, 0), tolerance: 1e-9) == true)
        let after = try TextKerning.letters(for: moved)[1].bounds
        #expect(after.min.isApproximatelyEqual(to: before.min + Vec2(0, 3), tolerance: 1e-6))
    }
}
