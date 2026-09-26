import Foundation
import Testing

@testable import SwiftCDDL

// Unit tests of the CBOR validator (RFC 8610 against RFC 8949 data items),
// first part: literals, controls, time, recursion and nesting limits.

/// A validator of `node` against the schema `cddl`.
private func unitValidator(
    _ cddl: String,
    _ node: CBORNode,
    enabledFeatures: [String]? = nil
) throws -> CBORValidator {
    CBORValidator(cddl: try cddlFromStr(cddl), cbor: node, enabledFeatures: enabledFeatures)
}

/// Runs `validator`, returning the failure or `nil` when the document matched.
private func unitVerdict(_ validator: CBORValidator) async -> CBORVerdict {
    do {
        try await validator.validate()
        return nil
    } catch {
        return error
    }
}

/// Whether `verdict` is the report that a control is not supported.
private func isUnsupported(_ verdict: CBORVerdict) -> Bool {
    if case .unsupported = verdict {
        return true
    }
    return false
}

/// The rendered text of a failure, or the empty string for a match.
private func rendered(_ verdict: CBORVerdict) -> String {
    verdict.map { "\($0)" } ?? ""
}

/// Nests `node` inside `levels` one-element arrays, building from the inside out.
private func nestedInArrays(_ node: CBORNode, levels: Int) -> CBORNode {
    var result = node
    for _ in 0..<levels {
        result = .array([result])
    }
    return result
}

/// Tests of the CBOR validator's literals, controls, time handling, rule
/// recursion and nesting limits.
@Suite struct CBORValidatorUnitTests {
    private static let tcpFlagsSchema = """
        tcpflagbytes = bstr .bits flags
        flags = &(
          fin: 8,
          syn: 9,
          rst: 10,
          psh: 11,
          ack: 12,
          urg: 13,
          ece: 14,
          cwr: 15,
          ns: 0,
        ) / (4..7) ; data offset bits
        """

    @Test func validate() async {
        let verdict = await nodeResult(Self.tcpFlagsSchema, .bytes([0x90, 0x6d]))
        #expect(verdict == nil, "\(rendered(verdict))")
    }

    /// RFC 8610 Section 3.8.2: only the bits numbered by a member of the
    /// control type are allowed to be set. A byte string that sets no bit at
    /// all therefore holds, and one that sets a bit the control type does not
    /// name does not.
    @Test func validateBits() async {
        for admitted: [UInt8] in [[0x90, 0x6d], [0x00, 0x00], [0xf1, 0xff]] {
            let verdict = await nodeResult(Self.tcpFlagsSchema, .bytes(admitted))
            #expect(verdict == nil, "\(hexString(admitted)): \(rendered(verdict))")
        }

        // Bits 1, 2 and 3 are named by neither alternative.
        for rejected: [UInt8] in [[0x0e, 0x00], [0xff, 0xff]] {
            let verdict = await nodeResult(Self.tcpFlagsSchema, .bytes(rejected))
            #expect(verdict != nil, "\(hexString(rejected))")
        }
    }

    /// A range controller of a comparison operator names every value between
    /// its bounds, and the comparison holds when it holds against all of
    /// them: the greatest member for `.gt` and `.ge`, the least for `.lt` and
    /// `.le`. The upper bound of an exclusive range is not a member of it.
    @Test func validateComparisonAgainstIntRangeController() async {
        // (operator, inclusive upper bound, value, holds)
        let cases: [(String, Bool, Int64, Bool)] = [
            (".gt", true, 50, true),
            (".gt", true, 11, true),
            (".gt", true, 10, false),
            (".gt", true, 5, false),
            (".gt", true, 0, false),
            (".gt", true, -1, false),
            (".ge", true, 50, true),
            (".ge", true, 10, true),
            (".ge", true, 5, false),
            (".ge", true, -1, false),
            (".lt", true, -1, true),
            (".lt", true, 0, false),
            (".lt", true, 5, false),
            (".lt", true, 50, false),
            (".le", true, -1, true),
            (".le", true, 0, true),
            (".le", true, 5, false),
            (".le", true, 50, false),
            // The exclusive range 0...10 holds 0 through 9.
            (".gt", false, 10, true),
            (".gt", false, 9, false),
            (".ge", false, 10, true),
            (".ge", false, 9, true),
            (".ge", false, 8, false),
            (".lt", false, -1, true),
            (".lt", false, 0, false),
            (".le", false, 0, true),
            (".le", false, 1, false),
        ]

        for (control, isInclusive, value, holds) in cases {
            let range = isInclusive ? ".." : "..."
            let cddl = "start = int \(control) (0\(range)10)"
            let verdict = await nodeResult(cddl, .integer(value))
            #expect((verdict == nil) == holds, "int \(control) (0\(range)10) against \(value)")
        }
    }

    /// A float range with an exclusive upper bound has no greatest member, and
    /// a value stands above every member of one exactly when it reaches the
    /// bound the range stops short of.
    @Test func validateComparisonAgainstFloatRangeController() async {
        let cases: [(String, Bool, Double, Bool)] = [
            (".gt", true, 50.0, true),
            (".gt", true, 10.0, false),
            (".ge", true, 10.0, true),
            (".ge", true, 9.5, false),
            (".lt", true, -0.5, true),
            (".lt", true, 0.0, false),
            (".le", true, 0.0, true),
            (".le", true, 5.0, false),
            (".gt", false, 10.0, true),
            (".gt", false, 9.5, false),
            (".ge", false, 10.0, true),
            (".ge", false, 9.5, false),
        ]

        for (control, isInclusive, value, holds) in cases {
            let range = isInclusive ? ".." : "..."
            let cddl = "start = float \(control) (0.0\(range)10.0)"
            let verdict = await nodeResult(cddl, .float(value))
            #expect((verdict == nil) == holds, "float \(control) (0.0\(range)10.0) against \(value)")
        }
    }

    /// A range that holds no value at all resolves to no bound to compare
    /// against, and is reported as the malformed range it is rather than
    /// admitting or excluding everything.
    @Test func validateComparisonAgainstEmptyRangeController() async {
        for cddl in ["start = int .gt (0...0)", "start = int .lt (5..3)"] {
            let verdict = await nodeResult(cddl, .integer(50))
            #expect(verdict != nil)
            #expect(
                rendered(verdict).contains("holds no values to compare against"),
                "unexpected error: \(rendered(verdict))"
            )
        }
    }

    /// A byte string literal holds the bytes it denotes whichever notation it
    /// is written in, so a base64 literal matches exactly the byte string a
    /// base16 literal of the same content matches (RFC 8610 Section 3.1).
    @Test func validateBase64ByteStringLiteral() async {
        // Padded, unpadded, and the standard alphabet alongside the URL-safe one.
        let cases: [(String, [UInt8])] = [
            ("b64'AQID'", [0x01, 0x02, 0x03]),
            ("b64'AQL_'", [0x01, 0x02, 0xff]),
            ("b64'AQL/'", [0x01, 0x02, 0xff]),
            ("b64'AQI='", [0x01, 0x02]),
            ("b64'AQI'", [0x01, 0x02]),
            ("b64''", []),
        ]

        for (literal, denoted) in cases {
            let cddl = "start = \(literal)"
            let own = await nodeResult(cddl, .bytes(denoted))
            #expect(own == nil, "\(literal) against its own content")

            let other = await nodeResult(cddl, .bytes([0x07, 0x08, 0x09]))
            #expect(other != nil, "\(literal) against other content")
        }

        // A literal that is not valid base64 denotes no byte string.
        for malformed in ["start = b64'A'", "start = b64'++__'", "start = b64'AQ='"] {
            #expect((try? cddlFromStr(malformed)) == nil, "\(malformed) parsed")
        }
    }

    /// RFC 9165 Section 3: `.abnfb` matches a byte string against an ABNF
    /// grammar. That control is not supported here, and is reported as such.
    @Test func validateAbnfb1() async throws {
        let cddl = """
            oid = bytes .abnfb ("oid" .det cbor-tags-oid)
            roid = bytes .abnfb ("roid" .det cbor-tags-oid)

            cbor-tags-oid = '
              oid = 1*arc
              roid = *arc
              arc = [nlsb] %x00-7f
              nlsb = %x81-ff *%x80-ff
            '
            """

        let sha256OID = "2.16.840.1.101.3.4.2.1"
        let validator = try unitValidator(cddl, .bytes(Array(sha256OID.utf8)))
        let verdict = await unitVerdict(validator)
        #expect(isUnsupported(verdict), "\(rendered(verdict))")
    }

    /// RFC 9165 Section 4: `.feature` admits its target when the named feature
    /// is enabled.
    @Test func validateFeature() async {
        let cddl = """
            v = JC<"v", 2>
            JC<J, C> = J .feature "json" / C .feature "cbor"
            """

        let verdict = await nodeResult(cddl, .unsigned(2), enabledFeatures: ["cbor"])
        #expect(verdict == nil, "\(rendered(verdict))")
    }

    @Test func validateTypeChoiceAlternate() async {
        let cddl = """
            tester = [ $vals ]
            $vals /= 12
            $vals /= 13
            """

        let verdict = await nodeResult(cddl, .array([.unsigned(13)]))
        #expect(verdict == nil, "\(rendered(verdict))")
    }

    @Test func validateGroupChoiceAlternateInArray() async {
        let cddl = """
            tester = [$$val]
            $$val //= (
              type: 10,
              data: uint
            )
            $$val //= (
              type: 11,
              data: tstr
            )
            """

        let verdict = await nodeResult(cddl, .array([.unsigned(11), .text("test")]))
        #expect(verdict == nil, "\(rendered(verdict))")
    }

    @Test func validateTdateTag() async {
        let verdict = await nodeResult("root = time", .tagged(1, .float(1_680_965_875.01)))
        #expect(verdict == nil, "\(rendered(verdict))")
    }

    /// RFC 9165 Section 3: `.abnfb` is not supported here, and is reported as
    /// such rather than admitting or rejecting the data.
    @Test func validateAbnfb2() async throws {
        let cddl = """
            ; Binary ABNF Test Schema
            test_cbor = {
              61285: sub_map
            }

            sub_map = {
              1: signature_abnf
            }

            signature = bytes .size 64

            signature_abnf = signature .abnfb '
            ANYDATA
            ANYDATA = *OCTET

            OCTET =  %x00-FF
            '
            """

        let node = CBORNode.map([
            (key: .unsigned(61285), value: .map([(key: .unsigned(1), value: .bytes(Array("test".utf8)))]))
        ])
        let validator = try unitValidator(cddl, node)
        let verdict = await unitVerdict(validator)
        #expect(isUnsupported(verdict), "\(rendered(verdict))")
    }

    @Test func multiTypeChoiceTypeRuleArrayValidation() async {
        let cddl = """
            Ref = nil / refShort / refFull

            blobSize = uint
            hashID = uint .lt 23
            hashName = text
            hashDigest = bytes

            refShort = [ blobSize, hashID, hashDigest ]
            refFull = { 1: blobSize, 2: hashName, 3: hashDigest }
            """

        let node = CBORNode.array([
            .unsigned(3),
            .unsigned(2),
            .bytes(hexBytes("BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD")),
        ])
        let verdict = await nodeResult(cddl, node)
        #expect(verdict == nil, "\(rendered(verdict))")
    }

    @Test func taggedDataInArrayValidation() async {
        let cddl = """
            start = [ * help ]

            help = #6.123(bstr)
            """

        let verdict = await nodeResult(cddl, .array([.tagged(123, .bytes([0x00]))]))
        #expect(verdict == nil, "\(rendered(verdict))")
    }

    @Test func testConditionalArrayValidation() async {
        let cddl = """
            NestedPart = [
              disposition: 0,
              language: tstr,
              partIndex: uint,
              ( NullPart // SinglePart )
            ]

            NullPart = ( cardinality: 0 )
            SinglePart = (
                cardinality: 1,
                contentType: tstr,
                content: bstr
            )
            """

        // A SinglePart with six elements: disposition, language, partIndex,
        // cardinality, contentType and content.
        let node = CBORNode.array([
            .unsigned(0),
            .text("en"),
            .unsigned(1),
            .unsigned(1),
            .text("text/plain"),
            .bytes(Array("hello world".utf8)),
        ])
        let verdict = await nodeResult(cddl, node)
        #expect(verdict == nil, "Validation should succeed for SinglePart structure: \(rendered(verdict))")
    }

    @Test func extractCbor() throws {
        let validator = try unitValidator("start = any", .float(1.23))
        #expect(validator.extractCBOR() == .float(1.23))
    }

    @Test func validateNumberAcceptsFloatAndInt() async {
        let cases: [(String, CBORNode)] = [
            ("x = number", .float(2.0)),
            ("x = number", .unsigned(5)),
            ("x = number .eq 5", .unsigned(5)),
            ("x = number .ge 1.0", .float(2.5)),
        ]
        for (cddl, node) in cases {
            let verdict = await nodeResult(cddl, node)
            #expect(verdict == nil, "\(cddl) should accept \(node)")
        }
    }

    @Test func validateBstrSizeRange() async {
        let cddl = "m = { field: bstr .size (16..1000) }"
        func document(_ length: Int) -> CBORNode {
            .map([(key: .text("field"), value: .bytes([UInt8](repeating: 0, count: length)))])
        }

        // A byte string of a length inside the range.
        #expect(await nodeResult(cddl, document(100)) == nil)
        // One that is too short.
        #expect(await nodeResult(cddl, document(10)) != nil)
        // One that is too long.
        #expect(await nodeResult(cddl, document(1500)) != nil)
    }

    @Test func validateBstrSizeExclusiveRange() async {
        let cddl = "m = { field: bstr .size (16...1000) }"
        func document(_ length: Int) -> CBORNode {
            .map([(key: .text("field"), value: .bytes([UInt8](repeating: 0, count: length)))])
        }

        // 17 bytes is inside the range.
        #expect(await nodeResult(cddl, document(17)) == nil)
        // 16 bytes is its inclusive lower bound.
        #expect(await nodeResult(cddl, document(16)) == nil)
    }

    private static let nestedCBORInner = """
        bar = {
            a: text,
            b: int,
            c: bstr
        }
        """

    /// The valid embedded map and one missing its required `c` entry.
    private static var embeddedDocuments: (valid: [UInt8], invalid: [UInt8]) {
        let valid = CBORNode.map([
            (key: .text("a"), value: .text("test")),
            (key: .text("b"), value: .integer(-42)),
            (key: .text("c"), value: .bytes(Array("bytes".utf8))),
        ])
        let invalid = CBORNode.map([
            (key: .text("a"), value: .text("test")),
            (key: .text("b"), value: .integer(-42)),
        ])
        return (valid.encoded(), invalid.encoded())
    }

    /// RFC 8610 Section 3.8.4: `.cbor` validates the embedded encoded item.
    @Test func validateNestedCbor() async {
        let cddl = """
            root = {
                foo: bstr .cbor bar
            }

            \(Self.nestedCBORInner)
            """
        let embedded = Self.embeddedDocuments

        let valid = CBORNode.map([(key: .text("foo"), value: .bytes(embedded.valid))])
        #expect(await nodeResult(cddl, valid) == nil)

        // The embedded map misses its required `c` entry.
        let invalid = CBORNode.map([(key: .text("foo"), value: .bytes(embedded.invalid))])
        #expect(await nodeResult(cddl, invalid) != nil)
    }

    @Test func validateNestedCborInArray() async {
        let cddl = """
            root = [
                foo: bstr .cbor bar
            ]

            \(Self.nestedCBORInner)
            """
        let embedded = Self.embeddedDocuments

        let valid = CBORNode.array([.bytes(embedded.valid)])
        let verdict = await nodeResult(cddl, valid)
        #expect(verdict == nil, "\(rendered(verdict))")
        // Validating the same document again gives the same verdict.
        #expect(await nodeResult(cddl, valid) == nil)

        let invalid = CBORNode.array([.bytes(embedded.invalid)])
        #expect(await nodeResult(cddl, invalid) != nil)
    }

    @Test func validateNestedArrays() async {
        // An array type written inline.
        var verdict = await nodeResult(
            "array = [0, [* int]]",
            .array([.unsigned(0), .array([.unsigned(1), .unsigned(2)])])
        )
        #expect(verdict == nil, "\(rendered(verdict))")

        // The inner array named by its own rule.
        verdict = await nodeResult(
            """
            root = [0, inner]
            inner = [* int]
            """,
            .array([.unsigned(0), .array([.unsigned(1), .unsigned(2)])])
        )
        #expect(verdict == nil, "\(rendered(verdict))")

        // Literal members at both levels.
        verdict = await nodeResult(
            "direct = [1, [2, 3]]",
            .array([.unsigned(1), .array([.unsigned(2), .unsigned(3)])])
        )
        #expect(verdict == nil, "\(rendered(verdict))")
    }

    @Test func validateDirectNestedArray() async {
        let verdict = await nodeResult(
            "direct = [1, [2, 3]]",
            .array([.unsigned(1), .array([.unsigned(2), .unsigned(3)])])
        )
        #expect(verdict == nil, "\(rendered(verdict))")
        for issue in verdict?.issues ?? [] {
            Issue.record("\(issue.reason) at \(issue.cborLocation)")
        }
    }

    @Test func validateRecursiveStructures() async {
        let cddl = """
            Tree = {
              root: Node
            }

            Node = [
              value: text,
              children: [* Node]
            ]
            """

        let node = CBORNode.map([
            (
                key: .text("root"),
                value: .array([
                    .text("value"),
                    .array([
                        .array([.text("child1"), .array([])]),
                        .array([.text("child2"), .array([])]),
                    ]),
                ])
            )
        ])
        let verdict = await nodeResult(cddl, node)
        #expect(verdict == nil, "a recursive structure should validate: \(rendered(verdict))")
    }

    /// RFC 8610 Section 3.5.1: an empty map type admits only the empty map.
    @Test func testIssue221EmptyMapWithExtraKeysCbor() async {
        let verdict = await nodeResult("root = {}", .map([(key: .text("x"), value: .text("y"))]))
        #expect(verdict != nil, "an entry the empty map type does not name should fail")
        let errors = issues(verdict)
        #expect(errors.count == 1)
        #expect(errors.first?.reason.contains("expected empty map") == true)
    }

    @Test func testEmptyMapSchemaWithEmptyCbor() async {
        let verdict = await nodeResult("root = {}", .map([]))
        #expect(verdict == nil, "the empty map matches the empty map type")
    }

    @Test func testIssue221ReproduceExactScenarioCbor() async {
        let verdict = await nodeResult("root = {}", .map([(key: .text("x"), value: .text("y"))]))
        let errors = issues(verdict)
        #expect(!errors.isEmpty, "Should have validation errors")
        let message = errors.first?.reason ?? ""
        #expect(
            message.contains("expected empty map"),
            "Error message should indicate expected empty map, got: \(message)"
        )
    }

    /// RFC 9165 Section 3: `.abnf` with a `.det` controller. The control is not
    /// supported here and is reported as such for either document.
    @Test func validateAbnfWithDetTypenameController() async throws {
        let cddl = """
            start = modified-date-time

            modified-date-time = text .abnf modified-dt-abnf
            modified-dt-abnf = "modified-dt" .det rfc3339z

            rfc3339z = '
               date-fullyear   = 4DIGIT
               date-month      = 2DIGIT
               date-mday       = 2DIGIT
               time-hour       = 2DIGIT
               time-minute     = 2DIGIT
               time-second     = 2DIGIT
               time-secfrac    = "." 1*DIGIT
               DIGIT           =  %x30-39
               partial-time    = time-hour ":" time-minute ":" time-second [time-secfrac]
               full-date       = date-fullyear "-" date-month "-" date-mday
               modified-dt     = full-date ["T" partial-time "Z"]
            '
            """

        let valid = try unitValidator(cddl, .text("1985-04-12T23:20:50.52Z"))
        let validVerdict = await unitVerdict(valid)
        #expect(isUnsupported(validVerdict), "\(rendered(validVerdict))")

        // An invalid date and time is not admitted either.
        let invalid = try unitValidator(cddl, .text("not-a-date"))
        let invalidVerdict = await unitVerdict(invalid)
        #expect(invalidVerdict != nil, "Expected validation to fail for invalid datetime value")
    }

    @Test func multiTypeChoiceArrayOptionalNoError() async {
        let cddl = """
            root = [? item]
            item = uint / tstr
            """
        #expect(
            await nodeResult(cddl, .array([.unsigned(42)])) == nil,
            "Optional multi-type-choice should pass for a valid element"
        )
        #expect(
            await nodeResult(cddl, .array([.text("test-string")])) == nil,
            "Optional multi-type-choice should pass for a valid element"
        )
    }

    @Test func multiTypeChoiceArrayZeroOrMoreNoError() async {
        let cddl = """
            root = [* item]
            item = uint / tstr
            """
        #expect(
            await nodeResult(cddl, .array([.unsigned(1), .text("hello")])) == nil,
            "Zero-or-more multi-type-choice should pass for valid elements"
        )
        #expect(
            await nodeResult(cddl, .array([])) == nil,
            "Zero-or-more multi-type-choice should pass for valid elements"
        )
    }

    @Test func multiTypeChoiceArrayOneOrMoreFailsEmpty() async {
        let cddl = """
            root = [+ item]
            item = uint / tstr
            """
        #expect(
            await nodeResult(cddl, .array([])) != nil,
            "One-or-more with empty array should fail validation"
        )
    }

    /// One-or-more with a single matching type (not a type choice) passes.
    @Test func multiTypeChoiceArrayOneOrMoreSingleTypePasses() async {
        #expect(
            await nodeResult("root = [+ uint]", .array([.unsigned(1), .unsigned(2)])) == nil,
            "One-or-more with matching uint elements should pass"
        )
    }

    /// An array with an element that does not match the single expected type
    /// fails.
    @Test func multiTypeChoiceArrayWrongTypeSingleFails() async {
        #expect(
            await nodeResult("root = [+ uint]", .array([.text("not a uint")])) != nil,
            "Array with non-matching type should fail validation"
        )
    }

    @Test func validateByteStringLiteralMatchesEqualBytes() async {
        #expect(
            await nodeResult("root = h'0102'", .bytes([0x01, 0x02])) == nil,
            "byte string literal should match the byte string with that content"
        )
    }

    @Test func validateByteStringLiteralRejectsUnequalBytes() async {
        #expect(
            await nodeResult("root = h'0102'", .bytes([0x03, 0x04])) != nil,
            "byte string literal should not match a byte string with different content"
        )
        #expect(
            await nodeResult("root = h'0102'", .bytes([0x01])) != nil,
            "byte string literal should not match a prefix of its content"
        )
    }

    @Test func validateByteStringLiteralWithNonUtf8Content() async {
        // Content that is not valid UTF-8 must still compare and render.
        #expect(await nodeResult("root = h'ff'", .bytes([0xff])) == nil)

        let verdict = await nodeResult("root = h'ff'", .bytes([0x00]))
        #expect(verdict != nil, "non-matching content should be rejected")
        #expect(
            rendered(verdict).contains("h'ff'"),
            "expected the literal to be rendered as base16, got: \(rendered(verdict))"
        )
    }

    /// An unprefixed literal denotes the UTF-8 bytes of its content, so it is
    /// four bytes long where the base16 literal h'0102' is two.
    @Test func validateUnprefixedByteStringLiteralMatchesUtf8Content() async {
        #expect(await nodeResult("root = '0102'", .bytes(Array("0102".utf8))) == nil)
        #expect(await nodeResult("root = '0102'", .bytes(Array("0103".utf8))) != nil)
        #expect(await nodeResult("root = '0102'", .bytes([0x01, 0x02])) != nil)
    }

    @Test func validateByteStringLiteralInArrayAndMap() async {
        #expect(await nodeResult("root = [h'0102']", .array([.bytes([0x01, 0x02])])) == nil)
        #expect(await nodeResult("root = [h'0102']", .array([.bytes([0x03, 0x04])])) != nil)
        #expect(
            await nodeResult("root = { k: h'0102' }", .map([(key: .text("k"), value: .bytes([0x01, 0x02]))]))
                == nil
        )
        #expect(
            await nodeResult("root = { k: h'0102' }", .map([(key: .text("k"), value: .bytes([0x03, 0x04]))]))
                != nil
        )
    }

    /// A text string literal only matches a text string data item.
    @Test func validateTextLiteralAgainstByteStringIsRejected() async {
        #expect(await nodeResult("root = \"abc\"", .text("abc")) == nil)
        #expect(await nodeResult("root = \"abc\"", .bytes(Array("abc".utf8))) != nil)
    }

    /// A byte string literal only matches a byte string data item, in either
    /// notation and whatever the content reads as.
    @Test func validateByteStringLiteralAgainstTextIsRejected() async {
        for cddl in ["root = h'616263'", "root = 'abc'"] {
            #expect(await nodeResult(cddl, .bytes(Array("abc".utf8))) == nil)
            #expect(await nodeResult(cddl, .text("abc")) != nil)
        }
    }

    /// RFC 8949 Section 3.4.2: tag 1 encloses a count of seconds.
    @Test func validateTimeTagAcceptsIntegerInRange() async {
        #expect(await nodeResult("root = time", .tagged(1, .unsigned(1_363_896_240))) == nil)
        #expect(await nodeResult("root = time", .tagged(1, .integer(-1))) == nil)
    }

    @Test func validateTimeTagRejectsIntegerOutOfRange() async {
        #expect(
            await nodeResult("root = time", .tagged(1, .unsigned(UInt64.max))) != nil,
            "an integer above the representable range of seconds is not a point in time"
        )
        // -18446744073709551616, the least integer CBOR encodes.
        #expect(
            await nodeResult("root = time", .tagged(1, .negative(UInt64.max))) != nil,
            "an integer below the representable range of seconds is not a point in time"
        )
    }

    @Test func validateTimeTagRejectsNonFiniteFloat() async {
        #expect(await nodeResult("root = time", .tagged(1, .float(.nan))) != nil)
        #expect(await nodeResult("root = time", .tagged(1, .float(.infinity))) != nil)
        #expect(await nodeResult("root = time", .tagged(1, .float(-.infinity))) != nil)
    }

    /// An integer data item carries a wider range of seconds than the instants
    /// a date and time can express, so a count outside that range is not a
    /// point in time. Converting the count into a finer unit before checking it
    /// would wrap an out-of-range count back inside the range and admit it.
    @Test func validateTimeRejectsSecondsOutsideTheRepresentableRange() async {
        // A bare number and one carrying the epoch-based date and time tag
        // denote a point in time the same way, so the same range bounds both.
        func accepts(_ node: CBORNode) async -> Bool {
            let bare = await nodeResult("root = time", node)
            let tagged = await nodeResult("root = time", .tagged(1, node))
            return bare == nil && tagged == nil
        }
        func rejects(_ node: CBORNode) async -> Bool {
            let bare = await nodeResult("root = time", node)
            let tagged = await nodeResult("root = time", .tagged(1, node))
            return bare != nil && tagged != nil
        }

        // The outermost seconds of the supported calendar: the last second of
        // year 262142 and the first second of year -262143.
        let last: Int64 = 8_210_266_876_799
        let first: Int64 = -8_334_601_228_800

        // The outermost seconds a point in time can be expressed with are
        // still points in time.
        #expect(await accepts(.integer(last)))
        #expect(await accepts(.integer(first)))
        #expect(await accepts(.float(Double(last - 1))))

        #expect(await rejects(.integer(last + 1)))
        #expect(await rejects(.integer(first - 1)))
        #expect(await rejects(.integer(Int64.max)))
        #expect(await rejects(.integer(Int64.min)))
        #expect(await rejects(.unsigned(UInt64.max)))
        #expect(await rejects(.float(.nan)))
        #expect(await rejects(.float(1e300)))
        #expect(await rejects(.float(-1e300)))
    }

    /// RFC 9165 Section 2.1: `.plus` denotes the sum of its target and
    /// controller. Forming the sum at a width it can overflow would leave it
    /// standing for a different number, and the data item equal to that number
    /// would be admitted by a control no data item can satisfy.
    @Test func validatePlusControlReportsASumOutsideTheRangeOfItsType() async {
        // A sum the target's type holds is the number it reads as.
        #expect(await nodeResult("root = 18446744073709551614 .plus 1", .unsigned(UInt64.max)) == nil)
        #expect(await nodeResult("root = 3 .plus -1", .integer(2)) == nil)
        #expect(await nodeResult("root = -3 .plus 1", .integer(-2)) == nil)
        // A sum below zero is still a number, and is the negative one it reads as.
        #expect(await nodeResult("root = 0 .plus -1", .integer(-1)) == nil)

        // A sum above the unsigned range is no number a literal holds, and the
        // value it would wrap to does not stand in for it.
        #expect(await nodeResult("root = 18446744073709551615 .plus 1", .integer(0)) != nil)
        #expect(await nodeResult("root = 18446744073709551615 .plus 1", .unsigned(UInt64.max)) != nil)
        #expect(await nodeResult("root = 0 .plus -1", .unsigned(UInt64.max)) != nil)
        #expect(await nodeResult("root = 0 .plus -1", .integer(0)) != nil)
    }

    /// RFC 9165 Section 2.1: a sum of an integer target and a float controller
    /// takes the type of the target, and converting a float to an integer
    /// selects its floor, rounding towards negative infinity, not towards zero.
    @Test func validatePlusControlFloorsAFractionalSum() async {
        let cases: [(String, Int64)] = [
            ("root = 1 .plus 2.7", 3),
            ("root = 1 .plus -0.5", 0),
            ("root = 1 .plus -1.5", -1),
            ("root = 0 .plus -0.5", -1),
            ("root = 5 .plus -2.7", 2),
            ("root = -5 .plus -2.7", -8),
            ("root = -5 .plus 2.7", -3),
            ("root = -1 .plus 0.5", -1),
            // A controller that carries no fraction is its own floor.
            ("root = -3 .plus 1.0", -2),
        ]
        for (schema, sum) in cases {
            #expect(await nodeResult(schema, .integer(sum)) == nil, "\(schema) does not denote \(sum)")
            // The sum is one number, so the neighbours a different rounding
            // would have reached are not admitted.
            for neighbour in [sum - 1, sum + 1] {
                #expect(await nodeResult(schema, .integer(neighbour)) != nil, "\(schema) admits \(neighbour)")
            }
        }
    }

    /// A float target keeps its own type, so the sum stays a float and no
    /// rounding takes place.
    @Test func validatePlusControlKeepsAFloatTargetAFloat() async {
        #expect(await nodeResult("root = 1.5 .plus 2", .float(3.5)) == nil)
        #expect(await nodeResult("root = 1.5 .plus 2", .integer(3)) != nil)
        #expect(await nodeResult("root = 1.5 .plus 2", .integer(4)) != nil)
    }

    @Test func validateRangeWithNegativeBoundsInArrayAndMap() async {
        let mapCDDL = "m = { field: -5..5 }"
        #expect(await nodeResult(mapCDDL, .map([(key: .text("field"), value: .integer(-2))])) == nil)
        #expect(await nodeResult(mapCDDL, .map([(key: .text("field"), value: .integer(-9))])) != nil)

        let arrayCDDL = "a = [* -5..5]"
        #expect(await nodeResult(arrayCDDL, .array([.integer(-1), .integer(0), .integer(5)])) == nil)
        #expect(await nodeResult(arrayCDDL, .array([.integer(-9)])) != nil)
    }

    /// A rule reference stands for the rule's definition wherever it occurs
    /// (RFC 8610 Appendix C), so a rule that recurses through a homogeneous
    /// occurrence has to be checked against the data at every nesting level,
    /// not only the outermost one.
    @Test func validateRecursiveTypeRuleChecksEveryNestingLevel() async {
        let cddl = "data = int / tstr / [* data]"

        let valid = CBORNode.array([.unsigned(1), .array([.text("a"), .array([.unsigned(2)])])])
        let verdict = await nodeResult(cddl, valid)
        #expect(verdict == nil, "\(rendered(verdict))")

        // A float satisfies none of the three type choices, and it sits two
        // levels down.
        #expect(await nodeResult(cddl, .array([.array([.float(2.5)])])) != nil)
    }

    /// The recursion may run through an intermediate rule, so that the rule is
    /// re-entered at a different data item one level down.
    @Test func validateRecursionThroughReferencedRule() async {
        let cddl = """
            data = int / tstr / list
            list = [* data]
            """

        let verdict = await nodeResult(cddl, .array([.unsigned(1), .array([.text("x")])]))
        #expect(verdict == nil, "\(rendered(verdict))")

        #expect(await nodeResult(cddl, .array([.float(2.5)])) != nil)
    }

    /// A cycle that steps into no data denotes no type at all, so no document
    /// can satisfy it.
    @Test func validateRuleCycleThatConsumesNoDataIsAnError() async {
        for cddl in ["x = x\n", "a = b\nb = a\n"] {
            let verdict = await nodeResult(cddl, .unsigned(1))
            #expect(verdict != nil, "a cycle cannot be satisfied")
            #expect(rendered(verdict).contains("without consuming any data"), "got:\n\(rendered(verdict))")
        }
    }

    /// A cycle denotes no type at all wherever it is reached, including from an
    /// array entry, where the rule is resolved against one array item.
    @Test func validateRuleCycleReachedFromAnArrayEntryIsAnError() async {
        let verdict = await nodeResult("top = [a]\na = b\nb = a\n", .array([.unsigned(1)]))
        #expect(verdict != nil, "a cycle cannot be satisfied")
        #expect(rendered(verdict).contains("without consuming any data"), "got:\n\(rendered(verdict))")
    }

    /// `?` admits zero occurrences (RFC 8610 Section 3.2), so an optional entry
    /// imposes no requirement once the array has run out of items. A rule
    /// reached through one therefore terminates on the data instead of being
    /// re-entered on the same array, and every level that is present is still
    /// validated.
    @Test func validateOptionalRecursiveTail() async {
        let cddl = "a = [int, ? a]\n"

        for valid: CBORNode in [
            .array([.unsigned(1)]),
            .array([.unsigned(1), .array([.unsigned(2)])]),
            .array([.unsigned(1), .array([.unsigned(2), .array([.unsigned(3)])])]),
        ] {
            let verdict = await nodeResult(cddl, valid)
            #expect(verdict == nil, "\(rendered(verdict))")
        }

        let invalid = CBORNode.array([.unsigned(1), .array([.unsigned(2), .array([.text("x")])])])
        let verdict = await nodeResult(cddl, invalid)
        #expect(verdict != nil, "\"x\" is not an int")
        #expect(rendered(verdict).contains("/1/1/0"), "got:\n\(rendered(verdict))")
        #expect(!rendered(verdict).contains("without consuming any data"), "got:\n\(rendered(verdict))")
    }

    /// Two rules that reach each other through optional entries recurse the
    /// same way a single self-referential rule does.
    @Test func validateMutuallyRecursiveOptionalTails() async {
        let cddl = "a = [int, ? b]\nb = [int, ? a]\n"

        for valid: CBORNode in [
            .array([.unsigned(1)]),
            .array([.unsigned(1), .array([.unsigned(2)])]),
            .array([.unsigned(1), .array([.unsigned(2), .array([.unsigned(3)])])]),
        ] {
            let verdict = await nodeResult(cddl, valid)
            #expect(verdict == nil, "\(rendered(verdict))")
        }

        let invalid = CBORNode.array([.unsigned(1), .array([.unsigned(2), .array([.text("x")])])])
        let verdict = await nodeResult(cddl, invalid)
        #expect(verdict != nil, "\"x\" is not an int")
        #expect(rendered(verdict).contains("/1/1/0"), "got:\n\(rendered(verdict))")
    }

    /// `0*1` admits zero occurrences just as `?` does, while an occurrence
    /// indicator with a non-zero lower bound still requires an item to be
    /// present.
    @Test func validateRecursiveTailUnderAnExplicitOccurrence() async {
        let optional = "a = [int, 0*1 a]\n"
        for valid: CBORNode in [.array([.unsigned(1)]), .array([.unsigned(1), .array([.unsigned(2)])])] {
            let verdict = await nodeResult(optional, valid)
            #expect(verdict == nil, "\(rendered(verdict))")
        }

        let required = "a = [int, 1*2 a]\n"
        #expect(
            await nodeResult(required, .array([.unsigned(1)])) != nil,
            "the entry requires at least one occurrence"
        )
    }

    /// Only a rule re-entered against the same data item is a cycle, so a chain
    /// of aliases resolves rather than being reported as one, and the bound it
    /// does answer to is the one on rule nesting.
    @Test func validateAliasChainIsNotACycle() async throws {
        var chain = ""
        for link in 0..<20 {
            chain += "r\(link) = r\(link + 1)\n"
        }
        chain += "r20 = int\n"

        let valid = await nodeResult(chain, .unsigned(1))
        #expect(valid == nil, "\(rendered(valid))")

        let invalid = await nodeResult(chain, .text("x"))
        #expect(invalid != nil, "\"x\" is not an int")
        #expect(rendered(invalid).contains("expected type int"), "got:\n\(rendered(invalid))")
        #expect(!rendered(invalid).contains("without consuming any data"), "got:\n\(rendered(invalid))")

        let bounded = try unitValidator(chain, .unsigned(1))
        bounded.setMaxRuleNesting(4)
        let verdict = await unitVerdict(bounded)
        #expect(verdict != nil, "the chain is longer than the bound on rule nesting")
        #expect(rendered(verdict).contains("maximum supported rule nesting"), "got:\n\(rendered(verdict))")
    }

    /// An unwrapped name (RFC 8610 Section 3.7) is a rule reference resolved
    /// against the item already held: a chain of them against one item answers
    /// to the bound on rule nesting, and a rule reached again through one
    /// without any data consumed is a cycle rather than a walk.
    @Test func validateUnwrapResolvesAgainstTheSameItemUnderTheRuleNestingBound() async throws {
        let cddl = "x = [~y] / uint\ny = [~z]\nz = [~w]\nw = [uint]\n"

        for (maxRuleNesting, admitted) in [(4, true), (2, false)] {
            let validator = try unitValidator(cddl, .array([.unsigned(1)]))
            validator.setMaxRuleNesting(maxRuleNesting)
            let verdict = await unitVerdict(validator)
            if admitted {
                #expect(verdict == nil, "got:\n\(rendered(verdict))")
            } else {
                #expect(verdict != nil, "three unwraps against one array exceed a bound of two")
                #expect(
                    rendered(verdict).contains("maximum supported rule nesting"),
                    "got:\n\(rendered(verdict))"
                )
            }
        }

        let verdict = await nodeResult("x = [~x] / uint\n", .array([.unsigned(1)]))
        #expect(verdict != nil, "no array satisfies a group spliced from itself")
        #expect(
            rendered(verdict).contains("rule x is defined in terms of itself without consuming any data"),
            "got:\n\(rendered(verdict))"
        )
    }

    /// A tagged alternative `/=` adds to a rule is evaluated against the item
    /// the tag encloses, and the rule's definition admitting that item settles
    /// it.
    @Test func validateTypeChoiceAlternateTaggedOverTheRuleDefinition() async {
        let cddl = "x = uint\nx /= #6.1(x)\n"
        func tagged(_ node: CBORNode) -> CBORNode { .tagged(1, node) }

        #expect(await nodeResult(cddl, .unsigned(5)) == nil)
        #expect(await nodeResult(cddl, tagged(.unsigned(5))) == nil)
        #expect(await nodeResult(cddl, tagged(tagged(.unsigned(5)))) == nil)

        #expect(await nodeResult(cddl, .text("a")) != nil)
        #expect(await nodeResult(cddl, tagged(.text("a"))) != nil)
        #expect(await nodeResult(cddl, .tagged(2, .unsigned(5))) != nil)
    }

    /// The bound on rule nesting counts the rules resolved against one data
    /// item, so it does not limit how deeply the data may nest: a recursive
    /// rule keeps resolving past the bound as long as every step descends into
    /// the data.
    @Test func validateRuleNestingBoundDoesNotLimitDataNesting() async throws {
        let cddl = "data = int / [* data]\n"
        let valid = nestedInArrays(.unsigned(1), levels: 10)
        let invalid = nestedInArrays(.text("x"), levels: 10)

        let validValidator = try unitValidator(cddl, valid)
        validValidator.setMaxRuleNesting(4)
        let validVerdict = await unitVerdict(validValidator)
        #expect(validVerdict == nil, "\(rendered(validVerdict))")

        let invalidValidator = try unitValidator(cddl, invalid)
        invalidValidator.setMaxRuleNesting(4)
        #expect(await unitVerdict(invalidValidator) != nil, "the text string ten levels down is not an int")
    }

    /// A cycle reached from a type choice that some other choice satisfies must
    /// not reject the document, whichever choice the cycle sits in.
    @Test func validateCycleInALosingTypeChoiceDoesNotReject() async {
        for cddl in ["a = int / b\nb = a\n", "a = b / int\nb = a\n"] {
            let verdict = await nodeResult(cddl, .unsigned(1))
            #expect(verdict == nil, "\(rendered(verdict))")

            #expect(await nodeResult(cddl, .text("x")) != nil, "no choice matches a text string")
        }
    }

    /// Recursion through map values is checked at every nesting level, the
    /// same way recursion through arrays is.
    @Test func validateRecursionThroughMapValues() async {
        let cddl = """
            top = {* tstr => data}
            data = int / {* tstr => data}
            """

        let valid = CBORNode.map([(key: .text("k"), value: .map([(key: .text("j"), value: .unsigned(1))]))])
        let verdict = await nodeResult(cddl, valid)
        #expect(verdict == nil, "\(rendered(verdict))")

        let invalid = CBORNode.map([(key: .text("k"), value: .map([(key: .text("j"), value: .float(1.5))]))])
        #expect(await nodeResult(cddl, invalid) != nil, "1.5 is neither an int nor a map")
    }

    /// Validation descends one nesting level of the data at a time, so the
    /// supported nesting depth is bounded. The bound is an implementation limit
    /// and is reported as one, and the embedder can move it.
    @Test func validateDataNestedPastTheSupportedDepthReportsTheLimit() async throws {
        let cddl = "data = int / [* data]\n"
        let atLimit = nestedInArrays(.unsigned(1), levels: 4)
        let pastLimit = CBORNode.array([atLimit])

        let atValidator = try unitValidator(cddl, atLimit)
        atValidator.setMaxNestingDepth(4)
        let atVerdict = await unitVerdict(atValidator)
        #expect(atVerdict == nil, "\(rendered(atVerdict))")

        let pastValidator = try unitValidator(cddl, pastLimit)
        pastValidator.setMaxNestingDepth(4)
        let pastVerdict = await unitVerdict(pastValidator)
        #expect(pastVerdict != nil, "the data is nested too deeply")
        #expect(
            rendered(pastVerdict).contains("maximum supported nesting depth of 4"),
            "got:\n\(rendered(pastVerdict))"
        )

        // The same document is within the default limit.
        #expect(ValidationLimits.defaultMaxNestingDepth > 5)
        let defaultVerdict = await nodeResult(cddl, pastLimit)
        #expect(defaultVerdict == nil, "\(rendered(defaultVerdict))")
    }

    /// The bound is on how far validation descends, not on the document: a
    /// schema that does not step into the nesting is held to nothing by it,
    /// and a document nested past it validates as long as the rules stop above.
    @Test func validateNestingBoundIsConsumedOnlyByDescending() async throws {
        let node = nestedInArrays(.unsigned(1), levels: 8)

        for schema in ["top = any\n", "top = [any]\n", "top = [[any]]\n"] {
            let validator = try unitValidator(schema, node)
            validator.setMaxNestingDepth(2)
            let verdict = await unitVerdict(validator)
            #expect(verdict == nil, "\(schema): \(rendered(verdict))")
        }

        // The same document under a rule that descends through all of it does
        // reach the bound.
        let validator = try unitValidator("data = int / [* data]\n", node)
        validator.setMaxNestingDepth(2)
        let verdict = await unitVerdict(validator)
        #expect(verdict != nil, "the rule descends past the bound")
        #expect(
            rendered(verdict).contains("maximum supported nesting depth of 2"),
            "got:\n\(rendered(verdict))"
        )
    }

    /// The resources validation needs are bounded by the nesting bound rather
    /// than by the document, so data nested far past the bound is reported
    /// rather than descended into without end.
    @Test func validateDataNestedFarPastTheSupportedDepthReturnsOnASmallStack() async throws {
        let node = nestedInArrays(.unsigned(1), levels: 500)
        let validator = try unitValidator("data = int / [* data]\n", node)
        validator.setMaxNestingDepth(4)
        let verdict = await unitVerdict(validator)
        #expect(verdict != nil, "the data is nested too deeply")
        #expect(rendered(verdict).contains("maximum supported nesting depth"), "got:\n\(rendered(verdict))")
    }
}
