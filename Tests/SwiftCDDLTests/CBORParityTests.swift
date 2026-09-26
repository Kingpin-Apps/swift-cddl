import Foundation
import Testing

@testable import SwiftCDDL

private typealias P = CBORParityFixture

/// The text conversion control operators of RFC 9741 Section 2.1, each paired
/// with a text string that is a well formed encoding under it.
private let textConversions: [(String, String)] = [
    (".b64u", "AQID"),
    (".b64c", "AQID"),
    (".b64u-sloppy", "AQID"),
    (".b64c-sloppy", "AQID"),
    (".hex", "010203"),
    (".hexlc", "010203"),
    (".hexuc", "010203"),
    (".b32", "AEBAG"),
    (".h32", "04106"),
    (".b45", "X5030"),
]

/// Levels of nesting the choice-isolation cases reach: deep enough that state
/// one alternative left behind would be read back by several later levels.
let cborParityNestedChoiceDepth = 64

/// A rejection the CBOR validator can reach is worded in one place, so a data
/// item refused on the same grounds reads the same wherever it is reported;
/// a type states the same thing wherever it stands (RFC 8610 Sections 2 and 3).
@Suite struct CBORParityTests {
    /// Several array items failing every alternative alike are reported in
    /// document order, the first of them at the head, on every run.
    @Test func itemsFailingAlikeAreReportedInDocumentOrderOnEveryRun() async {
        let cddl = "a = [* uint / bool]"
        let items = P.array(Array(repeating: P.text("a"), count: 5))
        // Every item fails both alternatives, so each is reported once per
        // alternative, item by item.
        let expected = (0..<5).flatMap { ["/\($0)", "/\($0)"] }

        for _ in 0..<20 {
            #expect(await P.locations(cddl, items) == expected)
        }
    }

    /// A whole seconds count that denotes no representable point in time is
    /// named by its digits.
    @Test func outOfRangeWholeTimestampIsWordedAlikeByBothValidators() async {
        let cases: [(CBORNode, String)] = [
            (.unsigned(9_223_372_036_854_775_808), "9223372036854775808"),
            (.negative(9_223_372_036_854_775_808), "-9223372036854775809"),
            (.unsigned(10_000_000_000_000), "10000000000000"),
        ]
        for (seconds, digits) in cases {
            let expected = "expected time data type, invalid UNIX timestamp \(digits)"
            #expect(await P.reasons("root = time", seconds) == [expected])
        }
    }

    /// A seconds count carrying a fraction is named as a float literal is
    /// written.
    @Test func outOfRangeFractionalTimestampIsWordedAlikeByBothValidators() async {
        let cases: [(Double, String)] = [
            (1e13, "10000000000000.0"),
            (-1e13, "-10000000000000.0"),
            (1e13 + 0.5, "10000000000000.5"),
        ]
        for (seconds, digits) in cases {
            let expected = "expected time data type, invalid UNIX timestamp \(digits)"
            #expect(await P.reasons("root = time", P.float(seconds)) == [expected])
        }
    }

    /// A float denoting no point in time at all is spelled out rather than
    /// approximated by a literal that cannot hold it.
    @Test func nonFiniteTimestampIsNamedByTheValueItDenotes() async {
        let cases: [(Double, String)] = [
            (.nan, "NaN"),
            (.infinity, "Infinity"),
            (-.infinity, "-Infinity"),
        ]
        for (seconds, digits) in cases {
            #expect(
                await P.reasons("root = time", P.float(seconds))
                    == ["expected time data type, invalid UNIX timestamp \(digits)"])
        }
    }

    /// A seconds count reached through tag 1 is named the same way as one that
    /// stands on its own.
    @Test func outOfRangeTaggedTimestampNamesTheSecondsCount() async {
        #expect(
            await P.reasons("root = time", .tagged(1, .unsigned(9_223_372_036_854_775_808)))
                == ["expected time data type, invalid UNIX timestamp 9223372036854775808"])

        #expect(
            await P.reasons("root = time", .tagged(1, P.float(1e13)))
                == ["expected time data type, invalid UNIX timestamp 10000000000000.0"])
    }

    /// The count is named by its digits alone: the type a data item was decoded
    /// into is not part of what the rejection reports.
    @Test func timestampRejectionDoesNotNameADecodedRepresentation() async {
        let leaked = ["Integer(", "Float(", "Tag(", "Text(", "Bytes("]

        let values: [CBORNode] = [
            .unsigned(9_223_372_036_854_775_808),
            P.float(1e13),
            .tagged(1, .unsigned(9_223_372_036_854_775_808)),
            .tagged(1, P.float(1e13)),
        ]
        for value in values {
            for reason in await P.reasons("root = time", value) {
                for name in leaked {
                    #expect(!reason.contains(name), "\(reason) names a decoded representation: \(name)")
                }
            }
        }
    }

    /// A seconds count that does denote a point in time is admitted.
    @Test func representableTimestampIsAdmittedByBothValidators() async {
        for value in [P.int(1_363_896_240), P.int(0), P.int(-1_363_896_240), P.float(1_363_896_240.5)] {
            #expect(await P.reasons("root = time", value) == [])
        }

        #expect(await P.reasons("root = time", .tagged(1, P.int(1_363_896_240))) == [])
    }

    /// A member key a map does not hold is named as the CDDL writes it; a
    /// bareword member key stands for the text string of that name.
    @Test func missingMemberKeyIsWordedAlikeByBothValidators() async {
        for schema in ["root = { a: int }", "root = { \"a\": int }"] {
            #expect(await P.reasons(schema, P.map([])) == ["map missing key: \"a\""])
        }
    }

    /// The key is escaped as its own notation requires, so the rendering reads
    /// back as the literal that names the key.
    @Test func missingMemberKeyIsEscapedByBothValidators() async {
        let schema = "root = { \"a\\\"b\": int }"

        #expect(await P.reasons(schema, P.map([])) == ["map missing key: \"a\\\"b\""])
    }

    /// A member key the map does hold is not reported missing.
    @Test func presentMemberKeyIsAdmittedByBothValidators() async {
        let schema = "root = { a: int }"

        #expect(await P.reasons(schema, P.map([("a", P.int(1))])) == [])
    }

    /// RFC 9741 Section 2.1 gives a text conversion control operator a `bytes`
    /// controller. A text type is no type a byte string belongs to, so the text
    /// is rejected however well formed the encoding is.
    @Test func textConversionAgainstATextControllerIsRejectedByBothValidators() async {
        for (ctrl, encoded) in textConversions {
            let schema = "root = tstr \(ctrl) tstr"

            let reasons = await P.reasons(schema, P.text(encoded))
            #expect(!reasons.isEmpty, "\(ctrl) admits a text controller against \(encoded)")
            #expect(reasons == ["\(ctrl) decoded byte string: expected type tstr, got Bytes([1, 2, 3])"], "\(ctrl)")

            // Text that is no encoding at all is refused on the encoding,
            // before the controller is reached.
            let garbage = "!!!definitely not encoded!!!"
            #expect(
                await P.reasons(schema, P.text(garbage)) == ["text string \"\(garbage)\" is not \(ctrl) encoded"],
                "\(ctrl)")
        }
    }

    /// A byte string type as the controller is the form RFC 9741 writes its own
    /// examples in: the decoded byte string has to be a member of it.
    @Test func textConversionAgainstAByteStringTypeIsSettledAlikeByBothValidators() async {
        for (ctrl, encoded) in textConversions {
            for controller in ["bstr", "sig"] {
                let schema = "root = tstr \(ctrl) \(controller)\nsig = bstr"
                #expect(await P.reasons(schema, P.text(encoded)) == [], "\(ctrl) \(controller)")
            }

            // Three bytes are what every encoding above stands for, so a size
            // of two is a byte string type the decoded bytes are not a member of.
            let schema = "root = tstr \(ctrl) sig\nsig = bstr .size 2"
            let reasons = await P.reasons(schema, P.text(encoded))
            #expect(!reasons.isEmpty, "\(ctrl) admits three bytes against .size 2")
            #expect(reasons == ["\(ctrl) decoded byte string: expected h'010203' .size 2, got 3"], "\(ctrl)")

            // The same byte string type with the size the bytes do have is
            // admitted, so the rejection above is the size.
            let sized = "root = tstr \(ctrl) sig\nsig = bstr .size 3"
            #expect(await P.reasons(sized, P.text(encoded)) == [], "\(ctrl)")
        }
    }

    /// A byte string literal is one byte string type among others, so it is
    /// settled by the same match.
    @Test func textConversionAgainstAByteStringLiteralIsWordedAlikeByBothValidators() async {
        for (ctrl, encoded) in textConversions {
            #expect(await P.reasons("root = tstr \(ctrl) h'010203'", P.text(encoded)) == [], "\(ctrl)")

            #expect(
                await P.reasons("root = tstr \(ctrl) h'010204'", P.text(encoded))
                    == ["\(ctrl) decoded byte string: expected value h'010204', got h'010203'"],
                "\(ctrl)")
        }
    }

    /// The shape RFC 9741 Section 2.1 writes its own example in: text carrying
    /// the base64url form of a byte string whose content is described further
    /// by `.cbor`.
    @Test func textConversionOverADescribedByteStringIsSettledAlikeByBothValidators() async {
        let schema = """
            signature-for-json = tstr .b64u signature
            signature = bstr .cbor payload
            payload = [int, tstr]
            """

        // "ggFhYQ" is the base64url form of the CBOR encoding of [1, "a"].
        #expect(await P.reasons(schema, P.text("ggFhYQ")) == [])

        // "AQID" is well formed base64url and decodes to a byte string the
        // controller does not describe.
        let reasons = await P.reasons(schema, P.text("AQID"))
        #expect(!reasons.isEmpty, "a byte string outside the controller was admitted")
        #expect(
            reasons == [
                ".b64u decoded byte string: error decoding embedded CBOR: 2 trailing bytes after the data item: a CBOR document is a single data item"
            ])
    }

    /// A control operator whose operand the schema leaves standing for no value
    /// states nothing for a data item to be judged against; that is raised
    /// apart from the mismatches, and no matching alternative buries it.
    @Test func brokenControlOperandIsRaisedOnTheSchemaChannelByBothValidators() async {
        for schema in [
            "root = int .eq (1 .plus a)\na = tstr",
            // An alternative that matches must not bury the fault.
            "root = int .eq (1 .plus a) / int\na = tstr",
            // The same operand reached as a computed controller.
            "root = int .lt (1 .plus a)\na = tstr",
        ] {
            let verdict = await cborResult(schema, P.int(3).encoded())
            if case .invalidSchema(let issue) = verdict {
                #expect(issue.reason.contains(".plus"), "\(issue.reason)")
            } else {
                Issue.record("\(schema) gave \(verdict.map { "\($0)" } ?? "a match")")
            }
        }

        for schema in [
            "root = \"x\" .cat a\na = 3",
            "root = (\"x\" .cat a) / tstr\na = 3",
            "root = \"x\" .det a\na = 3",
        ] {
            let verdict = await cborResult(schema, P.text("a").encoded())
            guard case .invalidSchema = verdict else {
                Issue.record("\(schema) gave \(verdict.map { "\($0)" } ?? "a match")")
                continue
            }
        }
    }

    /// The same operators over operands the schema does define stay on the
    /// channel that answers for the data.
    @Test func soundControlOperandStaysOnTheDataChannelInBothValidators() async {
        let schema = "root = int .eq (1 .plus 2)"

        await expectValid(schema, P.int(3).encoded())

        #expect(await P.reasons(schema, P.int(4)) == ["expected value 3, got Integer(4)"])
    }

    /// A document is one data item (RFC 8949 Section 5.1), and what follows it
    /// is refused at the framing level rather than reported as a mismatch.
    @Test func inputCarryingMoreThanOneDocumentIsRefusedByBothValidators() async {
        let cases: [(String, [UInt8])] = [
            ("root = uint", [0x05, 0x06]),
            ("root = [int]", [0x81, 0x01, 0xff]),
        ]
        for (schema, document) in cases {
            let verdict = await cborResult(schema, document)
            switch verdict {
            case .validation(let errors):
                Issue.record("\(schema): trailing bytes were reported as a mismatch: \(errors)")
            case .cborDecoding(let error):
                #expect("\(error)".contains("trailing byte"), "\(schema): \(error)")
            case .some(let error):
                Issue.record("\(schema): \(error)")
            case .none:
                Issue.record("\(schema): bytes after the document were accepted")
            }
        }
    }

    /// Input that is exactly one document is admitted, so the framing check
    /// refuses nothing the schema admits.
    @Test func inputThatIsExactlyOneDocumentIsAdmittedByBothValidators() async {
        let cases: [(String, [UInt8])] = [
            ("root = uint", [0x05]),
            ("root = [int]", [0x81, 0x01]),
            ("root = [int]", [0x9f, 0x01, 0xff]),
        ]
        for (schema, document) in cases {
            await expectValid(schema, document)
        }
    }

    /// A document that did not decode and a schema that did not parse are two
    /// faults with two corrections, and are kept apart.
    @Test func undecodableDocumentAndUnparseableSchemaAreSeparateFaultsInBothValidators() async {
        let schema = "root = uint"
        // An array head whose element never arrives.
        let document: [UInt8] = [0x82, 0x01]
        let brokenSchema = "root = = uint"
        let whole: [UInt8] = [0x05]

        let undecodable = await cborResult(schema, document)
        guard case .cborDecoding = undecodable else {
            Issue.record("a document that did not decode gave \(undecodable.map { "\($0)" } ?? "a match")")
            return
        }

        let unparseable = await cborResult(brokenSchema, whole)
        guard case .cddlParsing = unparseable else {
            Issue.record("a schema that did not parse gave \(unparseable.map { "\($0)" } ?? "a match")")
            return
        }

        // The message may not name the other fault.
        let message = "\(undecodable.map { "\($0)" } ?? "")"
        #expect(!message.contains("CDDL"), "\(message)")

        // The boundary: a schema that parses and a document that decodes.
        await expectValid(schema, whole)
    }

    /// A type choice at every level of a nested document is settled the same
    /// way however deep the nesting goes: state an alternative left behind
    /// would show as a document judged differently at depth.
    @Test func aTypeChoiceAtEveryLevelIsSettledAlikeByBothValidators() async {
        let arraySchema = "x = tstr / bool / [* x] / uint"
        let mapSchema = "x = tstr / bool / {* tstr => x} / uint"
        let admittedLeaf = P.int(5)
        let refusedLeaf = P.int(-1)

        for levels in [0, 1, 2, 8, 40, cborParityNestedChoiceDepth] {
            #expect(
                await P.reasons(arraySchema, P.nestedArrays(levels, admittedLeaf)) == [],
                "nested arrays admitted at \(levels) levels")
            #expect(
                await P.reasons(mapSchema, P.nestedMaps(levels, admittedLeaf)) == [],
                "nested maps admitted at \(levels) levels")
            #expect(
                !(await P.reasons(arraySchema, P.nestedArrays(levels, refusedLeaf))).isEmpty,
                "nested arrays refused at \(levels) levels")
            #expect(
                !(await P.reasons(mapSchema, P.nestedMaps(levels, refusedLeaf))).isEmpty,
                "nested maps refused at \(levels) levels")
        }
    }

    /// RFC 9165 Section 3 `.abnf` controllers, well formed and not. This
    /// implementation does not provide `.abnf`, so every such schema is
    /// reported as unsupported rather than matched or refused.
    @Test func abnfControllerAndTargetFaultsAreSeparatedAlikeByBothValidators() async {
        // The controller is a string, in either notation, and a parenthesized
        // one is the string its `.cat` computes.
        for cddl in [
            #"root = tstr .abnf "oct\noct = %x61-63\n""#,
            "root = tstr .abnf 'oct\noct = %x61-63\n'",
            #"root = tstr .abnf ("oct" .cat "\noct = %x61-63\n")"#,
        ] {
            for document in ["a", "z"] {
                let verdict = await cborResult(cddl, P.text(document).encoded())
                guard case .unsupported = verdict else {
                    Issue.record("\(cddl) against \(document): \(verdict.map { "\($0)" } ?? "a match")")
                    continue
                }
            }
        }

        for cddl in [
            // A rulelist with no rule named on the first line.
            #"root = tstr .abnf "oct = %x61-63""#,
            "root = tstr .abnf 'oct = %x61-63'",
            // A first line naming a rule the rulelist does not define.
            #"root = tstr .abnf "missing\noct = %x61-63\n""#,
            // A byte string controller that is not valid UTF-8.
            #"root = tstr .abnf h'ff'"#,
        ] {
            let verdict = await cborResult(cddl, P.text("a").encoded())
            guard case .unsupported = verdict else {
                Issue.record("\(cddl): \(verdict.map { "\($0)" } ?? "a match")")
                continue
            }
        }

        // A controller that is a computation the schema cannot carry out is a
        // fault in the schema before any grammar is read.
        for cddl in [
            // A parenthesized controller carrying no `.cat` or `.det`.
            #"root = tstr .abnf ("x")"#,
            #"root = tstr .abnf (1)"#,
            "root = tstr .abnf (a)\na = \"x\"\n",
            // A parenthesized controller whose concatenation cannot be
            // evaluated.
            #"root = tstr .abnf ("x" .cat undef)"#,
        ] {
            let verdict = await cborResult(cddl, P.text("a").encoded())
            guard case .invalidSchema = verdict else {
                Issue.record("\(cddl): \(verdict.map { "\($0)" } ?? "a match")")
                continue
            }
        }
    }

    /// A byte string literal and a text string data item are distinct types
    /// whatever their content, so `.ne` against one is satisfied by every text
    /// document and `.eq` against one by none, whichever of the three byte
    /// string notations the literal is written in.
    @Test func byteStringLiteralAgainstATextDocumentIsSettledAlikeByBothValidators() async {
        // The same byte, written as UTF-8 text, base16 and base64, and how
        // each is named in a rejection.
        let controllers: [(String, String)] = [("'x'", "'x'"), ("h'78'", "h'78'"), ("b64'eA=='", "b64'eA'")]
        for (controller, rendered) in controllers {
            for document in ["x", "a"] {
                let notEqual = "root = tstr .ne \(controller)"
                #expect(await P.reasons(notEqual, P.text(document)) == [], "\(notEqual) against \(document)")

                let equal = "root = tstr .eq \(controller)"
                let reasons = await P.reasons(equal, P.text(document))
                #expect(reasons == ["expected value \(rendered), got \"\(document)\""], "\(equal) against \(document)")
                #expect(
                    reasons.first.map { $0.hasPrefix("expected value ") && $0.hasSuffix("got \"\(document)\"") } == true,
                    "got: \(reasons)")
            }
        }
    }

    /// A byte string literal reached with no control operator in play describes
    /// a data item, and a text string is not one; the literal and the data item
    /// are named the same way at the top level and inside an array.
    @Test func byteStringLiteralAsADataItemIsWordedAlikeByBothValidators() async {
        #expect(await P.reasons("root = 'x'", P.text("x")) == ["expected value 'x', got \"x\""])
        #expect(await P.reasons("root = ['x']", P.array([P.text("x")])) == ["expected value 'x', got \"x\""])
        #expect(await P.reasons("root = ['x']", P.array([P.text("y")])) == ["expected value 'x', got \"y\""])
    }

    /// `.eq` states that the data item is one of the values its controller
    /// denotes, and `.ne` the negation (RFC 8610 Section 3.8.6).
    @Test func equalityAndExclusionAnswerForControllerMembershipInBothValidators() async {
        // `.eq` admits the members of its controller and refuses the rest.
        #expect(await P.settled("root = tstr .eq \"x\"", P.text("x")))
        #expect(!(await P.settled("root = tstr .eq \"x\"", P.text("y"))))
        #expect(await P.settled("root = tstr .eq tstr", P.text("x")))
        #expect(!(await P.settled("root = any .eq tstr", P.int(3))))

        // `.ne` refuses exactly what `.eq` admits.
        #expect(!(await P.settled("root = tstr .ne \"x\"", P.text("x"))))
        #expect(await P.settled("root = tstr .ne \"x\"", P.text("y")))
        #expect(!(await P.settled("root = tstr .ne tstr", P.text("x"))))
        #expect(await P.settled("root = any .ne tstr", P.int(3)))

        // A controller reached through a rule name denotes what the rule
        // denotes, whether that is a single value or a whole type.
        #expect(!(await P.settled("root = tstr .ne c\nc = \"x\"", P.text("x"))))
        #expect(await P.settled("root = tstr .ne c\nc = \"x\"", P.text("y")))
        #expect(!(await P.settled("root = tstr .ne c\nc = tstr", P.text("x"))))
        #expect(await P.settled("root = tstr .ne c\nc = uint", P.text("x")))
    }

    /// The exclusion `.ne` states holds against every shape a controller can
    /// denote: a type choice, a range, an array and a map.
    @Test func exclusionCoversEveryShapeOfControllerInBothValidators() async {
        let cases: [(String, CBORNode, CBORNode)] = [
            ("root = tstr .ne (\"x\" / \"y\")", P.text("z"), P.text("x")),
            ("root = int .ne (0..10)", P.int(11), P.int(5)),
            ("root = [* int] .ne [int]", P.array([P.int(1), P.int(2)]), P.array([P.int(1)])),
        ]
        for (schema, excluded, member) in cases {
            #expect(
                await P.settled(schema, excluded),
                "\(schema) must admit a data item its controller does not denote")
            #expect(
                !(await P.settled(schema, member)),
                "\(schema) must refuse a data item its controller denotes")
        }
    }

    /// `.and` and `.within` both state the intersection of their two types
    /// (RFC 8610 Section 3.8.5).
    @Test func intersectionOperatorsResolveATypeControllerInBothValidators() async {
        for schema in [
            "root = uint .and uint",
            "root = uint .within number",
            "root = uint .and c\nc = uint",
            "root = uint .within c\nc = number",
            // A controller denoting a single value is the same statement over
            // a type of one member.
            "root = uint .and 3",
            "root = uint .within (0..10)",
        ] {
            #expect(await P.settled(schema, P.int(3)), "\(schema) must admit a data item both of its types denote")
        }

        for schema in [
            "root = uint .and nint",
            "root = uint .within nint",
            "root = uint .and c\nc = nint",
            "root = uint .within c\nc = nint",
            "root = uint .and 4",
            "root = uint .within (4..10)",
        ] {
            #expect(
                !(await P.settled(schema, P.int(3))),
                "\(schema) must refuse a data item only one of its types denotes")
        }
    }

    /// `.cat`, `.det` and `.plus` stand for the value they compute from their
    /// two operands (RFC 9165), so an operand that denotes no value is a fault
    /// in the schema whatever the document holds.
    @Test func computingOperatorsRaiseAnUnusableTargetOnTheSchemaChannel() async {
        for schema in [
            "root = bstr .cat \"x\"",
            "root = bstr .det \"x\"",
            "root = tstr .cat \"x\"",
            "root = tstr .det \"x\"",
            "root = uint .plus 1",
            "root = int .plus 1",
        ] {
            for document in [P.text("x"), P.int(3), CBORNode.bool(true)] {
                let verdict = await cborResult(schema, document.encoded())
                if case .invalidSchema(let issue) = verdict {
                    #expect(issue.reason.contains("target of"), "\(schema): \(issue.reason)")
                } else {
                    Issue.record("\(schema) against \(document) gave \(verdict.map { "\($0)" } ?? "a match")")
                }
            }
        }

        // The same operators over operands that do denote values stay on the
        // channel that answers for the document.
        #expect(await P.settled("root = \"a\" .cat \"b\"", P.text("ab")))
        #expect(!(await P.settled("root = \"a\" .cat \"b\"", P.text("ac"))))
        #expect(await P.settled("root = 1 .plus 2", P.int(3)))
        #expect(!(await P.settled("root = 1 .plus 2", P.int(4))))
    }

    /// The type a control operator's target names is a precondition for the
    /// control saying anything about the data item: a number written with a
    /// fraction is not an integer.
    @Test func aControlTargetIsHeldToItsOwnTypeAlikeByBothValidators() async {
        for schema in [
            "root = int .ne \"x\"",
            "root = int .gt 1",
            "root = nint .ne -2",
            "root = uint .ne 5",
        ] {
            #expect(
                !(await P.settled(schema, P.float(1.5))),
                "\(schema) must refuse a number that is not an integer")
        }

        for schema in ["root = float .ne 2.5", "root = float .gt 1.0"] {
            #expect(
                !(await P.settled(schema, P.int(3))),
                "\(schema) must refuse an integer where a floating point number is named")
            #expect(await P.settled(schema, P.float(1.5)), "\(schema) must admit a floating point number")
        }
    }

    /// A schema whose choice alternatives cannot be told apart at the head of
    /// the data item makes the walk exponential in the nesting; the bound on
    /// work stops it, and the refusal names that bound.
    @Test func aWalkExponentialInTheNestingIsStoppedAlikeByBothValidators() async {
        // Two alternatives that both descend, and a leaf no alternative admits.
        let schema = "x = a / b / uint\na = [x]\nb = [x]\n"
        let levels = 40
        let limits = ValidationLimits(maxValidationWork: 50_000)

        let refusedLeaf = P.text("no alternative admits this")
        let refused = await P.limited(schema, P.nestedArrays(levels, refusedLeaf).encoded(), limits)
        #expect(refused != nil, "the walk is exponential in the depth")
        let message = refused.map { "\($0)" } ?? ""

        let named = "maximum supported \(limits.maxValidationWork) steps of validation work"
        #expect(message.contains(named), "\(message)")

        // The same schema over a document the budget does fit is answered.
        let admitted = await P.limited(schema, P.nestedArrays(levels, P.int(5)).encoded(), limits)
        #expect(admitted == nil)
    }

    /// The budget is spent over a run, not per data item: a budget that fits a
    /// document does not fit twice as much of it.
    @Test func theWorkBudgetIsChargedAcrossAWholeDocumentByBothValidators() async throws {
        let schema = "x = [* uint]"

        func fits(_ items: Int, _ budget: Int) async -> Bool {
            let value = P.array((0..<items).map { P.int(Int64($0)) })
            return await P.limited(schema, value.encoded(), ValidationLimits(maxValidationWork: budget)) == nil
        }

        // The smallest budget that fits sixteen items.
        var cost = 1
        while !(await fits(16, cost)) {
            cost += 1
            try #require(cost < 10_000, "sixteen items cost more than the search")
        }

        // Twice the items do not fit what the half of them fitted exactly.
        #expect(!(await fits(32, cost)))
    }

    /// A payload a text conversion control operator decodes out of the document
    /// is walked on the budget of the run that reached it, not on one of its
    /// own.
    @Test func textConversionPayloadsShareOneWorkBudgetOnBothChannels() async throws {
        let schema = "root = [* (tstr .hex inner)]\ninner = bstr .cbor [* uint]\n"

        // One payload: a CBOR array of eight integers, written as the hex text
        // the `.hex` control decodes back into those bytes.
        let payload = hexString(P.array((0..<8).map { P.int(Int64($0)) }).encoded())

        func fits(_ payloads: Int, _ budget: Int) async -> Bool {
            let value = P.array(Array(repeating: P.text(payload), count: payloads))
            return await P.limited(schema, value.encoded(), ValidationLimits(maxValidationWork: budget)) == nil
        }

        var cost = 1
        while !(await fits(1, cost)) {
            cost += 1
            try #require(cost < 10_000, "one payload costs more than the search")
        }

        // A second payload has to come out of what the first left.
        #expect(!(await fits(2, cost)))

        // And room for both is room enough.
        #expect(await fits(2, cost * 3))
    }

    /// A chain of rule references costs the way the levels of the data do, and
    /// the descent budget bounds what the two cost together.
    @Test func aRuleChainAtEveryLevelIsBoundedByTheDescentBudgetInBothValidators() async {
        // One reference short of what the default rule bound admits, resolved
        // once per level.
        let prelude = P.chainedAliases(63)

        // Shallow enough that the budget carries the walk.
        await P.assertSettledInEveryPlacement(
            prelude, "x", admitted: [P.nestedEmptyArrays(2)], refused: [P.int(5)])

        // Deep enough that it does not: inside both nesting bounds, so nothing
        // but the descent budget can refuse this.
        let schema = "root = x\(prelude)"
        let refused = await cborResult(schema, P.nestedEmptyArrays(1000).encoded())
        #expect(refused != nil, "the descent costs more than the default budget")
        let message = refused.map { "\($0)" } ?? ""
        let named = "maximum supported descent budget of \(ValidationLimits.defaultMaxDescentCost) bytes"
        #expect(message.contains(named), "\(message)")
    }

    /// A level of the data is charged to the descent budget as well as a
    /// reference resolved against it, so a document nesting deeply enough is
    /// refused by the budget.
    @Test func aDeepDocumentIsBoundedByTheDescentBudgetInBothValidators() async {
        let schema = "x = [* x]"
        let limits = ValidationLimits(maxDescentCost: 160_000)

        let five = await P.limited(schema, P.nestedEmptyArrays(5).encoded(), limits)
        #expect(five == nil, "five levels are inside the budget")

        let twenty = await P.limited(schema, P.nestedEmptyArrays(20).encoded(), limits)
        #expect(twenty != nil, "twenty levels are not")

        let message = twenty.map { "\($0)" } ?? ""
        let named = "maximum supported descent budget of \(limits.maxDescentCost) bytes"
        #expect(message.contains(named), "\(message)")
    }

    /// What the failed alternatives of a choice recorded is held until the
    /// choice settles and is charged to the descent budget, whether the
    /// alternatives were tried on a copy of the level or in place.
    @Test func whatAFailedAlternativeRecordedIsChargedToTheDescentByBothValidators() async throws {
        let levels = 5
        let texts = (0..<20).map { "\"k\($0)\" / " }.joined()
        let leaf = P.text("k0")
        let arraysDocument = P.nestedArrays(levels, leaf).encoded()
        let mapsDocument = P.nestedMaps(levels, leaf).encoded()

        // The alternatives of a type written out in the rule body are tried in
        // place against an array; a rule's alternatives are tried on a copy.
        let two = ("x = [* x] / \"k0\"\n", arraysDocument)
        let arrays = ("x = (\(texts)[* x] / uint)\n", arraysDocument)
        let maps = ("x = \(texts){k: x} / uint\n", mapsDocument)

        func verdict(_ schema: String, _ bytes: [UInt8], _ budget: Int) async -> String {
            let result = await P.limited(schema, bytes, ValidationLimits(maxDescentCost: budget))
            guard let result else { return "valid" }
            guard let issues = result.issues else {
                Issue.record("expected validation errors, got \(result)")
                return "error: \(result)"
            }
            let reasons = issues.map(\.reason)
            if !reasons.isEmpty, reasons.allSatisfy({ $0.contains("maximum supported descent budget") }) {
                return "budget"
            }
            return "invalid: \(reasons)"
        }

        // The smallest budget that carries the two-alternative rule through
        // the document.
        var refusedBudget = 0
        var admittedBudget = 1 << 24
        try #require(await verdict(two.0, two.1, admittedBudget) == "valid")
        while admittedBudget - refusedBudget > 1 {
            let mid = refusedBudget + (admittedBudget - refusedBudget) / 2
            if await verdict(two.0, two.1, mid) == "valid" {
                admittedBudget = mid
            } else {
                refusedBudget = mid
            }
        }
        let carries = admittedBudget + 2048

        let cases: [((String, [UInt8]), Int, String)] = [
            (two, carries, "valid"),
            (arrays, carries, "budget"),
            (maps, carries, "budget"),
            (arrays, 64 * carries, "valid"),
            (maps, 64 * carries, "valid"),
        ]
        for ((schema, bytes), budget, expected) in cases {
            #expect(await verdict(schema, bytes, budget) == expected, "\(schema) at \(budget)")
        }
    }

    /// A document nested ten thousand levels deep is settled with the verdict
    /// its leaf decides, and a refused leaf is named by its own location.
    @Test func aDocumentNestedTenThousandLevelsIsSettledOnASmallStackByBothValidators() async {
        let levels = 10_000

        // Arrays: `81` opens a single-element array, `05` is the integer 5 and
        // `60` the empty text string, which no alternative admits.
        let arraySchema = "x = [* x] / uint"
        let admittedArrays = Array(repeating: UInt8(0x81), count: levels) + [0x05]
        let refusedArrays = Array(repeating: UInt8(0x81), count: levels) + [0x60]
        #expect(await P.errors(arraySchema, admittedArrays).isEmpty)
        let arrayErrors = await P.errors(arraySchema, refusedArrays)
        let arrayLeaf = String(repeating: "/0", count: levels)
        #expect(
            arrayErrors.contains { $0.cborLocation == arrayLeaf && $0.reason.contains("expected type uint") },
            "the leaf is named: \(arrayErrors.prefix(3).map { ($0.cborLocation.count, $0.reason) })")

        // Maps: `a1 61 6b` opens a single-entry map under the key "k".
        let mapSchema = "x = {* tstr => x} / uint"
        var opened: [UInt8] = []
        for _ in 0..<levels {
            opened.append(contentsOf: [0xa1, 0x61, 0x6b])
        }
        #expect(await P.errors(mapSchema, opened + [0x05]).isEmpty)
        let mapErrors = await P.errors(mapSchema, opened + [0x60])
        let mapLeaf = String(repeating: "/\"k\"", count: levels)
        #expect(
            mapErrors.contains { $0.cborLocation == mapLeaf && $0.reason.contains("expected type uint") },
            "the leaf is named: \(mapErrors.prefix(3).map { ($0.cborLocation.count, $0.reason) })")
    }

    /// A choice of well over a hundred alternatives that fail at every level
    /// holds so much a level that the descent budget refuses it, as a limit,
    /// well before the nesting bound is reached.
    @Test func aChoiceOfManyAlternativesIsRefusedByTheDescentBudgetBeforeTheNestingBound() async {
        var schema = "x = c<x> / {* x => x} / [* x] / int / bstr\nc<a> = #6.102([uint, [* a]])"
        for tag in Array(121...127) + Array(1280...1400) {
            schema += " / #6.\(tag)([* a])"
        }
        schema += "\n"

        let budget = "maximum supported descent budget of \(ValidationLimits.defaultMaxDescentCost) bytes"
        let depthBound = "maximum supported nesting depth of \(ValidationLimits.defaultMaxNestingDepth)"

        // Nested single-item arrays around the integer 0.
        func document(_ levels: Int) -> [UInt8] {
            Array(repeating: UInt8(0x81), count: levels) + [0x00]
        }

        // Two thousand levels are inside the budget.
        #expect(await P.errors(schema, document(2_000)).isEmpty)

        // Sixteen thousand are not: refused under the budget, and not under
        // the depth bound, which lies past them.
        let refused = await cborResult(schema, document(16_000))
        #expect(refused != nil, "refused")
        let message = refused.map { "\($0)" } ?? ""
        #expect(message.contains(budget), "\(message)")
        #expect(!message.contains(depthBound), "\(message)")
    }

    /// The alternatives of a type choice are evaluated apart: what one records
    /// is not seen by the next, at any depth.
    @Test func anAlternativeDoesNotSeeWhatTheAlternativeBeforeItRecordedInBothValidators() async {
        let mapSchema = "x = {* tstr => tstr} / {k: x} / uint"
        let nestedThree = P.map([("k", P.map([("k", P.map([("k", P.int(5))]))]))])
        #expect(await P.errors(mapSchema, nestedThree.encoded()).isEmpty)
        let extraKey = P.map([("k", P.map([("k", P.map([("k", P.int(5)), ("extra", P.int(1))]))]))])
        #expect(!(await P.errors(mapSchema, extraKey.encoded())).isEmpty)

        let arraySchema = "x = [tstr, * x] / [x] / uint"
        func nested(_ leaf: CBORNode) -> CBORNode {
            P.array([P.array([leaf])])
        }
        #expect(await P.errors(arraySchema, nested(P.array([P.int(5)])).encoded()).isEmpty)
        #expect(!(await P.errors(arraySchema, nested(P.array([P.int(5), P.int(1)])).encoded())).isEmpty)
    }
}
