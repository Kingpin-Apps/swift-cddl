import Testing

@testable import SwiftCDDL

/// Encoded example data items from RFC 8949 Appendix A, plus a few simple
/// values (RFC 8949 Section 3.3).
private enum Examples {
    static let boolFalse = hexBytes("f4")
    static let boolTrue = hexBytes("f5")
    static let null = hexBytes("f6")
    static let undefined = hexBytes("f7")

    static let int0 = hexBytes("00")
    static let int1 = hexBytes("01")
    static let int23 = hexBytes("17")
    static let int24 = hexBytes("1818")
    /// -1000
    static let nint1000 = hexBytes("3903e7")

    /// Half precision.
    static let float00 = hexBytes("f90000")
    /// Half precision.
    static let float10 = hexBytes("f93c00")
    /// Single precision.
    static let float1e5 = hexBytes("fa47c35000")
    /// Double precision.
    static let float1e300 = hexBytes("fb7e37e43c8800759c")

    /// `[]`
    static let arrayEmpty = hexBytes("80")
    /// `[1, 2, 3]`
    static let array123 = hexBytes("83010203")
    /// `[1, [2, 3], [4, 5]]`
    static let array1_23_45 = hexBytes("8301820203820405")

    static let textEmpty = hexBytes("60")
    static let textIETF = hexBytes("6449455446")
    /// U+6C34
    static let textCJK = hexBytes("63e6b0b4")

    static let bytesEmpty = hexBytes("40")
    static let bytes1234 = hexBytes("4401020304")

    /// simple(0), unassigned.
    static let simple0 = hexBytes("e0")
    /// simple(19), unassigned.
    static let simple19 = hexBytes("f3")
    /// simple(32), unassigned, in the two-byte encoding.
    static let simple32 = hexBytes("f820")
    /// simple(255), unassigned, in the two-byte encoding.
    static let simple255 = hexBytes("f8ff")
}

/// A record of a name and an age, as a map keyed by its field names.
private func personStruct(_ name: String, _ age: UInt64) -> CBORNode {
    .map([(key: .text("name"), value: .text(name)), (key: .text("age"), value: .unsigned(age))])
}

/// A map with text keys, in order.
private func textMap(_ entries: [(String, CBORNode)]) -> CBORNode {
    .map(entries.map { (key: CBORNode.text($0.0), value: $0.1) })
}

/// Validates the encoding of `node`, expecting a match.
private func expectValidNode(
    _ cddl: String,
    _ node: CBORNode,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    await expectValid(cddl, node.encoded(), sourceLocation: sourceLocation)
}

/// Validates the encoding of `node`, expecting a mismatch.
private func expectInvalidNode(
    _ cddl: String,
    _ node: CBORNode,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    await expectInvalid(cddl, node.encoded(), sourceLocation: sourceLocation)
}

/// The rendered failure of validating `bytes`, expected to be a mismatch;
/// empty when the document matched.
private func failureText(
    _ cddl: String,
    _ bytes: [UInt8],
    sourceLocation: SourceLocation = #_sourceLocation
) async -> String {
    guard let error = await expectInvalid(cddl, bytes, sourceLocation: sourceLocation) else { return "" }
    return error.description
}

/// The failure of validating `bytes` against `cddl`, or `nil` on a match,
/// without the comparison with the reference oracle (for schemas whose
/// verdict here differs by design).
private func directVerdict(_ cddl: String, _ bytes: [UInt8]) async -> CBORValidationError? {
    do {
        try await validateCBOR(cddl: cddl, cbor: bytes)
        return nil
    } catch {
        return error
    }
}

/// Validation of basic CBOR data items, arrays, maps, tags and byte string
/// literals against CDDL (RFC 8610 Sections 2, 3 and 3.5).
@Suite
struct CBORValidationTests {
    @Test func validateCborBool() async {
        let cddl = "thing = true"
        await expectValid(cddl, Examples.boolTrue)
        await expectInvalid(cddl, Examples.boolFalse)
        await expectInvalid(cddl, Examples.null)
    }

    @Test func validateCborFloat() async {
        var cddl = "thing = 0.0"
        await expectValid(cddl, Examples.float00)
        await expectInvalid(cddl, Examples.float10)

        cddl = "thing = float"
        await expectValid(cddl, Examples.float10)
        await expectValid(cddl, Examples.float1e5)
        await expectValid(cddl, Examples.float1e300)

        cddl = "thing = float16"
        await expectValid(cddl, Examples.float10)

        // A float encoded in fewer bits than the type names still matches:
        // preferred serialization (RFC 8949 Section 4.1) shrinks floats to the
        // shortest width that keeps the value.
        cddl = "thing = float32"
        await expectValid(cddl, Examples.float10)
        await expectValid(cddl, Examples.float1e5)

        cddl = "thing = float64"
        await expectValid(cddl, Examples.float10)
        await expectValid(cddl, Examples.float1e300)
    }

    @Test func validateCborInteger() async {
        var cddl = "thing = 23 / 24"
        await expectValid(cddl, Examples.int23)
        await expectValid(cddl, Examples.int24)
        cddl = "thing = 1"
        await expectInvalid(cddl, Examples.null)
        await expectInvalid(cddl, Examples.float10)
        await expectInvalid(cddl, Examples.boolTrue)
        cddl = "thing = int"
        await expectValid(cddl, Examples.int0)
        await expectValid(cddl, Examples.int24)
        await expectValid(cddl, Examples.nint1000)
        await expectInvalid(cddl, Examples.float10)
        cddl = "thing = uint"
        await expectValid(cddl, Examples.int0)
        await expectValid(cddl, Examples.int24)
        await expectInvalid(cddl, Examples.nint1000)
    }

    @Test func validateCborUintControlOps() async {
        // Control operators over a uint target are evaluated, not skipped.
        let int8 = hexBytes("08")
        let int255 = hexBytes("18ff")
        let int256 = hexBytes("190100")
        let cases: [(String, [UInt8], [UInt8])] = [
            ("thing = uint .le 23", Examples.int23, Examples.int24),
            ("thing = uint .lt 24", Examples.int23, Examples.int24),
            ("thing = uint .gt 23", Examples.int24, Examples.int23),
            ("thing = uint .ge 24", Examples.int24, Examples.int23),
            ("thing = uint .eq 23", Examples.int23, Examples.int24),
            ("thing = uint .ne 23", Examples.int24, Examples.int23),
            ("thing = uint .size 1", int255, int256),
            ("thing = uint .bits 3", int8, Examples.int23),
        ]
        for (cddl, accept, reject) in cases {
            await expectValid(cddl, accept)
            await expectInvalid(cddl, reject)
            await expectInvalid(cddl, Examples.nint1000)
        }
    }

    @Test func validateCborTextstring() async {
        let cddl = "thing = tstr"
        await expectValid(cddl, Examples.textEmpty)
        await expectValid(cddl, Examples.textIETF)
        await expectValid(cddl, Examples.textCJK)
        await expectInvalid(cddl, Examples.bytesEmpty)
    }

    @Test func validateCborBytestring() async {
        let cddl = "thing = bstr"
        await expectValid(cddl, Examples.bytesEmpty)
        await expectValid(cddl, Examples.bytes1234)
        await expectInvalid(cddl, Examples.textEmpty)
        await expectInvalid(cddl, Examples.array123)
    }

    @Test func validateCborArray() async {
        var cddl = "thing = []"
        await expectValid(cddl, Examples.arrayEmpty)
        await expectInvalid(cddl, Examples.null)

        await expectInvalid(cddl, Examples.array123)

        cddl = "thing = [1, 2, 3]"
        await expectValid(cddl, Examples.array123)
    }

    @Test func validateCborGroup() async {
        await expectValid("thing = (* int)", Examples.int0)
    }

    @Test func validateCborHomogenousArray() async {
        var cddl = "thing = [* int]"  // zero or more
        await expectValid(cddl, Examples.arrayEmpty)
        await expectValid(cddl, Examples.array123)
        cddl = "thing = [+ int]"  // one or more
        await expectValid(cddl, Examples.array123)
        await expectInvalid(cddl, Examples.arrayEmpty)
        cddl = "thing = [? int]"  // zero or one
        await expectValid(cddl, Examples.arrayEmpty)
        await expectValidNode(cddl, .array([.unsigned(42)]))
        await expectInvalid(cddl, Examples.array123)

        cddl = "thing = [* tstr]"
        await expectInvalid(cddl, Examples.array123)

        // An alias type; the rule validated against comes first.
        cddl = "thing = [* zipcode]  zipcode = int"
        await expectValid(cddl, Examples.arrayEmpty)
        await expectValid(cddl, Examples.array123)
    }

    @Test func validateCborArrayGroups() async {
        await expectValid("thing = [int, (int, int)]", Examples.array123)
        await expectValid("thing = [(int, int, int)]", Examples.array123)
        await expectValid("thing = [* (int)]", Examples.array123)

        // Three elements cannot be consumed by repetitions of a two-entry group.
        await expectInvalid("thing = [* (int, int)]", Examples.array123)
    }

    @Test func validateCborArrayRecord() async {
        var cddl = "thing = [a: int, b: int, c: int]"
        await expectValid(cddl, Examples.array123)
        await expectInvalid(cddl, Examples.arrayEmpty)

        cddl = "thing = [a: tstr, b: int]"
        await expectValidNode(cddl, .array([.text("Alice"), .unsigned(42)]))
        await expectInvalidNode(cddl, .array([.unsigned(43), .text("Carol")]))
        await expectInvalidNode(cddl, .array([.text("David"), .unsigned(44), .unsigned(45)]))
        await expectInvalidNode(cddl, .array([.text("Eve")]))

        cddl = "thing = [a: tstr, b: uint, c: float32, d: bool]"
        await expectValidNode(cddl, .array([.text("xyz"), .unsigned(17), .float(9.9), .bool(false)]))

        await expectInvalid(cddl, Examples.array123)
    }

    @Test func validateCborMap() async {
        let bytes = personStruct("Bob", 43).encoded()
        await expectValid("thing = {name: tstr, age: int}", bytes)
        await expectValid("thing = {name: tstr, ? age: int}", bytes)

        // A key is optional when its occurrence is "?" or "*", and required
        // when it is "+".
        await expectValid("thing = {name: tstr, age: int, ? minor: bool}", bytes)
        await expectValid("thing = {name: tstr, age: int, * minor: bool}", bytes)
        await expectInvalid("thing = {name: tstr, age: int, + minor: bool}", bytes)

        await expectInvalid("thing = {name: tstr, age: tstr}", bytes)

        await expectInvalid("thing = {name: tstr}", bytes)

        // "* keytype => valuetype" collects the remaining entries of the
        // expected types.
        await expectValid("thing = {* tstr => any}", bytes)
        await expectValid("thing = {name: tstr, * tstr => any}", bytes)
        await expectValid("thing = {name: tstr, age: int, * tstr => any}", bytes)
        await expectValid("thing = {+ tstr => any}", bytes)

        // One entry cannot be collected because its value type does not match.
        await expectInvalid("thing = {* tstr => int}", bytes)

        // Two entries cannot be collected because their key type does not match.
        await expectInvalid("thing = {* int => any}", bytes)

        await expectInvalid("thing = {name: tstr, age: int, minor: bool}", bytes)

        await expectInvalid("thing = {x: int, y: int, z: int}", Examples.array123)
    }

    @Test func validateCborMapFloatKey() async {
        // A float-typed map key matches floats, not null keys.
        let mapFloatKey = hexBytes("a1f93e0001")  // {1.5: 1}
        let mapNullKey = hexBytes("a1f601")  // {null: 1}

        var cddl = "m = { float => uint }"
        await expectValid(cddl, mapFloatKey)
        await expectInvalid(cddl, mapNullKey)

        cddl = "m = { ? float => uint }"
        await expectValid(cddl, mapFloatKey)
        await expectInvalid(cddl, mapNullKey)
    }

    @Test func verifyLargeTagValues() async {
        let cddl = """

                    thing = #6.8386104246373017956(tstr) / #6.42(tstr)

            """

        // A small tag number.
        #expect(await cborResult(cddl, CBORNode.tagged(42, .text("test")).encoded()) == nil)

        // A tag number needing eight bytes.
        #expect(await cborResult(cddl, CBORNode.tagged(8_386_104_246_373_017_956, .text("test")).encoded()) == nil)

        // A tag number the schema does not name.
        #expect(await cborResult(cddl, CBORNode.tagged(99, .text("test")).encoded()) != nil)
    }

    @Test func validateRangeOperators() async {
        let cddl = """
            test = {
                inclusive: 5..10,      ; inclusive-inclusive range
                exclusive: 5...10,     ; inclusive-exclusive range (per RFC 8610)
            }

            """

        // The inclusive range (..) and the range excluding its upper bound (...).
        #expect(await nodeResult(cddl, textMap([("inclusive", .integer(5)), ("exclusive", .integer(5))])) == nil)
        #expect(await nodeResult(cddl, textMap([("inclusive", .integer(10)), ("exclusive", .integer(9))])) == nil)

        // 10 lies outside 5...10.
        #expect(
            await nodeResult(cddl, textMap([("inclusive", .integer(10)), ("exclusive", .integer(10))])) != nil,
            "10 should fail inclusive-exclusive range 5...10")

        // 4 lies outside 5..10.
        #expect(
            await nodeResult(cddl, textMap([("inclusive", .integer(4)), ("exclusive", .integer(5))])) != nil,
            "4 should fail inclusive range 5..10")
    }

    @Test func validateCborSizeRangeWithConstant() async {
        let cddl = """

                    person = {name: tstr .size (1..max_tstr_length), age: uint}
                    max_tstr_length = 100

            """

        // A name length within the range.
        await expectValidNode(cddl, textMap([("name", .text("Alice")), ("age", .integer(30))]))

        // A name length at the upper bound.
        await expectValidNode(
            cddl, textMap([("name", .text(String(repeating: "a", count: 100))), ("age", .integer(30))]))

        // A name length above the range.
        await expectInvalidNode(
            cddl, textMap([("name", .text(String(repeating: "a", count: 101))), ("age", .integer(30))]))

        // A name length below the range.
        await expectInvalidNode(cddl, textMap([("name", .text("")), ("age", .integer(30))]))
    }

    /// `#7.N` matches the simple value N, assigned or not (RFC 8610 Section
    /// 3.6, RFC 8949 Section 3.3).
    @Test func validateCborSimpleValues() async {
        var cddl = "thing = #7.32"
        await expectValid(cddl, Examples.simple32)

        await expectInvalid(cddl, Examples.simple255)

        cddl = "thing = #7.0"
        await expectValid(cddl, Examples.simple0)

        cddl = "thing = #7.19"
        await expectValid(cddl, Examples.simple19)

        cddl = "thing = #7.255"
        await expectValid(cddl, Examples.simple255)

        // Major type 7 without an argument matches any simple value.
        cddl = "thing = #7"
        await expectValid(cddl, Examples.simple0)
        await expectValid(cddl, Examples.simple32)
        await expectValid(cddl, Examples.simple255)

        // ... and booleans, null and floats.
        await expectValid(cddl, Examples.boolTrue)
        await expectValid(cddl, Examples.boolFalse)
        await expectValid(cddl, Examples.null)
        await expectValid(cddl, Examples.float10)

        // The assigned simple values through #7.N.
        cddl = "thing = #7.20"
        await expectValid(cddl, Examples.boolFalse)
        await expectInvalid(cddl, Examples.boolTrue)

        cddl = "thing = #7.21"
        await expectValid(cddl, Examples.boolTrue)
        await expectInvalid(cddl, Examples.boolFalse)

        cddl = "thing = #7.22"
        await expectValid(cddl, Examples.null)
        await expectInvalid(cddl, Examples.boolTrue)
    }

    /// An array record rejects an array with more elements than it has entries.
    @Test func validateCborArrayRecordExtraElements() async {
        let cddl = "thing = [a: tstr, b: int]"

        await expectValidNode(cddl, .array([.text("testString"), .unsigned(1)]))

        await expectInvalidNode(cddl, .array([.text("testString"), .unsigned(1), .unsigned(2)]))
    }

    @Test func validateDecfracAndBigfloat() async {
        // A decimal fraction: tag 4 over [exponent, mantissa], 273.15 = 27315 * 10^-2.
        await expectValidNode("temperature = decfrac", .tagged(4, .array([.integer(-2), .integer(27315)])))

        // A bigfloat: tag 5 over [exponent, mantissa], 1.5 = 3 * 2^-1.
        await expectValidNode("measurement = bigfloat", .tagged(5, .array([.integer(-1), .integer(3)])))

        // The wrong tag for decfrac.
        await expectInvalidNode("temperature = decfrac", .tagged(5, .array([.integer(-2), .integer(27315)])))

        // The wrong tag for bigfloat.
        await expectInvalidNode("measurement = bigfloat", .tagged(4, .array([.integer(-1), .integer(3)])))

        // Not an array inside the tag.
        await expectInvalidNode("temperature = decfrac", .tagged(4, .integer(42)))

        // A float exponent.
        await expectInvalidNode(
            "temperature = decfrac", .tagged(4, .array([.float(1.5, width: .half), .integer(27315)])))

        // The same through an explicit tag.
        await expectValidNode("mytype = #6.4([int, integer])", .tagged(4, .array([.integer(-2), .integer(27315)])))

        // A bigfloat with a bignum mantissa (tag 2).
        await expectValidNode(
            "big_measurement = bigfloat", .tagged(5, .array([.integer(-1), .tagged(2, .bytes([0x01, 0x00]))])))
    }

    /// A nested map under `* k => {+ k2 => v}` validates (RFC 8610 Section 3.5).
    @Test func validateNestedMapMemberValue() async {
        let cddl = "start = {* bytes => {+ bytes => uint}}"

        await expectValidNode(
            cddl, .map([(key: .bytes([0x61, 0x62]), value: .map([(key: .bytes([0x63]), value: .integer(5))]))]))

        // The inner value has to be a map, not a uint.
        await expectInvalidNode(cddl, .map([(key: .bytes([0x61, 0x62]), value: .integer(5))]))
    }

    /// A generic type instantiated as a map type resolves to its body rather
    /// than being compared whole against the key type of the enclosing map.
    @Test func validateGenericTypenameAsMap() async {
        let cddl = """

                start = outer<positive>
                outer<v> = {* outer_key => {+ inner_key => v}}
                outer_key = bytes .size 4
                inner_key = bytes .size (0 .. 4)
                positive = 1 .. 18446744073709551615

            """

        // A 4-byte outer key, a 3-byte inner key, value 1.
        await expectValidNode(
            cddl,
            .map([
                (
                    key: .bytes([0x01, 0x02, 0x03, 0x04]),
                    value: .map([(key: .bytes([0x66, 0x6f, 0x6f]), value: .integer(1))])
                )
            ]))

        // Value 0 lies outside `positive`.
        await expectInvalidNode(
            cddl,
            .map([
                (
                    key: .bytes([0x01, 0x02, 0x03, 0x04]),
                    value: .map([(key: .bytes([0x66, 0x6f, 0x6f]), value: .integer(0))])
                )
            ]))
    }

    /// Array entries past the first are validated when the array type is
    /// `[primitive, generic<arg>]`.
    @Test func validateArrayWithGenericTypenameEntry() async {
        let cddl = """

                start = [counter, outer<positive>]
                counter = uint
                outer<v> = {* outer_key => {+ inner_key => v}}
                outer_key = bytes .size 4
                inner_key = bytes .size (0 .. 4)
                positive = 1 .. 18446744073709551615

            """

        await expectValidNode(
            cddl,
            .array([
                .integer(1_000_000),
                .map([
                    (
                        key: .bytes([0x01, 0x02, 0x03, 0x04]),
                        value: .map([(key: .bytes([0x66, 0x6f, 0x6f]), value: .integer(1))])
                    )
                ]),
            ]))

        // The second element is a string instead of a map.
        await expectInvalidNode(cddl, .array([.integer(1), .text("wrong")]))

        // The second element is a map of the wrong inner shape.
        await expectInvalidNode(
            cddl, .array([.integer(1), .map([(key: .bytes([0x01, 0x02, 0x03, 0x04]), value: .integer(5))])]))

        // A zero leaf value lies outside `positive`.
        await expectInvalidNode(
            cddl,
            .array([
                .integer(1),
                .map([
                    (
                        key: .bytes([0x01, 0x02, 0x03, 0x04]),
                        value: .map([(key: .bytes([0x66, 0x6f, 0x6f]), value: .integer(0))])
                    )
                ]),
            ]))
    }

    /// Negative integer literals reach down to -2^64, the smallest CBOR
    /// integer (RFC 8949 Section 3.1, major type 1).
    @Test func validateNegativeBelowI64Min() async {
        let cddl = "start = -18446744073709551616"

        await expectValidNode(cddl, .negative(UInt64.max))

        await expectInvalidNode(cddl, .integer(-1))
    }

    /// An array whose group has optional entries accepts every length from
    /// the mandatory count up to the mandatory plus the optional count.
    @Test func optionalEntryLengthAcceptsShortArrays() async {
        let cddl = "start = [a: int, b: tstr, ? c: bytes]"

        // The optional entry absent.
        await expectValidNode(cddl, .array([.integer(1), .text("ok")]))

        // The optional entry present.
        await expectValidNode(cddl, .array([.integer(1), .text("ok"), .bytes([0xde, 0xad])]))

        // Too short.
        await expectInvalidNode(cddl, .array([.integer(1)]))

        // Too long.
        await expectInvalidNode(cddl, .array([.integer(1), .text("ok"), .bytes([0xde, 0xad]), .integer(99)]))
    }

    /// A bareword key in an array is documentation only (RFC 8610 Section
    /// 3.5.2), even when the bareword also names a rule whose body is an array.
    @Test func arrayMemberKeyBarewordIsDocumentationOnly() async {
        let cddl = """

                start = [+ record]
                record = [tag: tag_kind, idx: uint .size 4, payload: payload_t, pair: pair]
                tag_kind = 0 / 1 / 2 / 3 / 4
                payload_t = #6.121([])
                pair = [fst: uint, snd: uint]

            """

        await expectValidNode(
            cddl,
            .array([
                .array([
                    .integer(1), .integer(0), .tagged(121, .array([])), .array([.integer(7), .integer(11)]),
                ])
            ]))

        // A pair of one element is reported at its deep location.
        let message = await failureText(
            cddl,
            CBORNode.array([
                .array([.integer(1), .integer(0), .tagged(121, .array([])), .array([.integer(7)])])
            ]).encoded())
        #expect(message.contains("/0/3"), "expected deep path /0/3 in error, got:\n\(message)")
    }

    /// `[+ T]` over a referenced rule validates every element of the array.
    @Test func homogeneousArrayIteratesEveryElement() async {
        let cddl = """

                start = nonempty_set<inner>
                nonempty_set<a> = #6.258([+ a]) / [+ a]
                inner = [int, tstr]

            """

        let innerGood = CBORNode.array([.integer(1), .text("ok")])
        let innerBad = CBORNode.array([.integer(2), .integer(99)])

        await expectValidNode(cddl, .array([innerGood, innerGood]))

        // A good element and a bad one: reported at /1/1.
        let message = await failureText(cddl, CBORNode.array([innerGood, innerBad]).encoded())
        #expect(message.contains("/1/1"), "expected deep path /1/1 in failure message, got:\n\(message)")

        // `[+ int]` rejects a mismatch in the middle of the array.
        let simple = await failureText(
            "start = [+ int]", CBORNode.array([.integer(1), .text("oops"), .integer(3)]).encoded())
        #expect(simple.contains("/1"))
    }

    /// When every alternative of a type choice fails, the errors carry the
    /// deep location of the failure inside each alternative, naming map keys.
    @Test func typeChoiceFailureReportsDeepPath() async {
        let cddl = """

                start = uint / outer<int>
                outer<v> = {* bytes => {+ bytes => v}}

            """

        let node = CBORNode.map([
            (key: .bytes([0xab]), value: .map([(key: .bytes([0xcd]), value: .text("not-int"))]))
        ])
        let message = await failureText(cddl, node.encoded())

        #expect(message.contains("/h'ab'"), "expected path to walk into the bytes-keyed entry, got:\n\(message)")
        #expect(!message.contains("/Map(["), "expected no map dump segment in cbor_location, got:\n\(message)")
    }

    /// `.cborseq` decodes its byte string as a CBOR sequence (RFC 8742) into
    /// an array of every item, not just the first.
    @Test func validateCborseqDecodesConcatenatedItems() async {
        // A byte string holding the items 1, 2 and 3.
        let bytes = CBORNode.bytes([0x01, 0x02, 0x03]).encoded()

        // A fixed shape.
        await expectValid("start = bstr .cborseq [int, int, int]", bytes)

        // A homogeneous array.
        await expectValid("start = bstr .cborseq [+ int]", bytes)

        // The empty sequence matches `[]`.
        await expectValid("start = bstr .cborseq []", CBORNode.bytes([]).encoded())

        // The items are not text strings.
        await expectInvalid("start = bstr .cborseq [+ tstr]", bytes)
    }

    /// A wrong-size byte string at array index `i`, matched through a rule
    /// whose body is `bstr .size N`, is reported at `/i`.
    @Test func typeChoiceSizeFailureReportsArrayIndexPath() async {
        let cddl = """

                start = wrap<inner>
                wrap<a> = #6.258([+ a]) / [+ a]
                inner = [pubkey, signature]
                pubkey = bytes .size 32
                signature = bytes .size 64

            """

        // A signature that is too short, at [0][1].
        let node = CBORNode.array([
            .array([.bytes([UInt8](repeating: 0x01, count: 32)), .bytes([UInt8](repeating: 0x02, count: 10))])
        ])
        let message = await failureText(cddl, node.encoded())
        #expect(message.contains("/0/1"), "expected deep path /0/1 in error, got:\n\(message)")
        #expect(message.contains(".size 64"), "expected size constraint mention, got:\n\(message)")
    }

    /// Integer literals up to 2^64 - 1 parse and validate.
    @Test func validateU64MaxLiteralInRange() async {
        let cddl = """

                start = 1 .. 18446744073709551615

            """

        // The lower bound.
        await expectValidNode(cddl, .integer(1))

        // The upper bound.
        await expectValidNode(cddl, .unsigned(UInt64.max))

        // Below the range.
        await expectInvalidNode(cddl, .integer(0))

        // The same range through a type name.
        let named = """

                start = 1 .. max_u64
                max_u64 = 18446744073709551615

            """
        await expectValidNode(named, .unsigned(UInt64.max))

        // The literal alone.
        let literal = "start = 18446744073709551615"
        await expectValidNode(literal, .unsigned(UInt64.max))
        await expectInvalidNode(literal, .integer(0))
    }

    /// `bstr .size N` filters map keys as a member key, and rejects data of the
    /// wrong type or size as a top-level type.
    @Test func validateBstrSizeInMemberKeyAndTopLevel() async {
        let cddl = "start = bstr .size 32"
        await expectValidNode(cddl, .bytes([UInt8](repeating: 0xaa, count: 32)))

        await expectInvalidNode(cddl, .bytes([UInt8](repeating: 0xaa, count: 31)))

        await expectInvalidNode(cddl, .text("xx"))

        // A member key: the keys are 32-byte strings.
        let mapCDDL = "start = {* bstr .size 32 => uint}"
        await expectValidNode(mapCDDL, .map([(key: .bytes([UInt8](repeating: 0xbb, count: 32)), value: .integer(7))]))

        // The empty map matches under `*`.
        await expectValidNode(mapCDDL, .map([]))
    }

    /// A byte string literal matches exactly the byte string of its content,
    /// including inside a type choice.
    @Test func validateByteStringLiteralInTypeChoice() async {
        let cddl = "start = h'0102' / h'0304'"

        for content: [UInt8] in [[0x01, 0x02], [0x03, 0x04]] {
            await expectValidNode(cddl, .bytes(content))
        }

        await expectInvalidNode(cddl, .bytes([0x05, 0x06]))
    }

    /// A byte string literal renders in base16 in error messages, whatever its
    /// content.
    @Test func byteStringLiteralErrorMessageRendersHex() async {
        var message = await failureText("start = h'ff'", CBORNode.bytes([0x00]).encoded())
        #expect(message.contains("h'ff'"), "expected the literal rendered as base16, got: \(message)")

        // Content that is valid UTF-8 is still not rendered as text.
        message = await failureText("start = h'6161'", CBORNode.bytes([0x00]).encoded())
        #expect(message.contains("h'6161'"), "expected the literal rendered as base16, got: \(message)")
    }

    /// A missing map key that is a byte string literal is reported in base16.
    @Test func validateByteStringLiteralMemberKey() async {
        let cddl = "start = { h'0102' => uint }"

        await expectValidNode(cddl, .map([(key: .bytes([0x01, 0x02]), value: .integer(10))]))

        let message = await failureText(cddl, CBORNode.map([(key: .bytes([0x03, 0x04]), value: .integer(10))]).encoded())
        #expect(message.contains("h'0102'"), "expected the missing key rendered as base16, got: \(message)")
    }

    /// Base16 literals are case insensitive, and whitespace inside them is not
    /// content (RFC 8610 Appendix G.2).
    @Test func validateByteStringLiteralHexDigitCase() async {
        var bytes = CBORNode.bytes([0x48, 0x65]).encoded()
        for cddl in ["start = h'4865'", "start = h'48 65'"] {
            await expectValid(cddl, bytes)
        }

        bytes = CBORNode.bytes([0xab]).encoded()
        for cddl in ["start = h'AB'", "start = h'ab'", "start = h'Ab'"] {
            await expectValid(cddl, bytes)
        }

        // An odd number of digits or a non-hex digit is not a literal at all.
        for cddl in ["start = h'0'", "start = h'zz'"] {
            #expect(throws: ParserError.self, "expected \(cddl) to fail to parse") {
                _ = try cddlFromStr(cddl)
            }
        }
    }

    /// An unprefixed byte string literal denotes the UTF-8 bytes of its text,
    /// which carries escape sequences (RFC 8610 Section 3.1).
    @Test func validateByteStringLiteralEscapeSequences() async {
        let cases: [(String, [UInt8])] = [
            (#"start = '\n'"#, [0x0a]),
            (#"start = '\t'"#, [0x09]),
            (#"start = '\''"#, [0x27]),
            (#"start = '\\'"#, [0x5c]),
            (#"start = 'a\tb'"#, [0x61, 0x09, 0x62]),
            (#"start = '\u{2318}'"#, [0xe2, 0x8c, 0x98]),
        ]
        for (cddl, content) in cases {
            await expectValidNode(cddl, .bytes(content))
        }

        // The escape sequence denotes one byte, not the two characters it is
        // written with.
        await expectInvalidNode(#"start = '\n'"#, .bytes([0x5c, 0x6e]))
    }

    /// A byte string literal is a value, so it cannot be the controller of an
    /// operator that constrains its target by something other than a value.
    @Test func byteStringLiteralIsNotASizeOrBitsController() async {
        let bytes = CBORNode.bytes([0x02]).encoded()

        for (cddl, control) in [("start = bstr .size h'02'", ".size"), ("start = bstr .bits h'02'", ".bits")] {
            let message = await failureText(cddl, bytes)
            #expect(message.contains(control), "expected the error to name \(control), got: \(message)")
        }
    }

    /// `.default` supplies the value an absent optional entry is assumed to
    /// have; a present entry still has to match the target.
    @Test func validateByteStringLiteralDefaultValue() async {
        var cddl = "start = { ? k: h'0102' .default h'0304' }"

        let present = textMap([("k", .bytes([0x01, 0x02]))])
        await expectValidNode(cddl, present)

        await expectValidNode(cddl, .map([]))

        let other = textMap([("k", .bytes([0x09, 0x09]))])
        await expectInvalidNode(cddl, other)

        cddl = "start = { k: h'0102' .default h'0304' }"
        await expectValidNode(cddl, present)
        await expectInvalidNode(cddl, other)
    }

    /// `.cat` and `.det` denote the byte string of the operands' contents
    /// concatenated (RFC 9165 Section 2.1).
    @Test func validateConcatenatedByteStringLiteral() async {
        let cases: [(String, [UInt8])] = [
            (#"start = h'6161' .cat "b""#, [0x61, 0x61, 0x62]),
            ("start = h'3031' .cat h'3233'", [0x30, 0x31, 0x32, 0x33]),
            ("start = h'3031' .cat '23'", [0x30, 0x31, 0x32, 0x33]),
            ("start = h'00' .cat h'ff'", [0x00, 0xff]),
        ]
        for (cddl, content) in cases {
            await expectValidNode(cddl, .bytes(content))
        }

        // The base16 notation of an operand is not its content.
        let message = await failureText(#"start = h'6161' .cat "b""#, CBORNode.bytes([0x61, 0x61, 0x36, 0x32]).encoded())
        #expect(message.contains("concatenated byte string"), "expected the concatenation error, got: \(message)")

        // A text target concatenated with a base16 literal denotes text.
        await expectValidNode(#"start = "testing" .cat h'313233'"#, .text("testing123"))
    }

    /// `.eq` and `.ne` take a byte string target, and both evaluate the
    /// controller rather than accept every data item.
    @Test func validateByteStringEqualityControls() async {
        let matching = CBORNode.bytes([0x01, 0x02]).encoded()
        let other = CBORNode.bytes([0x09, 0x09]).encoded()

        await expectValid("start = bstr .eq h'0102'", matching)
        await expectInvalid("start = bstr .eq h'0102'", other)

        await expectValid("start = bstr .ne h'0102'", other)
        await expectInvalid("start = bstr .ne h'0102'", matching)

        // A data item that is not an array cannot equal an array controller.
        await expectInvalidNode("start = [1, 2] .eq [1, 2]", .integer(3))
    }

    /// A byte string literal keeps its value meaning wherever an operator
    /// recurses into a target or into a payload it decoded.
    @Test func validateByteStringLiteralUnderRecursingControls() async {
        let matching = CBORNode.bytes([0x01, 0x02]).encoded()
        let other = CBORNode.bytes([0x09, 0x09]).encoded()

        for cddl in ["start = bstr .and h'0102'", "start = h'0102' .within bstr"] {
            await expectValid(cddl, matching)
            await expectInvalid(cddl, other)
        }

        // A `.cbor` payload that decodes to a byte string is compared with the
        // literal by the same equality.
        var bytes = CBORNode.bytes(CBORNode.bytes([0x01, 0x02]).encoded()).encoded()
        await expectValid("start = bstr .cbor h'0102'", bytes)
        await expectInvalid("start = bstr .cbor h'0304'", bytes)

        // So is every item of a `.cborseq` payload.
        let payload = CBORNode.bytes([0x01, 0x02]).encoded() + CBORNode.bytes([0x03, 0x04]).encoded()
        bytes = CBORNode.bytes(payload).encoded()
        await expectValid("start = bstr .cborseq [h'0102', h'0304']", bytes)
        await expectInvalid("start = bstr .cborseq [h'0102', h'0909']", bytes)
    }

    /// A byte string literal and a text string literal denote different types,
    /// so neither matches the other's data item whatever their content.
    @Test func byteStringLiteralDoesNotMatchText() async {
        let text = CBORNode.text("aa").encoded()
        let bytes = CBORNode.bytes([0x61, 0x61]).encoded()

        for cddl in ["start = h'6161'", "start = 'aa'"] {
            await expectValid(cddl, bytes)

            let message = await failureText(cddl, text)
            #expect(message.contains("got \"aa\""), "expected the text data item in the error, got: \(message)")
        }

        // Content that does not read as the same text is rejected the same way,
        // as is a literal reached through a group entry.
        await expectInvalidNode("start = h'0102'", .text("\u{1}\u{2}"))

        await expectInvalidNode("start = [h'6161']", .array([.text("aa")]))
        await expectValidNode("start = [h'6161']", .array([.bytes([0x61, 0x61])]))

        // A text string is never equal to a byte string literal, which is what
        // `.ne` asks for and what `.eq` and a concatenation cannot have.
        await expectValid("start = tstr .ne h'6161'", text)
        await expectInvalid("start = tstr .eq h'6161'", text)
        let concatenation = await failureText("start = h'61' .cat h'61'", text)
        #expect(
            concatenation.contains("concatenated byte string"),
            "expected the concatenation error, got: \(concatenation)")

        // The other direction: a text string literal does not match a byte
        // string, so `.ne` against one holds, and the data item renders in
        // base16.
        await expectInvalid(#"start = "aa""#, bytes)
        await expectValid(#"start = bstr .ne "aa""#, bytes)
        await expectInvalid(#"start = bstr .eq "aa""#, bytes)
        let message = await failureText(#"start = "aa""#, bytes)
        #expect(message.contains("h'6161'"), "expected the data item rendered as base16, got: \(message)")
    }

    /// The `.abnfb` operator (RFC 9165 Section 3) takes a grammar whose first
    /// line names the rule to start from, in either byte string literal
    /// notation. This implementation does not provide ABNF matching, so both
    /// documents are reported as needing an unsupported feature.
    @Test func validateAbnfGrammarInEitherByteStringNotation() async {
        let grammar = "oct\noct = %x61-63\n"
        let base16 = hexString(Array(grammar.utf8))

        for cddl in [
            "start = bstr .abnfb h'\(base16)'",
            """
            start = bstr .abnfb 'oct
                  oct = %x61-63
                '
            """,
        ] {
            // The grammar admits 0x61.
            let admitted = await directVerdict(cddl, CBORNode.bytes([0x61]).encoded())
            guard case .unsupported = admitted else {
                Issue.record("expected an unsupported feature for \(cddl), got \(String(describing: admitted))")
                continue
            }

            // The grammar does not admit 0x7a.
            let rejected = await directVerdict(cddl, CBORNode.bytes([0x7a]).encoded())
            guard case .unsupported = rejected else {
                Issue.record("expected an unsupported feature for \(cddl), got \(String(describing: rejected))")
                continue
            }
        }
    }
}
