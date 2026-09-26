import Testing

@testable import SwiftCDDL

/// Integer and float literals written in radix and hexfloat notation (RFC 8610
/// Section 3.1 and Appendix B; RFC 9682 Section 3.2) denote the values they
/// spell, wherever a literal may stand. The literals that must not parse are
/// covered by the literal tests.
@Suite struct RadixLiteralValidationTests {
    // MARK: - Private helpers

    /// The schema parses, and the CBOR document `cborHex` matches it.
    private func assertValidClaim(_ cddl: String, _ cborHex: String, sourceLocation: SourceLocation = #_sourceLocation) async {
        do {
            _ = try cddlFromStr(cddl)
        } catch {
            Issue.record("the parser rejected \(cddl.debugDescription): \(error)", sourceLocation: sourceLocation)
            return
        }
        await expectValid(cddl, hexBytes(cborHex), sourceLocation: sourceLocation)
    }

    // MARK: - Tests

    /// RFC 8610 Appendix B: uint = ... / "0x" 1*HEXDIG.
    @Test func radixHexUintValue() async {
        await assertValidClaim("thing = 0x10", "10")
    }

    /// RFC 8610 Appendix B: uint = ... / "0b" 1*BINDIG.
    @Test func radixBinUintValue() async {
        await assertValidClaim("thing = 0b1010", "0a")
    }

    /// RFC 8610 Section 3.1: hex numbers are case insensitive, including the "0x" prefix.
    @Test func radixHexUpperPrefix() async {
        await assertValidClaim("thing = 0X10", "10")
    }

    /// RFC 8610 Section 3.1: binary numbers are case insensitive, including the "0b" prefix.
    @Test func radixBinUpperPrefix() async {
        await assertValidClaim("thing = 0B1010", "0a")
    }

    /// RFC 8610 Section 3.1: hex digits a-f match in lower case too.
    @Test func radixHexLowercaseDigit() async {
        await assertValidClaim("thing = 0x0f", "0f")
    }

    /// RFC 8610 Appendix B: int = ["-"] uint.
    @Test func radixNegativeHexInt() async {
        await assertValidClaim("thing = -0x10", "2f")
    }

    /// RFC 8610 Appendix B: int = ["-"] uint.
    @Test func radixNegativeBinInt() async {
        await assertValidClaim("thing = -0b101", "24")
    }

    /// RFC 8610 Section 2.2.2.1 and Appendix B rangeop.
    @Test func radixHexRangeBounds() async {
        await assertValidClaim("thing = 0x00..0xff", "18ff")
    }

    /// RFC 8610 Appendix B: memberkey = value S ":".
    @Test func radixHexMemberkeyValue() async {
        await assertValidClaim("thing = {0x10: tstr}", "a1106161")
    }

    /// RFC 8610 Appendix B: memberkey = value S ":".
    @Test func radixBinMemberkeyValue() async {
        await assertValidClaim("thing = {0b1010: tstr}", "a10a6161")
    }

    /// RFC 8610 Section 2.2.3: "#" DIGIT ["." uint].
    @Test func radixMajorAiUint() async {
        await assertValidClaim("thing = #0.0x18", "1818")
    }

    /// RFC 9682 Section 3.2: head-number = uint, so #6.0x20 is tag 32.
    @Test func radixTagHeadNumber() async {
        await assertValidClaim("thing = #6.0x20(tstr)", "d8206161")
    }

    /// RFC 9682 Section 3.2: #7.<head-number> with head-number 32..255 stands for that simple value, so #7.0x20 is simple(32).
    @Test func radixSimpleHeadNumber() async {
        await assertValidClaim("thing = #7.0x20", "f820")
    }

    /// RFC 8610 Appendix B: occur = [uint] "*" [uint], with the same radix-capable uint, so 0x2*0x4 means 2..4 occurrences.
    @Test func radixOccurrenceBounds() async {
        await assertValidClaim("thing = [0x2*0x4 tstr]", "8261616162")
    }

    /// RFC 8610 Appendix B: hexfloat ends with a "p" exponent.
    @Test func hexfloatValidWithPExponent() async {
        await assertValidClaim("thing = 0x1.8p+1", "fb4008000000000000")
    }

    /// RFC 8610 Section 3.1: hex numbers are case insensitive.
    @Test func radixHexUpperDigits() async {
        await assertValidClaim("thing = 0xFF", "18ff")
    }

    /// RFC 8610 Appendix B: uint = ... / "0x" 1*HEXDIG.
    @Test func radixHexZero() async {
        await assertValidClaim("thing = 0x0", "00")
    }

    /// RFC 8610 Appendix B: uint = ... / "0b" 1*BINDIG.
    @Test func radixBinZero() async {
        await assertValidClaim("thing = 0b0", "00")
    }

    /// RFC 8610 Appendix B: uint has no size bound; the full 64-bit range is covered without overflow.
    @Test func radixHexU64Max() async {
        await assertValidClaim("thing = 0xffffffffffffffff", "1bffffffffffffffff")
    }

    /// RFC 8610 Section 3.8.6: the .lt controller is a type1; value = number.
    @Test func radixControlArg() async {
        await assertValidClaim("thing = uint .lt 0x10", "0f")
    }

    /// RFC 8610 Appendix B hexfloat: the fraction is optional, "p" is required.
    @Test func hexfloatNoFraction() async {
        await assertValidClaim("thing = 0x1p3", "fb4020000000000000")
    }

    /// RFC 8610 Appendix B: "p" is a case-insensitive ABNF literal, so 0x1P3 is a valid hexfloat (8.0).
    @Test func hexfloatUpperP() async {
        await assertValidClaim("thing = 0x1P3", "fb4020000000000000")
    }

    /// RFC 8610 Appendix B: hexfloat = ["-"] "0x" ....
    @Test func hexfloatNegative() async {
        await assertValidClaim("thing = -0x1.8p+1", "fbc008000000000000")
    }

    /// Tag numbers (RFC 8610 Section 3.6; RFC 9682 Section 3.2 head-number) cover the full 64-bit range: tag(2^64-1) around the text "a".
    @Test func radixHexTagHeadU64Max() async {
        await assertValidClaim("thing = #6.0xffffffffffffffff(tstr)", "dbffffffffffffffff6161")
    }

    /// RFC 8610 Appendix B: number = hexfloat / (int ["." fraction] ["e" exponent]); the fraction is optional, so 1e5 is a valid float literal (100000.0).
    @Test func floatExponentWithoutFraction() async {
        await assertValidClaim("thing = 1e5", "fb40f86a0000000000")
    }

    /// The float mantissa is an int (RFC 8610 Appendix B), so it has no leading zeros; zero itself and zero-led fractions and exponents remain valid. The parse errors for `042e5` and `01.5` are covered by the literal tests.
    @Test func floatLeadingZeroRejected() async {
        await assertValidClaim("thing = 0.5", "fb3fe0000000000000")
        await assertValidClaim("thing = 1.05e05", "fb40f9a28000000000")
    }

    /// RFC 8610 Appendix B: uint = DIGIT1 *DIGIT / "0".
    @Test func guardrailDecimalUintValue() async {
        await assertValidClaim("thing = 16", "10")
    }

    /// RFC 8610 Appendix B: occur = [uint] "*" [uint].
    @Test func guardrailDecimalOccurrenceBounds() async {
        await assertValidClaim("thing = [2*4 tstr]", "8261616162")
    }

    /// `042` is not a uint literal, but in a group, where entries need no
    /// separating whitespace, it reads as the two entries `0 42`, so `[042]`
    /// matches the array [0, 42] and only that.
    @Test func decimalLeadingZeroRegroupsInArrays() async {
        await assertValidClaim("thing = [042]", "8200182a")
        let verdict = await cborResult("thing = [042]", hexBytes("81182a"))
        #expect(verdict != nil, "[042] must not validate the array [42]")
    }
}
