import Foundation
import Testing

@testable import SwiftCDDL

/// What reading `text` gives, written the way the reader vectors write it: `OK`
/// and the value -- a number as `u`, `i` or `f` for how it is read, a float
/// with its exponent form and its JSON form, an array item by item, anything
/// else as compact JSON -- or `ERR` and the error.
private func readerOutcome(_ text: String) -> String {
    do {
        return "OK " + describeRead(try JSONNode.parse(text))
    } catch {
        return "ERR \(error)"
    }
}

private func describeRead(_ node: JSONNode) -> String {
    switch node {
    case .number(let n):
        switch n.value {
        case .unsigned(let v): return "u\(v)"
        case .negative(let v): return "i\(v)"
        case .float(let v): return "f\(exponentialDescription(v))|\(n)"
        }
    case .array(let array):
        return "[" + array.items.map(describeRead).joined(separator: ",") + "]"
    default:
        return node.fullRendering
    }
}

/// `levels` containers opened by `open` and closed by `close` around `leaf`.
private func nested(_ levels: Int, _ open: String, _ close: String, _ leaf: String) -> String {
    String(repeating: open, count: levels) + leaf + String(repeating: close, count: levels)
}

/// Reading JSON documents (RFC 8259): the grammar, numbers, strings, objects
/// with repeated names, nesting without a bound, and rendering.
@Suite struct JSONNodeTests {
    /// A vector of the reader: a document and what reading it gives.
    private struct ReaderVector: Decodable {
        var document: String
        var read: String
    }

    /// Every scalar form, every container form, every whitespace and the
    /// malformed documents nearest to each, and the edges of the number
    /// grammar: each reads to the value, or fails with the error, the vector
    /// states.
    @Test func readerVectorsAreReadAsStated() throws {
        let data = try Data(contentsOf: Fixtures.url("json/reader-vectors.json"))
        let vectors = try JSONDecoder().decode([ReaderVector].self, from: data)
        #expect(vectors.count == 603)
        for vector in vectors {
            #expect(readerOutcome(vector.document) == vector.read, "reading \(debugString(vector.document))")
        }
    }

    /// Integers are read as integers while they fit 64 bits, and as floats
    /// past that, and negative zero is a float.
    @Test func numbersAreReadByTheirWrittenForm() throws {
        func number(_ text: String) throws -> JSONNumber {
            guard case .number(let n) = try JSONNode.parse(text) else {
                throw JSONParsingError(message: "not a number", line: 0, column: 0)
            }
            return n
        }
        #expect(try number("18446744073709551615").value == .unsigned(.max))
        #expect(try number("-9223372036854775808").value == .negative(.min))
        #expect(try number("18446744073709551616").value == .float(18446744073709551616.0))
        #expect(try number("-9223372036854775809").value == .float(-9223372036854775808.0))
        #expect(try number("-0").value.isFloatNegativeZero)
        #expect(try number("100").isWrittenAsInteger)
        #expect(try !number("1e2").isWrittenAsInteger)
        #expect(try number("123456789012345678901234567890").exactInteger?.description == "123456789012345678901234567890")
        #expect(try number("1.5").exactInteger == nil)
        #expect(try number("1e2").text == "1e2")
        #expect(try number("1e2").description == "100.0")
        #expect(try number("1e16").description == "1e+16")
        #expect(try number("1e-7").description == "1e-7")
        #expect(throws: JSONParsingError.self) { try JSONNode.parse("1e400") }
    }

    /// An object keeps its members as written, a name given twice twice, and
    /// is read as the set of its names each holding the last value written,
    /// in the order of the names' bytes.
    @Test func objectsKeepTheirMembersAndAreReadByName() throws {
        guard case .object(let object) = try JSONNode.parse(#"{"b":1,"a":2,"a":3}"#) else {
            Issue.record("not an object")
            return
        }
        #expect(object.members.map(\.key) == ["b", "a", "a"])
        #expect(object.entries.map(\.key) == ["a", "b"])
        #expect(object.entries.first?.value == .integer(3))
        #expect(JSONNode.object(object).description == #"{"b":1,"a":2,"a":3}"#)
        #expect(JSONNode.object(object).fullRendering == #"{"a":3,"b":1}"#)
    }

    /// Names are compared by their scalars: a precomposed and a decomposed
    /// "é" are two names (RFC 8259 Section 8.3).
    @Test func canonicallyEquivalentNamesAreDistinct() throws {
        guard case .object(let object) = try JSONNode.parse("{\"\u{E9}\":1,\"e\u{301}\":2}") else {
            Issue.record("not an object")
            return
        }
        #expect(object.entries.count == 2)
        #expect(JSONNode.string("\u{E9}") != JSONNode.string("e\u{301}"))
        #expect(try JSONNode.parse("{\"\u{E9}\":1}") == .object([(key: "\u{E9}", value: .integer(1))]))
    }

    /// Documents nested past any stack are read in full, to the same value a
    /// document one level shallower has one level down.
    @Test func documentsPastTheRecursiveDepthAreReadInFull() throws {
        for (open, close, leaf) in [("[", "]", "5"), (#"{"k":"#, "}", #""x""#)] {
            var node = try JSONNode.parse(nested(10_000, open, close, leaf))
            var depth = 0
            while true {
                if case .array(let array) = node {
                    #expect(array.items.count == 1)
                    node = array.items[0]
                } else if case .object(let object) = node {
                    #expect(object.entries.count == 1)
                    node = object.entries[0].value
                } else {
                    break
                }
                depth += 1
            }
            #expect(depth == 10_000)
            #expect(node == (try JSONNode.parse(leaf)))
        }
    }

    /// The reader has no depth at which it changes, and a malformed deep
    /// document is refused with a position as a shallow one is.
    @Test func theBoundaryBetweenTheReadersIsSeamless() throws {
        let at = nested(127, "[", "]", "1")
        let past = nested(128, "[", "]", "1")
        #expect(try JSONNode.parse(past) == .array([try JSONNode.parse(at)]))

        do {
            _ = try JSONNode.parse(String(repeating: "[", count: 128) + "1,")
            Issue.record("a malformed deep document was read")
        } catch {
            #expect("\(error)".contains("line 1 column"), "\(error)")
        }
    }

    /// A value nested far past what a small stack holds is read, compared,
    /// rendered and freed on it.
    @Test func aDeepValueIsFreedOnASmallStack() async {
        let deep = nested(100_000, "[", "]", "1")
        let finished: Bool = await withCheckedContinuation { continuation in
            let thread = Thread {
                var ok = false
                if var value = try? JSONNode.parse(deep) {
                    let copy = value
                    ok = copy == value && value.description.utf8.count == deep.utf8.count
                    value = .null
                    _ = value
                }
                continuation.resume(returning: ok)
            }
            thread.stackSize = 64 * 1024
            thread.start()
        }
        #expect(finished)
    }

    /// A string is written back escaped as RFC 8259 Section 7 requires.
    @Test func stringsAreRenderedEscaped() throws {
        let node = try JSONNode.parse(#""a\"b\\c\n\t\u0001\u007fé""#)
        #expect(node.description == "\"a\\\"b\\\\c\\n\\t\\u0001\u{7f}\u{e9}\"")
    }

    /// Bytes that are not UTF-8 are no document.
    @Test func bytesThatAreNotUTF8AreRefused() {
        #expect(throws: JSONParsingError.self) { try JSONNode.parse(bytes: [0x22, 0xff, 0x22]) }
        #expect((try? JSONNode.parse(bytes: Array(#"{"a":[1]}"#.utf8))) != nil)
    }
}

extension JSONNumber.Value {
    fileprivate var isFloatNegativeZero: Bool {
        if case .float(let v) = self { return v == 0 && v.sign == .minus }
        return false
    }
}
