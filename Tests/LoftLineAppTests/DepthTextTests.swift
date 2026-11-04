import Foundation
import Testing
@testable import LoftLineApp
@testable import LoftLineKit

/// Issue #96. `%g` keeps six significant digits, so from 1000 up the third decimal was dropped ("1234.57").
@Test(arguments: [
    (0.125, "0.125"), (-0.77, "-0.77"), (19.05, "19.05"), (0.0, "0"), (-0.0, "0"), (1e-5, "0"), (0.0004, "0"),
    (2438.4, "2438.4"), (1234.568, "1234.568"), (123456.789, "123456.789"), (12.0, "12"), (-1219.225, "-1219.225"),
])
func depthTextKeepsThreeDecimalsAtAnyMagnitude(value: Double, text: String) {
    #expect(DepthText.number(value) == text)
}
