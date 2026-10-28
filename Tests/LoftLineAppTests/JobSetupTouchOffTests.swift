import CADCore
import Foundation
import Testing
@testable import LoftLineApp

/// The touch-off spot: where the touch plate goes on the material, in the material frame and the document's units.
@Suite struct JobSetupTouchOffTests {
    @Test func olderJobSetupDecodesWithNoSpot() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(JobSetup())) as! [String: Any]
        json.removeValue(forKey: "touchOffSpot")
        let back = try JSONDecoder().decode(JobSetup.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(back.touchOffSpot == nil)
    }

    @Test func touchOffSpotScales() {
        var j = JobSetup()
        j.touchOffSpot = Vec2(2, 3)
        let s = j.scaled(by: 25.4).touchOffSpot
        #expect(abs((s?.x ?? 0) - 50.8) < 1e-9 && abs((s?.y ?? 0) - 76.2) < 1e-9)
    }

    @Test func touchOffSpotRoundTripsUnitsExactly() {
        // Like the datum offset: a spot the user has not edited in the form comes back exactly as the document has it.
        var doc = Document()
        doc.job.touchOffSpot = Vec2(2.125, 3.3)
        var f = JobSetupForm(document: doc)
        f.setUnits(.millimeter)
        f.setUnits(.inch)
        #expect(f.job.touchOffSpot == Vec2(2.125, 3.3))
    }
}
