import Testing

@testable import SwiftCDDL

/// Range endpoint semantics per RFC 8610 Section 2.2.2.1: `..` includes both
/// endpoints; `...` includes the lower endpoint and excludes only the upper.
/// Ranges are defined between two integer values (matching integers) or
/// between two floating-point values (matching floats) only.
@Suite struct RangeEndpointsTests {
    // MARK: - Private helpers

    private struct Claim {
        var cddl: String
        var cbor: String
        var accept: Bool
        var rationale: String

        init(_ cddl: String, _ cbor: String, _ accept: Bool, _ rationale: String) {
            self.cddl = cddl
            self.cbor = cbor
            self.accept = accept
            self.rationale = rationale
        }
    }

    private func check(_ claims: [Claim], sourceLocation: SourceLocation = #_sourceLocation) async {
        for claim in claims {
            let verdict = await cborResult(claim.cddl, hexBytes(claim.cbor), sourceLocation: sourceLocation)
            #expect(
                (verdict == nil) == claim.accept,
                "\(claim.cddl) with CBOR \(claim.cbor) should \(claim.accept ? "accept" : "reject"): \(claim.rationale) (got \(String(describing: verdict)))",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - Tests

    @Test func rangeEndpointsNintToNintInclusive() async {
        // `..` includes both endpoints for integer ranges.
        await check([
            Claim("t = -10..-3", "2a", false, "-11 is below lower endpoint -10"),
            Claim("t = -10..-3", "29", true, "lower endpoint -10 is included"),
            Claim("t = -10..-3", "26", true, "-7 is mid-window"),
            Claim("t = -10..-3", "22", true, "upper endpoint -3 is included"),
            Claim("t = -10..-3", "21", false, "-2 is above upper endpoint -3"),
        ])
    }

    @Test func rangeEndpointsNintToNintExclusiveUpper() async {
        // `...` includes the lower endpoint and excludes only the upper
        // endpoint.
        await check([
            Claim("t = -10...-3", "2a", false, "-11 is below lower endpoint -10"),
            Claim("t = -10...-3", "29", true, "lower endpoint -10 is included"),
            Claim("t = -10...-3", "26", true, "-7 is mid-window"),
            Claim("t = -10...-3", "22", false, "upper endpoint -3 is excluded"),
            Claim("t = -10...-3", "21", false, "-2 is above upper endpoint -3"),
        ])
    }

    @Test func rangeEndpointsNintToUintInclusive() async {
        // Integer ranges match integer values, including sign-spanning ranges.
        await check([
            Claim("t = -10..10", "2a", false, "-11 is below lower endpoint -10"),
            Claim("t = -10..10", "29", true, "lower endpoint -10 is included"),
            Claim("t = -10..10", "00", true, "0 is mid-window"),
            Claim("t = -10..10", "0a", true, "upper endpoint 10 is included"),
            Claim("t = -10..10", "0b", false, "11 is above upper endpoint 10"),
        ])
    }

    @Test func rangeEndpointsNintToUintExclusiveUpper() async {
        // Sign-spanning `...` ranges include the lower endpoint and exclude
        // only the upper endpoint.
        await check([
            Claim("t = -10...10", "2a", false, "-11 is below lower endpoint -10"),
            Claim("t = -10...10", "29", true, "lower endpoint -10 is included"),
            Claim("t = -10...10", "00", true, "0 is mid-window"),
            Claim("t = -10...10", "0a", false, "upper endpoint 10 is excluded"),
            Claim("t = -10...10", "0b", false, "11 is above upper endpoint 10"),
        ])
    }

    @Test func rangeEndpointsFloatToFloatInclusive() async {
        // Float ranges match floating-point values only.
        await check([
            Claim("t = 0.5..10.5", "fbbfe0000000000000", false, "-0.5 is below lower endpoint 0.5"),
            Claim("t = 0.5..10.5", "fb3fe0000000000000", true, "lower endpoint 0.5 is included"),
            Claim("t = 0.5..10.5", "fb4016000000000000", true, "5.5 is mid-window"),
            Claim("t = 0.5..10.5", "fb4025000000000000", true, "upper endpoint 10.5 is included"),
            Claim("t = 0.5..10.5", "fb4027000000000000", false, "11.5 is above upper endpoint 10.5"),
            Claim("t = 0.5..10.5", "f97e00", false, "NaN is unordered and must not match a bounded range"),
            Claim(
                "t = 0.5..10.5", "05", false,
                "float ranges match floating-point values, not integer encodings"
            ),
        ])
    }

    @Test func rangeEndpointsFloatToFloatExclusiveUpper() async {
        // Float `...` ranges include the lower endpoint and exclude only the
        // upper endpoint.
        await check([
            Claim("t = 0.5...10.5", "fbbfe0000000000000", false, "-0.5 is below lower endpoint 0.5"),
            Claim("t = 0.5...10.5", "fb3fe0000000000000", true, "lower endpoint 0.5 is included"),
            Claim("t = 0.5...10.5", "fb4016000000000000", true, "5.5 is mid-window"),
            Claim("t = 0.5...10.5", "fb4025000000000000", false, "upper endpoint 10.5 is excluded"),
            Claim("t = 0.5...10.5", "fb4027000000000000", false, "11.5 is above upper endpoint 10.5"),
            Claim("t = 0.5...10.5", "f97e00", false, "NaN is unordered and must not match a bounded range"),
        ])
    }

    @Test func rangeEndpointsUintToUintControls() async {
        // uint..uint ranges keep working, with half-open semantics on `...`.
        await check([
            Claim("t = 5..10", "04", false, "4 is below lower endpoint 5"),
            Claim("t = 5..10", "05", true, "lower endpoint 5 is included"),
            Claim("t = 5..10", "07", true, "7 is mid-window"),
            Claim("t = 5..10", "0a", true, "upper endpoint 10 is included"),
            Claim("t = 5..10", "0b", false, "11 is above upper endpoint 10"),
            Claim("t = 5...10", "04", false, "4 is below lower endpoint 5"),
            Claim("t = 5...10", "05", true, "lower endpoint 5 is included"),
            Claim("t = 5...10", "07", true, "7 is mid-window"),
            Claim("t = 5...10", "0a", false, "upper endpoint 10 is excluded"),
            Claim("t = 5...10", "0b", false, "11 is above upper endpoint 10"),
        ])
    }
}
