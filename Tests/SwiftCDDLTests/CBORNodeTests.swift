import CBORCodable
import Foundation
import BigInt
import Testing

@testable import SwiftCDDL

/// The decoded CBOR data model: decoding a single data item, a prefix and a
/// sequence (RFC 8949, RFC 8742), the faults decoding reports, the bounds on
/// nesting, and how deep values are compared and rendered.
@Suite struct CBORNodeTests {
    // MARK: - Private helpers

    /// The error decoding `bytes` as one data item reports, or `nil` when it
    /// decodes.
    private func decodeFailure(_ bytes: [UInt8]) -> CBORDecodingError? {
        do {
            _ = try decodeCBOR(bytes)
            return nil
        } catch {
            return error
        }
    }

    /// The text of the error decoding `bytes` reports, or the empty string
    /// when it decodes.
    private func decodeReason(_ bytes: [UInt8]) -> String {
        decodeFailure(bytes)?.description ?? ""
    }

    /// Whether the error is a syntax error, whatever its offset.
    private func isSyntax(_ error: CBORDecodingError?) -> Bool {
        if case .syntax? = error { return true }
        return false
    }

    /// `levels` single-element arrays around the integer 1, built without
    /// recursing.
    private func nestedArrays(_ levels: Int) -> CBORNode {
        var value = CBORNode.integer(1)
        for _ in 0..<levels {
            value = .array([value])
        }
        return value
    }

    /// How many single-element arrays `value` nests, walked without recursing.
    private func nestingOf(_ value: CBORNode) -> Int {
        var depth = 0
        var at = value
        while let items = at.arrayItems {
            #expect(items.count == 1)
            guard let first = items.first else { break }
            at = first
            depth += 1
        }
        return depth
    }

    // MARK: - Scalars and containers

    @Test func decodeStandardSimpleValues() throws {
        #expect(try decodeCBOR([0xf4]) == .bool(false))
        #expect(try decodeCBOR([0xf5]) == .bool(true))
        #expect(try decodeCBOR([0xf6]) == .null)
        // undefined (0xf7) keeps its own case; the validator treats it as null.
        #expect(try decodeCBOR([0xf7]) == .undefined)
    }

    @Test func decodeNonstandardSimpleValues() throws {
        #expect(try decodeCBOR([0xe0]) == .simple(0))
        #expect(try decodeCBOR([0xf3]) == .simple(19))
        #expect(try decodeCBOR([0xf8, 0x20]) == .simple(32))
        #expect(try decodeCBOR([0xf8, 0xff]) == .simple(255))
    }

    @Test func decodeInteger() throws {
        #expect(try decodeCBOR([0x00]) == .integer(0))
        #expect(try decodeCBOR([0x01]) == .integer(1))
        #expect(try decodeCBOR([0x17]) == .integer(23))
        #expect(try decodeCBOR([0x18, 0x18]) == .integer(24))
        #expect(try decodeCBOR([0x20]) == .integer(-1))
        #expect(try decodeCBOR([0x20]) == .negative(0))
    }

    @Test func decodeText() throws {
        #expect(try decodeCBOR([0x60]) == .text(""))
        #expect(try decodeCBOR([0x64, 0x49, 0x45, 0x54, 0x46]) == .text("IETF"))
    }

    @Test func decodeBytes() throws {
        #expect(try decodeCBOR([0x40]) == .bytes([]))
        #expect(try decodeCBOR([0x44, 0x01, 0x02, 0x03, 0x04]) == .bytes([1, 2, 3, 4]))
    }

    @Test func decodeArray() throws {
        #expect(try decodeCBOR([0x80]) == .array([]))
        #expect(try decodeCBOR([0x83, 0x01, 0x02, 0x03]) == .array([.integer(1), .integer(2), .integer(3)]))
    }

    @Test func decodeMap() throws {
        #expect(try decodeCBOR([0xa0]) == .map([]))
    }

    @Test func decodeTag() throws {
        let input: [UInt8] = [0xd8, 0x2a, 0x64, 0x74, 0x65, 0x73, 0x74]
        #expect(try decodeCBOR(input) == .tagged(42, .text("test")))
    }

    @Test func decodeFloat() throws {
        // A half-precision float keeps the width it was encoded in.
        #expect(try decodeCBOR([0xf9, 0x00, 0x00]) == .float(0.0, width: .half))
        #expect(try decodeCBOR([0xf9, 0x3c, 0x00]) == .float(1.0, width: .half))
    }

    @Test func decodeArrayWithSimpleValues() throws {
        let input: [UInt8] = [0x83, 0xf8, 0x20, 0x01, 0xf5]
        #expect(try decodeCBOR(input) == .array([.simple(32), .integer(1), .bool(true)]))
    }

    /// A value of the CBOR value model converts to the node holding the same
    /// data item.
    @Test func fromCBORValueModel() {
        #expect(CBORNode(CBOR.unsignedInt(42)) == .integer(42))
        #expect(CBORNode(CBOR.tagged(1, .textString("hello"))) == .tagged(1, .text("hello")))
    }

    /// Converting from the CBOR value model keeps every kind of data item, the
    /// width of each float and the length encoding of each container and
    /// string, in the order the model holds them.
    @Test func conversionFromTheCBORValueModelIsFaithful() {
        let value: CBOR = .array([
            .unsignedInt(1),
            .negativeInt(0),
            .byteString(Data([1, 2])),
            .textString("t"),
            .map([.textString("k"): .unsignedInt(7), .unsignedInt(2): .array([.null])]),
            .tagged(1, .tagged(2, .byteString(Data([0xff])))),
            .half(0x3c00),
            .float(1.5),
            .double(2.5),
            .simple(20),
            .simple(21),
            .simple(22),
            .simple(23),
            .simple(0),
            .simple(32),
            .boolean(true),
            .null,
            .undefined,
            .indefiniteArray([.unsignedInt(1), .indefiniteArray([])]),
            .indefiniteMap([.textString("a"): .boolean(false)]),
            .indefiniteByteString([Data([1]), Data([2, 3])]),
            .indefiniteTextString(["a", "bc"]),
        ])

        let expected: CBORNode = .array([
            .unsigned(1),
            .negative(0),
            .byteString([1, 2]),
            .textString("t"),
            .map([
                (key: .text("k"), value: .integer(7)),
                (key: .integer(2), value: .array([.null])),
            ]),
            .tagged(1, .tagged(2, .bytes([0xff]))),
            .float(1.0, width: .half),
            .float(1.5, width: .single),
            .float(2.5, width: .double),
            .bool(false),
            .bool(true),
            .null,
            .undefined,
            .simple(0),
            .simple(32),
            .bool(true),
            .null,
            .undefined,
            .array([.integer(1), .array([], indefinite: true)], indefinite: true),
            .map([(key: .text("a"), value: .bool(false))], indefinite: true),
            .byteString([1, 2, 3], indefinite: true),
            .textString("abc", indefinite: true),
        ])

        #expect(CBORNode(value) == expected)
    }

    // MARK: - One data item

    /// A CBOR document is one data item, so bytes after the item the input
    /// starts with are not part of it. Reporting how many were left over is
    /// what tells a caller its framing is wrong rather than its data.
    @Test func decodeCborRejectsBytesAfterTheDataItem() {
        let cases: [([UInt8], Int)] = [
            // 05 06: a uint followed by a second uint.
            ([0x05, 0x06], 1),
            // 81 01 ff: [1] followed by a stray break.
            ([0x81, 0x01, 0xff], 1),
            // A scalar followed by six bytes of anything.
            ([0x05, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff], 6),
            // The bytes after a definite-length string are outside it too.
            ([0x42, 0x01, 0x02, 0x03], 1),
        ]
        for (input, trailing) in cases {
            let error = decodeFailure(input)
            #expect(error == .trailingBytes(trailing), "wrong result for \(input): \(String(describing: error))")
        }

        let reason = decodeReason([0x05, 0x06])
        #expect(reason.contains("1"), "the count is named: \(reason)")
    }

    /// The boundary, not a blanket refusal: an input that is exactly one data
    /// item decodes, however that item is shaped.
    @Test func decodeCborAcceptsAnInputThatIsExactlyOneDataItem() throws {
        #expect(try decodeCBOR([0x05]) == .integer(5))
        #expect(try decodeCBOR([0x81, 0x01]) == .array([.integer(1)]))
        // Indefinite-length forms end on their break, which is part of the
        // item; the node records that the length was indefinite.
        #expect(try decodeCBOR([0x9f, 0x01, 0xff]) == .array([.integer(1)], indefinite: true))
        #expect(try decodeCBOR([0x5f, 0x41, 0x01, 0xff]) == .byteString([1], indefinite: true))
        #expect(try decodeCBOR([0x42, 0x01, 0x02]) == .bytes([1, 2]))
    }

    /// Reading one item out of a longer buffer is what the prefix decoder is
    /// for, and the byte count it reports is what lets the caller find the
    /// next.
    @Test func decodeCborPrefixReportsWhatTheItemTook() throws {
        let cases: [([UInt8], CBORNode, Int)] = [
            ([0x05, 0x06], .integer(5), 1),
            ([0x81, 0x01, 0xff], .array([.integer(1)]), 2),
            // A header with an argument, and a payload the length counts.
            ([0x18, 0x18, 0x00], .integer(24), 2),
            ([0x42, 0x01, 0x02, 0x03], .bytes([1, 2]), 3),
        ]
        for (input, expected, used) in cases {
            let (node, consumed) = try decodeCBORPrefix(input)
            #expect(node == expected, "for \(input)")
            #expect(consumed == used, "for \(input)")
        }
    }

    /// A sequence is zero or more whole data items (RFC 8742). Input that stops
    /// inside one holds a truncated item, which is not the same thing as the
    /// sequence having ended.
    @Test func decodeCborSequenceRejectsATruncatedItem() {
        let inputs: [[UInt8]] = [
            // 01 81: a uint, then an array header whose element is missing.
            [0x01, 0x81],
            // A header whose argument bytes are not there.
            [0x01, 0x1a, 0x00],
            // A byte string shorter than its declared length.
            [0x01, 0x43, 0x01],
            // An indefinite-length array with no break.
            [0x01, 0x9f, 0x01],
        ]
        for input in inputs {
            #expect((try? decodeCBORSequence(input)) == nil, "accepted a truncated item: \(input)")
        }
    }

    /// Input that stops part way through a data item is the input running out,
    /// which is a fault of the document rather than of the reader that held it,
    /// so it has a variant of its own.
    @Test func aTruncatedDocumentIsReportedAsEndOfInput() {
        let ones = [UInt8](repeating: 0xff, count: 8)
        let inputs: [[UInt8]] = [
            // An empty input holds no data item at all.
            [],
            // A header whose argument bytes are missing.
            [0x1a, 0x00],
            [0xf8],
            // Containers whose declared elements are missing.
            [0x81],
            [0xa1],
            [0xa1, 0x01],
            [0xc1],
            // Strings shorter than their declared length.
            [0x43, 0x01],
            [0x63, 0x41],
            // Indefinite-length forms with no break.
            [0x9f, 0x01],
            [0xbf, 0x01, 0x02],
            [0x5f, 0x41, 0x01],
            // A declared length no input could carry is reached the same way:
            // the bytes run out, they are not counted out in advance.
            [0x9b] + ones,
            [0xbb] + ones,
            [0x5b] + ones,
            [0x7b] + ones,
        ]
        for input in inputs {
            let error = decodeFailure(input)
            #expect(error == .unexpectedEndOfInput, "expected end of input for \(input), got \(String(describing: error))")
        }

        let reason = decodeReason([0x81])
        #expect(reason.contains("end of input"), "the message names what happened: \(reason)")
    }

    /// The other decoding faults keep their own variants: routing truncation
    /// to the end-of-input variant may not swallow them.
    @Test func otherDecodingFaultsKeepTheirOwnVariants() {
        // 1c: an additional-information value that encodes no argument.
        #expect(isSyntax(decodeFailure([0x1c])))
        // A break where a data item was expected.
        #expect(decodeFailure([0xff]) == .unexpectedBreak)
        // 62 c3 28: a two-byte text string whose bytes are not valid UTF-8.
        #expect(isSyntax(decodeFailure([0x62, 0xc3, 0x28])))
        #expect(decodeFailure([0x05, 0x06]) == .trailingBytes(1))
    }

    /// RFC 8949 Section 3.2.3: the chunks of an indefinite-length string are
    /// definite-length strings of the same major type.
    @Test func indefiniteLengthStringChunksMustBeDefiniteStringsOfTheSameType() throws {
        let inputs: [[UInt8]] = [
            // An indefinite-length byte string nested inside one.
            [0x5f, 0x5f, 0x41, 0x01, 0xff, 0xff],
            // An indefinite-length text string nested inside one.
            [0x7f, 0x7f, 0x61, 0x41, 0xff, 0xff],
            // A text chunk inside a byte string, and a byte chunk inside a
            // text one.
            [0x5f, 0x61, 0x41, 0xff],
            [0x7f, 0x41, 0x01, 0xff],
            // A chunk that is not a string at all.
            [0x5f, 0x01, 0xff],
            [0x7f, 0x01, 0xff],
        ]
        for input in inputs {
            let error = decodeFailure(input)
            #expect(isSyntax(error), "accepted an ill-formed chunk \(input): \(String(describing: error))")
        }

        // The well-formed forms still decode, chunks and all.
        #expect(try decodeCBOR([0x5f, 0x41, 0x01, 0x42, 0x02, 0x03, 0xff]) == .byteString([1, 2, 3], indefinite: true))
        #expect(try decodeCBOR([0x7f, 0x61, 0x41, 0x62, 0x42, 0x43, 0xff]) == .textString("ABC", indefinite: true))
        #expect(try decodeCBOR([0x5f, 0xff]) == .byteString([], indefinite: true))
        #expect(try decodeCBOR([0x7f, 0xff]) == .textString("", indefinite: true))
    }

    /// Each chunk of an indefinite-length text string is valid UTF-8 on its
    /// own, so a character may not be split across two of them.
    @Test func indefiniteLengthTextChunksAreEachValidUtf8() throws {
        // The two bytes of U+00A2 (c2 a2) split over two chunks.
        #expect(isSyntax(decodeFailure([0x7f, 0x41, 0xc2, 0x41, 0xa2, 0xff])))
        #expect(isSyntax(decodeFailure([0x7f, 0x61, 0xc2, 0x61, 0xa2, 0xff])))
        // Whole characters in one chunk are fine.
        #expect(try decodeCBOR([0x7f, 0x62, 0xc2, 0xa2, 0xff]) == .textString("\u{a2}", indefinite: true))
    }

    /// A header declares its own length and nothing has checked it against the
    /// bytes that are left, so committing memory to it up front would let a
    /// handful of bytes abort the process instead of returning an error.
    @Test func aDeclaredLengthNoInputCouldCarryReturnsRatherThanAborting() throws {
        let ones = [UInt8](repeating: 0xff, count: 8)
        let inputs: [[UInt8]] = [
            // Byte and text strings claiming 2^64-1 bytes of payload.
            [0x5b] + ones,
            [0x7b] + ones,
            // Arrays and maps claiming 2^64-1 members.
            [0x9b] + ones,
            [0xbb] + ones,
            // The same claim from inside an indefinite-length string's chunk.
            [0x5f, 0x5b] + ones,
            [0x7f, 0x7b] + ones,
        ]
        for input in inputs {
            #expect(decodeFailure(input) != nil, "accepted a length no input could carry: \(input)")
        }

        // A length the input does carry is still read in one pass.
        var long: [UInt8] = [0x5a, 0x00, 0x02, 0x00, 0x00]
        long.append(contentsOf: [UInt8](repeating: 0xaa, count: 128 * 1024))
        #expect(try decodeCBOR(long) == .bytes([UInt8](repeating: 0xaa, count: 128 * 1024)))
    }

    /// Reading the chunks of an indefinite-length string iterates over them,
    /// so the count of them is bounded by the input rather than by the stack.
    @Test func aDocumentOfIndefiniteLengthStringHeadersReturnsOnASmallStack() {
        for header: UInt8 in [0x5f, 0x7f] {
            let bytes = [UInt8](repeating: header, count: 200_000)
            #expect(decodeFailure(bytes) != nil, "accepted \(header) repeated 200,000 times")
        }
    }

    @Test func decodeCborSequenceAcceptsWholeItems() throws {
        #expect(try decodeCBORSequence([]) == .array([]))
        #expect(try decodeCBORSequence([0x01, 0x81, 0x02]) == .array([.integer(1), .array([.integer(2)])]))
        // An indefinite-length item ends the moment its break is read, so the
        // item after it starts a new element rather than joining it.
        #expect(
            try decodeCBORSequence([0x9f, 0x01, 0xff, 0x02])
                == .array([.array([.integer(1)], indefinite: true), .integer(2)])
        )
    }

    // MARK: - Nesting bounds

    /// A document nested past the supported depth is answered with the limit
    /// it passed; what is within the bound decodes as it always did.
    @Test func decodeDataNestedPastTheSupportedDepthReportsTheLimit() {
        var within = [UInt8](repeating: 0x81, count: maxDecodeNestingDepth - 1)
        within.append(0x01)
        var past = [UInt8](repeating: 0x81, count: maxDecodeNestingDepth + 1)
        past.append(0x01)

        #expect(decodeFailure(within) == nil)

        let reason = decodeReason(past)
        #expect(reason.contains("maximum supported decoding depth"), "got:\n\(reason)")
    }

    /// Copying, comparing and freeing a value all walk it without recursing,
    /// so a value nested far past what a small stack holds is copied, compared
    /// and freed.
    @Test func aDeeplyNestedValueIsCopiedComparedAndFreedOnASmallStack() {
        var deep: CBORNode? = nestedArrays(100_000)
        var copy: CBORNode? = deep
        #expect(copy.map(nestingOf) == 100_000)
        #expect(copy == deep)

        var other: CBORNode? = .array([.tagged(1, nestedArrays(99_999))])
        #expect(copy != other, "a different item deep inside is told apart")
        #expect(nestedArrays(100_000) != nestedArrays(99_999))

        copy = nil
        deep = nil
        other = nil
        #expect(copy == nil && deep == nil && other == nil)
    }

    /// Decoding keeps its open containers on the heap, so a document nested to
    /// the bound decodes, and one past it is refused.
    @Test func aDocumentNestedToTheDecodingBoundDecodesOnASmallStack() throws {
        var atTheBound = [UInt8](repeating: 0x81, count: maxDecodeNestingDepth)
        atTheBound.append(0x01)
        let value = try decodeCBOR(atTheBound)
        #expect(nestingOf(value) == maxDecodeNestingDepth)

        var past = [UInt8](repeating: 0x81, count: maxDecodeNestingDepth + 1)
        past.append(0x01)
        #expect(decodeFailure(past) == .nestedTooDeeply)
    }

    /// Rendering a value is cut off at a depth: what lies below is elided
    /// rather than walked.
    @Test func renderingADeepValueIsBoundedInDepth() {
        let deep = nestedArrays(100_000)
        let rendered = deep.displayRendering
        #expect(rendered == String(repeating: "[", count: 8) + "[...]" + String(repeating: "]", count: 8))
        let debugged = deep.debugRendering
        #expect(debugged.contains("Array(...)"), "\(debugged)")
        #expect(debugged.utf8.count < 512, "\(debugged.utf8.count)")

        // Within the depth a value renders in full.
        #expect(nestedArrays(3).displayRendering == "[[[Integer(1)]]]")
    }

    /// The answer is the same whichever way the data nests, and a document
    /// nested far past the bound is still answered.
    @Test func decodeDataNestedFarPastTheSupportedDepthReturnsOnASmallStack() {
        // An array, a map key, a map value and a tag each nest one level.
        let leads: [[UInt8]] = [[0x81], [0xa1], [0xa1, 0x01], [0xc1]]
        for lead in leads {
            var bytes: [UInt8] = []
            bytes.reserveCapacity(lead.count * 100_000 + 1)
            for _ in 0..<100_000 {
                bytes.append(contentsOf: lead)
            }
            bytes.append(0x01)

            let reason = decodeReason(bytes)
            #expect(reason.contains("maximum supported decoding depth"), "got:\n\(reason)")
        }
    }

    // MARK: - Encoding details the node keeps

    /// The width a float was encoded in and whether a string or container was
    /// encoded with an indefinite length are part of the decoded node, and
    /// encoding the node writes them back as they were.
    @Test func indefiniteLengthAndFloatWidthSurviveDecodingAndEncoding() throws {
        let cases: [(String, CBORNode)] = [
            ("f93c00", .float(1.0, width: .half)),
            ("fa3f800000", .float(1.0, width: .single)),
            ("fb3ff0000000000000", .float(1.0, width: .double)),
            ("f97e00", .float(.nan, width: .half)),
            ("9f0102ff", .array([.integer(1), .integer(2)], indefinite: true)),
            ("9fff", .array([], indefinite: true)),
            ("bf616101ff", .map([(key: .text("a"), value: .integer(1))], indefinite: true)),
            ("5f420102ff", .byteString([1, 2], indefinite: true)),
            ("7f626162ff", .textString("ab", indefinite: true)),
            ("5fff", .byteString([], indefinite: true)),
            ("7fff", .textString("", indefinite: true)),
            ("830102f93c00", .array([.integer(1), .integer(2), .float(1.0, width: .half)])),
            ("d82a9ff93c00ff", .tagged(42, .array([.float(1.0, width: .half)], indefinite: true))),
            ("f7", .undefined),
        ]
        for (hex, expected) in cases {
            let bytes = hexBytes(hex)
            let node = try decodeCBOR(bytes)
            #expect(node == expected, "decoding \(hex)")
            #expect(hexString(node.encoded()) == hex, "encoding \(hex)")
            #expect(try decodeCBOR(node.encoded()) == node, "round trip of \(hex)")
        }

        // A string of several chunks is re-encoded as one chunk, and decodes
        // back to the same node.
        let chunked = try decodeCBOR(hexBytes("5f41014202 03ff"))
        #expect(chunked == .byteString([1, 2, 3], indefinite: true))
        #expect(try decodeCBOR(chunked.encoded()) == chunked)

        // The width and the length encoding take part in equality.
        #expect(CBORNode.float(1.0, width: .half) != .float(1.0, width: .double))
        #expect(CBORNode.float(1.0, width: .half) != .float(1.0, width: .single))
        #expect(CBORNode.array([.integer(1)], indefinite: true) != .array([.integer(1)]))
        #expect(CBORNode.map([], indefinite: true) != .map([]))
        #expect(CBORNode.byteString([1], indefinite: true) != .bytes([1]))
        #expect(CBORNode.textString("a", indefinite: true) != .text("a"))
        #expect(CBORNode.undefined != .null)
    }

    /// Integers span -2^64 to 2^64-1 in major types 0 and 1, and bignums
    /// (tags 2 and 3) carry any magnitude (RFC 8949 Section 3.4.3).
    @Test func integersCoverTheWholeRangeAndBignums() throws {
        let largest = try decodeCBOR(hexBytes("1bffffffffffffffff"))
        #expect(largest.bigIntegerValue == BigInt("18446744073709551615"))
        #expect(largest.integerValue?.description == "18446744073709551615")

        let smallest = try decodeCBOR(hexBytes("3bffffffffffffffff"))
        #expect(smallest.bigIntegerValue == BigInt("-18446744073709551616"))
        #expect(smallest.integerValue?.description == "-18446744073709551616")
        #expect(smallest.integerValue! < CBORInteger(isNegative: true, argument: 0))

        // 2^64 as a bignum, and -2^64 - 1.
        let unsignedBignum = try decodeCBOR(hexBytes("c249010000000000000000"))
        #expect(unsignedBignum.bigIntegerValue == BigInt("18446744073709551616"))
        let negativeBignum = try decodeCBOR(hexBytes("c349010000000000000000"))
        #expect(negativeBignum.bigIntegerValue == BigInt("-18446744073709551617"))

        #expect(CBORNode.text("1").bigIntegerValue == nil)
        #expect(CBORNode.tagged(2, .text("1")).bigIntegerValue == nil)
    }
}
