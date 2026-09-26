import Foundation
import Testing

@testable import SwiftCDDL

/// A float in the shortest width that holds it exactly, as preferred
/// serialization encodes it (RFC 8949 Section 4.1).
private func shortestFloat(_ value: Double) -> CBORNode {
    if doubleToHalf(value) != nil {
        return .float(value, width: .half)
    }
    if Double(Float(value)) == value {
        return .float(value, width: .single)
    }
    return .float(value)
}

/// Validates the encoding of `node`, expecting a match.
private func expectValidNode(
    _ cddl: String,
    _ node: CBORNode,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await cborResult(cddl, node.encoded(), sourceLocation: sourceLocation)
    #expect(
        verdict == nil, "\(comment.map { "\($0): " } ?? "")expected a match, got \(verdict.map { "\($0)" } ?? "")",
        sourceLocation: sourceLocation)
}

/// Validates the encoding of `node`, expecting a mismatch.
private func expectInvalidNode(
    _ cddl: String,
    _ node: CBORNode,
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await cborResult(cddl, node.encoded(), sourceLocation: sourceLocation)
    #expect(verdict != nil, comment ?? "expected a mismatch", sourceLocation: sourceLocation)
}

/// The rendered failure of validating the encoding of `node`, expected to be
/// a failure; empty when the document matched.
private func failureText(
    _ cddl: String,
    _ node: CBORNode,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> String {
    guard let error = await expectInvalid(cddl, node.encoded(), sourceLocation: sourceLocation) else { return "" }
    return error.description
}

/// A map with text keys, in order.
private func textMap(_ entries: [(String, CBORNode)]) -> CBORNode {
    .map(entries.map { (key: CBORNode.text($0.0), value: $0.1) })
}

/// The failure of validating the encoding of `node` against `cddl`, or `nil`
/// on a match, without the comparison with the reference oracle: the schemas
/// this is used for need ABNF matching (RFC 9165 Section 3), which this
/// implementation reports as unsupported.
private func abnfVerdict(_ cddl: String, _ node: CBORNode) async -> CBORValidationError? {
    do {
        try await validateCBOR(cddl: cddl, cbor: node.encoded())
        return nil
    } catch {
        return error
    }
}

/// Expects matching `node` against an ABNF grammar to be reported as an
/// unsupported feature, where a matching verdict (either way) was asked for.
private func expectUnsupportedAbnf(
    _ cddl: String,
    _ node: CBORNode,
    _ comment: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await abnfVerdict(cddl, node)
    guard case .unsupported = verdict else {
        Issue.record(
            "\(comment): expected an unsupported feature, got \(verdict.map { "\($0)" } ?? "a match")",
            sourceLocation: sourceLocation)
        return
    }
}

/// Expects a controller that denotes no ABNF grammar to be reported as a
/// fault in the schema whose text contains `fragment`, or as the unsupported
/// feature it is here.
private func expectFaultyAbnfController(
    _ cddl: String,
    _ node: CBORNode,
    containing fragment: String? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await abnfVerdict(cddl, node)
    switch verdict {
    case .unsupported:
        break
    case .invalidSchema(let issue):
        if let fragment {
            #expect(issue.reason.contains(fragment), "got: \(issue.reason)", sourceLocation: sourceLocation)
        }
    default:
        Issue.record(
            "\(cddl) denotes no grammar and is a fault in the schema, got \(verdict.map { "\($0)" } ?? "a match")",
            sourceLocation: sourceLocation)
    }
}

/// Validation of the `.abnf`/`.abnfb` (RFC 9165 Section 3), arithmetic and
/// concatenation (RFC 9165 Section 2) and comparison (RFC 8610 Section 3.8.6)
/// control operators, `.default`, and literals in every notation (RFC 8610
/// Section 3.1).
@Suite
struct CBORValidationControlTests {
    /// The `.abnf` family takes a grammar naming the rule to start from on its
    /// first line and holding the rulelist below it; a controller in any other
    /// form denotes no grammar, so nothing validates against it.
    @Test func validateAbnfControllerWithoutARulelist() async {
        let rulelistOnly = hexString(Array("oct = %x61-63".utf8))

        for cddl in [
            "start = bstr .abnfb h'\(rulelistOnly)'",
            "start = bstr .abnfb 'oct = %x61-63'",
            "start = bstr .abnfb ''",
        ] {
            for content: [UInt8] in [[0x61], [0x7a]] {
                await expectFaultyAbnfController(cddl, .bytes(content))
            }
        }

        let cddl = #"start = tstr .abnf "oct = %x61-63""#
        for text in ["a", "z"] {
            await expectFaultyAbnfController(cddl, .text(text))
        }
    }

    /// RFC 9165 Section 3: the controller of the `.abnf` family is a string,
    /// and a byte string controller denotes the grammar of the text string
    /// with the same bytes. Matching is unsupported here, so every document is
    /// reported as needing it.
    @Test func validateAbnfGrammarCarriedInAByteStringController() async {
        let base16 = hexString(Array("oct\noct = %x61-63\n".utf8))

        for cddl in [
            #"start = tstr .abnf "oct\noct = %x61-63\n""#,
            "start = tstr .abnf 'oct\noct = %x61-63\n'",
            "start = tstr .abnf h'\(base16)'",
        ] {
            await expectUnsupportedAbnf(cddl, .text("a"), "\(cddl) must accept a character the grammar admits")

            await expectUnsupportedAbnf(
                cddl, .text("z"), "\(cddl) must reject a character the grammar does not admit")
        }

        // A byte string controller that is not valid UTF-8 denotes no grammar.
        await expectFaultyAbnfController(
            "start = tstr .abnf h'ff'", .text("a"), containing: "invalid abnf controller")
    }

    /// A controller denoting no grammar is a fault in the schema; a document
    /// not matching a grammar the controller does denote is the answer asked
    /// for.
    @Test func validateAbnfSeparatesAFaultyControllerFromAMismatchingDocument() async {
        let text = CBORNode.text("a")
        let bytes = CBORNode.bytes([0x61])

        let faulty: [(String, CBORNode)] = [
            // A rulelist with no rule named on the first line.
            (#"start = tstr .abnf "oct = %x61-63""#, text),
            ("start = bstr .abnfb 'oct = %x61-63'", bytes),
            // A first line naming a rule the rulelist does not define.
            (#"start = tstr .abnf "missing\noct = %x61-63\n""#, text),
            ("start = bstr .abnfb 'missing\n      oct = %x61-63\n    '", bytes),
            // A rulelist that is not ABNF at all.
            (#"start = tstr .abnf "oct\n((((\n""#, text),
            ("start = bstr .abnfb 'oct\n      ((((\n    '", bytes),
            // A controller whose `.det` cannot be evaluated.
            (#"start = bstr .abnfb ("oct" .det nosuch)"#, bytes),
        ]
        for (cddl, node) in faulty {
            await expectFaultyAbnfController(cddl, node)
        }

        // A grammar that was built holds the document to itself.
        let built: [(String, CBORNode, CBORNode)] = [
            (#"start = tstr .abnf "oct\noct = %x61-63\n""#, .text("a"), .text("z")),
            ("start = bstr .abnfb 'oct\n        oct = %x61-63\n      '", .bytes([0x61]), .bytes([0x7a])),
        ]
        for (cddl, matching, mismatching) in built {
            await expectUnsupportedAbnf(cddl, matching, "\(cddl) admits the target")

            await expectUnsupportedAbnf(cddl, mismatching, "\(cddl) must report the target as the fault")
        }
    }

    /// The rule a grammar starts from has to be one its rulelist defines, and
    /// it has to account for the whole target.
    @Test func validateAbnfGrammarAgainstTheWholeTarget() async {
        var cddl = "start = bstr .abnfb 'oct\n      oct = %x61-63\n    '"

        await expectUnsupportedAbnf(cddl, .bytes([0x61]), "the grammar admits a single byte in range")

        await expectUnsupportedAbnf(cddl, .bytes([0x61, 0x61]), "the grammar admits one byte, not two")

        cddl = #"start = tstr .abnf "oct\noct = %x61-63\n""#
        await expectUnsupportedAbnf(cddl, .text("a"), "the grammar admits a single character in range")

        await expectUnsupportedAbnf(cddl, .text("ab"), "the grammar admits one character, not two")

        cddl = "start = bstr .abnfb 'missing\n      oct = %x61-63\n    '"
        await expectFaultyAbnfController(cddl, .bytes([0x61]), containing: "missing")
    }

    /// `.default` supplies the value an absent optional entry is assumed to
    /// have; a present entry still has to match the target, whatever the
    /// shape of the literal.
    @Test func validateLiteralDefaultValue() async {
        let cases: [(String, CBORNode, CBORNode)] = [
            (#"start = { ? k: "a" .default "b" }"#, .text("a"), .text("c")),
            ("start = { ? k: 1 .default 2 }", .integer(1), .integer(9)),
            ("start = { ? k: 1.5 .default 2.5 }", shortestFloat(1.5), shortestFloat(9.5)),
            ("start = { ? k: h'0102' .default h'0304' }", .bytes([0x01, 0x02]), .bytes([0x09, 0x09])),
        ]
        for (cddl, matching, other) in cases {
            let present = textMap([("k", matching)])
            await expectValidNode(cddl, present, "\(cddl) admits the value of its target")

            await expectValidNode(cddl, .map([]), "\(cddl) admits an absent entry")

            let otherMap = textMap([("k", other)])
            await expectInvalidNode(cddl, otherMap, "\(cddl) must reject a present value its target does not admit")

            let required = cddl.replacingOccurrences(of: "? k:", with: "k:")
            await expectValidNode(required, present, "\(required) admits the value of its target")
            await expectInvalidNode(
                required, otherMap, "\(required) must reject a present value its target does not admit")
        }
    }

    /// The target of `.eq` constrains the data item in its own right: a name
    /// that is not a primitive type names a type the data item is held to
    /// before the controller's value is matched.
    @Test func validateEqAgainstANamedTarget() async {
        await expectInvalidNode(
            "start = mytype .eq h'0102'\nmytype = [int]", .bytes([0x01, 0x02]), "a byte string is not an array of int")

        await expectInvalidNode(
            "start = mystr .eq \"aa\"\nmystr = \"bb\"", .text("aa"), "\"aa\" is not the value the target names")

        let cddl = "start = mytype .eq [1]\nmytype = [int]"
        await expectValidNode(cddl, .array([.integer(1)]), "[1] is an array of int equal to the controller")

        await expectInvalidNode(cddl, .array([.integer(2)]), "[2] does not equal the controller")
    }

    /// An operator evaluating its target and its controller as values holds
    /// when the data item matches both.
    @Test func validateUintTargetAgainstValueController() async {
        for cddl in ["start = uint .and 2", "start = uint .within 2", "start = int .and 2"] {
            await expectValidNode(cddl, .integer(2), "\(cddl) admits the value of its controller")

            await expectInvalidNode(cddl, .integer(3), "\(cddl) must reject a value its controller does not admit")
        }
    }

    /// A byte string data item renders in base16 wherever an error names it.
    @Test func validateByteStringErrorsRenderDataInBase16() async {
        for cddl in ["start = bstr .eq 2", "start = bstr .size 3"] {
            let message = await failureText(cddl, .bytes([0x61, 0x61]))
            #expect(
                message.contains("h'6161'") && !message.contains("[97, 97]"),
                "expected the data item rendered as base16, got: \(message)")
        }

        // Matching against a grammar is unsupported here.
        await expectUnsupportedAbnf(
            "start = bstr .abnfb 'oct\n        oct = %x61-63\n      '", .bytes([0x61, 0x61]),
            "the data item does not match")

        let message = await failureText("start = bstr .bits h'02'", .bytes([0xff]))
        #expect(
            message.contains("h'ff'") && !message.contains("[255]"),
            "expected the data item rendered as base16, got: \(message)")
    }

    /// RFC 8610 Section 3.1: a byte string literal can be written in base64
    /// as well as base16 and unprefixed; two literals denoting the same bytes
    /// match the same data.
    @Test func validateBase64ByteStringLiteral() async {
        let cases: [(String, [UInt8])] = [
            ("start = b64'AQID'", [0x01, 0x02, 0x03]),
            // Padded and unpadded write the same content.
            ("start = b64'AQI='", [0x01, 0x02]),
            ("start = b64'AQI'", [0x01, 0x02]),
            // The standard alphabet alongside the URL-safe one.
            ("start = b64'AQL_'", [0x01, 0x02, 0xff]),
            ("start = b64'AQL/'", [0x01, 0x02, 0xff]),
            ("start = b64''", []),
            // Whitespace inside a literal is not content.
            ("start = b64'AQ ID'", [0x01, 0x02, 0x03]),
        ]
        for (cddl, content) in cases {
            await expectValidNode(cddl, .bytes(content), "\(cddl) must match the bytes it denotes")

            await expectInvalidNode(cddl, .bytes([0x07, 0x08, 0x09]), "\(cddl) must not match other bytes")
        }

        // A literal that is not valid base64 denotes no byte string, and the
        // two alphabets are not mixed within one literal.
        for cddl in ["start = b64'A'", "start = b64'AQ='", "start = b64'++__'", "start = b64'!!!!'"] {
            await expectInvalidNode(cddl, .bytes([0x01]), "\(cddl) must not parse")
        }
    }

    /// Literals written in different notations for the same bytes are the
    /// same value to every operator taking one.
    @Test func base64ByteStringLiteralEqualsTheOtherNotations() async {
        let node = CBORNode.bytes([0x31, 0x32, 0x33])

        for cddl in [
            "start = bstr .eq b64'MTIz'",
            "start = b64'MTIz' / h'000000'",
            "start = b64'MTI' .cat h'33'",
            "start = h'3132' .cat b64'Mw'",
        ] {
            await expectValidNode(cddl, node, "\(cddl)")
        }

        for cddl in ["start = bstr .ne b64'MTIz'", "start = b64'MTI0'", "start = b64'MTI' .cat h'34'"] {
            await expectInvalidNode(cddl, node, "\(cddl) must not match")
        }
    }

    /// A comparison against a controller naming more than one value holds when
    /// it holds against every one of them, which for a range is the member at
    /// the end the operator points at.
    @Test func validateComparisonAgainstRangeController() async {
        let holding: [(String, Int64)] = [
            ("start = int .gt (0..10)", 11),
            ("start = int .ge (0..10)", 10),
            ("start = int .lt (0..10)", -1),
            ("start = int .le (0..10)", 0),
            // The exclusive range 0...10 holds 0 through 9.
            ("start = int .gt (0...10)", 10),
            ("start = int .ge (0...10)", 9),
        ]
        for (cddl, value) in holding {
            await expectValidNode(cddl, .integer(value), "\(cddl) against \(value)")
        }

        // A value drawn from the range is not above or below every member.
        let failing: [(String, Int64)] = [
            ("start = int .gt (0..10)", 5),
            ("start = int .gt (0..10)", 10),
            ("start = int .ge (0..10)", 5),
            ("start = int .lt (0..10)", 5),
            ("start = int .lt (0..10)", 0),
            ("start = int .le (0..10)", 5),
            ("start = int .gt (0...10)", 9),
            ("start = int .ge (0...10)", 8),
        ]
        for (cddl, value) in failing {
            await expectInvalidNode(cddl, .integer(value), "\(cddl) must reject \(value)")
        }
    }

    /// A controller written as a name resolves to the type it names.
    @Test func validateComparisonAgainstNamedRangeController() async {
        let cddl = """
            start = int .gt bound
            bound = 0..10

            """

        await expectValidNode(cddl, .integer(50))

        await expectInvalidNode(cddl, .integer(5))
    }

    /// A float literal member key names a float key, and an integer key of
    /// equal value is a different key.
    @Test func floatMemberKeyIsNamedInFloatNotation() async {
        let cddl = "start = { 1.0 => int }"

        await expectValidNode(cddl, .map([(key: shortestFloat(1.0), value: .integer(1))]))

        // The path names the key it descended through.
        var message = await failureText(cddl, .map([(key: shortestFloat(1.0), value: .text("x"))]))
        #expect(message.contains("/1.0"), "got: \(message)")

        // An integer key does not answer for a float member key, and the
        // message does not name the integer key as the missing one.
        message = await failureText(cddl, .map([(key: .integer(1), value: .integer(1))]))
        #expect(message.contains("map missing key: 1.0"), "got: \(message)")
    }

    /// A float literal names a float wherever a message echoes it.
    @Test func floatLiteralsAreNamedInFloatNotationInMessages() async {
        let cases: [(String, CBORNode, String)] = [
            ("start = 2.0", shortestFloat(3.0), "expected value 2.0"),
            ("start = 2.0", .integer(2), "expected 2.0"),
            ("start = float .lt 2.0", shortestFloat(3.0), "expected value .lt 2.0"),
            ("start = 1.0..2.0", shortestFloat(3.0), "1.0 <= value <= 2.0"),
            // A sum of two float literals can reach an infinity, which a
            // message spells out.
            ("start = 1e308 .plus 1e308", shortestFloat(1.0), "expected computed .plus value Infinity"),
        ]
        for (cddl, document, expected) in cases {
            let message = await failureText(cddl, document)
            #expect(message.contains(expected), "\(cddl) should report \(expected), got: \(message)")
        }
    }

    /// A formatted schema answers every document the way its source did.
    @Test func formattingASchemaWithFloatLiteralsPreservesItsVerdicts() async throws {
        let floatKeyed = CBORNode.map([(key: shortestFloat(1.0), value: .integer(1))])
        let integerKeyed = CBORNode.map([(key: .integer(1), value: .integer(1))])

        let cases: [(String, CBORNode, Bool)] = [
            ("start = 2.0", shortestFloat(2.0), true),
            ("start = 2.0", .integer(2), false),
            ("start = 1.0..2.0", shortestFloat(1.5), true),
            ("start = 1.0..2.0", .integer(1), false),
            ("start = float .eq 3.0", shortestFloat(3.0), true),
            ("start = { 1.0 => int }", floatKeyed, true),
            ("start = { 1.0 => int }", integerKeyed, false),
        ]
        for (cddl, document, expected) in cases {
            let before = await cborResult(cddl, document.encoded())
            #expect((before == nil) == expected, "\(cddl) answered unexpectedly before formatting")

            let formatted = format(try cddlFromStr(cddl))
            let after = await cborResult(formatted, document.encoded())
            #expect(
                (after == nil) == expected, "\(cddl) answers differently once formatted to \(formatted)")
        }
    }

    /// An RFC 9165 arithmetic control applies to the value its target
    /// denotes, and a target naming a type rule denotes that rule's value, in
    /// every position a type can occupy.
    @Test func validateArithmeticControlResolvesARuleNameTarget() async {
        let cases: [(String, String, CBORNode, CBORNode)] = [
            ("top level", "start = a .plus 2\na = 1", .integer(3), .integer(1)),
            ("array entry", "start = [a .plus 2]\na = 1", .array([.integer(3)]), .array([.integer(1)])),
            (
                "repeated array entry", "start = [+ a .plus 2]\na = 1", .array([.integer(3), .integer(3)]),
                .array([.integer(3), .integer(1)])
            ),
            ("map value", "start = { k: a .plus 2 }\na = 1", textMap([("k", .integer(3))]), textMap([("k", .integer(1))])),
            (
                "member key", "start = { (a .plus 2) => int }\na = 1", .map([(key: .integer(3), value: .integer(9))]),
                .map([(key: .integer(1), value: .integer(9))])
            ),
            ("chained rule names", "start = b .plus 2\nb = a\na = 1", .integer(3), .integer(1)),
            ("generic parameter", "start = g<a>\ng<t> = t .plus 2\na = 1", .integer(3), .integer(1)),
            // A choice of the named rule leading back to it stands for no
            // value, and the choices beside it stand for what they do.
            ("self-referential type choice", "start = 1 .plus a\na = 2 / a", .integer(3), .integer(4)),
        ]
        for (position, cddl, admitted, rejected) in cases {
            await expectValidNode(cddl, admitted, "\(position): the computed .plus value must be admitted")
            await expectInvalidNode(
                cddl, rejected, "\(position): the target's own value must not stand in for the computed one")
        }
    }

    /// `.cat` and `.det` resolve a rule name in target position the way
    /// `.plus` does, in every position a control can occupy.
    @Test func validateConcatenationControlResolvesARuleNameTarget() async {
        let cases: [(String, String, CBORNode, CBORNode)] = [
            ("top level .cat", "start = s .cat \"b\"\ns = \"a\"", .text("ab"), .text("a")),
            ("top level .det", "start = s .det \"b\"\ns = \"a\"", .text("ab"), .text("a")),
            ("array entry .cat", "start = [s .cat \"b\"]\ns = \"a\"", .array([.text("ab")]), .array([.text("a")])),
            (
                "map value .cat", "start = { k: s .cat \"b\" }\ns = \"a\"", textMap([("k", .text("ab"))]),
                textMap([("k", .text("a"))])
            ),
            (
                "member key .cat", "start = { (s .cat \"b\") => int }\ns = \"a\"", textMap([("ab", .integer(9))]),
                textMap([("a", .integer(9))])
            ),
            (
                "member key .det", "start = { (s .det \"b\") => int }\ns = \"a\"", textMap([("ab", .integer(9))]),
                textMap([("a", .integer(9))])
            ),
            ("chained rule names .cat", "start = t .cat \"b\"\nt = s\ns = \"a\"", .text("ab"), .text("a")),
            ("generic parameter .cat", "start = g<s>\ng<t> = t .cat \"b\"\ns = \"a\"", .text("ab"), .text("a")),
            ("byte string target .cat", "start = s .cat h'62'\ns = h'61'", .bytes([0x61, 0x62]), .bytes([0x61])),
            // A choice of the named rule leading back to it stands for no
            // value, and the choices beside it stand for what they do.
            ("self-referential type choice .cat", "start = \"p\" .cat a\na = \"x\" / a", .text("px"), .text("p")),
        ]
        for (position, cddl, admitted, rejected) in cases {
            await expectValidNode(cddl, admitted, "\(position): the computed concatenation must be admitted")
            await expectInvalidNode(
                cddl, rejected, "\(position): the target's own value must not stand in for the concatenation")
        }
    }

    /// A name given as an operand of an arithmetic control has to denote a
    /// value of the kind the control takes; one denoting none is a defect in
    /// the schema.
    @Test func validateArithmeticControlReportsANameDenotingNoValue() async {
        let cases: [(String, CBORNode, String)] = [
            ("start = a .plus 2\na = \"x\"", .text("x"), "type rule a is not a numeric value"),
            // A name resolving through something other than itself is reported
            // for what that is, not for the choice leading back to it.
            ("start = a .plus 1\na = \"x\" / a", .integer(1), "type rule a is not a numeric value"),
            ("start = nope .plus 2", .integer(1), "no type rule named nope is defined"),
            ("start = 1 .plus nope", .integer(1), "no type rule named nope is defined"),
            ("start = a .plus 1\na = start", .integer(1), "defined in terms of itself"),
            ("start = a .plus 1\na = b .plus 1\nb = a .plus 1", .integer(1), "defined in terms of itself"),
            ("start = a .cat \"b\"\na = 1", .text("1b"), "type rule a is not a string literal"),
            ("start = nope .cat \"b\"", .text("b"), "no type rule named nope is defined"),
            ("start = nope .det \"b\"", .text("b"), "no type rule named nope is defined"),
            ("start = a .cat \"b\"\na = start", .text("b"), "defined in terms of itself"),
        ]
        for (cddl, document, expected) in cases {
            let message = await failureText(cddl, document)
            #expect(
                message.contains(expected), "for \(cddl) expected an error naming \(expected), got:\n\(message)")
        }
    }

    /// A sum no integer can hold stands for no value, also through a rule
    /// name.
    @Test func validatePlusReportsAnOutOfRangeSumThroughARuleName() async {
        for cddl in [
            "start = 18446744073709551615 .plus 18446744073709551615",
            "start = a .plus 18446744073709551615\na = 18446744073709551615",
            "start = a .plus b\na = 18446744073709551615\nb = 18446744073709551615",
        ] {
            let message = await failureText(cddl, .integer(1))
            #expect(message.contains("outside the range"), "for \(cddl) expected an out-of-range sum, got:\n\(message)")
        }
    }

    /// A parenthesized target denotes the value inside it, and `.cat`
    /// concatenates onto that value.
    @Test func validateConcatenationControlAcceptsAParenthesizedTarget() async {
        let cddl = #"start = ("a") .cat "b""#
        await expectValidNode(cddl, .text("ab"), "a parenthesized target denotes the literal inside it")
        await expectInvalidNode(cddl, .text("a"), "the target's own value must not stand in for the concatenation")
    }

    /// `.plus` adds its operands whatever numeric notation each is written in.
    @Test func validatePlusAddsAnUnsignedControllerToAFloatTarget() async {
        for cddl in ["start = 1.5 .plus 2", "start = a .plus 2\na = 1.5"] {
            await expectValidNode(cddl, shortestFloat(3.5), "\(cddl) must admit the sum 3.5")
            await expectInvalidNode(
                cddl, shortestFloat(1.5), "\(cddl): the target's own value must not stand in for the sum")
        }
    }

    /// A controller written as a computation stands for the value it
    /// computes, and that value is what the control constrains its target by.
    @Test func validateControlHoldsAgainstAComputedController() async {
        let integers: [(String, Int64, Int64)] = [
            ("start = int .lt (5 .plus 1)", 5, 6),
            ("start = int .le (5 .plus 1)", 6, 7),
            ("start = int .gt (5 .plus 1)", 7, 6),
            ("start = int .ge (5 .plus 1)", 6, 5),
            ("start = int .lt (b .plus 1)\nb = 5", 5, 6),
            ("start = int .ne (5 .plus 1)", 5, 6),
            ("start = int .eq (5 .plus 1)", 6, 5),
        ]
        for (cddl, admitted, rejected) in integers {
            await expectValidNode(cddl, .integer(admitted), "\(cddl) must admit \(admitted)")
            await expectInvalidNode(
                cddl, .integer(rejected), "\(cddl): the computed value is the bound, not the value to match")
        }

        let texts: [(String, String, String)] = [
            ("start = tstr .size (1 .plus 1)", "ab", "abc"),
            ("start = tstr .regexp (\"^a\" .cat \"b$\")", "ab", "zz"),
        ]
        for (cddl, admitted, rejected) in texts {
            await expectValidNode(cddl, .text(admitted), "\(cddl) must admit \(admitted)")
            await expectInvalidNode(
                cddl, .text(rejected), "\(cddl): the computed value states the constraint, not the value to match")
        }
    }

    /// The interval RFC 9165 gives `.plus`: a generic group whose upper bound
    /// is computed from its argument, each entry describing the item at its
    /// own position.
    @Test func validateIntervalWithAComputedUpperBound() async {
        for cddl in [
            "start = [interval<10>]\ninterval<BASE> = (int .ge BASE, int .lt (BASE .plus 100))",
            "start = interval<10>\ninterval<BASE> = (int .ge BASE, int .lt (BASE .plus 100))",
            "start = [int .ge 10, int .lt (10 .plus 100)]",
        ] {
            func document(_ lower: Int64, _ upper: Int64) -> CBORNode {
                .array([.integer(lower), .integer(upper)])
            }

            await expectValidNode(cddl, document(10, 109), "\(cddl) must admit [10, 109]")
            await expectInvalidNode(cddl, document(10, 110), "\(cddl): 110 is not below the computed bound")
            await expectInvalidNode(cddl, document(9, 109), "\(cddl): 9 is below the lower bound")
        }
    }

    /// A control operator in member key position holds against each key of
    /// the map; a key it does not admit is not one the entry answers for.
    @Test func validateControlInMemberKeyPositionHoldsAgainstEachKey() async {
        let cases: [(String, String, String, String)] = [
            ("direct target", "start = { tstr .size 2 => int }", "ab", "abc"),
            ("named target", "start = { k .size 2 => int }\nk = tstr", "ab", "abc"),
            ("parenthesized", "start = { (tstr .size 2) => int }", "ab", "abc"),
            ("regexp", "start = { tstr .regexp \"^a+$\" => int }", "aa", "zz"),
            ("equality", "start = { tstr .eq \"ab\" => int }", "ab", "b"),
            ("exclusion", "start = { tstr .ne \"ab\" => int }", "b", "ab"),
            ("computed key", "start = { (\"a\" .cat \"b\") => int }", "ab", "a"),
        ]
        for (position, cddl, admitted, rejected) in cases {
            await expectValidNode(
                cddl, textMap([(admitted, .integer(1))]), "\(position): a key the control admits must be answered for")
            await expectInvalidNode(
                cddl, textMap([(rejected, .integer(1))]),
                "\(position): a key the control does not admit must not be answered for")
        }
    }

    /// An occurrence indicator covering more than one entry lets a member key
    /// answer for every key left, each held to the control.
    @Test func validateControlInMemberKeyPositionCoversARunOfEntries() async {
        let cddl = "start = { * (tstr .size 2) => int }"
        func document(_ keys: [String]) -> CBORNode {
            textMap(keys.map { ($0, CBORNode.integer(1)) })
        }

        for admitted in [[], ["ab"], ["ab", "cd"]] {
            await expectValidNode(cddl, document(admitted), "keys the control admits must be answered for: \(admitted)")
        }

        for rejected in [["abc"], ["ab", "x"]] {
            await expectInvalidNode(
                cddl, document(rejected), "a key the control does not admit must not be answered for: \(rejected)")
        }
    }

    /// A control whose controller denotes no value constrains nothing; in
    /// member key position that is a defect in the schema.
    @Test func validateControlInMemberKeyPositionReportsAControllerDenotingNoValue() async {
        for cddl in ["start = { (tstr .size nope) => int }", "start = { tstr .size nope => int }"] {
            let message = await failureText(cddl, textMap([("ab", .integer(1))]))
            #expect(
                message.contains("map requires entry with key"),
                "for \(cddl) expected the entry to answer for no key, got:\n\(message)")
        }
    }

    /// A rule defined in terms of itself names no data type, and every control
    /// dispatching on its target's type answers that from the schema.
    @Test func validateControlTargetNamingACyclicRuleIsReported() async {
        for cddl in [
            "start = a .size 3\na = start",
            "start = a .lt 3\na = start",
            "start = a .regexp \"x\"\na = start",
            "start = a .bits b\na = start\nb = 0",
        ] {
            await expectInvalidNode(cddl, .integer(1), "\(cddl): a cyclic target names no data type")
        }
    }
}
