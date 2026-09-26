import Foundation
import Testing

@testable import SwiftCDDL

// Unit tests of the JSON validator (RFC 8610 against RFC 8259 documents),
// first part: literals, controls, limits, time and error reporting.

/// A validator of the document `json` against the schema `cddl`.
func jsonUnitValidator(_ cddl: String, _ json: String, enabledFeatures: [String]? = nil) throws -> JSONValidator {
    JSONValidator(cddl: try cddlFromStr(cddl), json: try JSONNode.parse(json), enabledFeatures: enabledFeatures)
}

/// Runs `validator`, returning the failure or `nil` when the document matched.
func jsonUnitVerdict(_ validator: JSONValidator) async -> JSONVerdict {
    do {
        try await validator.validate()
        return nil
    } catch {
        return error
    }
}

/// Whether `json` matches `cddl`; the verdict alone is under test.
func jsonAccepts(_ cddl: String, _ json: String, sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
    await jsonResult(cddl, json, sourceLocation: sourceLocation) == nil
}

/// The rendered text of a failure, or the empty string for a match.
func jsonRendered(_ verdict: JSONVerdict) -> String {
    verdict.map { "\($0)" } ?? ""
}

/// `1` nested inside `levels` one-element arrays.
private func nestedJSON(_ leaf: String, levels: Int) -> String {
    String(repeating: "[", count: levels) + leaf + String(repeating: "]", count: levels)
}

/// Tests of the JSON validator's literals, controls, limits, time handling
/// and error reporting.
@Suite struct JSONValidatorUnitTests {
    /// An unwrapped name is a rule reference resolved against the item already
    /// held: a chain of them against one item answers to the bound on rule
    /// nesting, and a rule reached again through one without any data consumed
    /// is a cycle rather than a walk.
    @Test func validateUnwrapResolvesAgainstTheSameItemUnderTheRuleNestingBound() async throws {
        let cddl = "x = [~y] / uint\ny = [~z]\nz = [~w]\nw = [uint]\n"
        for (maxRuleNesting, admitted) in [(4, true), (2, false)] {
            let validator = try jsonUnitValidator(cddl, "[1]")
            validator.setMaxRuleNesting(maxRuleNesting)
            let verdict = await jsonUnitVerdict(validator)
            if admitted {
                #expect(verdict == nil, "three unwraps against one array are within a bound of four")
            } else {
                #expect(jsonRendered(verdict).contains("maximum supported rule nesting"), "\(jsonRendered(verdict))")
            }
        }

        let verdict = await jsonUnitVerdict(try jsonUnitValidator("x = [~x] / uint\n", "[1]"))
        #expect(
            jsonRendered(verdict).contains("rule x is defined in terms of itself without consuming any data"),
            "\(jsonRendered(verdict))")
    }

    /// A range controller of a comparison operator names every value between
    /// its bounds, and the comparison holds when it holds against all of them:
    /// the greatest member for `.gt` and `.ge`, the least for `.lt` and `.le`.
    /// The upper bound of an exclusive range is not a member of it.
    @Test func validateComparisonAgainstIntRangeController() async {
        // (operator, inclusive upper bound, value, holds)
        let cases: [(String, Bool, String, Bool)] = [
            (".gt", true, "50", true),
            (".gt", true, "11", true),
            (".gt", true, "10", false),
            (".gt", true, "5", false),
            (".gt", true, "-1", false),
            (".ge", true, "50", true),
            (".ge", true, "10", true),
            (".ge", true, "5", false),
            (".lt", true, "-1", true),
            (".lt", true, "0", false),
            (".lt", true, "50", false),
            (".le", true, "-1", true),
            (".le", true, "0", true),
            (".le", true, "5", false),
            // The exclusive range 0...10 holds 0 through 9.
            (".gt", false, "10", true),
            (".gt", false, "9", false),
            (".ge", false, "10", true),
            (".ge", false, "9", true),
            (".ge", false, "8", false),
            (".le", false, "0", true),
            (".le", false, "1", false),
        ]
        for (control, isInclusive, value, holds) in cases {
            let range = isInclusive ? ".." : "..."
            let cddl = "start = int \(control) (0\(range)10)"
            #expect(await jsonAccepts(cddl, value) == holds, "int \(control) (0\(range)10) against \(value)")
        }
    }

    /// A float range with an exclusive upper bound has no greatest member, and a
    /// value stands above every member of one exactly when it reaches the bound
    /// the range stops short of.
    @Test func validateComparisonAgainstFloatRangeController() async {
        let cases: [(String, Bool, String, Bool)] = [
            (".gt", true, "50.0", true),
            (".gt", true, "10.0", false),
            (".ge", true, "10.0", true),
            (".ge", true, "9.5", false),
            (".lt", true, "-0.5", true),
            (".lt", true, "0.0", false),
            (".le", true, "0.0", true),
            (".le", true, "5.0", false),
            (".gt", false, "10.0", true),
            (".gt", false, "9.5", false),
            (".ge", false, "10.0", true),
            (".ge", false, "9.5", false),
        ]
        for (control, isInclusive, value, holds) in cases {
            let range = isInclusive ? ".." : "..."
            let cddl = "start = float \(control) (0.0\(range)10.0)"
            #expect(await jsonAccepts(cddl, value) == holds, "float \(control) (0.0\(range)10.0) against \(value)")
        }
    }

    /// A range that holds no value at all resolves to no bound to compare
    /// against, and is reported as the malformed range it is rather than
    /// admitting or excluding everything.
    @Test func validateComparisonAgainstEmptyRangeController() async {
        for cddl in ["start = int .gt (0...0)", "start = int .lt (5..3)"] {
            let verdict = await jsonResult(cddl, "50")
            #expect(jsonRendered(verdict).contains("holds no values to compare against"), "\(jsonRendered(verdict))")
        }
    }

    /// Only the bits numbered by a member of the control type are allowed to be
    /// set. The control says nothing about which bits must be set, so a value
    /// with no bit set always holds; a value with a bit the control type does
    /// not name does not.
    @Test func validateBits() async {
        let cddl = """
            start = uint .bits flags
            flags = &(
              low: 0,
              mid: 2,
            ) / (4..5)
            """

        // Bits 0, 2, 4 and 5 are named; 0 sets none of them.
        for admitted in ["0", "1", "4", "5", "16", "48", "53"] {
            #expect(await jsonAccepts(cddl, admitted), "admitted \(admitted)")
        }

        // Bits 1, 3 and 6 are named by neither alternative.
        for rejected in ["2", "8", "64", "3", "255"] {
            #expect(!(await jsonAccepts(cddl, rejected)), "rejected \(rejected)")
        }

        // The JSON data model has no byte strings, and the bits of a number
        // that is not a non-negative integer are not defined.
        for rejected in [#""abc""#, "-1", "1.5", "null"] {
            #expect(!(await jsonAccepts(cddl, rejected)), "rejected non-uint \(rejected)")
        }
    }

    /// The two validators agree on `.bits`: the control is decided from the
    /// bits set in the value, which the two data models represent the same way.
    @Test func validateBitsAgreesWithCBOR() async {
        let cddl = "start = uint .bits (0..3)"
        for value: UInt64 in [0, 1, 5, 8, 15, 16, 255] {
            let json = await jsonAccepts(cddl, String(value))
            let cbor = await cborResult(cddl, CBORNode.unsigned(value).encoded()) == nil
            #expect(json == cbor, "verdicts differ for \(value)")
        }
    }

    @Test func validateNumberAcceptsFloatAndInt() async throws {
        for json in ["2.5", "5"] {
            let verdict = await jsonUnitVerdict(try jsonUnitValidator("x = number", json))
            #expect(verdict == nil, "number should accept \(json)")
        }
    }

    @Test func validatePlus() async {
        let cddl = """
            interval<BASE> = (
              "test" => BASE .plus a
            )

            rect = {
              interval<X>
            }
            X = 0
            a = 10
            """
        await expectJSONValid(cddl, #"{ "test": 10 }"#)
    }

    @Test func validateFeature() async throws {
        let cddl = """
            v = JC<"v", 2>
            JC<J, C> =  C .feature "cbor" / J .feature "json"
            """
        let verdict = await jsonUnitVerdict(try jsonUnitValidator(cddl, #""v""#, enabledFeatures: ["json"]))
        #expect(verdict == nil, "\(jsonRendered(verdict))")
    }

    @Test func validateTypeChoiceAlternate() async {
        let cddl = """
            tester = [ $vals ]
            $vals /= 12
            $vals /= 13
            """
        await expectJSONValid(cddl, "[ 13 ]")
    }

    @Test func validateGroupChoiceAlternate() async {
        let cddl = """
            tester = $$vals
            $$vals //= 18
            $$vals //= 12
            """
        await expectJSONValid(cddl, "15")
    }

    @Test func validateGroupChoiceAlternateInArray1() async {
        let cddl = """
            tester = [$$val]
            $$val //= (
              type: 10,
              data: uint,
              t: 11
            )
            $$val //= (
              type: 11,
              data: tstr
            )
            """
        await expectJSONValid(cddl, "[10, 11, 11]")
    }

    @Test func validateGroupChoiceAlternateInArray2() async {
        let cddl = """
            tester = [$$val]
            $$val //= (
              type: 10,
              extra,
            )
            extra = (
              something: uint,
            )
            """
        await expectJSONValid(cddl, "[10, 1]")
    }

    @Test func sizeControlValidationError() async {
        let cddl = """
            start = Record
            Record = {
              id: Id
            }
            Id = uint .size 8
            """
        await expectJSONValid(cddl, #"{ "id": 5 }"#)
    }

    @Test func validateOccurrencesInObject() async {
        await expectJSONValid("limited = { 1* tstr => tstr }", #"{ "A": "B" }"#)
    }

    @Test func validateOptionalOccurrencesInObject() async {
        let cddl = """
            argument = {
              name: text,
              ? valid: "yes" / "no",
            }
            """
        await expectJSONValid(cddl, #"{ "name": "foo", "valid": "no" }"#)
    }

    @Test func validateRangeOperators() async {
        // An inclusive range (..).
        await expectJSONValid("thing = 5..10", "5")
        await expectJSONValid("thing = 5..10", "10")
        await expectJSONInvalid("thing = 5..10", "4")
        await expectJSONInvalid("thing = 5..10", "11")

        // A range excluding its upper bound (...).
        await expectJSONValid("thing = 5...10", "5")
        await expectJSONValid("thing = 5...10", "9")
        await expectJSONInvalid("thing = 5...10", "10")
        await expectJSONInvalid("thing = 5...10", "4")

        // The same with floats.
        await expectJSONValid("thing = 1.5...3.5", "1.5")
        await expectJSONValid("thing = 1.5...3.5", "2.5")
        await expectJSONInvalid("thing = 1.5...3.5", "3.5")
        await expectJSONInvalid("thing = 1.5...3.5", "1.0")

        // A range bounding the length of a string under `.size`.
        await expectJSONValid("thing = tstr .size (2...5)", #""ab""#)
        await expectJSONValid("thing = tstr .size (2...5)", #""abcd""#)
        await expectJSONInvalid("thing = tstr .size (2...5)", #""abcde""#)
        await expectJSONInvalid("thing = tstr .size (2...5)", #""a""#)
    }

    @Test func validateNestedArrays() async {
        await expectJSONValid("array = [0, [* int]]", "[0, [1, 2]]")
        await expectJSONValid("root = [0, inner]\ninner = [* int]", "[0, [1, 2]]")
        await expectJSONValid("direct = [1, [2, 3]]", "[1, [2, 3]]")
    }

    @Test func validateDirectNestedArray() async {
        await expectJSONValid("direct = [1, [2, 3]]", "[1, [2, 3]]")
    }

    /// An empty map schema admits no object holding a member.
    @Test func testIssue221EmptyMapWithExtraKeys() async {
        let reported = jsonIssues(await jsonResult("root = {}", #"{"x": "y"}"#))
        #expect(reported.count == 1)
        #expect(reported.first?.reason.contains("expected empty map") == true)
    }

    @Test func testEmptyMapSchemaWithEmptyJSON() async {
        await expectJSONValid("root = {}", "{}")
    }

    /// A choice fails when neither alternative admits the document.
    @Test func testIssue174ChoiceValidation() async {
        let cddl = """
            Root = Choice1 / Choice2

            Choice1 = {
               id1: text,
               ?id2: text,
               Extensible
            }

            Choice2 = {
               ?id1: text,
               id2: text,
               Extensible
            }

            Extensible = (*text => any)
            """

        // `id2` is not text in either choice.
        #expect(!jsonIssues(await jsonResult(cddl, #"{"id1": "example", "id2": 2}"#)).isEmpty)

        for valid in [
            #"{"id1": "example", "id2": "text"}"#,
            #"{"id1": "example"}"#,
            #"{"id2": "text"}"#,
        ] {
            await expectJSONValid(cddl, valid)
        }
    }

    @Test func testIssue221ReproduceExactScenario() async {
        let reported = jsonIssues(await jsonResult("root = {}", #"{"x": "y"}"#))
        #expect(!reported.isEmpty)
        #expect(reported.first?.reason.contains("expected empty map") == true, "\(reported)")
    }

    /// RFC 9165 Section 3 `.abnf` with a `.det` controller naming a rule. This
    /// implementation does not provide `.abnf`, so the schema is reported as
    /// using a feature that is not supported.
    @Test func validateAbnfWithDetTypenameController() async {
        let cddl = """
            start = sdf-syntax

            sdf-syntax = {
              ? info: sdfinfo
            }

            sdfinfo = {
              ? modified: modified-date-time
            }

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
        for json in [
            #"{ "info": { "modified": "1985-04-12T23:20:50.52Z" } }"#,
            #"{ "info": { "modified": "not-a-date" } }"#,
        ] {
            let verdict = await jsonResult(cddl, json)
            guard case .unsupported? = verdict else {
                Issue.record("expected .abnf to be reported as unsupported, got \(jsonRendered(verdict))")
                continue
            }
        }
    }

    /// A type choice whose alternatives cannot be told apart at the head of the
    /// value evaluates each of them in turn, and each one that descends walks
    /// everything below it again, so the alternatives multiply level by level.
    /// The run stops at the work bound and says so.
    @Test func validateChoiceAlternativesThatAllDescendStopAtTheWorkBound() async {
        let cddl = "x = a / b / uint\na = [x]\nb = [x]\n"
        let document = nestedJSON(#""no alternative admits this""#, levels: 40)
        let verdict = await jsonResult(cddl, document, limits: ValidationLimits(maxValidationWork: 50_000))
        #expect(jsonRendered(verdict).contains("steps of validation work"), "\(jsonRendered(verdict))")
    }

    /// Whether a run completed within `budget`, told apart from a run that
    /// completed and found a mismatch: only the budget is under test here.
    private func validatesWithin(_ cddl: String, _ json: String, _ budget: Int) async -> Bool {
        let verdict = await jsonResult(cddl, json, limits: ValidationLimits(maxValidationWork: budget))
        switch verdict {
        case nil:
            return true
        case .validation(let issues)?:
            return !issues.contains { $0.reason.contains("steps of validation work") }
        case let other?:
            Issue.record("unexpected failure: \(other)")
            return false
        }
    }

    /// The steps one run spends: the smallest budget it completes on.
    private func smallestBudgetThatReturns(_ cddl: String, _ json: String) async -> Int {
        var lo = 0
        var hi = 1_000_000
        #expect(await validatesWithin(cddl, json, hi), "the run does not complete within the search ceiling")
        while lo < hi {
            let mid = lo + (hi - lo) / 2
            if await validatesWithin(cddl, json, mid) {
                hi = mid
            } else {
                lo = mid + 1
            }
        }
        return lo
    }

    /// The budget belongs to the run, not to the level holding it: two
    /// documents of the same shape, one twice the other, cost differently.
    @Test func theWorkBudgetIsSpentOverTheWholeRun() async {
        let cddl = "x = [* uint]"
        func items(_ n: Int) -> String {
            "[" + (0..<n).map(String.init).joined(separator: ",") + "]"
        }
        let cost = await smallestBudgetThatReturns(cddl, items(16))
        #expect(
            await smallestBudgetThatReturns(cddl, items(32)) > cost,
            "a document twice the size cost no more than the budget the half of it did")
    }

    /// A run that costs exactly the budget it is given completes, and the same
    /// run one step short of it does not.
    @Test func aRunCostingExactlyTheBudgetCompletes() async {
        let cddl = "x = [* uint]"
        let document = "[0,1,2,3,4,5,6,7]"
        let cost = await smallestBudgetThatReturns(cddl, document)
        #expect(cost > 1, "the run has to cost something to have a boundary")
        #expect(await validatesWithin(cddl, document, cost))
        #expect(!(await validatesWithin(cddl, document, cost - 1)))
    }

    /// The bound on how far validation descends is consumed only by the steps
    /// it takes, so a schema that stops above the nesting imposes nothing on
    /// what lies below it.
    @Test func validateNestingBoundIsConsumedOnlyByDescending() async throws {
        let json = "[[[[[[[[1]]]]]]]]"
        for schema in ["top = any\n", "top = [any]\n", "top = [[any]]\n"] {
            let validator = try jsonUnitValidator(schema, json)
            validator.setMaxNestingDepth(2)
            let verdict = await jsonUnitVerdict(validator)
            #expect(verdict == nil, "\(schema): \(jsonRendered(verdict))")
        }

        let validator = try jsonUnitValidator("data = int / [* data]\n", json)
        validator.setMaxNestingDepth(2)
        let verdict = await jsonUnitVerdict(validator)
        #expect(jsonRendered(verdict).contains("maximum supported nesting depth of 2"), "\(jsonRendered(verdict))")
    }

    /// `.default` supplies the value an absent optional entry is assumed to
    /// have; a present entry still has to validate against the target.
    @Test func validateLiteralDefaultValue() async {
        for (cddl, matching, other) in [
            (#"start = { ? k: "a" .default "b" }"#, #"{"k":"a"}"#, #"{"k":"c"}"#),
            ("start = { ? k: 1 .default 2 }", #"{"k":1}"#, #"{"k":9}"#),
            ("start = { ? k: 1.5 .default 2.5 }", #"{"k":1.5}"#, #"{"k":9.5}"#),
        ] {
            await expectJSONValid(cddl, matching)
            await expectJSONValid(cddl, "{}")
            await expectJSONInvalid(cddl, other)

            let required = cddl.replacingOccurrences(of: "? k:", with: "k:")
            await expectJSONValid(required, matching)
            await expectJSONInvalid(required, other)
        }
    }

    /// JSON has no byte strings, so a byte string target admits no JSON value,
    /// with or without a control operator applied to it.
    @Test func validateByteStringTargetOfAControlOperator() async {
        for cddl in [#"start = bstr .ne "aa""#, #"start = bstr .eq "aa""#, "start = bstr"] {
            await expectJSONInvalid(cddl, #""aa""#)
        }

        // A target that does name a JSON data type still holds.
        await expectJSONValid(#"start = tstr .eq "aa""#, #""aa""#)
        await expectJSONValid(#"start = tstr .ne "aa""#, #""bb""#)
    }

    /// A base16 literal holds the byte string it denotes, which is what the
    /// encoding a text string is held to is compared against.
    @Test func validateEncodedTextAgainstABase16Controller() async {
        for (cddl, encoded, other) in [
            ("start = tstr .b64u h'0102'", #""AQI""#, #""AQM""#),
            ("start = tstr .hex h'0102'", #""0102""#, #""0103""#),
        ] {
            await expectJSONValid(cddl, encoded)
            await expectJSONInvalid(cddl, other)
        }
    }

    /// The bounds validation runs under limit what the walk holds, so how far
    /// they can be raised follows from the memory the caller has rather than
    /// from the schema.
    @Test func validateJSONFromStrUnderStatedLimits() async {
        let cddl = "data = int / [* data]\n"
        let depth = ValidationLimits.defaultMaxNestingDepth
        let pastTheDefault = nestedJSON("1", levels: depth + 1)

        var verdict = await jsonResult(cddl, pastTheDefault)
        #expect(jsonRendered(verdict).contains("maximum supported nesting depth"), "\(jsonRendered(verdict).prefix(300))")

        verdict = await jsonResult(cddl, pastTheDefault, limits: ValidationLimits(maxNestingDepth: depth + 8))
        #expect(verdict == nil, "\(jsonRendered(verdict).prefix(300))")

        // Raising the other bound says nothing about how deeply the data may
        // nest.
        verdict = await jsonResult(cddl, pastTheDefault, limits: ValidationLimits(maxRuleNesting: 1024))
        #expect(jsonRendered(verdict).contains("maximum supported nesting depth"), "\(jsonRendered(verdict).prefix(300))")

        // A raised bound validates what lies below it rather than admitting it.
        let invalid = nestedJSON("true", levels: depth + 1)
        verdict = await jsonResult(cddl, invalid, limits: ValidationLimits(maxNestingDepth: depth + 8))
        #expect(verdict != nil, "the leaf is not an int")
        #expect(!jsonRendered(verdict).contains("maximum supported nesting depth"))

        // Data within the default bound needs no limits stated for it.
        await expectJSONValid(cddl, nestedJSON("1", levels: 2))
    }

    /// Reaching a bound says that nothing below the point it was reached was
    /// examined, so it is reported once and validation stops there.
    @Test func breachingALimitReportsItOnceAndStops() async {
        let cddl = """
            data = leaf / wrapper / pair
            leaf = int
            wrapper = [data]
            pair = [data, data]
            """
        let json = nestedJSON("1", levels: ValidationLimits.defaultMaxNestingDepth + 4)

        let reported = jsonIssues(await jsonResult(cddl, json))
        #expect(reported.count == 1, "the breach is the whole report, got \(reported.count) errors")
        #expect(reported.first?.reason.contains("maximum supported nesting depth") == true)

        // The same schema still accumulates the mismatches of a document it can
        // walk in full.
        let mismatches = jsonIssues(await jsonResult(cddl, #"["x"]"#))
        #expect(mismatches.count > 1, "every alternative of the choice reports, got \(mismatches)")
    }

    /// An error message names the value that failed to match. Naming it must
    /// cost a bounded amount whatever the document holds, and must still name
    /// a small value in full.
    @Test func validateErrorMessageRendersALargeDataItemWithinTheBound() async {
        func reason(_ json: String) async -> String {
            jsonIssues(await jsonResult("a = tstr", json)).first?.reason ?? ""
        }

        let small = await reason("[1]")
        #expect(small.contains("[1]"), "\(small)")
        #expect(!small.hasSuffix("..."), "\(small)")

        let items = (0..<4096).map(String.init).joined(separator: ",")
        let large = await reason("[\(items)]")
        #expect(large.hasSuffix("..."), "\(large)")
        #expect(large.utf8.count < maxRenderedDataLength * 2, "the message grew with the document")
    }

    /// Bounds of different kinds do not denote a range, so a member key
    /// written as one names no set of keys. The fault is in the schema and has
    /// to be reported as one, including when the object holds no key to ask
    /// about.
    @Test func validateMemberKeyRangeWithBoundsOfDifferentKindsIsASchemaError() async {
        for json in ["{}", #"{"2":1}"#] {
            let verdict = await jsonResult("a = {* 1.5..3 => int}", json)
            #expect(jsonRendered(verdict).contains("must both be integers or both be floats"), "\(jsonRendered(verdict))")
        }

        // The same fault the non-member-key path reports.
        let verdict = await jsonResult("a = 1.5..3", "2")
        #expect(jsonRendered(verdict).contains("must both be integers or both be floats"), "\(jsonRendered(verdict))")

        // Bounds of one kind denote a range, whether or not any key falls in
        // it.
        await expectJSONValid("a = {* 1..3 => int}", "{}")
        await expectJSONValid("a = {* 1.5..3.5 => int}", "{}")
    }

    /// The integer prelude names differ in the sign they admit, and a name that
    /// constrains the sign settles the question on its own.
    @Test func validateIntegerPreludeNamesHoldToTheSignTheyAdmit() async {
        for name in ["uint", "unsigned"] {
            await expectJSONInvalid("a = \(name)", "-1")
            await expectJSONValid("a = \(name)", "0")
            await expectJSONValid("a = \(name)", "1")
        }

        await expectJSONValid("a = nint", "-1")
        await expectJSONInvalid("a = nint", "0")
        await expectJSONInvalid("a = nint", "1")

        for name in ["int", "integer", "number"] {
            await expectJSONValid("a = \(name)", "-1")
            await expectJSONValid("a = \(name)", "1")
        }

        // A name reached through another name is held to the same constraint.
        await expectJSONInvalid("b = uint\na = b", "-1")
        await expectJSONInvalid("b = nint\na = b", "1")

        // A name standing for a choice between them admits either.
        await expectJSONValid("a = uint / nint", "-1")
        await expectJSONValid("a = uint / nint", "1")

        // The sign is checked wherever the name is reached.
        await expectJSONInvalid("a = [* uint]", "[-1]")
        await expectJSONInvalid("a = {k: uint}", #"{"k":-1}"#)
        await expectJSONInvalid("a = uint / tstr", "-1")
    }

    /// A control narrows what a type admits, so the value has to be of the
    /// target's type before the control says anything about it.
    @Test func validateControlOperatorTargetTypeIsCheckedBeforeTheControl() async {
        await expectJSONInvalid("a = tstr .size 3", "255")
        await expectJSONInvalid("a = tstr .size 3", "true")
        await expectJSONInvalid("a = tstr .size 3", "null")
        await expectJSONValid("a = tstr .size 3", #""abc""#)
        await expectJSONInvalid("a = tstr .size 3", #""abcd""#)

        await expectJSONInvalid("a = uint .lt 5", #""x""#)
        await expectJSONValid("a = uint .lt 5", "4")
    }

    /// `.hexlc` and `.hexuc` differ from `.hex` only in the case they admit.
    @Test func validateHexControlHoldsTheTextToTheCaseItStates() async {
        await expectJSONValid("a = tstr .hex h'abcd'", #""abcd""#)
        await expectJSONValid("a = tstr .hex h'abcd'", #""ABCD""#)

        await expectJSONValid("a = tstr .hexlc h'abcd'", #""abcd""#)
        await expectJSONInvalid("a = tstr .hexlc h'abcd'", #""ABCD""#)

        await expectJSONValid("a = tstr .hexuc h'abcd'", #""ABCD""#)
        await expectJSONInvalid("a = tstr .hexuc h'abcd'", #""abcd""#)
    }

    /// A comparison relates the value to the literal rather than asking it to
    /// be equal to one.
    @Test func validateOrderingControlAgainstAValueOutsideTheLiteralsType() async {
        await expectJSONValid("a = int .lt 3", "-5")
        await expectJSONValid("a = int .lt 3", "1")
        await expectJSONInvalid("a = int .lt 3", "5")
        await expectJSONValid("a = int .gt -10", "-5")
        await expectJSONInvalid("a = int .gt -10", "-20")
    }

    /// RFC 9165 Section 2.1: `.plus` denotes the sum of its target and
    /// controller, and a sum outside the range of its type is no number.
    @Test func validatePlusControlReportsASumOutsideTheRangeOfItsType() async {
        await expectJSONValid("a = 18446744073709551614 .plus 1", "18446744073709551615")
        await expectJSONValid("a = 3 .plus -1", "2")
        await expectJSONValid("a = -3 .plus 1", "-2")
        await expectJSONValid("a = 0 .plus -1", "-1")

        await expectJSONInvalid("a = 18446744073709551615 .plus 1", "0")
        await expectJSONInvalid("a = 18446744073709551615 .plus 1", "18446744073709551615")
        await expectJSONInvalid("a = 0 .plus -1", "18446744073709551615")
        await expectJSONInvalid("a = 0 .plus -1", "0")
    }

    /// RFC 9165 Section 2.1: a sum of an integer target and a float controller
    /// takes the type of the target, and converting a float to an integer
    /// selects its floor.
    @Test func validatePlusControlFloorsAFractionalSum() async {
        for (schema, sum) in [
            ("a = 1 .plus 2.7", Int64(3)),
            ("a = 1 .plus -0.5", 0),
            ("a = 1 .plus -1.5", -1),
            ("a = 0 .plus -0.5", -1),
            ("a = 5 .plus -2.7", 2),
            ("a = -5 .plus -2.7", -8),
            ("a = -5 .plus 2.7", -3),
            ("a = -1 .plus 0.5", -1),
            // A controller that carries no fraction is its own floor.
            ("a = -3 .plus 1.0", -2),
        ] {
            #expect(await jsonAccepts(schema, String(sum)), "\(schema) does not denote \(sum)")
            for neighbour in [sum - 1, sum + 1] {
                #expect(!(await jsonAccepts(schema, String(neighbour))), "\(schema) admits \(neighbour)")
            }
        }
    }

    /// A float target keeps its own type, so the sum stays a float.
    @Test func validatePlusControlKeepsAFloatTargetAFloat() async {
        await expectJSONValid("a = 1.5 .plus 2", "3.5")
        await expectJSONInvalid("a = 1.5 .plus 2", "3")
        await expectJSONInvalid("a = 1.5 .plus 2", "4")
    }

    /// A fractional timestamp is a point in time.
    @Test func validateTimeAdmitsAFractionalTimestamp() async {
        await expectJSONValid("a = time", "1.5")
        await expectJSONValid("a = time", "1")
        await expectJSONInvalid("a = time", #""x""#)
    }

    /// A number carries a wider range of seconds than the instants a date and
    /// time can express, so a count outside that range is not a point in time.
    @Test func validateTimeRejectsSecondsOutsideTheRepresentableRange() async {
        // The last second of year 262142 and the first second of year -262143.
        let last: Int64 = 8_210_266_876_799
        let first: Int64 = -8_334_601_228_800

        await expectJSONValid("a = time", String(last))
        await expectJSONValid("a = time", String(first))
        await expectJSONValid("a = time", "\(last - 1).5")

        await expectJSONInvalid("a = time", String(last + 1))
        await expectJSONInvalid("a = time", String(first - 1))
        await expectJSONInvalid("a = time", String(Int64.max))
        await expectJSONInvalid("a = time", String(Int64.min))
        await expectJSONInvalid("a = time", String(UInt64.max))
        await expectJSONInvalid("a = time", "1e300")
        await expectJSONInvalid("a = time", "-1e300")
    }

    /// RFC 9741 Section 2.1: the sloppy variants relax only the bits the final
    /// symbol carries beyond the encoded data.
    @Test func validateB64SloppyRelaxesOnlyTheTrailingBits() async {
        let sloppyU = "a = tstr .b64u-sloppy h'68656c6c6f20776f726c64'"
        let sloppyC = "a = tstr .b64c-sloppy h'68656c6c6f20776f726c64'"
        let strictU = "a = tstr .b64u h'68656c6c6f20776f726c64'"
        let strictC = "a = tstr .b64c h'68656c6c6f20776f726c64'"

        #expect(await jsonAccepts(sloppyU, #""aGVsbG8gd29ybGQ""#))
        #expect(await jsonAccepts(sloppyC, #""aGVsbG8gd29ybGQ=""#))

        #expect(!(await jsonAccepts(strictU, #""aGVsbG8gd29ybGR""#)))
        #expect(!(await jsonAccepts(strictC, #""aGVsbG8gd29ybGR=""#)))
        #expect(await jsonAccepts(sloppyU, #""aGVsbG8gd29ybGR""#))
        #expect(await jsonAccepts(sloppyC, #""aGVsbG8gd29ybGR=""#))

        #expect(!(await jsonAccepts("a = tstr .b64u h'01'", #""AR""#)))
        #expect(await jsonAccepts("a = tstr .b64u-sloppy h'01'", #""AQ""#))
        #expect(await jsonAccepts("a = tstr .b64u-sloppy h'01'", #""AR""#))
        #expect(await jsonAccepts("a = tstr .b64c-sloppy h'01'", #""AQ==""#))
        #expect(await jsonAccepts("a = tstr .b64c-sloppy h'01'", #""AR==""#))
        #expect(!(await jsonAccepts("a = tstr .b64u-sloppy h'01'", #""Ag""#)))

        for truncation in [#""""#, #""Z""#, #""aGVsbG8g""#, #""aGVsbG8gd""#, #""aGVsbG8gd29yb""#] {
            #expect(!(await jsonAccepts(sloppyU, truncation)), ".b64u-sloppy admits \(truncation)")
            #expect(!(await jsonAccepts(sloppyC, truncation)), ".b64c-sloppy admits \(truncation)")
        }

        #expect(!(await jsonAccepts(sloppyU, #""aGVsbG8gd29ybGQ=""#)))
        #expect(!(await jsonAccepts(sloppyC, #""aGVsbG8gd29ybGQ""#)))

        #expect(!(await jsonAccepts("a = tstr .b64u-sloppy h'6865ff6f'", #""aGX/bw""#)))
        #expect(!(await jsonAccepts("a = tstr .b64c-sloppy h'6865ff6f'", #""aGX_bw==""#)))
    }

    /// Schemas whose only failure sits two levels into the data, reached
    /// through a rule that describes the item already held.
    private static let nestedFailureSchemas = [
        // A generic rule whose body is a type choice, reached from an array
        // entry.
        "t = [a, uint]\na = set<i>\nset<a0> = { * tstr => a0 } / [* a0]\ni = tstr .size ",
        // The same rule reached from an object value.
        "t = { k: a }\na = set<i>\nset<a0> = { * tstr => a0 } / [* a0]\ni = tstr .size ",
        // The same rule one array level further in.
        "t = [[a], uint]\na = set<i>\nset<a0> = { * tstr => a0 } / [* a0]\ni = tstr .size ",
        // A generic rule with no choice at all.
        "t = [a, uint]\na = wrap<i>\nwrap<a0> = [* a0]\ni = tstr .size ",
        // A type choice one of whose alternatives is itself a type choice.
        "t = [outer]\nouter = inner / uint\ninner = [* i] / tstr\ni = tstr .size ",
    ]

    private static func nestedFailureSchema(_ idx: Int, _ size: Int) -> String {
        "\(nestedFailureSchemas[idx])\(size)\n"
    }

    /// Every mismatch names the value it was found in.
    @Test func validateReportsEachErrorAtTheItemItWasFoundIn() async {
        let cases: [(Int, String, [String])] = [
            (0, #"[["x"], 1]"#, ["/0", "/0/0"]),
            (1, #"{"k": ["x"]}"#, ["/k", "/k/0"]),
            (2, #"[[["x"]], 1]"#, ["/0/0", "/0/0/0"]),
            (3, #"[["x"], 1]"#, ["/0/0"]),
            (4, #"[["x"]]"#, ["/0", "/0/0"]),
        ]
        for (idx, json, expected) in cases {
            let cddl = Self.nestedFailureSchema(idx, 32)
            let locations = Array(Set(jsonIssues(await jsonResult(cddl, json)).map(\.jsonLocation))).sorted()
            #expect(locations == expected, "wrong locations for:\n\(cddl)")
        }
    }

    /// The data those schemas do admit is still admitted.
    @Test func validateAdmitsTheDataTheNestedRulesDescribe() async {
        let cases: [(Int, String)] = [
            (0, #"[["x"], 1]"#),
            (0, #"[{"a": "x"}, 1]"#),
            (1, #"{"k": ["x"]}"#),
            (2, #"[[["x"]], 1]"#),
            (3, #"[["x"], 1]"#),
            (4, #"[["x"]]"#),
            (4, "[1]"),
        ]
        for (idx, json) in cases {
            let cddl = Self.nestedFailureSchema(idx, 1)
            #expect(await jsonAccepts(cddl, json), "\(cddl) rejects data it describes: \(json)")
        }
    }

    /// RFC 8610 Section 3.8.6: `.ne` states that the value is not the value its
    /// controller denotes; a controller that denotes a type denotes every value
    /// of that type.
    @Test func exclusionNegatesMembershipOfTheController() async {
        #expect(await jsonAccepts(#"root = tstr .ne "y""#, #""x""#))
        #expect(!(await jsonAccepts(#"root = tstr .ne "x""#, #""x""#)))
        #expect(await jsonAccepts(#"root = tstr .eq "x""#, #""x""#))
        #expect(!(await jsonAccepts(#"root = tstr .eq "y""#, #""x""#)))

        #expect(await jsonAccepts("root = tstr .ne uint", #""x""#))
        #expect(!(await jsonAccepts("root = tstr .ne tstr", #""x""#)))
        #expect(await jsonAccepts("root = tstr .eq tstr", #""x""#))
        #expect(!(await jsonAccepts("root = any .eq tstr", "3")))

        #expect(await jsonAccepts("root = tstr .ne c\nc = uint", #""x""#))
        #expect(!(await jsonAccepts("root = tstr .ne c\nc = tstr", #""x""#)))

        #expect(await jsonAccepts("root = bool .ne true", "false"))
        #expect(!(await jsonAccepts("root = bool .ne true", "true")))
    }

    /// RFC 9165: `.cat` stands for the value it computes from its two operands,
    /// so a target that denotes no value leaves it nothing to compute, whatever
    /// the document holds.
    @Test func computingOperatorReportsAnUnusableTargetAsASchemaFault() async {
        for document in [#""x""#, "3"] {
            let verdict = await jsonResult(#"root = bstr .cat "x""#, document)
            guard case .invalidSchema(let issue)? = verdict else {
                Issue.record("expected a schema fault, got \(jsonRendered(verdict))")
                continue
            }
            #expect(issue.reason.contains("target of"), "\(issue.reason)")
        }

        #expect(await jsonAccepts(#"root = "a" .cat "b""#, #""ab""#))
        #expect(!(await jsonAccepts(#"root = "a" .cat "b""#, #""ac""#)))
    }

    /// A byte string target admits no JSON value, so a control operator applied
    /// to it is refused for the target before the controller is reached.
    @Test func byteStringTargetAdmitsNoDocumentUnderAControlOperator() async {
        for cddl in [#"root = bstr .ne "aa""#, #"root = bstr .eq "aa""#, "root = bstr .size 2", "root = bstr"] {
            #expect(!(await jsonAccepts(cddl, #""aa""#)), "\(cddl)")
            #expect(!(await jsonAccepts(cddl, "2")), "\(cddl)")
        }
    }
}
