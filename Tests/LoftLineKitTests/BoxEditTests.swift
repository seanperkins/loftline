import CADCore
import Testing
@testable import LoftLineKit

/// What typing a new X, Y, width or height in the inspector does to the selection's bounding box.
@Suite struct BoxEditTests {
    let box = Rect2(x: 1, y: 2, width: 4, height: 2)

    @Test func movingKeepsTheSize() {
        #expect(BoxEdit.x(10).apply(to: box, keepAspect: true) == Rect2(x: 10, y: 2, width: 4, height: 2))
        #expect(BoxEdit.y(-3).apply(to: box, keepAspect: false) == Rect2(x: 1, y: -3, width: 4, height: 2))
    }

    @Test func sizeKeepsTheLowerLeftCornerAndTheProportionsWhenAsked() {
        #expect(BoxEdit.width(8).apply(to: box, keepAspect: true) == Rect2(x: 1, y: 2, width: 8, height: 4))
        #expect(BoxEdit.height(1).apply(to: box, keepAspect: true) == Rect2(x: 1, y: 2, width: 2, height: 1))
    }

    @Test func withoutProportionsTheOtherSideIsUntouched() {
        #expect(BoxEdit.width(8).apply(to: box, keepAspect: false) == Rect2(x: 1, y: 2, width: 8, height: 2))
        #expect(BoxEdit.height(5).apply(to: box, keepAspect: false) == Rect2(x: 1, y: 2, width: 4, height: 5))
    }

    @Test func aSizeNeverReachesZero() {
        #expect(BoxEdit.width(0).apply(to: box, keepAspect: false).width > 0)
        #expect(BoxEdit.height(-2).apply(to: box, keepAspect: false).height > 0)
    }

    @Test func aFlatBoxDoesNotDivideByZero() {
        let flat = Rect2(x: 0, y: 0, width: 5, height: 0)
        let r = BoxEdit.width(10).apply(to: flat, keepAspect: true)
        #expect(r.width == 10)
        #expect(r.height.isFinite)
    }
}

@Suite struct BoxEditNoiseTests {
    let box = Rect2(x: 7.545321, y: 5, width: 9.097712, height: 2.5)

    @Test func theDisplayedValueIsNotAnEdit() {
        // The fields show four decimals, and leaving one re-commits that rounded text.
        #expect(!BoxEdit.x(7.5453).changes(box))
        #expect(!BoxEdit.width(9.0977).changes(box))
        #expect(!BoxEdit.y(5).changes(box))
        #expect(!BoxEdit.height(2.5).changes(box))
    }

    @Test func aRealChangeIsAnEdit() {
        #expect(BoxEdit.x(7.6).changes(box))
        #expect(BoxEdit.width(9.1).changes(box))
        #expect(BoxEdit.y(5.001).changes(box))
        #expect(BoxEdit.height(3).changes(box))
    }
}
