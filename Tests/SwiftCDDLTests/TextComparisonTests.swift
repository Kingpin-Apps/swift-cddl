import Foundation
import Testing

@testable import SwiftCDDL

/// Text is compared as the scalars it is made of: a precomposed "é" (U+00E9)
/// and a decomposed one ("e" followed by U+0301) are canonically equivalent
/// but distinct text strings (RFC 8949 Section 3.1 compares text strings by
/// their UTF-8 bytes), so neither stands for the other.
@Suite struct TextComparisonTests {
    static let precomposed = "\u{E9}"
    static let decomposed = "e\u{301}"

    @Test func canonicallyEquivalentTextIsDistinct() {
        // The comparison under test is not the language's own string
        // equality, which holds for these two.
        #expect(Self.precomposed == Self.decomposed)
        #expect(!Self.precomposed.utf8.elementsEqual(Self.decomposed.utf8))
    }

    @Test func aTextLiteralMatchesOnlyItsOwnScalars() async throws {
        let cddl = "r = \"\(Self.precomposed)\""
        await expectValid(cddl, CBORNode.text(Self.precomposed).encoded())
        let verdict = await expectInvalid(cddl, CBORNode.text(Self.decomposed).encoded())
        let reported = issues(verdict)
        #expect(reported.map(\.reason) == ["expected value \"\(Self.precomposed)\" got \"\(Self.decomposed)\""])
    }

    @Test func aTextMemberKeyNamesOnlyItsOwnScalars() async throws {
        let cddl = "r = { \"\(Self.precomposed)\": int }"
        let matching = CBORNode.map([(key: .text(Self.precomposed), value: .unsigned(1))])
        await expectValid(cddl, matching.encoded())

        let other = CBORNode.map([(key: .text(Self.decomposed), value: .unsigned(1))])
        let verdict = await cborResult(cddl, other.encoded(), comparePaths: true)
        let reported = issues(verdict)
        #expect(
            reported.map(\.reason) == [
                "map missing key: \"\(Self.precomposed)\"", "unexpected key \"\(Self.decomposed)\"",
            ])
    }

    @Test func dataItemEqualityComparesScalars() {
        #expect(CBORNode.text(Self.precomposed) != CBORNode.text(Self.decomposed))
        #expect(!referenceEquals(.text(Self.precomposed), .text(Self.decomposed)))
        #expect(referenceEquals(.text(Self.precomposed), .text("\u{E9}")))
    }
}

/// The blocking entry points wait for the walk and report what the
/// asynchronous ones do.
@Suite struct BlockingValidationTests {
    @Test func theBlockingEntryPointsReportWhatTheAsynchronousOnesDo() throws {
        try validateCBOR(cddl: "thing = [* int]", cbor: hexBytes("83010203"))
        do {
            try validateCBOR(cddl: "thing = [* int]", cbor: Data(hexBytes("8301f503")))
            Issue.record("a mismatch was reported as a match")
        } catch {
            #expect(error.issues?.map(\.cborLocation) == ["/1"])
        }

        let validator = CBORValidator(cddl: try cddlFromStr("a = uint\nb = tstr\n"), cbor: .text("x"))
        validator.setRootRule("b")
        try validator.validate()
    }
}
