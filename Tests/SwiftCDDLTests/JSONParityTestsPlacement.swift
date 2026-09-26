import Foundation
import Testing

@testable import SwiftCDDL

private typealias J = JSONParityFixture
private typealias P = CBORParityFixture

/// A type states the same thing wherever it stands -- at the root, as an
/// object value and as an array item -- and the JSON validator settles it as
/// the CBOR validator does (RFC 8610 Sections 2 and 3).
@Suite struct JSONParityTestsPlacement {
    /// A literal denotes one value, and an object is not that value; only in
    /// member key position does a literal name a member.
    @Test func aLiteralOutsideMemberKeyPositionIsNotAMapLookupInEitherValidator() async {
        await J.assertSettledInEveryPlacement(
            "", "\"x\"", admitted: [#""x""#], refused: [#"{"x":9}"#, "{}", #""y""#])
        await J.assertSettledInEveryPlacement("", "5", admitted: ["5"], refused: [#"{"k":1}"#, "{}", "1"])
        await J.assertSettledInEveryPlacement(
            "\nname = \"x\"", "name", admitted: [#""x""#], refused: [#"{"x":9}"#, "{}"])
    }

    /// `.default` narrows nothing, so the value is held to the target whatever
    /// the controller is.
    @Test func defaultOnALiteralTargetStillHoldsTheDataItemToTheTarget() async {
        for typeExpr in ["5 .default \"x\"", "5 .default 5", "5 .default uint", "5 .default (0..10)"] {
            await J.assertSettledInEveryPlacement(
                "", typeExpr, admitted: ["5"], refused: [#"{"k":1}"#, "{}", "1", #""x""#])
        }
        await J.assertSettledInEveryPlacement(
            "", "\"x\" .default \"y\"", admitted: [#""x""#], refused: [#"{"x":9}"#, "{}", #""y""#])
        await J.assertSettledInEveryPlacement(
            "", "tstr .default \"x\"", admitted: [#""x""#, #""s""#], refused: [#"{"x":9}"#, "5"])
    }

    /// A target written as a map states the members the value has to hold.
    @Test func equalityOperatorsOnAMapTargetHoldTheDataItemToThatMap() async {
        let outside = [#"{"z":1}"#, #"{"j":"s"}"#, "{}", "5", "[1]"]
        await J.assertSettledInEveryPlacement(
            "", "{k: int} .eq {k: 1}", admitted: [#"{"k":1}"#], refused: [#"{"k":2}"#] + outside)
        await J.assertSettledInEveryPlacement(
            "", "{k: int} .ne {k: 1}", admitted: [#"{"k":2}"#], refused: [#"{"k":1}"#] + outside)
        await J.assertSettledInEveryPlacement(
            "\nm = {k: int}", "m .ne {k: 1}", admitted: [#"{"k":2}"#], refused: [#"{"k":1}"#] + outside)
    }

    /// A target written as an array states the items the value has to hold.
    @Test func equalityOperatorsOnAnArrayTargetHoldTheDataItemToThatArray() async {
        let outside = [#"["s"]"#, "[]", "[1,2]", "5", #"{"k":1}"#]
        await J.assertSettledInEveryPlacement("", "[int] .eq [1]", admitted: ["[1]"], refused: ["[2]"] + outside)
        await J.assertSettledInEveryPlacement("", "[int] .ne [1]", admitted: ["[2]"], refused: ["[1]"] + outside)
        await J.assertSettledInEveryPlacement("\na = [int]", "a .ne [1]", admitted: ["[2]"], refused: ["[1]"] + outside)
    }

    /// A controller denoting values the target does not admit leaves `.eq`
    /// with no value to be equal to.
    @Test func equalityWithAControllerOutsideTheTargetAdmitsNoDocument() async {
        await J.assertSettledInEveryPlacement("", "{k: int} .eq {z: 1}", admitted: [], refused: [#"{"z":1}"#, #"{"k":1}"#])
        await J.assertSettledInEveryPlacement("", "[int] .eq [\"s\"]", admitted: [], refused: [#"["s"]"#, "[1]"])
    }

    /// A literal stands as the target of an equality operator, and states
    /// there what the same type named by a rule states.
    @Test func aLiteralTargetOfAnEqualityOperatorIsReadAsTheTypeItNames() async {
        let refused = ["1", #""x""#, "{}"]
        for typeExpr in ["5 .ne 1", "5 .eq 5"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: ["5"], refused: refused)
        }
        await J.assertSettledInEveryPlacement("\nfive = 5", "five .ne 1", admitted: ["5"], refused: refused)
        await J.assertSettledInEveryPlacement("", "\"x\" .ne \"y\"", admitted: [#""x""#], refused: [#""y""#, "5", "{}"])
        await J.assertSettledInEveryPlacement("", "5 .eq 6", admitted: [], refused: ["5"])
        await J.assertSettledInEveryPlacement("", "5 .ne 5", admitted: [], refused: ["5"])
    }

    /// An integer stands in a comparison with a float bound.
    @Test func anIntegerComparedAgainstAFloatBoundIsSettledAlikeByBothValidators() async {
        await J.assertSettledInEveryPlacement("", "uint .gt 1.5", admitted: ["5", "2"], refused: ["1", "0"])
        await J.assertSettledInEveryPlacement("", "int .lt 1.5", admitted: ["-2", "1"], refused: ["5", "2"])
        await J.assertSettledInEveryPlacement("", "int .ge 1.5", admitted: ["2"], refused: ["1", "-2"])
        await J.assertSettledInEveryPlacement("", "int .le 1.5", admitted: ["1"], refused: ["2"])
    }

    /// The target a value failed to be of is named the same way by both
    /// validators, led by the noun each data model has for its shape.
    @Test func theTargetAnEqualityOperatorRejectsAgainstIsNamedAlikeByBothValidators() async {
        for (schema, cborPrefix, jsonPrefix) in [
            ("root = {k: int} .ne {k: 1}", "expected map { k: int }, got ", "expected object { k: int }, got "),
            ("root = {k: int} .eq {k: 1}", "expected map { k: int }, got ", "expected object { k: int }, got "),
            ("root = [int] .ne [1]", "expected array [ int ], got ", "expected array [ int ], got "),
            ("root = [int] .eq [1]", "expected array [ int ], got ", "expected array [ int ], got "),
        ] {
            let cbor = await P.reasons(schema, P.int(5))
            let json = await J.reasons(schema, "5")
            #expect(cbor.count == 1 && json.count == 1, "\(schema)")
            #expect(cbor.first?.hasPrefix(cborPrefix) == true, "cbor: \(cbor)")
            #expect(json.first?.hasPrefix(jsonPrefix) == true, "json: \(json)")
        }
    }

    /// A literal stands as the target of a comparison operator.
    @Test func aLiteralTargetOfAComparisonOperatorIsReadAsTheTypeItNames() async {
        let refused = ["1", "10", #""x""#, "{}"]
        for typeExpr in ["5 .lt 10", "5 .le 5", "5 .gt 1", "5 .ge 5"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: ["5"], refused: refused)
        }
        for typeExpr in ["five .lt 10", "five .le 5", "five .gt 1", "five .ge 5"] {
            await J.assertSettledInEveryPlacement("\nfive = 5", typeExpr, admitted: ["5"], refused: refused)
        }
        for typeExpr in ["5 .lt 5", "5 .le 1", "5 .gt 10", "5 .ge 10"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: [], refused: ["5"])
            var named = typeExpr
            named.replaceSubrange(named.range(of: "5")!, with: "five")
            await J.assertSettledInEveryPlacement("\nfive = 5", named, admitted: [], refused: ["5"])
        }
        for typeExpr in ["\"x\" .lt 10", "h'78' .gt 1"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: [], refused: [#""x""#, "5"])
        }
    }

    /// A float stands in a comparison with an integer bound.
    @Test func aFloatComparedAgainstAnIntegerBoundIsSettledAlikeByBothValidators() async {
        await J.assertSettledInEveryPlacement("", "float .lt 10", admitted: ["1.5", "-2.5"], refused: ["12.5", "10.0"])
        await J.assertSettledInEveryPlacement("", "float .le 10", admitted: ["10.0", "1.5"], refused: ["12.5"])
        await J.assertSettledInEveryPlacement("", "float .gt 1", admitted: ["1.5"], refused: ["1.0", "0.5"])
        await J.assertSettledInEveryPlacement("", "float .ge 1", admitted: ["1.0", "1.5"], refused: ["0.5"])
        await J.assertSettledInEveryPlacement("", "1.5 .lt 10", admitted: ["1.5"], refused: ["2.5", "1"])
        await J.assertSettledInEveryPlacement("", "1.5 .gt 10", admitted: [], refused: ["1.5"])
    }

    /// RFC 8610 Appendix D defines `number = int / float`, so the name admits
    /// a number written either way, under a control operator too.
    @Test func aNumberTargetAdmitsANumberWrittenEitherWayInBothValidators() async {
        let numbers = ["0", "5", "1.5", "0.0"]
        let others = [#""x""#, "null", "{}"]
        await J.assertSettledInEveryPlacement("", "number", admitted: numbers, refused: others)

        let refusedByGe = ["-1", "-1.5"] + others
        await J.assertSettledInEveryPlacement("", "number .ge 0", admitted: numbers, refused: refusedByGe)
        await J.assertSettledInEveryPlacement("", "number .gt 0", admitted: ["5", "1.5"], refused: ["0", "0.0", "-1.5"])
        await J.assertSettledInEveryPlacement("\nn = number", "n .ge 0", admitted: numbers, refused: refusedByGe)
    }

    /// A control operator on a map type does not excuse a member the group
    /// names.
    @Test func aControlOperatorOnAMapTypeDoesNotExcuseAnEntryTheGroupNames() async {
        await J.assertSettledInEveryPlacement("", "{a: any} .default {}", admitted: [#"{"a":1}"#], refused: ["{}", #"{"b":1}"#])
        await J.assertSettledInEveryPlacement(
            "", "{a: {b: int}} .default {}", admitted: [#"{"a":{"b":1}}"#], refused: [#"{"b":1}"#, "{}"])
        await J.assertSettledInEveryPlacement("\nm = {a: any}", "m .default {}", admitted: [#"{"a":1}"#], refused: ["{}"])
    }

    /// A group with no entries admits only the empty object or array, under a
    /// control operator as much as away from one.
    @Test func aControlOperatorOnAnEmptyMapOrArrayTypeAdmitsNoOther() async {
        await J.assertSettledInEveryPlacement("", "{} .default {a: int}", admitted: ["{}"], refused: [#"{"k":1}"#])
        await J.assertSettledInEveryPlacement("", "[] .default [1]", admitted: ["[]"], refused: ["[1]"])

        for (schema, json, node, prefix) in [
            ("root = {} .default {a: int}", #"{"k":1}"#, P.map([("k", P.int(1))]), "expected empty map, got "),
            ("root = [] .default [1]", "[1]", P.array([P.int(1)]), "expected empty array, got "),
        ] {
            let cbor = await P.reasons(schema, node)
            let reasons = await J.reasons(schema, json)
            #expect(cbor.count == 1 && reasons.count == 1, "\(schema): \(reasons)")
            #expect(cbor.first?.hasPrefix(prefix) == true, "cbor: \(cbor)")
            #expect(reasons.first?.hasPrefix(prefix) == true, "json: \(reasons)")
        }
    }

    /// A name among the integer types keeps its sign under a control operator.
    @Test func anIntegerTargetKeepsItsSignUnderAControlOperator() async {
        for typeExpr in ["nint .le 10", "nint .ne \"x\"", "nint .eq -2", "nint .lt 0"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: ["-2"], refused: ["5", "0"])
        }
        for typeExpr in ["uint .ge 0", "uint .ne \"x\""] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: ["5", "0"], refused: ["-2"])
        }
        await J.assertSettledInEveryPlacement("\nn = nint", "n .le 10", admitted: ["-2"], refused: ["5", "0"])
    }

    /// RFC 8610 Section 2.2.1 makes parenthesization syntactic, so a target
    /// keeps the type it denotes inside parentheses.
    @Test func anEqualityControlReadsAParenthesizedTargetAsTheTypeItEncloses() async {
        let cases: [(String, [String], [String])] = [
            ("\nt = (int) .eq 5", ["5"], ["6", #""x""#]),
            ("\nt = ((int)) .eq 5", ["5"], ["6", #""x""#]),
            ("\nt = (tstr) .eq \"x\"", [#""x""#], [#""y""#, "5"]),
            ("\nt = (0..10) .eq 5", ["5"], ["6", "20"]),
            ("\nt = (int) .ne 5", ["6"], ["5", #""x""#]),
            ("\nt = (tstr) .ne \"x\"", [#""y""#], [#""x""#, "5"]),
            ("\nt = (int) .lt 10", ["5"], ["20", #""x""#]),
        ]
        for (prelude, admitted, refused) in cases {
            await J.assertSettledInEveryPlacement(prelude, "t", admitted: admitted, refused: refused)
        }
    }

    /// A target that is not a type name is held to the way any other type
    /// expression is.
    @Test func anEqualityControlHoldsADataItemToATargetThatIsNotATypeName() async {
        await J.assertSettledInEveryPlacement("", "&(a: 1, b: 2) .eq 1", admitted: ["1"], refused: ["2", "3", #""x""#])
        await J.assertSettledInEveryPlacement("", "&(a: 1, b: 2) .ne 1", admitted: ["2"], refused: ["1", "3"])
        await J.assertSettledInEveryPlacement("", "any .eq 5", admitted: ["5"], refused: ["6", #""x""#])
        await J.assertSettledInEveryPlacement("", "any .ne 5", admitted: ["6", #""x""#], refused: ["5"])
    }

    /// A member key states the type of the names the entry answers for,
    /// however the type is written.
    @Test func aMemberKeyNamingATypeAnswersForTheKeysOfThatType() async {
        let one = #"{"a":1}"#
        let two = #"{"a":1,"b":2}"#
        for typeExpr in ["{* any => any}", "{+ any => any}"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: [one, two, #"{"a":"x"}"#], refused: ["1"])
        }
        await J.assertSettledInEveryPlacement("", "{* any => any}", admitted: ["{}"], refused: ["1"])
        await J.assertSettledInEveryPlacement("", "{any => any}", admitted: [one], refused: [two, "{}"])

        for typeExpr in ["{* (int / tstr) => int}", "{* (tstr / int) => int}", "{* tstr => int}", "{* (tstr) => int}"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: [one, two, "{}"], refused: [#"{"a":"x"}"#])
        }
        for typeExpr in ["{(int / tstr) => int}", "{(tstr / int) => int}"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: [one], refused: ["{}", #"{"a":"x"}"#])
        }

        // A member name is a string, which leaves a choice none of whose
        // alternatives admits a string answering for no member at all.
        for typeExpr in ["{* (uint / nil) => int}", "{* (int / nil) => int}", "{* (bool / nil) => int}"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: ["{}"], refused: [one, two])
        }
        await J.assertSettledInEveryPlacement("", "{+ (uint / nil) => int}", admitted: [], refused: ["{}", one])
    }

    /// A string that is not a URI is a document the schema refuses, rather
    /// than one that ends the validation.
    @Test func aTextStringThatIsNotAUriIsRefusedRatherThanAborting() async {
        await J.assertSettledInEveryPlacement(
            "", "uri", admitted: [#""http://x/""#, #""a:b""#],
            refused: [#""::""#, #""2020-01-01T00:00:00Z""#, #""a""#, #""""#])
        await J.assertSettledInEveryPlacement(
            "", "{* uri => any}", admitted: [#"{"http://x/":0}"#, "{}"],
            refused: [#"{"::":0}"#, #"{"2020-01-01T00:00:00Z":0}"#, #"{"a":0}"#])
    }

    /// A float literal's notation is how it was spelled rather than what it
    /// denotes.
    @Test func floatLiteralNotationDoesNotChangeWhatTheLiteralAdmits() async {
        for typeExpr in ["100.0", "1e2", "1.0e2", "1E2", "1e+2", "0x1.9p6"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: ["100.0"], refused: ["100.5", "101.0", #""100.0""#])
        }
        for typeExpr in ["float .lt 1e2", "float .lt 100.0", "float .lt 0x1.9p6", "float .ne 1e2", "float .ne 100.0"] {
            await J.assertSettledInEveryPlacement("", typeExpr, admitted: ["99.0"], refused: ["100.0"])
        }
    }

    /// `~name` denotes the group the type `name` holds (RFC 8610 Section 3.7),
    /// so an entry naming one inside an array stands for the run of items
    /// that group describes.
    @Test func anUnwrappedArrayTypeDenotesTheGroupTheArrayHolds() async {
        let cases: [(String, String, String, [String], [String])] = [
            ("\ninner = [1]", "[~inner]", "[(1)]", ["[1]"], ["[2]", "[[1]]", "[]", "[1,1]"]),
            ("\ninner = [int, tstr]", "[~inner]", "[(int, tstr)]", [#"[1,"x"]"#], [#"[[1,"x"]]"#, "[1]", #"["x",1]"#]),
            (
                "\ninner = [int, tstr]", "[0, ~inner, 9]", "[0, (int, tstr), 9]", [#"[0,1,"x",9]"#],
                ["[0,9]", #"[0,[1,"x"],9]"#]
            ),
            ("\ninner = [* int]", "[~inner]", "[(* int)]", ["[]", "[1]", "[1,2]"], [#"["x"]"#]),
        ]
        for (prelude, unwrapped, inline, admitted, refused) in cases {
            await J.assertSettledInEveryPlacement(prelude, unwrapped, admitted: admitted, refused: refused)
            await J.assertSettledInEveryPlacement(prelude, inline, admitted: admitted, refused: refused)
        }

        await J.assertSettledInEveryPlacement("\ninner = [1]", "[~inner .eq [1]]", admitted: ["[[1]]"], refused: ["[1]", "[[2]]"])

        for (schema, admitted, refused) in [
            ("root = ~inner\ninner = [1]", "[1]", ["[2]", "1", "[[1]]"]),
            ("root = {k: ~inner}\ninner = [1]", #"{"k":[1]}"#, [#"{"k":[2]}"#, #"{"k":1}"#, #"{"k":[[1]]}"#]),
        ] {
            #expect(await J.reasons(schema, admitted) == [], "refused \(admitted) against \(schema)")
            for document in refused {
                #expect(!(await J.reasons(schema, document)).isEmpty, "admitted \(document) against \(schema)")
            }
        }
    }

    /// Under weights that count one kind of step alone, the smallest budget
    /// that admits a document is the same count on both channels.
    @Test func descentWeightsAreChargedAlikeByBothValidators() async {
        let prelude = P.chainedAliases(3)
        let levels = 5
        let document = J.nestedEmptyArrays(levels)

        let placements: [(String, Int, Int, (String) -> String)] = [
            ("root = x", levels, 1 + 4 * levels, { $0 }),
            ("root = { k: x }", levels + 1, 1 + 4 * levels, { "{\"k\":\($0)}" }),
            ("root = [x]", levels + 1, 4 * levels, { "[\($0)]" }),
        ]

        for (root, placedLevels, hops, wrap) in placements {
            let schema = "\(root)\(prelude)"
            for (weights, expected) in [
                ((1, 0), placedLevels),
                ((0, 1), hops),
                ((7, 3), 7 * placedLevels + 3 * hops),
            ] {
                var found: Int?
                for budget in 0...4096 {
                    let limits = ValidationLimits(
                        maxDescentCost: budget, dataLevelCost: weights.0, ruleHopCost: weights.1)
                    let verdict = await J.limited(schema, wrap(document), limits)
                    guard let verdict else {
                        found = budget
                        break
                    }
                    let reasons = verdict.issues?.map(\.reason) ?? ["\(verdict)"]
                    #expect(
                        reasons.allSatisfy { $0.contains("maximum supported descent budget") },
                        "refused on other grounds at budget \(budget): \(reasons)")
                }
                #expect(found == expected, "json charges weights \(weights) against \(root)")
            }
        }
    }

    /// A control or range operator on a parenthesized type states the same
    /// thing wherever the type stands.
    @Test func anOperatorOnAParenthesizedTypeIsSettledAlikeInEveryPlacement() async {
        let refused = ["15", #""x""#]
        await J.assertSettledInEveryPlacement("", "(int) .lt 10", admitted: ["5"], refused: refused)
        await J.assertSettledInEveryPlacement("", "(int) .lt (10)", admitted: ["5"], refused: refused)
        await J.assertSettledInEveryPlacement("", "(int) .eq 5", admitted: ["5"], refused: refused)
        await J.assertSettledInEveryPlacement("", "(1)..(20)", admitted: ["5"], refused: ["25", #""x""#])
        await J.assertSettledInEveryPlacement("\nbound = 10", "(int) .lt bound", admitted: ["5"], refused: refused)
    }

    /// An object held to a map type by an equality operator is refused for
    /// its number of members in the same words by both validators, each naming
    /// the item by its own noun.
    @Test func mapEntryCountUnderEqualityIsWordedAlikeByBothValidators() async {
        let cases: [(String, CBORNode, String, String)] = [
            (
                "root = { a: int } .eq { a: int, b: int }", P.map([("a", P.int(1))]), #"{"a":1}"#,
                "expected map with 2 entries, got 1"
            ),
            (
                "root = { a: int, b: int } .eq { a: int }", P.map([("a", P.int(1)), ("b", P.int(2))]),
                #"{"a":1,"b":2}"#, "expected map with 1 entry, got 2"
            ),
        ]
        for (schema, node, document, expected) in cases {
            let cbor = await P.reasons(schema, node)
            let json = await J.reasons(schema, document)
            #expect(cbor.first == expected, "cbor: \(cbor)")
            #expect(cbor.count == json.count, "\(schema) is worded differently by the two validators")
            var objectWording = expected
            objectWording.replaceSubrange(objectWording.range(of: "map")!, with: "object")
            #expect(json.first == objectWording, "json: \(json)")
        }
    }

    /// `x = A` extended by `x /= B` denotes the type `x = A / B` (RFC 8610
    /// Section 3.9), wherever `x` is used from and however deeply the data
    /// nests.
    @Test func aTypeExtendedByAlternativesDenotesTheChoiceInBothValidators() async {
        let cases = [
            ("x = uint\nx /= [* x]\n", "x = uint / [* x]\n"),
            ("x = [* x]\nx /= uint\n", "x = [* x] / uint\n"),
            ("x = uint\nx /= [* r0]\nr0 = x\n", "x = uint / [* r0]\nr0 = x\n"),
            ("x = uint\nx /= {* tstr => x}\n", "x = uint / {* tstr => x}\n"),
            ("x = tstr\nx /= bool\nx /= [* x]\nx /= uint\n", "x = tstr / bool / [* x] / uint\n"),
            ("x /= [* x]\nx /= uint\n", "x = [* x] / uint\n"),
        ]
        for (extended, choice) in cases {
            for levels in [0, 1, 2, 8, cborParityNestedChoiceDepth] {
                for document in [
                    J.nested(levels, "[", "]", "5"),
                    J.nested(levels, "[", "]", "-1"),
                    J.nested(levels, "{\"k\":", "}", "5"),
                    J.nested(levels, "{\"k\":", "}", "-1"),
                ] {
                    for (e, c) in zip(J.placementsOfX(extended, document), J.placementsOfX(choice, document)) {
                        let extendedVerdict = await J.settled(e.schema, e.json)
                        let choiceVerdict = await J.settled(c.schema, c.json)
                        #expect(
                            extendedVerdict == choiceVerdict,
                            "\(e.schema) and \(c.schema) were settled differently against \(e.json)")
                    }
                }
            }
        }
    }

    /// A name that `/=` alternatives alone define is the choice of them.
    @Test func aPluggedTypeSocketIsTheChoiceOfItsPlugsInBothValidators() async {
        let schema = "$v /= 12\n$v /= 13\nx = $v\n"
        for (document, admitted) in [("12", true), ("13", true), ("14", false), (#""12""#, false)] {
            for placed in J.placementsOfX(schema, document) {
                #expect(await J.settled(placed.schema, placed.json) == admitted, "\(placed.schema) against \(placed.json)")
            }
        }
    }

    /// `[~x]` whose entries are `[~x]` again resolves `x` against the same
    /// array without consuming any data, which no finite array satisfies.
    @Test func anUnwrappedArrayGroupReEnteringItsRuleIsRejectedByBothValidators() async {
        let schema = "x = [~x] / uint\n"
        let cycle = "rule x is defined in terms of itself without consuming any data"
        for levels in [1, 2, 8] {
            for placed in J.placementsOfX(schema, J.nested(levels, "[", "]", "5")) {
                let reasons = await J.reasons(placed.schema, placed.json)
                #expect(reasons.contains(cycle), "\(placed.schema) against \(placed.json): \(reasons)")
            }
        }
        for placed in J.placementsOfX(schema, "5") {
            #expect(await J.settled(placed.schema, placed.json))
        }
    }

    /// A name unwrapped through a cycle of bare type names resolves to no rule.
    @Test func anUnwrapThroughACycleOfNamesIsRejectedAlikeByBothValidators() async {
        let schema = "x = [* ~y] / uint\ny = z\nz = y\n"
        let expected = "cannot unwrap identifier y, rule not found"
        for placed in J.placementsOfX(schema, "[5]") {
            let reasons = await J.reasons(placed.schema, placed.json)
            #expect(reasons.contains(expected), "\(placed.schema): \(reasons)")
        }
        for placed in J.placementsOfX(schema, "5") {
            #expect(await J.settled(placed.schema, placed.json))
        }
    }

    /// A group turned into a choice with `&` that names itself contributes
    /// nothing further.
    @Test func aGroupTurnedIntoAChoiceThatNamesItselfIsSettledAlikeByBothValidators() async {
        let schema = "x = &g\ng = (a: 1, b: 2, g)\n"
        for (document, admitted) in [("1", true), ("2", true), ("3", false)] {
            for placed in J.placementsOfX(schema, document) {
                #expect(await J.settled(placed.schema, placed.json) == admitted, "\(placed.schema) against \(placed.json)")
            }
        }
    }

    /// A chain of unwraps resolved against one value answers to the bound on
    /// rule nesting.
    @Test func aChainOfUnwrapsAgainstOneItemIsBoundedAlikeByBothValidators() async throws {
        let arrays = "x = [~y] / uint\ny = [~z]\nz = [~w]\nw = [uint]\n"
        let maps = "x = {~y}\ny = {~z}\nz = {~w}\nw = {a: uint}\n"
        let bound = "maximum supported rule nesting"

        for (schema, document) in [(arrays, "[5]"), (maps, #"{"a":5}"#)] {
            for placed in J.placementsOfX(schema, document) {
                #expect(await J.settled(placed.schema, placed.json), "\(placed.schema)")
                for (maxRuleNesting, admitted) in [(2, false), (4, true)] {
                    let validator = try jsonUnitValidator(placed.schema, placed.json)
                    validator.setMaxRuleNesting(maxRuleNesting)
                    let verdict = await jsonUnitVerdict(validator)
                    if admitted {
                        #expect(verdict == nil, "\(placed.schema): \(jsonRendered(verdict))")
                    } else {
                        #expect(jsonRendered(verdict).contains(bound), "\(placed.schema): \(jsonRendered(verdict))")
                    }
                }
            }
        }
    }

    /// An array-typed alternative is one alternative like any other, wherever
    /// the choice stands and whichever position the alternative takes.
    @Test func anArrayTypedAlternativeIsOneAlternativeAmongTheOthersInBothValidators() async {
        let five = "[5]"
        let bare = "5"
        let empty = "[]"
        let textItem = #"["a"]"#
        let two = "[5,6]"
        let flag = "true"

        for b in ["[uint]", "[? uint]", "[x: uint]", "[1*1 uint]"] {
            for typeExpr in ["b / uint", "b / uint / tstr", "uint / b / tstr", "uint / tstr / b", "(b / uint)"] {
                await J.assertSettledInEveryPlacement("\nb = \(b)", typeExpr, admitted: [five, bare], refused: [textItem, two, flag])
            }
        }
        for b in ["[* uint]", "[+ uint]"] {
            for typeExpr in ["b / tstr", "b / tstr / uint"] {
                await J.assertSettledInEveryPlacement("\nb = \(b)", typeExpr, admitted: [five, two], refused: [textItem, flag])
            }
        }
        await J.assertSettledInEveryPlacement("", "[uint] / uint", admitted: [five, bare], refused: [textItem, empty])
        await J.assertSettledInEveryPlacement("\nb = []", "b / uint", admitted: [empty, bare], refused: [five, textItem])
        await J.assertSettledInEveryPlacement(
            "\nx = [x / uint]", "x", admitted: [five, "[[5]]", "[[[5]]]"], refused: [#"[["a"]]"#, bare])
    }

    /// An array type written where a group entry stands for items of the array
    /// describes each of those items.
    @Test func anInlineArrayTypeAsAnArrayEntryDescribesEachItemItStandsFor() async {
        let cases: [(String, [String], [String])] = [
            ("root = [* [uint]]", ["[]", "[[5],[6]]"], ["[5]", #"[[5],["j"]]"#, "[[5],6]"]),
            ("root = [+ [uint]]", ["[[5]]"], ["[]", "[5]"]),
            ("root = [* ([uint] / uint)]", ["[]", "[[5],5]", "[5,[5]]"], [#"[[5],"x"]"#, #"[5,["x"]]"#]),
            ("root = [* (uint / [uint])]", ["[[5],5]", "[5,[5]]"], [#"[[5],"x"]"#]),
            ("root = [uint, [uint]]", ["[5,[5]]"], ["[5,5]", "[[5],5]"]),
        ]
        for (schema, admitted, refused) in cases {
            for document in admitted {
                #expect(await J.reasons(schema, document) == [], "refused \(document) against \(schema)")
            }
            for document in refused {
                #expect(!(await J.reasons(schema, document)).isEmpty, "admitted \(document) against \(schema)")
            }
        }
    }

    /// A type defined in terms of itself through a choice from a group is a
    /// chain of references resolved against one value, refused as a cycle.
    @Test func aTypeReEnteringItselfThroughAChoiceFromAGroupIsSettledAlikeByBothValidators() async {
        let cases: [(String, String, Bool)] = [
            ("x = &(1, x)\n", "1", true),
            ("x = &(1, x)\n", "3", false),
            ("x = &(* x)\n", "5", false),
            ("x = uint / &(int => &(x))\n", "1", true),
            ("x = tstr / &(int => &(x))\n", "1", false),
            ("x = &(1, y)\ny = 2 / &(3, x)\n", "1", true),
            ("x = &(1, y)\ny = 2 / &(3, x)\n", "3", true),
            ("x = &(1, y)\ny = 2 / &(3, x)\n", "4", false),
            ("x = &(a: 1, tstr)\n", #""a""#, true),
            ("x = &(a: 1, tstr)\n", "2", false),
            ("x = &g\ng = (a: 1, h)\nh = (b: 2, g)\n", "2", true),
            ("x = &g\ng = (a: 1, h)\nh = (b: 2, g)\n", "3", false),
        ]
        for (schema, document, admitted) in cases {
            for placed in J.placementsOfX(schema, document) {
                #expect(await J.settled(placed.schema, placed.json) == admitted, "\(placed.schema) against \(placed.json)")
            }
        }

        let expected = "rule x is defined in terms of itself without consuming any data"
        #expect(await J.reasons("x = &(1, x)\n", "3").contains(expected))
    }

    /// A container type a value is not of is named as the schema writes it,
    /// led by the noun the data model has for the shape.
    @Test func aContainerTypeADataItemIsNotOfIsNamedAsTheSchemaWritesIt() async {
        let person = "x = {\n  name: tstr,\n  age: uint,\n  ? nickname: tstr,\n}\n"
        let pair = "x = [name: tstr, age: uint]\n"
        let one = #"{"name":"Alice","age":30}"#
        let two = #"[{"name":"Alice","age":30},{"name":"Alice","age":30}]"#

        for (schema, document, prefix) in [
            (person, two, "expected object { name: tstr, age: uint, ? nickname: tstr }, got "),
            (person, "5", "expected object { name: tstr, age: uint, ? nickname: tstr }, got "),
            (pair, one, "expected array [ name: tstr, age: uint ], got "),
            (pair, "5", "expected array [ name: tstr, age: uint ], got "),
        ] {
            for (placed, reason) in await J.reasonsInEveryPlacement(schema, document) {
                #expect(reason.hasPrefix(prefix), "json against \(placed): \(reason)")
            }
        }
    }

    /// A group longer than the rendering bound is cut to its head and the rest
    /// counted; a group within the bound is rendered whole.
    @Test func aGroupLongerThanTheRenderingBoundIsCutToItsHead() async {
        let two = #"[{"name":"Alice","age":30},{"name":"Alice","age":30}]"#
        for (placed, reason) in await J.reasonsInEveryPlacement(P.wideMapSchema(20), two) {
            #expect(
                reason.hasPrefix("expected object { f0: uint, f1: uint, f2: uint, f3: uint, \u{2026} 16 more }, got "),
                "json against \(placed): \(reason)")
        }

        for entries in [maxRenderedGroupEntries, maxRenderedGroupEntries + 1, maxRenderedGroupEntries + 16] {
            let prefix = "expected object \(P.wideMapHead(entries)), got "
            for document in [two, "5"] {
                for (placed, reason) in await J.reasonsInEveryPlacement(P.wideMapSchema(entries), document) {
                    #expect(reason.hasPrefix(prefix), "json against \(placed): \(reason)")
                }
            }
        }
    }

    /// A rendered type carries none of the schema's comments and stands on one
    /// line.
    @Test func aRenderedTypeCarriesNoCommentAndNoLineBreak() async {
        let commentedMap =
            "x = {\n  a: int, ; the first\n  b: int, ; the second\n  c: int, ; more\n  d: int,\n  e: int, ; nearly\n  f: int, ; the last\n}\n"
        let commentedArray =
            "x = [\n  a: int, ; the first\n  b: int, ; the second\n  c: int, ; more\n  d: int,\n  e: int, ; nearly\n  f: int, ; the last\n]\n"
        let commentedTag =
            "x = #6.1({\n  a: int, ; the first\n  b: int, ; the second\n  c: int, ; more\n  d: int,\n  e: int, ; nearly\n  f: int, ; the last\n})\n"

        for (schema, document, prefix) in [
            (commentedMap, "5", "expected object { a: int, b: int, c: int, d: int, \u{2026} 2 more }, got "),
            (commentedMap, "[1]", "expected object { a: int, b: int, c: int, d: int, \u{2026} 2 more }, got "),
            (commentedArray, "5", "expected array [ a: int, b: int, c: int, d: int, \u{2026} 2 more ], got "),
            (
                commentedTag, "5",
                "unsupported data type for validating JSON, got #6.1({ a: int, b: int, c: int, d: int, \u{2026} 2 more })"
            ),
        ] {
            for (placed, reason) in await J.reasonsInEveryPlacement(schema, document) {
                #expect(reason.hasPrefix(prefix), "json against \(placed): \(reason)")
                #expect(!reason.contains { $0 == "\n" || $0 == "\t" || $0 == ";" }, "against \(placed): \(reason)")
            }
        }
    }

    /// Each alternative of a choice of container types is named through the
    /// same rendering in a rejection of its own.
    @Test func aTaggedTypeAndEachAlternativeOfAChoiceAreRenderedThroughTheSameHead() async {
        for placed in J.placementsOfX("x = {a: int} / {b: int}\n", "[1]") {
            let reasons = await J.reasons(placed.schema, placed.json)
            #expect(reasons.count == 2, "json against \(placed.schema): \(reasons)")
            #expect(reasons.first?.hasPrefix("expected object { a: int }, got ") == true, "\(reasons)")
            #expect(reasons.last?.hasPrefix("expected object { b: int }, got ") == true, "\(reasons)")
        }
    }

    /// The naming of a type moves no verdict.
    @Test func aNamedContainerTypeSettlesTheSameDocumentsInBothValidators() async {
        let prelude = "\nPerson = {\n  name: tstr,\n  age: uint,\n  ? nickname: tstr,\n}\nPersons = [+Person]\n"
        let alice = #"{"name":"Alice","age":30}"#
        let nicknamed = #"{"name":"Alice","age":30,"nickname":"Ali"}"#
        let two = #"[{"name":"Alice","age":30},{"name":"Alice","age":30,"nickname":"Ali"}]"#

        await J.assertSettledInEveryPlacement(
            prelude, "Person", admitted: [alice, nicknamed], refused: [two, "5", "{}", #"{"name":"Alice"}"#])
        await J.assertSettledInEveryPlacement(
            prelude, "Persons", admitted: [two, "[\(alice)]"], refused: [alice, "5", "[]", "[\(alice),5]"])
    }

    /// An inline map type under an occurrence indicator holds each item of the
    /// run to the map type as a whole.
    @Test func anInlineMapTypeUnderAnOccurrenceIndicatorHoldsEachItemToTheMap() async {
        let a1 = #"{"a":1}"#
        for typeExpr in ["[* {a: int}]", "[+ {a: int}]", "[* ({a: int})]"] {
            await J.assertSettledInEveryPlacement(
                "", typeExpr, admitted: ["[\(a1)]", #"[{"a":1},{"a":2}]"#],
                refused: ["[[1]]", "[[]]", "[5]", "[null]", #"[{"a":1,"b":2}]"#, "[{}]", #"[{"a":1},[1]]"#])
        }
        await J.assertSettledInEveryPlacement(
            "", "[* {a: int, b: tstr}]", admitted: [#"[{"a":1,"b":"x"}]"#], refused: [#"[[1,"x"]]"#, "[\(a1)]"])
        await J.assertSettledInEveryPlacement(
            "", "[* {? a: int}]", admitted: ["[]", "[{}]", "[\(a1)]"], refused: ["[[]]", "[[1]]", #"[{"b":1}]"#])
        await J.assertSettledInEveryPlacement(
            "", "[* {* tstr => int}]", admitted: ["[{}]", #"[{"a":1,"b":2}]"#], refused: ["[[1]]", #"[{"a":"x"}]"#])
        await J.assertSettledInEveryPlacement(
            "", "[uint, * {a: int}]", admitted: ["[1]", "[1,\(a1)]"], refused: ["[1,[1]]", "[\(a1)]"])

        for schema in ["x = [* {a: int}]\n", "x = [+ {a: int}]\n", "x = [{a: int}]\n", "x = [* m]\nm = {a: int}\n"] {
            for (placed, reason) in await J.reasonsInEveryPlacement(schema, "[[1]]") {
                #expect(reason.hasPrefix("expected object { a: int }, got "), "json against \(placed): \(reason)")
            }
        }

        for schema in ["x = [* {a: int}]\n", "x = [+ {a: int}]\n", "x = [{a: int}]\n"] {
            for (placed, reason) in await J.reasonsInEveryPlacement(schema, #"[{"a":1,"b":2}]"#) {
                #expect(reason == #"unexpected key "b""#, "json against \(placed)")
            }
        }
    }
}
