import BigInt
import Testing

@testable import SwiftCDDL

/// Literals at parse time: radix integers and hex floats (RFC 8610 Appendix
/// B), byte string literals (RFC 8610 §3.1, RFC 4648), member key forms
/// (RFC 8610 §3.5.1) and range endpoints (RFC 8610 §3.8.2).
@Suite struct LiteralTests {
    /// Both the unchecked and the checked parser accept `input`.
    private func assertParses(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: Never.self, "unchecked parser rejected \(input)", sourceLocation: sourceLocation) {
            try cddlFromStr(input)
        }
        #expect(throws: Never.self, "checked parser rejected \(input)", sourceLocation: sourceLocation) {
            try CDDL.fromSlice(Array(input.utf8))
        }
    }

    /// Both the unchecked and the checked parser reject `input`.
    private func assertParseError(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(throws: ParserError.self, "unchecked parser accepted \(input)", sourceLocation: sourceLocation) {
            try cddlFromStr(input)
        }
        #expect(throws: ParserError.self, "checked parser accepted \(input)", sourceLocation: sourceLocation) {
            try CDDL.fromSlice(Array(input.utf8))
        }
    }

    // MARK: Radix literals

    @Test(arguments: [
        "thing = 0x10", "thing = 0b1010", "thing = 0X10", "thing = 0B1010", "thing = 0x0f", "thing = -0x10",
        "thing = -0b101", "thing = 0x00..0xff", "thing = {0x10: tstr}", "thing = {0b1010: tstr}",
        "thing = #0.0x18", "thing = #6.0x20(tstr)", "thing = #7.0x20", "thing = [0x2*0x4 tstr]",
        "thing = 0x1.8p+1", "thing = 0xFF", "thing = 0x0", "thing = 0b0", "thing = 0xffffffffffffffff",
        "thing = uint .lt 0x10", "thing = 0x1p3", "thing = 0x1P3", "thing = -0x1.8p+1",
        "thing = #6.0xffffffffffffffff(tstr)", "thing = 1e5", "thing = 0.5", "thing = 1.05e05",
        "thing = [042]", "thing = 16", "thing = [2*4 tstr]",
    ])
    func radixValidClaimsParse(_ input: String) {
        assertParses(input)
    }

    @Test(arguments: [
        "thing = 0x1.8", "thing = 0x", "thing = 0b2", "thing = #6.0x10000000000000000(bstr)",
        "thing = [0x10000000000000000* tstr]", "thing = 042", "thing = 042e5", "thing = 01.5",
    ])
    func radixParseErrorClaims(_ input: String) {
        assertParseError(input)
    }

    @Test func radixValuesDecode() throws {
        func value(_ input: String) throws -> Type2? {
            firstType2(typeRule(try parseOK(input), 0))
        }
        #expect(try value("thing = 0x10") == .uintValue(value: 16, span: Span(8, 12, 1)))
        #expect(try value("thing = 0xffffffffffffffff") == .uintValue(value: UInt64.max, span: Span(8, 26, 1)))
        guard case .intValue(let negative, _)? = try value("thing = -0b101") else {
            Issue.record("expected an int")
            return
        }
        #expect(negative == -5)
        guard case .floatValue(let float, _, _)? = try value("thing = 0x1.8p+1") else {
            Issue.record("expected a float")
            return
        }
        #expect(float == 3.0)
    }

    /// Cardano's max_word64 (2^64-1) and -2^64 parse; below -2^64 does not.
    @Test func integerLiteralsCoverTheCBORRange() throws {
        guard case .intValue(let min, _)? = firstType2(typeRule(try parseOK("a = -18446744073709551616"), 0)) else {
            Issue.record("expected an int")
            return
        }
        #expect(min == -(BigInt(1) << 64))
        let err = parseErr("a = -18446744073709551617")
        #expect(err.contains("Invalid integer"), "got: \(err)")
        #expect(parseErr("a = 18446744073709551616").contains("Invalid unsigned integer"))
    }

    // MARK: Byte string literals

    @Test func decodedByteValuesAndASTNodesRenderAsCDDLLiterals() {
        for (value, expected) in [
            (ByteValue.b16([0xaa, 0x00, 0xff]), "h'aa00ff'"),
            (ByteValue.b16(Array("AA".utf8)), "h'4141'"),
            (ByteValue.b64([0xfb, 0xff]), "b64'-_8'"),
            (ByteValue.b64(Array("AA".utf8)), "b64'QUE'"),
        ] {
            #expect(value.description == expected)
            #expect(Type2(value).description == expected)
        }
    }

    @Test func invalidUnqualifiedByteStringStateRemainsFallible() {
        let value = ByteValue.utf8([0xff])
        #expect(value.description == "h'ff'")
        #expect(Type2(value).description == "h'ff'")
    }

    @Test func decodedByteStringLiteralsFormatAndReparse() throws {
        for (source, expected) in [
            ("m = b64'- _8 ='", "m = b64'-_8'"),
            ("m = b64'-_8'", "m = b64'-_8'"),
            ("m = b64'+/8='", "m = b64'-_8'"),
            ("m = b64'+/8'", "m = b64'-_8'"),
            ("m = b64'EjRWeA'", "m = b64'EjRWeA'"),
            ("m = b64'EjRWeA=='", "m = b64'EjRWeA'"),
            ("m = h'AA 00 FF'", "m = h'aa00ff'"),
        ] {
            let formatted = try parseOK(source).description
            #expect(formatted.trimmingWhitespace() == expected)
            #expect(try parseOK(formatted).description == formatted)
        }
    }

    @Test func commentsInsidePrefixedByteStringsAreIgnored() throws {
        for (source, expected) in [
            ("m = h'4342 ; comment with hex digits 4F52\n4F52'", "m = h'43424f52'"),
            ("m = b64'Ej ; note\nRWeA'", "m = b64'EjRWeA'"),
        ] {
            #expect(try parseOK(source).description.trimmingWhitespace() == expected)
        }
    }

    @Test(arguments: ["m = b64'+_8'", "m = b64'-/8'", "m = b64'+_8='", "m = b64'-/8='", "m = b64'Ej-W+A'"])
    func base64LiteralsMixingBothRFC4648AlphabetsAreRejected(_ schema: String) {
        let error = parseErr(schema)
        #expect(error.contains("mixes the RFC 4648 base64 and base64url alphabets"), "got: \(error)")
    }

    @Test func singleAlphabetBase64LiteralsDecode() throws {
        for (schema, expected) in [
            ("m = b64'-_8'", "m = b64'-_8'"),
            ("m = b64'+/8'", "m = b64'-_8'"),
            ("m = b64'-_8='", "m = b64'-_8'"),
            ("m = b64'+/8='", "m = b64'-_8'"),
            ("m = b64'EjRWeA'", "m = b64'EjRWeA'"),
        ] {
            #expect(try parseOK(schema).description.trimmingWhitespace() == expected)
        }
    }

    @Test(arguments: ["m = h'A'", "m = h'AG'", "m = b64'qg='", "m = b64'q'", "m = b64'q=g='"])
    func malformedEncodedByteLiteralsAreRejected(_ schema: String) {
        _ = parseErr(schema)
    }

    /// `\'` escapes in unprefixed byte strings.
    @Test func escapedQuoteInByteString() throws {
        guard case .utf8ByteString(let value, _)? = firstType2(typeRule(try parseOK("a = 'it\\'s'"), 0)) else {
            Issue.record("expected a byte string")
            return
        }
        #expect(value == Array("it's".utf8))
    }

    // MARK: Member key forms

    private func firstMemberKey(_ src: String) throws -> MemberKey? {
        memberKeyOf(arrayOrMapGroup(typeRule(try parseOK(src), 0)?.value), 0)
    }

    @Test func arrowFormLiteralKeyIsAType1Key() throws {
        #expect(memberKeyVariant(try firstMemberKey("a = { 0 => uint }")) == "Type1")
    }

    @Test func colonFormLiteralKeyIsAValueKey() throws {
        #expect(memberKeyVariant(try firstMemberKey("a = { 0: uint }")) == "Value")
    }

    @Test func barewordKeyIsABarewordKey() throws {
        #expect(memberKeyVariant(try firstMemberKey("a = { b: uint }")) == "Bareword")
    }

    @Test func arrowFormPreservesTheCutIndicator() throws {
        guard case .type1(_, let isCut, _, _, _, _)? = try firstMemberKey("a = { 0 ^ => uint }") else {
            Issue.record("expected a type1 key")
            return
        }
        #expect(isCut, "cut indicator was lost")
    }

    @Test(arguments: ["a = { 0 => uint }", "a = { 0 ^ => uint }", "a = { 0: uint }", "a = { b: uint }"])
    func memberKeyFormsRoundTripUnchanged(_ src: String) throws {
        #expect(try parseOK(src).description.trimmingWhitespace() == src)
    }

    // MARK: Range endpoints

    @Test(arguments: [
        "t = -10..-3", "t = -10...-3", "t = -10...10", "t = -10..10", "t = 0.5...10.5", "t = 0.5..10.5",
        "t = 5...10", "t = 5..10",
    ])
    func rangeEndpointSchemasParse(_ schema: String) throws {
        let cddl = try parseOK(schema)
        guard case .rangeOp(let isInclusive, _)? = typeRule(cddl, 0)?.value.typeChoices[0].type1.operator?.operator else {
            Issue.record("expected a range")
            return
        }
        #expect(isInclusive == !schema.contains("..."))
    }
}
