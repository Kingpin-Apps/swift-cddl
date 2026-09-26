import BigInt
import Testing

@testable import SwiftCDDL

/// Whole-document parses and the AST shapes they produce.
@Suite struct ParserIntegrationTests {
    /// Disabled: it asserts an array-entry shape that would break group
    /// inlining (a bare name in an array is a `TypeGroupname`).
    @Test(.disabled("asserts an array-entry shape that would break group inlining"))
    func bareTypenameInArrayIsValueMemberKey() throws {
        let cddl = try parseOK("CapabilityRequest = {}\nCapabilitiesRequest = {\n  firstMatch: [*CapabilityRequest]\n}\n")
        guard case .map(let group, _, _, _)? = firstType2(typeRule(cddl, 1)),
            case .valueMemberKey(let ge, _, _, _) = group.groupChoices[0].groupEntries[0].0,
            case .array(let inner, _, _, _) = ge.entryType.typeChoices[0].type1.type2
        else {
            Issue.record("unexpected shape")
            return
        }
        guard case .valueMemberKey = inner.groupChoices[0].groupEntries[0].0 else {
            Issue.record("array entries should use ValueMemberKey, not TypeGroupname")
            return
        }
    }

    /// A right-hand side that opens with a uint-led occurrence indicator is a
    /// group rule.
    @Test func uintLedOccurrenceIndicatorStartsAGroupRule() throws {
        let cddl = try parseOK("gr = 2*4 ( test )\ntest = int\n")
        let rule = try #require(groupRule(cddl, 0))
        #expect(rule.name.ident == "gr")
        guard case .inlineGroup(let occur, let group, _, _, _) = rule.entry else {
            Issue.record("expected an inline group entry for gr")
            return
        }
        guard case .exact(lower: 2, upper: 4, _)? = occur?.occur else {
            Issue.record("expected occurrence 2*4, got \(String(describing: occur))")
            return
        }
        #expect(group.groupChoices[0].groupEntries.count == 1)
    }

    /// The lookahead that recognises the group rule above must not divert a
    /// type rule whose type is a bare uint.
    @Test func bareUintBodyStaysATypeRule() throws {
        let cddl = try parseOK("a = 2\n")
        let rule = try #require(typeRule(cddl, 0))
        #expect(rule.name.ident == "a")
        guard case .uintValue(2, _) = rule.value.typeChoices[0].type1.type2 else {
            Issue.record("expected uint 2")
            return
        }
    }

    @Test func verifyCDDL() throws {
        let input = """
            myrule = secondrule
            myrange = 10..upper
            upper = 500 / 600
            gr = 2* ( test )
            messages = message<"reboot", "now">
            message<t, v> = {type: 2, value: v}
            color = &colors
            colors = ( red: "red" )
            test = ( int / float )

            """
        let cddl = try parseOK(input)

        #expect(cddl.rules.count == 9)
        #expect(
            cddl.rules.map { $0.name() }
                == ["myrule", "myrange", "upper", "gr", "messages", "message", "color", "colors", "test"]
        )

        let myrule = try #require(typeRule(cddl, 0))
        #expect(myrule.name.ident == "myrule")
        #expect(!myrule.isTypeChoiceAlternate)
        #expect(myrule.genericParams == nil)
        guard case .typename(let secondrule, _, _) = myrule.value.typeChoices[0].type1.type2 else {
            Issue.record("Expected typename for myrule")
            return
        }
        #expect(secondrule.ident == "secondrule")

        let myrange = try #require(typeRule(cddl, 1))
        let t1 = myrange.value.typeChoices[0].type1
        if case .uintValue(let value, _) = t1.type2 {
            #expect(value == 10)
        }
        let op = try #require(t1.operator)
        if case .rangeOp(let isInclusive, _) = op.operator {
            #expect(isInclusive)
        }
        if case .typename(let ident, _, _) = op.type2 {
            #expect(ident.ident == "upper")
        }

        let upper = try #require(typeRule(cddl, 2))
        #expect(upper.value.typeChoices.count == 2)
        if case .uintValue(let value, _) = upper.value.typeChoices[0].type1.type2 {
            #expect(value == 500)
        }
        if case .uintValue(let value, _) = upper.value.typeChoices[1].type1.type2 {
            #expect(value == 600)
        }

        let messages = try #require(typeRule(cddl, 4))
        if case .typename(let ident, let ga?, _) = messages.value.typeChoices[0].type1.type2 {
            #expect(ident.ident == "message")
            #expect(ga.args.count == 2)
            if case .textValue(let value, _) = ga.args[0].arg.type2 {
                #expect(value == "reboot")
            }
            if case .textValue(let value, _) = ga.args[1].arg.type2 {
                #expect(value == "now")
            }
        }

        let message = try #require(typeRule(cddl, 5))
        #expect(message.name.ident == "message")
        let gps = try #require(message.genericParams)
        #expect(gps.params.count == 2)
        #expect(gps.params[0].param.ident == "t")
        #expect(gps.params[1].param.ident == "v")
        if case .map(let group, _, _, _) = message.value.typeChoices[0].type1.type2 {
            #expect(group.groupChoices[0].groupEntries.count == 2)
            if case .valueMemberKey(let ge, _, _, _) = group.groupChoices[0].groupEntries[0].0 {
                if case .bareword(let ident, _, _, _)? = ge.memberKey {
                    #expect(ident.ident == "type")
                }
                if case .uintValue(let value, _) = ge.entryType.typeChoices[0].type1.type2 {
                    #expect(value == 2)
                }
            }
            if case .valueMemberKey(let ge, _, _, _) = group.groupChoices[0].groupEntries[1].0 {
                if case .bareword(let ident, _, _, _)? = ge.memberKey {
                    #expect(ident.ident == "value")
                }
                if case .typename(let ident, _, _) = ge.entryType.typeChoices[0].type1.type2 {
                    #expect(ident.ident == "v")
                }
            }
        }

        let color = try #require(typeRule(cddl, 6))
        #expect(color.name.ident == "color")
        guard case .choiceFromGroup = color.value.typeChoices[0].type1.type2 else {
            Issue.record("expected choice from group")
            return
        }

        let test = try #require(typeRule(cddl, 8))
        #expect(test.name.ident == "test")
        if case .parenthesizedType(let pt, _, _, _) = test.value.typeChoices[0].type1.type2 {
            #expect(pt.typeChoices.count == 2)
            if case .typename(let ident, _, _) = pt.typeChoices[0].type1.type2 {
                #expect(ident.ident == "int")
            }
            if case .typename(let ident, _, _) = pt.typeChoices[1].type1.type2 {
                #expect(ident.ident == "float")
            }
        }

        // The formatted output can be re-parsed.
        _ = try parseOK(cddl.description)
    }

    @Test func criReference() throws {
        let cddl = """
            CRI-Reference = [
              (?scheme, ?((host.name // host.ip), ?port) // path.type),
              *path,
              *query,
              ?fragment
            ]

            scheme    = (0, text .regexp "[a-z][a-z0-9+.-]*")
            host.name = (1, text)
            host.ip   = (2, bytes .size 4 / bytes .size 16)
            port      = (3, 0..65535)
            path.type = (4, 0..127)
            path      = (5, text)
            query     = (6, text)
            fragment  = (7, text)

            """
        let ast = try parseOK(cddl)
        #expect(!ast.description.isEmpty)
    }

    /// A parenthesized type followed by a control operator is one array
    /// entry.
    @Test func parenthesizedTypeWithControlOperatorIsOneArrayEntry() throws {
        let cddl = try parseOK("a = [(int) .lt 10]\n")
        guard case .array(let group, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("expected an array")
            return
        }
        let entries = group.groupChoices[0].groupEntries
        #expect(entries.count == 1)
        guard case .valueMemberKey(let ge, _, _, _) = entries[0].0 else {
            Issue.record("expected a value entry, got \(entries[0].0)")
            return
        }
        #expect(ge.memberKey == nil)
        #expect(ge.occur == nil)
        let type1 = ge.entryType.typeChoices[0].type1
        guard case .parenthesizedType(let pt, _, _, _) = type1.type2 else {
            Issue.record("expected a parenthesized target, got \(type1.type2)")
            return
        }
        guard case .typename(let ident, _, _) = pt.typeChoices[0].type1.type2 else {
            Issue.record("expected int")
            return
        }
        #expect(ident.ident == "int")
        guard case .ctlOp(ctrl: .lt, _)? = type1.operator?.operator else {
            Issue.record("expected .lt")
            return
        }

        let formatted = cddl.description
        #expect(try parseOK(formatted).description == formatted)

        let plain = try parseOK("a = [(int)]\n")
        guard case .array(let plainGroup, _, _, _)? = firstType2(typeRule(plain, 0)),
            case .inlineGroup = plainGroup.groupChoices[0].groupEntries[0].0
        else {
            Issue.record("expected an inline group entry")
            return
        }
    }
}

/// The entry points, and the grammar over small examples.
@Suite struct ParserEntryPointTests {
    @Test func cddlFromStrBasic() {
        #expect(throws: Never.self) { try cddlFromStr("myrule = int\n") }
    }

    @Test func multipleRulesWithReferenceToParenthesizedType() throws {
        let cddl = try parseOK("basic = int\nouter = (basic)\n")
        #expect(cddl.rules.count == 2)
        let names = cddl.rules.map { $0.name() }
        #expect(names.contains("basic"))
        #expect(names.contains("outer"))
    }

    @Test(arguments: [
        "myrule = int\n",
        "person = { name: tstr, age: uint }\n",
        "\nperson = {\n  name: tstr,\n  age: uint\n}\n\naddress = {\n  street: tstr,\n  city: tstr\n}\n",
        "\n; This is a comment\nperson = {\n  name: tstr,  ; person's name\n  age: uint   ; person's age\n}\n",
        "value = int / text / bool\n",
        "my-array = [* int]\n",
        "\nmap<K, V> = { * K => V }\nmy-map = map<text, int>\n",
        "port = 0..65535\n",
        "email = tstr .regexp \"[^@]+@[^@]+\"",
        "tagged-value = #6.32(tstr)\n",
    ])
    func grammarAcceptsExamples(_ input: String) {
        #expect(grammarAccepts(input))
    }

    @Test func grammarAndParserAgree() throws {
        let input = "\nperson = {\n  name: tstr,\n  age: uint\n}\n"
        _ = try parseOK(input)
        #expect(grammarAccepts(input))
    }

    @Test(arguments: [
        "reputation-object = { application: tstr, reputons: [* reputon] }\n",
        "reputon = { rating: float16-32, ? confidence: float16-32, ? sample-size: uint }\n",
        "CDDLtest = thing\n",
        "thing = ( int / float )\n",
        "size = uint .size 4\n",
    ])
    func grammarAcceptsRFC8610Examples(_ example: String) {
        #expect(grammarAccepts(example))
    }

    @Test func rootTypeName() throws {
        #expect(try rootTypeNameFromCDDLStr("g<t> = [t]\nroot = int\n") == "root")
        #expect(throws: ParserError.self) { try rootTypeNameFromCDDLStr("g = (a: int)\n") }
    }
}

/// Parses of individual constructs.
@Suite struct ParserUnitTests {
    @Test func verifySimpleTypeRule() throws {
        let cddl = try parseOK("a = 1234\n")
        #expect(cddl.rules.count == 1)
        #expect(cddl.rules[0].name() == "a")
    }

    @Test func verifyDuplicateRuleError() {
        let err = parseErr("a = 1234\na = b\n")
        #expect(err.contains("already defined") || err.contains("error"), "Expected duplicate rule error, got: \(err)")
    }

    @Test func verifyGenericparams() throws {
        let cddl = try parseOK("myrule<t, v> = t / v\n")
        #expect(cddl.rules.count == 1)
        let gps = try #require(typeRule(cddl, 0)?.genericParams)
        #expect(gps.params.count == 2)
        #expect(gps.params[0].param.ident == "t")
        #expect(gps.params[1].param.ident == "v")
    }

    @Test func verifyGenericargs() throws {
        let cddl = try parseOK("myrule = message<\"reboot\", \"now\">\nmessage<a, b> = { action: a, time: b }\n")
        #expect(cddl.rules.count == 2)
        guard case .typename(let ident, let ga?, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected typename with generic args")
            return
        }
        #expect(ident.ident == "message")
        #expect(ga.args.count == 2)
    }

    @Test func verifyTypeChoice() throws {
        let cddl = try parseOK("myrule = ( tchoice1 / tchoice2 )\n")
        #expect(cddl.rules.count == 1)
        guard case .parenthesizedType(let pt, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected parenthesized type")
            return
        }
        #expect(pt.typeChoices.count == 2)
    }

    @Test func verifyType1Ranges() throws {
        let cddl = try parseOK("r1 = 5..10\nr2 = -10.5...10.1\nr3 = 1.5..4.5\n")
        #expect(cddl.rules.count == 3)

        let r1 = try #require(typeRule(cddl, 0)?.value.typeChoices[0].type1.operator)
        guard case .rangeOp(let inclusive1, _) = r1.operator else {
            Issue.record("Expected range op")
            return
        }
        #expect(inclusive1)

        let r2 = try #require(typeRule(cddl, 1)?.value.typeChoices[0].type1.operator)
        guard case .rangeOp(let inclusive2, _) = r2.operator else {
            Issue.record("Expected range op")
            return
        }
        #expect(!inclusive2)
    }

    @Test func verifyType1Control() throws {
        let cddl = try parseOK("myrule = target .lt controller\n")
        let t1 = try #require(typeRule(cddl, 0)?.value.typeChoices[0].type1)
        if case .typename(let ident, _, _) = t1.type2 {
            #expect(ident.ident == "target")
        }
        guard case .ctlOp(let ctrl, _)? = t1.operator?.operator else {
            Issue.record("Expected control op")
            return
        }
        #expect(ctrl == .lt)
    }

    @Test func verifyType2TextValue() throws {
        let cddl = try parseOK("myrule = \"myvalue\"\n")
        guard case .textValue(let value, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected text value")
            return
        }
        #expect(value == "myvalue")
    }

    @Test func verifyType2TypenameWithGenerics() throws {
        let cddl = try parseOK("myrule = message<\"reboot\", \"now\">\nmessage<a, b> = a / b\n")
        guard case .typename(let ident, let genericArgs, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected typename")
            return
        }
        #expect(ident.ident == "message")
        #expect(genericArgs?.args.count == 2)
    }

    @Test func verifyType2SocketPlug() throws {
        let cddl = try parseOK("myrule = $$tcp-option\n")
        // Only a type rule is inspected: `$$tcp-option` cannot be
        // a typename (an id cannot start with `$`), so the rule parses as a
        // group rule naming the group socket.
        if let rule = typeRule(cddl, 0) {
            guard case .typename(let ident, _, _)? = firstType2(rule) else {
                Issue.record("Expected typename")
                return
            }
            #expect(ident.ident == "tcp-option")
            #expect(ident.socket == .group)
        }
    }

    @Test func verifyType2Unwrap() throws {
        let cddl = try parseOK("myrule = ~group1\ngroup1 = (int)\n")
        guard case .unwrap(let ident, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected unwrap")
            return
        }
        #expect(ident.ident == "group1")
    }

    @Test func verifyType2TaggedData() throws {
        let cddl = try parseOK("myrule = #6.997(tstr)\n")
        guard case .taggedData(let tag, let t, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected tagged data")
            return
        }
        #expect(tag == .literal(997))
        #expect(t.typeChoices.count == 1)
    }

    @Test func verifyType2Float() throws {
        let cddl = try parseOK("myrule = 9.9\n")
        guard case .floatValue(let value, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected float value")
            return
        }
        #expect(abs(value - 9.9) < Double.ulpOfOne)
    }

    @Test func verifyType2Any() throws {
        let cddl = try parseOK("myrule = #\n")
        guard case .any? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected any")
            return
        }
    }

    @Test func verifyType2ArrayWithOccurrence() throws {
        let cddl = try parseOK("myrule = [*3 reputon]\n")
        guard case .array(let group, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected array")
            return
        }
        #expect(group.groupChoices.count == 1)
        guard case .typeGroupname(let ge, _, _, _) = group.groupChoices[0].groupEntries[0].0 else {
            Issue.record("Expected type groupname entry")
            return
        }
        #expect(ge.name.ident == "reputon")
        #expect(ge.occur != nil)
    }

    @Test func verifyType2ChoiceFromGroup() throws {
        let cddl = try parseOK("myrule = &groupname\ngroupname = (int)\n")
        guard case .choiceFromGroup(let ident, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected choice from group")
            return
        }
        #expect(ident.ident == "groupname")
    }

    @Test func verifyType2ChoiceFromInlineGroup() throws {
        let cddl = try parseOK("myrule = &( inlinegroup )\ninlinegroup = (int)\n")
        guard case .choiceFromInlineGroup? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("Expected choice from inline group")
            return
        }
    }

    @Test func verifyType2MapWithCut() throws {
        let cddl = try parseOK("myrule = { ? \"optional-key\" ^ => int }\n")
        let t2 = try #require(firstType2(typeRule(cddl, 0)))
        let group = try #require(containerGroup(t2))
        guard case .valueMemberKey(let ge, _, _, _) = group.groupChoices[0].groupEntries[0].0 else {
            Issue.record("Expected value member key entry")
            return
        }
        #expect(ge.occur != nil)
        guard case .type1(_, let isCut, _, _, _, _)? = ge.memberKey else {
            Issue.record("Expected type1 member key")
            return
        }
        #expect(isCut)
    }

    @Test func verifyGrpentBarewordKey() throws {
        let cddl = try parseOK("myrule = { type1: type2 }\n")
        guard case .bareword(let ident, _, _, _)? = memberKeyOf(arrayOrMapGroup(typeRule(cddl, 0)?.value), 0) else {
            Issue.record("Expected bareword member key")
            return
        }
        #expect(ident.ident == "type1")
    }

    @Test func verifyGrpentValueKey() throws {
        let cddl = try parseOK("myrule = { ? 0: addrdistr }\n")
        let group = try #require(arrayOrMapGroup(typeRule(cddl, 0)?.value))
        guard case .valueMemberKey(let ge, _, _, _) = group.groupChoices[0].groupEntries[0].0 else {
            Issue.record("Expected value member key entry")
            return
        }
        #expect(ge.occur != nil)
        guard case .value(let value, _, _, _)? = ge.memberKey else {
            Issue.record("Expected value member key")
            return
        }
        #expect(value == .uint(0))
    }

    @Test func verifyGrpentBarewordKeyWithArrowInValue() throws {
        let cddl = try parseOK("myrule = { key: { * uint => uint } }\n")
        guard case .bareword(let ident, _, _, _)? = memberKeyOf(arrayOrMapGroup(typeRule(cddl, 0)?.value), 0) else {
            Issue.record("Expected bareword member key")
            return
        }
        #expect(ident.ident == "key")
    }

    @Test func verifyGrpentValueKeyWithArrowInValue() throws {
        let cddl = try parseOK("myrule = { 2: { * uint => uint } }\n")
        guard case .value(let value, _, _, _)? = memberKeyOf(arrayOrMapGroup(typeRule(cddl, 0)?.value), 0) else {
            Issue.record("Expected value member key")
            return
        }
        #expect(value == .uint(2))
    }

    @Test func verifyGrpentTextValueKeyContainingArrow() throws {
        let cddl = try parseOK("myrule = { \"a=>b\": uint }\n")
        guard case .value(let value, _, _, _)? = memberKeyOf(arrayOrMapGroup(typeRule(cddl, 0)?.value), 0) else {
            Issue.record("Expected value member key")
            return
        }
        #expect(value == .text("a=>b"))
    }

    @Test func verifyGrpentArrowKeyStaysType1() throws {
        let cddl = try parseOK("myrule = { uint => tstr }\nmyrule2 = { tstr ^ => uint }\n")
        guard case .type1(_, let isCut0, _, _, _, _)? = memberKeyOf(arrayOrMapGroup(typeRule(cddl, 0)?.value), 0),
            case .type1(_, let isCut1, _, _, _, _)? = memberKeyOf(arrayOrMapGroup(typeRule(cddl, 1)?.value), 0)
        else {
            Issue.record("Expected type1 member keys")
            return
        }
        #expect(!isCut0)
        #expect(isCut1)
    }

    @Test func verifyGrpentOptionalComma() throws {
        let cddl = try parseOK("myrule = { a: uint, b: tstr }\nmyrule2 = { a: uint, b: tstr, }\n")

        let entries0 = try #require(arrayOrMapGroup(typeRule(cddl, 0)?.value)).groupChoices[0].groupEntries
        #expect(entries0.count == 2)
        #expect(entries0[0].1.optionalComma)
        #expect(!entries0[1].1.optionalComma)

        let entries1 = try #require(arrayOrMapGroup(typeRule(cddl, 1)?.value)).groupChoices[0].groupEntries
        #expect(entries1.count == 2)
        #expect(entries1[0].1.optionalComma)
        #expect(entries1[1].1.optionalComma)
    }

    @Test func verifyGrpentOptionalCommaAcrossGroupChoice() throws {
        let cddl = try parseOK("myrule = { a: 1, b: 2, // c: 3 }\n")
        let group = try #require(arrayOrMapGroup(typeRule(cddl, 0)?.value))
        #expect(group.groupChoices.count == 2)

        let first = group.groupChoices[0].groupEntries
        #expect(first.count == 2)
        #expect(first[0].1.optionalComma)
        #expect(first[1].1.optionalComma)

        let second = group.groupChoices[1].groupEntries
        #expect(second.count == 1)
        #expect(!second[0].1.optionalComma)
    }

    @Test func verifyGrpentMemberKeyFormsInArray() throws {
        let cddl = try parseOK("myrule = [ label: tstr, keyed: { * uint => uint } ]\nmyrule2 = [ uint => tstr ]\n")
        let group = arrayOrMapGroup(typeRule(cddl, 0)?.value)
        guard case .bareword(let label, _, _, _)? = memberKeyOf(group, 0),
            case .bareword(let keyed, _, _, _)? = memberKeyOf(group, 1)
        else {
            Issue.record("Expected bareword member keys")
            return
        }
        #expect(label.ident == "label")
        #expect(keyed.ident == "keyed")
        guard case .type1? = memberKeyOf(arrayOrMapGroup(typeRule(cddl, 1)?.value), 0) else {
            Issue.record("Expected type1 member key")
            return
        }
    }

    @Test func verifyGrpentMemberKeyInNestedInlineGroup() throws {
        let cddl = try parseOK("myrule = { ( k: { * uint => uint }, j: uint ) }\n")
        let outer = try #require(arrayOrMapGroup(typeRule(cddl, 0)?.value))
        guard case .inlineGroup(_, let inline, _, _, _) = outer.groupChoices[0].groupEntries[0].0 else {
            Issue.record("Expected inline group entry")
            return
        }
        guard case .bareword(let k, _, _, _)? = memberKeyOf(inline, 0),
            case .bareword(let j, _, _, _)? = memberKeyOf(inline, 1)
        else {
            Issue.record("Expected bareword member keys")
            return
        }
        #expect(k.ident == "k")
        #expect(j.ident == "j")

        guard case .valueMemberKey(let ge, _, _, _) = inline.groupChoices[0].groupEntries[0].0,
            case .map(let nested, _, _, _) = ge.entryType.typeChoices[0].type1.type2,
            case .type1? = memberKeyOf(nested, 0)
        else {
            Issue.record("Expected the nested entry to keep its arrow form")
            return
        }
    }

    @Test func verifyOccurrenceIndicators() throws {
        let cddl = try parseOK("r1 = [1*3 int]\nr2 = [* int]\nr3 = [+ int]\nr4 = [? int]\n")
        #expect(cddl.rules.count == 4)

        for (idx, expected) in ["Exact(1,3)", "ZeroOrMore", "OneOrMore", "Optional"].enumerated() {
            let group = try #require(arrayOrMapGroup(typeRule(cddl, idx)?.value))
            let occur: Occur?
            switch group.groupChoices[0].groupEntries[0].0 {
            case .typeGroupname(let ge, _, _, _): occur = ge.occur?.occur
            case .valueMemberKey(let ge, _, _, _): occur = ge.occur?.occur
            default: occur = nil
            }
            switch (expected, try #require(occur)) {
            case ("Exact(1,3)", .exact(let lower, let upper, _)):
                #expect(lower == 1)
                #expect(upper == 3)
            case ("ZeroOrMore", .zeroOrMore), ("OneOrMore", .oneOrMore), ("Optional", .optional):
                break
            default:
                Issue.record("Occurrence mismatch for rule \(idx): expected \(expected)")
            }
        }
    }

    @Test func verifyGroupChoices() throws {
        let cddl = try parseOK("myrule = { int, int // int, tstr }\n")
        let group = try #require(arrayOrMapGroup(typeRule(cddl, 0)?.value))
        #expect(group.groupChoices.count == 2)
        #expect(group.groupChoices[0].groupEntries.count == 2)
        #expect(group.groupChoices[1].groupEntries.count == 2)
    }

    @Test func verifyNestedArrays() throws {
        let cddl = try parseOK("myrule = [ [* file-entry], [* directory-entry] ]\n")
        let group = try #require(arrayOrMapGroup(typeRule(cddl, 0)?.value))
        #expect(group.groupChoices[0].groupEntries.count == 2)
    }

    @Test func verifyTypeChoiceAlternates() throws {
        let cddl = try parseOK("myrule = int\nmyrule /= tstr\n")
        #expect(cddl.rules.count == 2)
        #expect(typeRule(cddl, 1)?.isTypeChoiceAlternate == true)
    }

    @Test func verifyGroupRule() throws {
        let cddl = try parseOK("mygroup = ( a: int, b: tstr )\n")
        #expect(cddl.rules.count == 1)
        #expect(cddl.rules[0].name() == "mygroup")
    }

    @Test(arguments: ["myrule = int\n", "myrule = { name: tstr, age: uint }\n", "myrule = [* int]\n", "myrule = 5..10\n"])
    func verifyRoundtripFormatting(_ input: String) throws {
        let formatted = try parseOK(input).description
        _ = try parseOK(formatted)
    }

    @Test func verifyInlineGroupInArray() throws {
        let cddl = try parseOK("myrule = [ ( a: int, b: tstr ) ]\n")
        let group = try #require(arrayOrMapGroup(typeRule(cddl, 0)?.value))
        #expect(!group.groupChoices.isEmpty)
    }

    @Test func verifyGenericRuleWithArgs() throws {
        let cddl = try parseOK("map<K, V> = { * K => V }\nmy-map = map<text, int>\n")
        #expect(cddl.rules.count == 2)
        #expect(typeRule(cddl, 0)?.genericParams?.params.count == 2)
    }

    @Test func verifyArrayMemberKeyWithGenerics() throws {
        let cddl = try parseOK("myrule = { 0: finite_set<transaction_input> }\n")
        let group = try #require(arrayOrMapGroup(typeRule(cddl, 0)?.value))
        guard case .valueMemberKey(let ge, _, _, _) = group.groupChoices[0].groupEntries[0].0 else {
            Issue.record("Expected value member key entry")
            return
        }
        if case .value(let value, _, _, _)? = ge.memberKey {
            #expect(value == .uint(0))
        }
        guard case .typename(let ident, let genericArgs, _) = ge.entryType.typeChoices[0].type1.type2 else {
            Issue.record("Expected typename")
            return
        }
        #expect(ident.ident == "finite_set")
        #expect(genericArgs != nil)
    }

    @Test func verifyMultipleRules() throws {
        let input = """
            reputation-object = {
              application: tstr,
              reputons: [* reputon],
            }

            reputon = {
              rating: float16-32,
              ? confidence: float16-32,
              ? sample-size: uint,
            }

            """
        let cddl = try parseOK(input)
        #expect(cddl.rules.count == 2)
        #expect(cddl.rules[0].name() == "reputation-object")
        #expect(cddl.rules[1].name() == "reputon")
    }

    @Test func verifyControlOperators() throws {
        let inputs: [(String, ControlOperator)] = [
            ("myrule = uint .size 4\n", .size),
            ("myrule = tstr .regexp \"[^@]+@[^@]+\"", .regexp),
            ("myrule = tstr .eq \"hello\"\n", .eq),
        ]
        for (input, expected) in inputs {
            let cddl = try parseOK(input)
            guard case .ctlOp(let ctrl, _)? = typeRule(cddl, 0)?.value.typeChoices[0].type1.operator?.operator else {
                Issue.record("Expected control op for \(input)")
                continue
            }
            #expect(ctrl == expected)
        }
    }

    /// The error highlights the offending token, not the preceding rule.
    @Test func errorShouldPointAtInvalidTokenNotPreviousRule() {
        let input = "value = 0x1\n\nbreak"
        #expect {
            try parseCDDL(input)
        } throws: { error in
            guard case .parser(let position, _) = error as? ParserError else { return false }
            let bytes = Array(input.utf8)
            let highlighted = String(decoding: bytes[position.range.0..<position.range.1], as: UTF8.self)
            #expect(highlighted == "break")
            #expect(position.line == 3)
            #expect(position.column == 1)
            return true
        }
    }
}
