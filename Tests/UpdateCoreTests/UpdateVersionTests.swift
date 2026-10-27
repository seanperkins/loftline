import Testing
import UpdateCore

@Suite struct UpdateVersionTests {
    @Test func numericNotLexicalOrder() {
        #expect(UpdateVersion.compare("0.4.10", "0.4.9") == 1)
        #expect(UpdateVersion.compare("0.4.9", "0.4.10") == -1)
    }

    @Test func suffixAfterDigitsIsIgnored() {
        #expect(UpdateVersion.compare("0.4.0-rc1", "0.4.0") == 0)
        // A dot inside the suffix must not add a part: 0.4.0-rc.1 is not newer than 0.4.0.
        #expect(UpdateVersion.compare("0.4.0-rc.1", "0.4.0") == 0)
        #expect(UpdateVersion.compare("0.4.0+build.5", "0.4.0") == 0)
    }

    @Test func leadingVIsIgnored() {
        #expect(UpdateVersion.compare("v1.2.3", "1.2.3") == 0)
        #expect(UpdateVersion.compare("v1.2.4", "1.2.3") == 1)
    }

    @Test func missingPartsAreZero() {
        #expect(UpdateVersion.compare("1.2", "1.2.0") == 0)
        #expect(UpdateVersion.compare("1.2", "1.2.1") == -1)
        #expect(UpdateVersion.compare("1.2.0.0.1", "1.2") == 1)
    }

    @Test func aPartWithNoDigitsCountsAsZero() {
        #expect(UpdateVersion.compare("1.x.3", "1.0.3") == 0)
        #expect(UpdateVersion.compare("", "0") == 0)
    }

    @Test func leadingZerosAreNotSignificant() {
        #expect(UpdateVersion.compare("1.02", "1.2") == 0)
    }

    @Test func veryLongNumbersDoNotOverflow() {
        #expect(UpdateVersion.compare("1.99999999999999999999999", "1.99999999999999999999998") == 1)
        #expect(UpdateVersion.compare("1.99999999999999999999998", "1.99999999999999999999999") == -1)
    }

    @Test func isNewerIsStrict() {
        #expect(UpdateVersion.isNewer("0.4.10", than: "0.4.9"))
        #expect(!UpdateVersion.isNewer("0.4.9", than: "0.4.9"))
        #expect(!UpdateVersion.isNewer("0.4.8", than: "0.4.9"))
    }
}
