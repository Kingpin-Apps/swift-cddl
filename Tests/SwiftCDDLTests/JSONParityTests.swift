import Foundation
import Testing

@testable import SwiftCDDL

private typealias J = JSONParityFixture
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

/// A rejection the JSON validator and the CBOR validator can both reach is
/// worded in one place, so a value refused on the same grounds reads the same
/// whichever of them reports it (RFC 8610 Sections 2 and 3, RFC 8259).
@Suite struct JSONParityTests {
    /// Several array items failing every alternative alike are reported in
    /// document order, the first of them at the head, on every run.
    @Test func itemsFailingAlikeAreReportedInDocumentOrderOnEveryRun() async {
        let cddl = "a = [* uint / bool]"
        let document = #"["a", "a", "a", "a", "a"]"#
        let expected = (0..<5).flatMap { ["/\($0)", "/\($0)"] }
        for _ in 0..<20 {
            #expect(await J.locations(cddl, document) == expected)
        }
        #expect(await P.locations(cddl, P.array(Array(repeating: P.text("a"), count: 5))) == expected)
    }

    /// A whole seconds count that denotes no representable point in time is
    /// named by its digits, the same way by both validators.
    @Test func outOfRangeWholeTimestampIsWordedAlikeByBothValidators() async {
        let cases: [(CBORNode, String)] = [
            (.unsigned(9_223_372_036_854_775_808), "9223372036854775808"),
            (.negative(9_223_372_036_854_775_808), "-9223372036854775809"),
            (.unsigned(10_000_000_000_000), "10000000000000"),
        ]
        for (node, document) in cases {
            let expected = "expected time data type, invalid UNIX timestamp \(document)"
            #expect(await P.reasons("root = time", node) == [expected])

            // A JSON number wider than 64 bits is read as a float, so only the
            // counts a JSON document carries exactly are compared.
            if Int64(document) != nil {
                #expect(await J.reasons("root = time", document) == [expected])
            }
        }
    }

    /// A seconds count carrying a fraction is named as a float literal is
    /// written, by both validators.
    @Test func outOfRangeFractionalTimestampIsWordedAlikeByBothValidators() async {
        let cases: [(Double, String, String)] = [
            (1e13, "1e13", "10000000000000.0"),
            (-1e13, "-1e13", "-10000000000000.0"),
            (1e13 + 0.5, "10000000000000.5", "10000000000000.5"),
        ]
        for (seconds, document, digits) in cases {
            let expected = "expected time data type, invalid UNIX timestamp \(digits)"
            #expect(await P.reasons("root = time", P.float(seconds)) == [expected])
            #expect(await J.reasons("root = time", document) == [expected])
        }
    }

    /// A seconds count that does denote a point in time is admitted.
    @Test func representableTimestampIsAdmittedByBothValidators() async {
        for document in ["1363896240", "0", "-1363896240", "1363896240.5"] {
            #expect(await J.reasons("root = time", document) == [])
        }
    }

    /// A member key an object does not hold is named as the CDDL writes it,
    /// led by the noun the validator's data model has for the item.
    @Test func missingMemberKeyIsWordedAlikeByBothValidators() async {
        for schema in ["root = { a: int }", "root = { \"a\": int }"] {
            #expect(await P.reasons(schema, .map([])) == ["map missing key: \"a\""])
            #expect(await J.reasons(schema, "{}") == ["object missing key: \"a\""])
        }
    }

    /// The key is escaped as its own notation requires.
    @Test func missingMemberKeyIsEscapedByBothValidators() async {
        let schema = #"root = { "a\"b": int }"#
        #expect(await P.reasons(schema, .map([])) == [#"map missing key: "a\"b""#])
        #expect(await J.reasons(schema, "{}") == [#"object missing key: "a\"b""#])
    }

    /// A member key the object does hold is not reported missing.
    @Test func presentMemberKeyIsAdmittedByBothValidators() async {
        #expect(await J.reasons("root = { a: int }", #"{"a":1}"#) == [])
    }

    /// RFC 9741 Section 2.1 gives a text conversion control operator a byte
    /// string controller; a text type is none, so the text is rejected however
    /// well formed the encoding is, by both validators on the same grounds.
    @Test func textConversionAgainstATextControllerIsRejectedByBothValidators() async {
        for (ctrl, encoded) in textConversions {
            let schema = "root = tstr \(ctrl) tstr"
            let reasons = await P.reasons(schema, P.text(encoded))
            #expect(!reasons.isEmpty, "\(ctrl) admits a text controller against \(encoded)")
            #expect(await J.reasons(schema, "\"\(encoded)\"") == reasons, "\(ctrl)")

            let garbage = "!!!definitely not encoded!!!"
            let garbageReasons = await P.reasons(schema, P.text(garbage))
            #expect(garbageReasons == ["text string \"\(garbage)\" is not \(ctrl) encoded"])
            #expect(await J.reasons(schema, "\"\(garbage)\"") == garbageReasons, "\(ctrl)")
        }
    }

    /// A byte string type as the controller is admitted, and a byte string
    /// that is not a member of it is refused alike by both.
    @Test func textConversionAgainstAByteStringTypeIsSettledAlikeByBothValidators() async {
        for (ctrl, encoded) in textConversions {
            let document = "\"\(encoded)\""
            for controller in ["bstr", "sig"] {
                #expect(await J.reasons("root = tstr \(ctrl) \(controller)\nsig = bstr", document) == [])
            }

            let schema = "root = tstr \(ctrl) sig\nsig = bstr .size 2"
            let reasons = await P.reasons(schema, P.text(encoded))
            #expect(!reasons.isEmpty, "\(ctrl) admits three bytes against .size 2")
            #expect(await J.reasons(schema, document) == reasons, "\(ctrl)")

            #expect(await J.reasons("root = tstr \(ctrl) sig\nsig = bstr .size 3", document) == [])
        }
    }

    /// A byte string literal is one byte string type among others, and is
    /// reported in the same words by both.
    @Test func textConversionAgainstAByteStringLiteralIsWordedAlikeByBothValidators() async {
        for (ctrl, encoded) in textConversions {
            let document = "\"\(encoded)\""
            #expect(await J.reasons("root = tstr \(ctrl) h'010203'", document) == [], "\(ctrl)")

            let schema = "root = tstr \(ctrl) h'010204'"
            let expected = ["\(ctrl) decoded byte string: expected value h'010204', got h'010203'"]
            #expect(await P.reasons(schema, P.text(encoded)) == expected)
            #expect(await J.reasons(schema, document) == expected, "\(ctrl)")
        }
    }

    /// Text carrying the base64url form of a byte string whose content is
    /// described further, by `.cbor`, is settled alike by both validators.
    @Test func textConversionOverADescribedByteStringIsSettledAlikeByBothValidators() async {
        let schema = """
            signature-for-json = tstr .b64u signature
            signature = bstr .cbor payload
            payload = [int, tstr]
            """
        #expect(await J.reasons(schema, #""ggFhYQ""#) == [])

        let reasons = await P.reasons(schema, P.text("AQID"))
        #expect(!reasons.isEmpty, "a byte string outside the controller was admitted")
        #expect(await J.reasons(schema, #""AQID""#) == reasons)
    }

    /// A control operator whose operand stands for no value is raised apart
    /// from the mismatches, and no matching alternative buries it.
    @Test func brokenControlOperandIsRaisedOnTheSchemaChannelByBothValidators() async {
        for schema in [
            "root = int .eq (1 .plus a)\na = tstr",
            "root = int .eq (1 .plus a) / int\na = tstr",
            "root = int .lt (1 .plus a)\na = tstr",
        ] {
            let verdict = await jsonResult(schema, "3")
            guard case .invalidSchema(let issue)? = verdict else {
                Issue.record("\(schema) gave \(jsonRendered(verdict))")
                continue
            }
            #expect(issue.reason.contains(".plus"), "\(issue.reason)")
        }

        for schema in [
            "root = \"x\" .cat a\na = 3",
            "root = (\"x\" .cat a) / tstr\na = 3",
            "root = \"x\" .det a\na = 3",
        ] {
            let verdict = await jsonResult(schema, #""a""#)
            guard case .invalidSchema? = verdict else {
                Issue.record("\(schema) gave \(jsonRendered(verdict))")
                continue
            }
        }
    }

    /// The same operators over operands the schema does define stay on the
    /// channel that answers for the data.
    @Test func soundControlOperandStaysOnTheDataChannelInBothValidators() async {
        let schema = "root = int .eq (1 .plus 2)"
        await expectJSONValid(schema, "3")
        #expect(await P.reasons(schema, P.int(4)) == ["expected value 3, got Integer(4)"])
        #expect(await J.reasons(schema, "4") == ["expected value 3, got 4"])
    }

    /// A document is one value, and what follows it is outside the document:
    /// such input is refused at the framing level, not reported as a mismatch.
    @Test func inputCarryingMoreThanOneDocumentIsRefusedByBothValidators() async {
        for (schema, document) in [("root = uint", "5 6"), ("root = [int]", "[1] null")] {
            let verdict = await jsonResult(schema, document)
            guard case .jsonParsing? = verdict else {
                Issue.record("\(schema): \(jsonRendered(verdict))")
                continue
            }
        }
    }

    /// Input that is exactly one document is admitted.
    @Test func inputThatIsExactlyOneDocumentIsAdmittedByBothValidators() async {
        await expectJSONValid("root = uint", "5")
        await expectJSONValid("root = [int]", "[1]")
    }

    /// A document that did not parse and a schema that did not parse are two
    /// faults, kept apart.
    @Test func undecodableDocumentAndUnparseableSchemaAreSeparateFaultsInBothValidators() async {
        let schema = "root = uint"
        var verdict = await jsonResult(schema, "{")
        guard case .jsonParsing? = verdict else {
            Issue.record("a document that did not parse gave \(jsonRendered(verdict))")
            return
        }
        #expect(!jsonRendered(verdict).contains("CDDL"), "\(jsonRendered(verdict))")

        verdict = await jsonResult("root = = uint", "5")
        guard case .cddlParsing? = verdict else {
            Issue.record("a schema that did not parse gave \(jsonRendered(verdict))")
            return
        }

        await expectJSONValid(schema, "5")
    }

    /// A type choice at every level of a nested document is settled the same
    /// way, however deep the nesting goes.
    @Test func aTypeChoiceAtEveryLevelIsSettledAlikeByBothValidators() async {
        let arraySchema = "x = tstr / bool / [* x] / uint"
        let mapSchema = "x = tstr / bool / {* tstr => x} / uint"
        for levels in [0, 1, 2, 8, 40, cborParityNestedChoiceDepth] {
            #expect(await J.reasons(arraySchema, J.nested(levels, "[", "]", "5")) == [], "\(levels) levels")
            #expect(await J.reasons(mapSchema, J.nested(levels, "{\"k\":", "}", "5")) == [], "\(levels) levels")
            #expect(!(await J.reasons(arraySchema, J.nested(levels, "[", "]", "-1"))).isEmpty, "\(levels) levels")
            #expect(!(await J.reasons(mapSchema, J.nested(levels, "{\"k\":", "}", "-1"))).isEmpty, "\(levels) levels")
        }
    }

    /// RFC 9165 Section 3 `.abnf` controllers, well formed and not. This
    /// implementation does not provide `.abnf`: a grammar reached is reported
    /// as unsupported, and a controller that is a computation the schema cannot
    /// carry out is a fault in the schema before any grammar is read -- the
    /// same way on both channels.
    @Test func abnfControllerAndTargetFaultsAreSeparatedAlikeByBothValidators() async {
        for cddl in [
            #"root = tstr .abnf "oct\noct = %x61-63\n""#,
            "root = tstr .abnf 'oct\noct = %x61-63\n'",
            #"root = tstr .abnf ("oct" .cat "\noct = %x61-63\n")"#,
            #"root = tstr .abnf "oct = %x61-63""#,
            "root = tstr .abnf 'oct = %x61-63'",
            #"root = tstr .abnf "missing\noct = %x61-63\n""#,
            #"root = tstr .abnf h'ff'"#,
        ] {
            for document in [#""a""#, #""z""#] {
                let verdict = await jsonResult(cddl, document)
                guard case .unsupported? = verdict else {
                    Issue.record("\(cddl) against \(document): \(jsonRendered(verdict))")
                    continue
                }
            }
        }

        for cddl in [
            #"root = tstr .abnf ("x")"#,
            #"root = tstr .abnf (1)"#,
            "root = tstr .abnf (a)\na = \"x\"\n",
            #"root = tstr .abnf ("x" .cat undef)"#,
        ] {
            let verdict = await jsonResult(cddl, #""a""#)
            guard case .invalidSchema? = verdict else {
                Issue.record("\(cddl): \(jsonRendered(verdict))")
                continue
            }
        }
    }

    /// A byte string literal and a text string are distinct types whatever
    /// their content: `.ne` against one is satisfied by every text document
    /// and `.eq` by none, worded alike by both validators.
    @Test func byteStringLiteralAgainstATextDocumentIsSettledAlikeByBothValidators() async {
        for controller in ["'x'", "h'78'", "b64'eA=='"] {
            for document in ["x", "a"] {
                let json = "\"\(document)\""
                #expect(await J.reasons("root = tstr .ne \(controller)", json) == [])

                let equal = "root = tstr .eq \(controller)"
                let reasons = await P.reasons(equal, P.text(document))
                #expect(await J.reasons(equal, json) == reasons, "\(equal) against \(document)")
                #expect(
                    reasons.first.map { $0.hasPrefix("expected value ") && $0.hasSuffix("got \"\(document)\"") } == true,
                    "\(reasons)")
            }
        }
    }

    /// A byte string literal reached with no control operator describes a
    /// value, and no string is one; both validators name it alike.
    @Test func byteStringLiteralAsADataItemIsWordedAlikeByBothValidators() async {
        #expect(await J.reasons("root = 'x'", #""x""#) == (await P.reasons("root = 'x'", P.text("x"))))
        #expect(
            await J.reasons("root = ['x']", #"["x"]"#) == (await P.reasons("root = ['x']", P.array([P.text("x")]))))
        #expect(await J.reasons("root = ['x']", #"["y"]"#) == [#"expected value 'x', got "y""#])
    }

    /// `.eq` states that the value is one of the values its controller
    /// denotes, and `.ne` the negation of that.
    @Test func equalityAndExclusionAnswerForControllerMembershipInBothValidators() async {
        #expect(await J.settledAlike(#"root = tstr .eq "x""#, P.text("x"), #""x""#))
        #expect(!(await J.settledAlike(#"root = tstr .eq "x""#, P.text("y"), #""y""#)))
        #expect(await J.settledAlike("root = tstr .eq tstr", P.text("x"), #""x""#))
        #expect(!(await J.settledAlike("root = any .eq tstr", P.int(3), "3")))

        #expect(!(await J.settledAlike(#"root = tstr .ne "x""#, P.text("x"), #""x""#)))
        #expect(await J.settledAlike(#"root = tstr .ne "x""#, P.text("y"), #""y""#))
        #expect(!(await J.settledAlike("root = tstr .ne tstr", P.text("x"), #""x""#)))
        #expect(await J.settledAlike("root = any .ne tstr", P.int(3), "3"))

        #expect(!(await J.settledAlike("root = tstr .ne c\nc = \"x\"", P.text("x"), #""x""#)))
        #expect(await J.settledAlike("root = tstr .ne c\nc = \"x\"", P.text("y"), #""y""#))
        #expect(!(await J.settledAlike("root = tstr .ne c\nc = tstr", P.text("x"), #""x""#)))
        #expect(await J.settledAlike("root = tstr .ne c\nc = uint", P.text("x"), #""x""#))
    }

    /// The exclusion `.ne` states holds against every shape a controller can
    /// denote.
    @Test func exclusionCoversEveryShapeOfControllerInBothValidators() async {
        let cases: [(String, CBORNode, String, CBORNode, String)] = [
            (#"root = tstr .ne ("x" / "y")"#, P.text("z"), #""z""#, P.text("x"), #""x""#),
            ("root = int .ne (0..10)", P.int(11), "11", P.int(5), "5"),
            ("root = [* int] .ne [int]", P.array([P.int(1), P.int(2)]), "[1,2]", P.array([P.int(1)]), "[1]"),
        ]
        for (schema, excluded, excludedJSON, member, memberJSON) in cases {
            #expect(await J.settledAlike(schema, excluded, excludedJSON), "\(schema)")
            #expect(!(await J.settledAlike(schema, member, memberJSON)), "\(schema)")
        }
    }

    /// `.and` and `.within` both state the intersection of their two types.
    @Test func intersectionOperatorsResolveATypeControllerInBothValidators() async {
        for schema in [
            "root = uint .and uint",
            "root = uint .within number",
            "root = uint .and c\nc = uint",
            "root = uint .within c\nc = number",
            "root = uint .and 3",
            "root = uint .within (0..10)",
        ] {
            #expect(await J.settledAlike(schema, P.int(3), "3"), "\(schema)")
        }
        for schema in [
            "root = uint .and nint",
            "root = uint .within nint",
            "root = uint .and c\nc = nint",
            "root = uint .within c\nc = nint",
            "root = uint .and 4",
            "root = uint .within (4..10)",
        ] {
            #expect(!(await J.settledAlike(schema, P.int(3), "3")), "\(schema)")
        }
    }

    /// `.cat`, `.det` and `.plus` stand for the value they compute, so an
    /// operand that denotes no value is a fault in the schema whatever the
    /// document holds.
    @Test func computingOperatorsRaiseAnUnusableTargetOnTheSchemaChannel() async {
        for schema in [
            #"root = bstr .cat "x""#,
            #"root = bstr .det "x""#,
            #"root = tstr .cat "x""#,
            #"root = tstr .det "x""#,
            "root = uint .plus 1",
            "root = int .plus 1",
        ] {
            for document in [#""x""#, "3", "true"] {
                let verdict = await jsonResult(schema, document)
                guard case .invalidSchema(let issue)? = verdict else {
                    Issue.record("\(schema) against \(document) gave \(jsonRendered(verdict))")
                    continue
                }
                #expect(issue.reason.contains("target of"), "\(schema): \(issue.reason)")
            }
        }

        #expect(await J.settledAlike(#"root = "a" .cat "b""#, P.text("ab"), #""ab""#))
        #expect(!(await J.settledAlike(#"root = "a" .cat "b""#, P.text("ac"), #""ac""#)))
        #expect(await J.settledAlike("root = 1 .plus 2", P.int(3), "3"))
        #expect(!(await J.settledAlike("root = 1 .plus 2", P.int(4), "4")))
    }

    /// The type a control operator's target names is a precondition for the
    /// control, and a number written with a fraction is not an integer.
    @Test func aControlTargetIsHeldToItsOwnTypeAlikeByBothValidators() async {
        for schema in [#"root = int .ne "x""#, "root = int .gt 1", "root = nint .ne -2", "root = uint .ne 5"] {
            #expect(!(await J.settledAlike(schema, P.float(1.5), "1.5")), "\(schema)")
        }
        for schema in ["root = float .ne 2.5", "root = float .gt 1.0"] {
            #expect(!(await J.settledAlike(schema, P.int(3), "3")), "\(schema)")
            #expect(await J.settledAlike(schema, P.float(1.5), "1.5"), "\(schema)")
        }
    }

    /// A walk exponential in the nesting is stopped at the bound on work, and
    /// the refusal worded the same way by both validators.
    @Test func aWalkExponentialInTheNestingIsStoppedAlikeByBothValidators() async {
        let schema = "x = a / b / uint\na = [x]\nb = [x]\n"
        let levels = 40
        let limits = ValidationLimits(maxValidationWork: 50_000)
        let named = "maximum supported \(limits.maxValidationWork) steps of validation work"

        let cbor = await P.limited(schema, P.nestedArrays(levels, P.text("no alternative admits this")).encoded(), limits)
        let json = await J.limited(schema, J.nested(levels, "[", "]", #""no alternative admits this""#), limits)
        #expect(jsonRendered(json).contains(named), "\(jsonRendered(json))")
        #expect(cbor.map { "\($0)" }?.contains(named) == true)

        #expect(await J.limited(schema, J.nested(levels, "[", "]", "5"), limits) == nil)
    }

    /// The budget is spent over a run: a budget that fits a document does not
    /// fit twice as much of it, on either channel.
    @Test func theWorkBudgetIsChargedAcrossAWholeDocumentByBothValidators() async {
        let schema = "x = [* uint]"
        func fits(_ items: Int, _ budget: Int) async -> Bool {
            let limits = ValidationLimits(maxValidationWork: budget)
            let node = P.array((0..<items).map { P.int(Int64($0)) })
            let document = "[" + (0..<items).map(String.init).joined(separator: ",") + "]"
            let cbor = await P.limited(schema, node.encoded(), limits) == nil
            let json = await J.limited(schema, document, limits) == nil
            #expect(cbor == json, "\(items) items within \(budget) steps")
            return json
        }

        var cost = 1
        while !(await fits(16, cost)) {
            cost += 1
            if cost >= 10_000 {
                Issue.record("sixteen items cost more than the search")
                return
            }
        }
        #expect(!(await fits(32, cost)))
    }

    /// A payload a text conversion control decodes is walked on the budget of
    /// the run that reached it, alike on both channels.
    @Test func textConversionPayloadsShareOneWorkBudgetOnBothChannels() async {
        let schema = "root = [* (tstr .hex inner)]\ninner = bstr .cbor [* uint]\n"
        let payload = hexString(P.array((0..<8).map { P.int(Int64($0)) }).encoded())

        func fits(_ payloads: Int, _ budget: Int) async -> Bool {
            let limits = ValidationLimits(maxValidationWork: budget)
            let node = P.array(Array(repeating: P.text(payload), count: payloads))
            let document = "[" + Array(repeating: "\"\(payload)\"", count: payloads).joined(separator: ",") + "]"
            let cbor = await P.limited(schema, node.encoded(), limits) == nil
            let json = await J.limited(schema, document, limits) == nil
            #expect(cbor == json, "\(payloads) payloads within \(budget) steps")
            return json
        }

        var cost = 1
        while !(await fits(1, cost)) {
            cost += 1
            if cost >= 10_000 {
                Issue.record("one payload costs more than the search")
                return
            }
        }
        #expect(!(await fits(2, cost)))
        #expect(await fits(2, cost * 3))
    }

    /// A chain of rule references at every level is bounded by the descent
    /// budget, and reported alike by both validators.
    @Test func aRuleChainAtEveryLevelIsBoundedByTheDescentBudgetInBothValidators() async {
        let prelude = P.chainedAliases(63)
        await J.assertSettledInEveryPlacement(prelude, "x", admitted: [J.nestedEmptyArrays(2)], refused: ["5"])

        let schema = "root = x\(prelude)"
        let named = "maximum supported descent budget of \(ValidationLimits.defaultMaxDescentCost) bytes"
        let verdict = await jsonResult(schema, J.nestedEmptyArrays(1000))
        #expect(jsonRendered(verdict).contains(named), "\(jsonRendered(verdict).prefix(300))")
    }

    /// A level of the data is charged to the descent budget as well as a
    /// reference resolved against it.
    @Test func aDeepDocumentIsBoundedByTheDescentBudgetInBothValidators() async {
        let schema = "x = [* x]"
        let limits = ValidationLimits(maxDescentCost: 160_000)

        func settled(_ levels: Int) async -> (Bool, String) {
            let cbor = await P.limited(schema, P.nestedEmptyArrays(levels).encoded(), limits)
            let json = await J.limited(schema, J.nestedEmptyArrays(levels), limits)
            #expect((cbor == nil) == (json == nil), "the two validators disagree at \(levels) levels")
            return (json == nil, jsonRendered(json))
        }

        #expect(await settled(5).0, "five levels are inside the budget")
        let (admitted, message) = await settled(20)
        #expect(!admitted, "twenty levels are not")
        #expect(message.contains("maximum supported descent budget of \(limits.maxDescentCost) bytes"), "\(message)")
    }

    /// What the failed alternatives of a choice recorded is charged to the
    /// descent budget in the bytes the records hold, by both validators.
    @Test func whatAFailedAlternativeRecordedIsChargedToTheDescentByBothValidators() async {
        let levels = 5
        let texts = (0..<20).map { "\"k\($0)\" / " }.joined()
        let arraysDocument = J.nested(levels, "[", "]", #""k0""#)
        let mapsDocument = J.nested(levels, "{\"k\":", "}", #""k0""#)
        let arraysNode = P.nestedArrays(levels, P.text("k0"))
        let mapsNode = P.nestedMaps(levels, P.text("k0"))

        let two = ("x = [* x] / \"k0\"\n", arraysDocument, arraysNode)
        let arrays = ("x = (\(texts)[* x] / uint)\n", arraysDocument, arraysNode)
        let maps = ("x = \(texts){k: x} / uint\n", mapsDocument, mapsNode)

        func verdictText(_ verdict: [String]?) -> String {
            guard let reasons = verdict else { return "valid" }
            if !reasons.isEmpty && reasons.allSatisfy({ $0.contains("maximum supported descent budget") }) {
                return "budget"
            }
            return "invalid: \(reasons)"
        }
        func jsonVerdict(_ schema: String, _ document: String, _ budget: Int) async -> String {
            let verdict = await J.limited(schema, document, ValidationLimits(maxDescentCost: budget))
            guard let verdict else { return "valid" }
            guard let issues = verdict.issues else {
                Issue.record("expected validation errors, got \(verdict)")
                return "fault"
            }
            return verdictText(issues.map(\.reason))
        }
        func cborVerdict(_ schema: String, _ node: CBORNode, _ budget: Int) async -> String {
            let verdict = await P.limited(schema, node.encoded(), ValidationLimits(maxDescentCost: budget))
            guard let verdict else { return "valid" }
            guard let issues = verdict.issues else {
                Issue.record("expected validation errors, got \(verdict)")
                return "fault"
            }
            return verdictText(issues.map(\.reason))
        }
        func smallestAdmitting(_ admits: (Int) async -> Bool) async -> Int {
            var refused = 0
            var admitted = 1 << 24
            #expect(await admits(admitted))
            while admitted - refused > 1 {
                let mid = refused + (admitted - refused) / 2
                if await admits(mid) {
                    admitted = mid
                } else {
                    refused = mid
                }
            }
            return admitted
        }

        let cborCarries = await smallestAdmitting { await cborVerdict(two.0, two.2, $0) == "valid" }
        let jsonCarries = await smallestAdmitting { await jsonVerdict(two.0, two.1, $0) == "valid" }
        let carries = max(cborCarries, jsonCarries) + 2048

        for (testCase, budget, expected) in [
            (two, carries, "valid"),
            (arrays, carries, "budget"),
            (maps, carries, "budget"),
            (arrays, 64 * carries, "valid"),
            (maps, 64 * carries, "valid"),
        ] {
            #expect(await jsonVerdict(testCase.0, testCase.1, budget) == expected, "json \(testCase.0) at \(budget)")
            #expect(await cborVerdict(testCase.0, testCase.2, budget) == expected, "cbor \(testCase.0) at \(budget)")
        }
    }

    /// A document nested ten thousand levels deep is settled with the verdict
    /// its leaf decides, and a refused leaf is named by its own location.
    @Test func aDocumentNestedTenThousandLevelsIsSettledOnASmallStackByBothValidators() async {
        let levels = 10_000

        var schema = "x = [* x] / uint"
        #expect(await J.errors(schema, J.nested(levels, "[", "]", "5")).isEmpty)
        var errors = await J.errors(schema, J.nested(levels, "[", "]", #""""#))
        var leaf = String(repeating: "/0", count: levels)
        #expect(errors.contains { $0.jsonLocation == leaf && $0.reason.contains("expected type uint") }, "the leaf is named")

        schema = "x = {* tstr => x} / uint"
        #expect(await J.errors(schema, J.nested(levels, "{\"k\":", "}", "5")).isEmpty)
        errors = await J.errors(schema, J.nested(levels, "{\"k\":", "}", #""""#))
        leaf = String(repeating: "/k", count: levels)
        #expect(errors.contains { $0.jsonLocation == leaf && $0.reason.contains("expected type uint") }, "the leaf is named")
    }

    /// A choice of well over a hundred alternatives that fail at every level
    /// is refused by the descent budget before the nesting bound is reached.
    @Test func aChoiceOfManyAlternativesIsRefusedByTheDescentBudgetBeforeTheNestingBound() async {
        var schema = "x = c<x> / {* x => x} / [* x] / int / bstr\nc<a> = #6.102([uint, [* a]])"
        for tag in Array(121...127) + Array(1280...1400) {
            schema += " / #6.\(tag)([* a])"
        }
        schema += "\n"

        let budget = "maximum supported descent budget of \(ValidationLimits.defaultMaxDescentCost) bytes"
        let depthBound = "maximum supported nesting depth of \(ValidationLimits.defaultMaxNestingDepth)"

        #expect(await J.errors(schema, J.nested(2_000, "[", "]", "0")).isEmpty)

        // The records held differ in size between implementations, so the depth
        // at which the budget runs out is not compared, only the verdict.
        let message = jsonRendered(await jsonResult(schema, J.nested(16_000, "[", "]", "0"), compareErrors: false))
        #expect(message.contains(budget), "\(message.prefix(300))")
        #expect(!message.contains(depthBound), "\(message.prefix(300))")
    }

    /// The alternatives of a type choice are evaluated apart: what one records
    /// is not seen by the next, at any depth.
    @Test func anAlternativeDoesNotSeeWhatTheAlternativeBeforeItRecordedInBothValidators() async {
        let mapSchema = "x = {* tstr => tstr} / {k: x} / uint"
        #expect(await J.errors(mapSchema, #"{"k":{"k":{"k":5}}}"#).isEmpty)
        #expect(!(await J.errors(mapSchema, #"{"k":{"k":{"k":5,"extra":1}}}"#)).isEmpty)

        let arraySchema = "x = [tstr, * x] / [x] / uint"
        #expect(await J.errors(arraySchema, "[[[5]]]").isEmpty)
        #expect(!(await J.errors(arraySchema, "[[[5,1]]]")).isEmpty)
    }
}
