import Foundation
import Testing

@testable import SwiftCDDL

/// JSON documents validated against schemas written out in full: fixtures,
/// controls, ranges, generics and member keys (RFC 8610, RFC 9165, RFC 8259).
@Suite struct CDDLJSONTests {
    @Test func verifyJSONValidation() async throws {
        await expectJSONValid(try Fixtures.read("cddl/reputon.cddl"), try Fixtures.read("json/reputon.json"))
    }

    /// An array record admits exactly the items its entries name.
    @Test func validateJSONArrayRecordExtraElements() async {
        let cddl = "thing = [a: tstr, b: int]"
        await expectJSONValid(cddl, #"["testString", 1]"#)
        await expectJSONInvalid(cddl, #"["testString", 1, 2]"#)
        await expectJSONInvalid(cddl, #"["testString"]"#)
    }

    /// `.size` on a uint is a byte-width bound (RFC 8610 Section 3.8.1), and a
    /// range controller bounds that width rather than the value.
    @Test func validateJSONUintSizeWidthsAndRanges() async {
        await expectJSONValid("start = uint .size 3", "16777215")
        await expectJSONInvalid("start = uint .size 3", "16777216")
        await expectJSONValid("start = uint .size 8", "18446744073709551615")
        await expectJSONValid("start = uint .size 16", "1")
        await expectJSONValid("start = uint .size (1..2)", "65535")
        await expectJSONInvalid("start = uint .size (1..2)", "65536")
        await expectJSONValid("start = uint .size (1...2)", "255")
        await expectJSONInvalid("start = uint .size (1...2)", "256")

        let verdict = await jsonResult("start = uint .size (2..1)", "0")
        #expect(jsonRendered(verdict).contains("admits no byte width"), "\(jsonRendered(verdict))")
    }

    /// The target type of a control operator is a precondition for applying
    /// it.
    @Test func validateJSONUintControlTargetRejectsNonUintData() async {
        for cddl in ["start = uint .size 2", "start = uint .lt 10"] {
            for json in [#""ab""#, "null", "1.5", "true", "-1", "[]", "{}"] {
                let verdict = await jsonResult(cddl, json)
                #expect(jsonRendered(verdict).contains("expected type uint"), "for \(json) got \(jsonRendered(verdict))")
            }
        }
    }

    /// The controller of `.ne` is a type, so a range controller excludes every
    /// value it contains and nothing else.
    @Test func validateJSONNeWithARangeController() async {
        for inside in ["0", "5", "10"] {
            await expectJSONInvalid("start = uint .ne (0..10)", inside)
        }
        for outside in ["11", "50"] {
            await expectJSONValid("start = uint .ne (0..10)", outside)
        }
        await expectJSONValid("start = uint .ne (0...10)", "10")
        await expectJSONInvalid("start = uint .ne (0...10)", "9")
    }

    /// A control operator applies to the items an array entry stands for.
    @Test func validateJSONControlOperatorInAnArray() async {
        for (cddl, json) in [
            ("start = [* uint .size 4]", "[1, 2, 3]"),
            ("start = [* uint .size 2]", "[]"),
            ("start = [* uint .size 2]", "[1, 2]"),
            ("start = [+ uint .size 2]", "[1, 2]"),
            ("start = [uint .size 2]", "[1]"),
            ("start = [a: uint .size 2]", "[1]"),
            ("start = [? uint .size 2]", "[1]"),
            ("start = [2*2 uint .lt 100]", "[1, 2]"),
            ("start = [* uint .ne 10]", "[1, 2]"),
            ("start = [* uint .eq 1]", "[1, 1]"),
            (#"start = {"a" => [* uint .size 2]}"#, #"{"a": [1, 2]}"#),
        ] {
            await expectJSONValid(cddl, json)
        }

        let cddl = "start = [* narrow]\nnarrow = uint .size 2"
        await expectJSONValid(cddl, "[1, 2]")
        await expectJSONInvalid(cddl, "[1, 70000]")
    }

    /// The control describes every item of a run, each reported at its own
    /// position.
    @Test func validateJSONControlOperatorAppliesToEveryItemOfARun() async {
        for (cddl, json) in [
            ("start = [* uint .size 2]", "[1, 70000]"),
            ("start = [+ uint .size 2]", "[1, 70000]"),
            ("start = [2*2 uint .lt 100]", "[1, 200]"),
            ("start = [* uint .ne 10]", "[1, 10]"),
            ("start = [* uint .eq 1]", "[1, 2]"),
        ] {
            let rendered = jsonRendered(await jsonResult(cddl, json))
            #expect(rendered.contains("JSON location /1"), "for \(cddl) got \(rendered)")
        }

        for json in [#"[1, "ab"]"#, "[1, -1]"] {
            let rendered = jsonRendered(await jsonResult("start = [* uint .size 2]", json))
            #expect(rendered.contains("JSON location /1") && rendered.contains("expected type uint"), "\(rendered)")
        }

        let rendered = jsonRendered(await jsonResult(#"start = {"a" => [* uint .size 2]}"#, #"{"a": [1, 70000]}"#))
        #expect(rendered.contains("JSON location /a/1"), "\(rendered)")
    }

    /// A uint target outside an array group holds the value itself to being a
    /// uint.
    @Test func validateJSONUintControlTargetRejectsAnArray() async {
        for json in ["[1]", "[]", "[1, 2]"] {
            await expectJSONInvalid("start = uint .size 2", json)
        }
    }

    /// A control operator whose target names a rule is applied to the type
    /// that rule resolves to.
    @Test func validateJSONControlOperatorWithARuleReferenceTarget() async {
        await expectJSONValid("start = u .size 2\nu = uint", "1")
        await expectJSONInvalid("start = u .size 2\nu = uint", "70000")

        await expectJSONValid("start = [* u .size 2]\nu = uint", "[1, 2]")
        let rendered = jsonRendered(await jsonResult("start = [* u .size 2]\nu = uint", "[1, 70000]"))
        #expect(rendered.contains("JSON location /1"), "\(rendered)")
    }

    /// No string is a member of a range, so `.ne` against one holds.
    @Test func validateJSONNeRangeAgainstAString() async {
        await expectJSONValid("start = tstr .ne (0..10)", #""x""#)
    }

    /// A float literal names a float wherever a message echoes it.
    @Test func validateJSONNamesFloatLiteralsInFloatNotation() async {
        for (cddl, json, expected) in [
            ("start = 2.0", "3.0", "expected value 2.0"),
            ("start = 2.0", #""x""#, "expected value 2.0"),
            ("start = float .lt 2.0", "3.0", "expected value .lt 2.0"),
            ("start = 1.0..2.0", "3.0", "1.0 <= value <= 2.0"),
            ("start = 1e308 .plus 1e308", "1.0", "expected computed .plus value Infinity"),
        ] {
            let rendered = jsonRendered(await jsonResult(cddl, json))
            #expect(rendered.contains(expected), "\(cddl) should report \(expected), got \(rendered)")
        }
    }

    /// An entry naming an array type under an occurrence indicator holds every
    /// nested array of the run to that type.
    @Test func validateJSONNestedArrayTypeAppliesToEveryItemOfARun() async {
        await expectJSONValid("start = [* [* uint .size 2]]", "[[1], [2]]")
        var rendered = jsonRendered(await jsonResult("start = [* [* uint .size 2]]", "[[1], [70000]]"))
        #expect(rendered.contains("JSON location /1/0"), "\(rendered)")

        await expectJSONValid("start = [* [int, tstr]]", #"[[1, "a"], [2, "b"]]"#)
        rendered = jsonRendered(await jsonResult("start = [* [int, tstr]]", #"[[1, "a"], ["b", 2]]"#))
        #expect(rendered.contains("JSON location /1/"), "\(rendered)")

        await expectJSONInvalid("start = [* [* uint]]", "[[1], 5]")

        await expectJSONValid("start = [[int], [tstr]]", #"[[1], ["a"]]"#)
        await expectJSONInvalid("start = [[int], [tstr]]", "[[1], [2]]")
    }

    /// A range bound is the value it denotes, however it is written.
    @Test func validateJSONRangeBoundsAreResolved() async {
        await expectJSONValid("start = -5..5", "3")
        await expectJSONValid("start = -5..5", "-3")
        await expectJSONInvalid("start = -5..5", "-7")

        await expectJSONValid("start = (1)..(3)", "2")
        await expectJSONInvalid("start = (1)..(3)", "4")

        await expectJSONValid("start = 1..max\nmax = limit\nlimit = 5\n", "3")
        await expectJSONInvalid("start = 1..max\nmax = limit\nlimit = 5\n", "6")

        await expectJSONValid("start = bounded<255>\nbounded<n> = 0..n\n", "255")
        await expectJSONInvalid("start = bounded<255>\nbounded<n> = 0..n\n", "256")

        await expectJSONValid("start = tstr .size (-1..5)", #""abc""#)
        await expectJSONInvalid("start = tstr .size (-1..5)", #""abcdef""#)

        await expectJSONValid("start = tstr .ne (1..5)", #""abc""#)

        var rendered = jsonRendered(await jsonResult("start = 0..10", #""abc""#))
        #expect(rendered.contains(".size control operator"), "\(rendered)")

        await expectJSONInvalid("start = 0..10", "3.5")
        await expectJSONInvalid("start = 0.0..10.0", "3")
        await expectJSONValid("start = 0.0..10.0", "3.5")

        rendered = jsonRendered(await jsonResult("start = 0.0 .. 1", "1"))
        #expect(rendered.contains("got 0.0 and 1"), "\(rendered)")

        rendered = jsonRendered(await jsonResult("start = 1..m\nm = (b: 1)\n", "1"))
        #expect(rendered.contains("Group name 'm' does not resolve to a numeric value"), "\(rendered)")

        rendered = jsonRendered(await jsonResult("start = 1..zzz", "1"))
        #expect(rendered.contains("not found in CDDL rules"), "\(rendered)")
    }

    /// A generic parameter is in scope in the rule that declares it and
    /// nowhere else (RFC 8610 Section 3.10).
    @Test func validateJSONGenericArgumentsAreScoped() async {
        let cddl = "start = wrapper<5>\nwrapper<n> = inner\ninner = 0..n\nn = 2\n"
        await expectJSONValid(cddl, "2")
        await expectJSONInvalid(cddl, "3")

        var rendered = jsonRendered(await jsonResult("start = wrapper<5>\nwrapper<n> = inner\ninner = 0..n\n", "3"))
        #expect(rendered.contains("not found in CDDL rules"), "\(rendered)")

        await expectJSONValid("start = [g<9>, g<2>]\ng<n> = 0..n\n", "[1, 2]")
        await expectJSONInvalid("start = [g<9>, g<2>]\ng<n> = 0..n\n", "[1, 5]")

        await expectJSONValid("start = [g<2>, g<9>]\ng<n> = 0..n\n", "[1, 5]")
        await expectJSONInvalid("start = [g<2>, g<9>]\ng<n> = 0..n\n", "[5, 1]")

        let run = "start = [* g<3>]\ng<n> = 0..n\n"
        await expectJSONValid(run, "[0, 1, 3]")
        await expectJSONValid(run, "[]")
        rendered = jsonRendered(await jsonResult(run, "[0, 1, 4]"))
        #expect(rendered.contains("JSON location /2"), "\(rendered)")

        let optional = "start = {? g<3>}\ng<n> = (v: 0..n)\n"
        await expectJSONValid(optional, "{}")
        await expectJSONValid(optional, #"{"v": 1}"#)
        await expectJSONInvalid(optional, #"{"v": 9}"#)

        let chain = "start = outer<5>\nouter<n> = inner<n>\ninner<m> = 0..m\n"
        await expectJSONValid(chain, "3")
        await expectJSONInvalid(chain, "7")
    }

    /// An arithmetic control resolves a rule name in target position to the
    /// value that rule denotes.
    @Test func validateJSONArithmeticControlResolvesARuleNameTarget() async {
        for (position, schema, admitted, rejected) in [
            ("top level", "start = a .plus 2\na = 1", "3", "1"),
            ("array entry", "start = [a .plus 2]\na = 1", "[3]", "[1]"),
            ("repeated array entry", "start = [+ a .plus 2]\na = 1", "[3, 3]", "[3, 1]"),
            ("map value", "start = { k: a .plus 2 }\na = 1", #"{"k": 3}"#, #"{"k": 1}"#),
            ("chained rule names", "start = b .plus 2\nb = a\na = 1", "3", "1"),
            ("generic parameter", "start = g<a>\ng<t> = t .plus 2\na = 1", "3", "1"),
            ("self-referential type choice", "start = 1 .plus a\na = 2 / a", "3", "4"),
        ] {
            #expect(await jsonAccepts(schema, admitted), "\(position): the computed .plus value must be admitted")
            #expect(!(await jsonAccepts(schema, rejected)), "\(position)")
        }
    }

    /// `.cat` and `.det` resolve a rule name in target position the same way
    /// `.plus` does.
    @Test func validateJSONConcatenationControlResolvesARuleNameTarget() async {
        for (position, schema, admitted, rejected) in [
            ("top level .cat", "start = s .cat \"b\"\ns = \"a\"", #""ab""#, #""a""#),
            ("top level .det", "start = s .det \"b\"\ns = \"a\"", #""ab""#, #""a""#),
            ("array entry .cat", "start = [s .cat \"b\"]\ns = \"a\"", #"["ab"]"#, #"["a"]"#),
            ("map value .cat", "start = { k: s .cat \"b\" }\ns = \"a\"", #"{"k": "ab"}"#, #"{"k": "a"}"#),
            ("member key .cat", "start = { (s .cat \"b\") => int }\ns = \"a\"", #"{"ab": 9}"#, #"{"a": 9}"#),
            ("member key .det", "start = { (s .det \"b\") => int }\ns = \"a\"", #"{"ab": 9}"#, #"{"a": 9}"#),
            ("chained rule names .cat", "start = t .cat \"b\"\nt = s\ns = \"a\"", #""ab""#, #""a""#),
            ("generic parameter .cat", "start = g<s>\ng<t> = t .cat \"b\"\ns = \"a\"", #""ab""#, #""a""#),
            ("self-referential type choice .cat", "start = \"p\" .cat a\na = \"x\" / a", #""px""#, #""p""#),
        ] {
            #expect(await jsonAccepts(schema, admitted), "\(position): the computed concatenation must be admitted")
            #expect(!(await jsonAccepts(schema, rejected)), "\(position)")
        }
    }

    /// A name given as an operand of an arithmetic control that denotes no
    /// value of the kind the control takes is a defect in the schema.
    @Test func validateJSONArithmeticControlReportsANameDenotingNoValue() async {
        for (schema, json, expected) in [
            ("start = a .plus 2\na = \"x\"", #""x""#, "type rule a is not a numeric value"),
            ("start = a .plus 1\na = \"x\" / a", "1", "type rule a is not a numeric value"),
            ("start = nope .plus 2", "1", "no type rule named nope is defined"),
            ("start = 1 .plus nope", "1", "no type rule named nope is defined"),
            ("start = a .plus 1\na = start", "1", "defined in terms of itself"),
            ("start = a .plus 1\na = b .plus 1\nb = a .plus 1", "1", "defined in terms of itself"),
            ("start = a .cat \"b\"\na = 1", #""1b""#, "type rule a is not a string literal"),
            ("start = nope .cat \"b\"", #""b""#, "no type rule named nope is defined"),
            ("start = nope .det \"b\"", #""b""#, "no type rule named nope is defined"),
            ("start = a .cat \"b\"\na = start", #""b""#, "defined in terms of itself"),
        ] {
            let rendered = jsonRendered(await jsonResult(schema, json))
            #expect(rendered.contains(expected), "for \(schema) expected \(expected), got \(rendered)")
        }
    }

    /// A sum no integer can hold stands for no value.
    @Test func validateJSONPlusReportsAnOutOfRangeSumThroughARuleName() async {
        for schema in [
            "start = 18446744073709551615 .plus 18446744073709551615",
            "start = a .plus 18446744073709551615\na = 18446744073709551615",
            "start = a .plus b\na = 18446744073709551615\nb = 18446744073709551615",
        ] {
            let rendered = jsonRendered(await jsonResult(schema, "1"))
            #expect(rendered.contains("outside the range"), "for \(schema) got \(rendered)")
        }
    }

    /// A parenthesized target denotes the value written inside it.
    @Test func validateJSONConcatenationControlAcceptsAParenthesizedTarget() async {
        await expectJSONValid(#"start = ("a") .cat "b""#, #""ab""#)
        await expectJSONInvalid(#"start = ("a") .cat "b""#, #""a""#)
    }

    /// `.plus` adds its operands whichever numeric notation each is written in.
    @Test func validateJSONPlusAddsAnUnsignedControllerToAFloatTarget() async {
        for schema in ["start = 1.5 .plus 2", "start = a .plus 2\na = 1.5"] {
            await expectJSONValid(schema, "3.5")
            await expectJSONInvalid(schema, "1.5")
        }
    }

    /// A controller written as a computation stands for the value it computes.
    @Test func validateJSONControlHoldsAgainstAComputedController() async {
        for (schema, admitted, rejected) in [
            ("start = int .lt (5 .plus 1)", "5", "6"),
            ("start = int .le (5 .plus 1)", "6", "7"),
            ("start = int .gt (5 .plus 1)", "7", "6"),
            ("start = int .ge (5 .plus 1)", "6", "5"),
            ("start = int .lt (b .plus 1)\nb = 5", "5", "6"),
            ("start = int .ne (5 .plus 1)", "5", "6"),
            ("start = int .eq (5 .plus 1)", "6", "5"),
            ("start = tstr .size (1 .plus 1)", #""ab""#, #""abc""#),
            (#"start = tstr .regexp ("^a" .cat "b$")"#, #""ab""#, #""zz""#),
        ] {
            await expectJSONValid(schema, admitted)
            await expectJSONInvalid(schema, rejected)
        }
    }

    /// The interval RFC 9165 gives `.plus`, whose upper bound is computed.
    @Test func validateJSONIntervalWithAComputedUpperBound() async {
        for schema in [
            "start = [interval<10>]\ninterval<BASE> = (int .ge BASE, int .lt (BASE .plus 100))",
            "start = interval<10>\ninterval<BASE> = (int .ge BASE, int .lt (BASE .plus 100))",
            "start = [int .ge 10, int .lt (10 .plus 100)]",
        ] {
            await expectJSONValid(schema, "[10, 109]")
            await expectJSONInvalid(schema, "[10, 110]")
            await expectJSONInvalid(schema, "[9, 109]")
        }
    }

    /// A control operator applied to a type in member key position holds
    /// against each name of the object.
    @Test func validateJSONControlInMemberKeyPositionHoldsAgainstEachKey() async {
        for (position, schema, admitted, rejected) in [
            ("direct target", "start = { tstr .size 2 => int }", "ab", "abc"),
            ("named target", "start = { k .size 2 => int }\nk = tstr", "ab", "abc"),
            ("parenthesized", "start = { (tstr .size 2) => int }", "ab", "abc"),
            ("regexp", "start = { tstr .regexp \"^a+$\" => int }", "aa", "zz"),
            ("equality", "start = { tstr .eq \"ab\" => int }", "ab", "b"),
            ("exclusion", "start = { tstr .ne \"ab\" => int }", "b", "ab"),
            ("computed key", "start = { (\"a\" .cat \"b\") => int }", "ab", "a"),
        ] {
            #expect(await jsonAccepts(schema, "{\"\(admitted)\": 1}"), "\(position)")
            #expect(!(await jsonAccepts(schema, "{\"\(rejected)\": 1}")), "\(position)")
        }
    }

    /// An occurrence indicator covering more than one member lets a member
    /// key answer for every name the group does not otherwise account for.
    @Test func validateJSONControlInMemberKeyPositionCoversARunOfEntries() async {
        let schema = "start = { * (tstr .size 2) => int }"
        func document(_ keys: [String]) -> String {
            "{" + keys.map { "\"\($0)\": 1" }.joined(separator: ", ") + "}"
        }
        for admitted in [[], ["ab"], ["ab", "cd"]] {
            await expectJSONValid(schema, document(admitted))
        }
        for rejected in [["abc"], ["ab", "x"]] {
            await expectJSONInvalid(schema, document(rejected))
        }
    }

    /// A controller denoting no value in member key position admits no key.
    @Test func validateJSONControlInMemberKeyPositionReportsAControllerDenotingNoValue() async {
        for schema in ["start = { (tstr .size nope) => int }", "start = { tstr .size nope => int }"] {
            let rendered = jsonRendered(await jsonResult(schema, #"{"ab": 1}"#))
            #expect(rendered.contains("object requires entry with key"), "for \(schema) got \(rendered)")
        }
    }

    /// A rule defined in terms of itself names no data type.
    @Test func validateJSONControlTargetNamingACyclicRuleIsReported() async {
        for schema in ["start = a .size 3\na = start", "start = a .lt 3\na = start", "start = a .regexp \"x\"\na = start"] {
            await expectJSONInvalid(schema, "1")
        }
    }

    /// `?` permits a type-keyed entry to be absent, and a present one is still
    /// held to its value type (RFC 8610 Section 3.2).
    @Test func validateJSONOptionalTypeDomainObjectKey() async {
        await expectJSONValid("m = { ? tstr => uint }", "{}")
        await expectJSONValid("m = { ? tstr => uint }", #"{"a": 1}"#)
        await expectJSONValid("m = { tstr => uint }", #"{"a": 1}"#)
        await expectJSONInvalid("m = { ? tstr => uint }", #"{"a": "b"}"#)
        await expectJSONInvalid("m = { tstr => uint }", "{}")
        await expectJSONInvalid("m = tstr", #"{"a": 1}"#)
    }

    /// A member no group entry matches is rejected as an unexpected key.
    @Test func validateJSONUnexpectedEntriesRejected() async {
        await expectJSONValid("m = { ? k: uint }", "{}")
        await expectJSONValid("m = { ? k: uint }", #"{"k": 1}"#)
        await expectJSONInvalid("m = { ? k: uint }", #"{"a": 1}"#)
        await expectJSONInvalid("m = { ? k: uint }", #"{"k": 1, "a": 2}"#)
    }

    /// `* any => any`, the extension-point idiom, permits unknown members.
    @Test func validateJSONAnyKeyPermitsExtraEntries() async {
        await expectJSONValid("m = { k: uint, * any => any }", #"{"k": 1}"#)
        await expectJSONValid("m = { k: uint, * any => any }", #"{"k": 1, "z": 9}"#)
        await expectJSONInvalid("m = { * any => any, k: uint }", #"{"k": 1, "z": 9}"#)
        // RFC 8610 Section 3.5.1 makes the bareword before `:` a text key, so
        // `* any: any` stands for members named "any".
        await expectJSONInvalid("m = { k: uint, * any: any }", #"{"k": 1, "z": 9}"#)
        await expectJSONValid("m = { k: uint, * any: any }", #"{"k": 1, "any": 9}"#)
        await expectJSONValid("m = { * any => any }", "{}")
        await expectJSONValid("m = { * any => any }", #"{"z": 9}"#)
        await expectJSONInvalid("m = { + any => any }", "{}")
        await expectJSONValid("m = { + any => any }", #"{"z": 9}"#)
        await expectJSONValid("m = { any => any }", #"{"z": 9}"#)
        await expectJSONInvalid("m = { k: uint, * any => uint }", #"{"k": 1, "z": "s"}"#)
        await expectJSONInvalid("m = { k: uint }", #"{"k": 1, "z": 9}"#)
    }

    /// A wrong value under a cut-carrying key is not rescued by an extension
    /// member (RFC 8610 Section 3.5.4).
    @Test func validateJSONAnyKeyDoesNotRescueCutValueMismatch() async {
        for schema in ["m = { k: uint, * any => any }", "m = { k: uint, any => any }"] {
            let rendered = jsonRendered(await jsonResult(schema, #"{"k": "s", "z": 9}"#))
            #expect(rendered.contains(#"/k: expected type uint, got "s""#), "schema \(schema): \(rendered)")
        }
    }

    /// A JSON validator can be pointed at a named type rule instead of the
    /// first.
    @Test func validateJSONAgainstANamedRootRule() async throws {
        let schema = try cddlFromStr("first = tstr\nsecond = uint\n")
        var validator = JSONValidator(cddl: schema, json: try JSONNode.parse("1"))
        #expect(await jsonUnitVerdict(validator) != nil, "the first rule is the default root")

        validator = JSONValidator(cddl: schema, json: try JSONNode.parse("1"))
        validator.setRootRule("second")
        #expect(await jsonUnitVerdict(validator) == nil)
    }
}
