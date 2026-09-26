import Testing

@testable import SwiftCDDL

/// The bignum prelude types (RFC 8610 Appendix D, RFC 8949 Section 3.4.3):
/// `biguint = #6.2(bstr)`, `bignint = #6.3(bstr)`, `bigint = biguint /
/// bignint`, as values and as member keys.
@Suite struct BignumTests {
    // MARK: - Private helpers

    private func assertValid(
        _ name: String,
        _ cddl: String,
        _ cbor: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let verdict = await cborResult(cddl, cbor, sourceLocation: sourceLocation)
        #expect(
            verdict == nil,
            "\(name): expected valid, got error: \(String(describing: verdict))",
            sourceLocation: sourceLocation
        )
    }

    private func assertInvalid(
        _ name: String,
        _ cddl: String,
        _ cbor: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let verdict = await cborResult(cddl, cbor, sourceLocation: sourceLocation)
        #expect(verdict != nil, "\(name): expected invalid, but it validated", sourceLocation: sourceLocation)
    }

    // MARK: - Tests

    @Test func bignumAsMapKey() async {
        await assertValid("bignint key", "start = { bignint => int }", [0xa1, 0xc3, 0x41, 0x01, 0x01])
        await assertValid("biguint key", "start = { biguint => int }", [0xa1, 0xc2, 0x41, 0x01, 0x01])
        await assertValid("bigint key, tag 2", "start = { bigint => int }", [0xa1, 0xc2, 0x41, 0x01, 0x01])
        await assertValid("bigint key, tag 3", "start = { bigint => int }", [0xa1, 0xc3, 0x41, 0x01, 0x01])
        // A rule name denotes the type it is defined as (RFC 8610 Section
        // 3.1), so an alias of `bignint` as a member key admits the same keys.
        // The first type rule is the validation root; `start` stays first so
        // this exercises the alias as a member key.
        await assertValid(
            "typename alias as key",
            "start = { k => int }\nk = bignint",
            [0xa1, 0xc3, 0x41, 0x01, 0x01]
        )

        await assertInvalid("bignint key given tag 2", "start = { bignint => int }", [0xa1, 0xc2, 0x41, 0x01, 0x01])
        await assertInvalid("biguint key given tag 3", "start = { biguint => int }", [0xa1, 0xc3, 0x41, 0x01, 0x01])
        await assertInvalid("bignum tag wrapping a non-bstr", "start = { bignint => int }", [0xa1, 0xc3, 0x01, 0x01])
        await assertInvalid("plain int key is not a bignum", "start = { bignint => int }", [0xa1, 0x01, 0x01])
        await assertInvalid("unknown tag as key", "start = { bignint => int }", [0xa1, 0xc5, 0x41, 0x01, 0x01])
        await assertInvalid("map value is still validated", "start = { bignint => tstr }", [0xa1, 0xc3, 0x41, 0x01, 0x01])
    }

    /// Occurrence indicators on a bignum member key.
    @Test func bignumAsMapKeyWithOccurrence() async {
        await assertValid("* with empty map", "start = { * bignint => int }", [0xa0])
        await assertValid("* with one entry", "start = { * bignint => int }", [0xa1, 0xc3, 0x41, 0x01, 0x01])
        await assertValid(
            "* with two entries",
            "start = { * bignint => int }",
            [0xa2, 0xc3, 0x41, 0x01, 0x01, 0xc3, 0x41, 0x02, 0x02]
        )
        await assertValid("+ with one entry", "start = { + bignint => int }", [0xa1, 0xc3, 0x41, 0x01, 0x01])
        await assertValid(
            "* behind .cbor, empty map",
            "start = [payload: x]\nx = bytes .cbor { * bignint => uint }",
            [0x81, 0x41, 0xa0]
        )
        await assertValid(
            "* behind .cbor, one entry",
            "start = [payload: x]\nx = bytes .cbor { * bignint => uint }",
            [0x81, 0x45, 0xa1, 0xc3, 0x41, 0x01, 0x01]
        )

        await assertInvalid(
            "* with second value of wrong type",
            "start = { * bignint => int }",
            [0xa2, 0xc3, 0x41, 0x01, 0x01, 0xc3, 0x41, 0x02, 0x61, 0x78]
        )
        await assertInvalid("* with foreign key", "start = { * bignint => int }", [0xa1, 0x01, 0x01])
        await assertInvalid("* with wrong-tag key", "start = { * bignint => int }", [0xa1, 0xc2, 0x41, 0x01, 0x01])
        await assertInvalid("+ with empty map", "start = { + bignint => int }", [0xa0])
    }

    @Test func bignumAsValue() async {
        await assertValid("[bignint] tag 3", "start = [bignint]", [0x81, 0xc3, 0x41, 0x01])
        await assertValid("[biguint] tag 2", "start = [biguint]", [0x81, 0xc2, 0x41, 0x01])
        await assertValid("[bigint] tag 2", "start = [bigint]", [0x81, 0xc2, 0x41, 0x01])
        await assertValid("[bigint] tag 3", "start = [bigint]", [0x81, 0xc3, 0x41, 0x01])

        await assertInvalid("[bignint] tag 2", "start = [bignint]", [0x81, 0xc2, 0x41, 0x01])
        await assertInvalid("[biguint] tag 3", "start = [biguint]", [0x81, 0xc3, 0x41, 0x01])
        await assertInvalid("[bignint] tag 1", "start = [bignint]", [0x81, 0xc1, 0x01])
        // A tag the validator has no dedicated handling for is still checked
        // against the bignum type.
        await assertInvalid("[bignint] unknown tag 5", "start = [bignint]", [0x81, 0xc5, 0x41, 0x01])
        await assertInvalid("[bignint] tag 3(1)", "start = [bignint]", [0x81, 0xc3, 0x01])
    }
}
