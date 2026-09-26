import Testing

@testable import SwiftCDDL

/// The grammar alone (`grammarAccepts`), without building the AST, and the
/// `number` production on its own (`parseNumberProduction`).
@Suite struct GrammarTests {
    @Test func basicTypeRule() {
        #expect(grammarAccepts("myrule = int"))
    }

    @Test func typeRuleWithComment() {
        #expect(grammarAccepts("; This is a comment\nmyrule = text"))
    }

    @Test func groupRule() {
        #expect(grammarAccepts("mygroup = (name: text, age: uint)"))
    }

    @Test func mapStructure() {
        #expect(grammarAccepts("person = {\n  name: tstr,\n  age: uint,\n  ? email: tstr\n}"))
    }

    @Test func arrayStructure() {
        #expect(grammarAccepts("coordinates = [x: int, y: int, z: int]"))
    }

    @Test func typeChoice() {
        #expect(grammarAccepts("value = int / text / bool"))
    }

    @Test func groupChoice() {
        #expect(grammarAccepts("entry = (\n  ( name: text, id: int ) //\n  ( label: text, value: int )\n)"))
    }

    @Test func occurrenceIndicators() {
        #expect(
            grammarAccepts(
                "data = {\n  ? optional: text,\n  * any_number: int,\n  + at_least_one: uint,\n  1*5 limited: text\n}"
            )
        )
    }

    /// RFC 8610 Appendix B: a group rule's right-hand side is a `grpent`,
    /// which may carry an occurrence indicator.
    @Test(arguments: ["2* ( test )", "2*4 ( test )", "* ( test )", "+ ( test )", "? ( test )", "2* test", "2*4 test"])
    func occurrenceIndicatorAsRuleBody(_ body: String) {
        #expect(grammarAccepts("gr = \(body)\ntest = int"), "Failed to parse \(body)")
    }

    /// An occurrence indicator cannot stand as a rule body on its own.
    @Test(arguments: ["gr = 2*", "gr = 2*4", "gr = *", "gr = +", "gr = ?", "gr = 2* )"])
    func occurrenceIndicatorWithoutEntryIsRejected(_ input: String) {
        #expect(!grammarAccepts(input), "Unexpectedly parsed \(input)")
    }

    @Test func controlOperators() {
        #expect(
            grammarAccepts(
                "hash = bstr .size 32\nemail = tstr .regexp \"[^@]+@[^@]+\"\nconfig = bstr .cbor { timeout: uint }"
            )
        )
    }

    @Test func ranges() {
        #expect(grammarAccepts("port = 0..65535\nage = 0..150"))
    }

    @Test func tags() {
        #expect(grammarAccepts("tagged = #6.32(tstr)\ntagged_type = #6.<type>\nmajor_type = #1.5"))
    }

    @Test func socketPlug() {
        #expect(grammarAccepts("$socket /= option1\n$$group-socket //= (field: int)"))
    }

    @Test func generics() {
        #expect(grammarAccepts("map<K, V> = { * K => V }\nmy_map = map<text, int>"))
    }

    @Test func unwrap() {
        #expect(grammarAccepts("unwrapped = ~group_name"))
    }

    @Test func cutOperator() {
        #expect(grammarAccepts("data = {\n  type: int,\n  tstr ^ => any\n}"))
    }

    @Test func stringValues() {
        #expect(grammarAccepts("name = \"literal text\"\nescaped = \"text with \\\"quotes\\\" and \\n newline\""))
    }

    @Test func byteStrings() {
        #expect(grammarAccepts("b16 = h'48656c6c6f'\nb64 = b64'SGVsbG8='"))
    }

    @Test func numericValues() {
        #expect(
            grammarAccepts(
                "unsigned = 42\nsigned = -10\nfloating = 3.14\nscientific = 1.5e10\nhex_float = 0x1.5p10"
            )
        )
    }

    @Test func arrowMap() {
        #expect(grammarAccepts("table = {\n  * text => int\n}"))
    }

    @Test func groupToChoice() {
        #expect(grammarAccepts("colors = &(red: 1, green: 2, blue: 3)\ncolor_choice = &color_group"))
    }

    @Test func ethereumAddressCDDL() throws {
        #expect(grammarAccepts(try Fixtures.read("did/ethereumAddress.cddl")))
    }

    @Test func intellisenseDemoCDDL() throws {
        #expect(grammarAccepts(try Fixtures.read("lsp/intellisense-demo.cddl")))
    }

    @Test func completionCDDL() throws {
        #expect(grammarAccepts(try Fixtures.read("lsp/completion.cddl")))
    }

    // MARK: RFC 9682

    @Test func rfc9682EmptyDataModel() {
        #expect(grammarAccepts(""))
    }

    @Test func rfc9682EmptyDataModelWithComments() {
        #expect(grammarAccepts("; This is a module with only comments\n; No rules here\n"))
    }

    @Test func rfc9682UnicodeBraceEscape() {
        #expect(grammarAccepts("a = \"D\\u{6f}mino's \\u{1F073} + \\u{2318}\""))
    }

    @Test func rfc9682UnicodeBraceEscapeLeadingZeros() {
        #expect(grammarAccepts("a = \"test \\u{006f}\""))
    }

    @Test func rfc9682TraditionalUnicodeEscape() {
        #expect(grammarAccepts("b = \"Domino's \\uD83C\\uDC73 + \\u2318\""))
    }

    @Test func rfc9682NonliteralTagNumber() {
        #expect(grammarAccepts("ct-tag<content> = #6.<ct-tag-number>(content)\nct-tag-number = 1668546817..1668612095"))
    }

    @Test func rfc9682SimpleValueTypeExpression() {
        #expect(grammarAccepts("my-simple = #7.<0..23>"))
    }

    @Test func rfc9682SimpleValueLiteral() {
        #expect(grammarAccepts("my-float16 = #7.25"))
    }

    /// RFC 8610 §3.5.1: a memberkey may be any type1, including a range.
    @Test func type1MemberkeyRange() throws {
        let input = "ranged_keys = {? 0 : [* int], * 3 .. 255 => [* int]}"
        #expect(grammarAccepts(input))
        #expect(throws: Never.self) { try parseCDDLChecked(input) }
    }

    /// RFC 8610 §3.5.1: a memberkey may be a typed array with a control op.
    @Test func type1MemberkeyArrayWithControl() throws {
        let input = "arr_keys = { + [tag : k_tag, index : uint .size 4] => [ data : payload ] }\nk_tag = uint\npayload = any"
        #expect(grammarAccepts(input))
        #expect(throws: Never.self) { try parseCDDLChecked(input) }
    }

    /// Returns the production `number` reads `literal` as, over the whole of
    /// it.
    private func numberProduction(_ literal: String) -> GrammarRule? {
        guard let (rule, length) = parseNumberProduction(literal) else {
            Issue.record("\(literal) should parse as a number")
            return nil
        }
        #expect(length == literal.utf8.count, "\(literal) should be read whole, not in part")
        return rule
    }

    /// The number of entries in the array the document's first rule is.
    private func arrayEntryCount(_ cddl: CDDL) -> Int? {
        guard case .array(let group, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
            Issue.record("the first rule is an array")
            return nil
        }
        return group.groupChoices[0].groupEntries.count
    }

    @Test(arguments: ["1e300", "1E-5", "-2e10", "5e-324", "1e+3", "0e0", "1.5e10"])
    func exponentWithoutFractionIsAFloat(_ literal: String) {
        #expect(numberProduction(literal) == .float_value, "\(literal) carries an exponent, so it is a float")
    }

    @Test func mantissaAloneStaysAnInteger() throws {
        for (literal, production) in [("1", GrammarRule.uint_value), ("42", .uint_value), ("-10", .int_value)] {
            #expect(numberProduction(literal) == production, "\(literal) carries no fraction and no exponent")
        }

        // An exponent has to follow the digits directly.
        for input in ["a = 1\ne = 2\n", "a = 1\nempty = 2\n"] {
            let cddl = try parseOK(input)
            #expect(cddl.rules.count == 2, "\(input.debugDescription) defines two rules")
        }

        // The comma between group entries is optional.
        for input in ["a = [1 e]\ne = int\n", "a = [1, e]\ne = int\n"] {
            let cddl = try parseOK(input)
            #expect(arrayEntryCount(cddl) == 2, "\(input.debugDescription) holds a literal and a name")
        }

        // Digits followed by an `e` that no digits follow are not a float.
        for input in ["a = 1e\n", "a = 1.5e\n", "a = 1e+\n"] {
            _ = parseErr(input)
        }
    }

    /// A parenthesized entry that a range or control operator follows is a
    /// type entry.
    @Test func parenthesizedTypeWithOperatorIsAnArrayEntry() throws {
        for input in [
            "a = [(int) .lt 10]\n",
            "a = [(int) .eq 5]\n",
            "a = [(1)..(20)]\n",
            "a = [? (int) .lt 10]\n",
            "a = [* (int) .lt 10]\n",
            "a = [(int) .lt (10)]\n",
            "a = [(int) .lt 10, tstr]\n",
            "a = [tstr, (int) .lt 10]\n",
            "a = [(int) ; comment\n .lt 10]\n",
        ] {
            _ = try parseOK(input)
        }

        for input in ["a = [(int)]\n", "a = [(int, tstr)]\n", "a = {(k: int)}\n"] {
            _ = try parseOK(input)
        }
        for input in ["a = [(int, tstr) .lt 10]\n", "a = {(k: int) .lt 10}\n"] {
            _ = parseErr(input)
        }
    }

    /// A colon/bareword member key stays a Bareword even when the entry's
    /// value contains "=>".
    @Test func barewordColonKeyNotMisparsedAsArrow() throws {
        func firstMemberKeyVariant(_ src: String) throws -> String {
            let cddl = try parseCDDL(src)
            guard case .map(let group, _, _, _)? = firstType2(typeRule(cddl, 0)) else {
                Issue.record("expected map")
                return ""
            }
            return memberKeyVariant(memberKey(group.groupChoices[0].groupEntries[0].0))
        }

        #expect(try firstMemberKeyVariant("foo = { b: \"=>\" }") == "Bareword")
        #expect(try firstMemberKeyVariant("foo = { b: { * uint => uint } }") == "Bareword")
        #expect(try firstMemberKeyVariant("foo = { b: uint }") == "Bareword")
        #expect(try firstMemberKeyVariant("foo = { 1: uint }") == "Value")
        #expect(try firstMemberKeyVariant("foo = { b => uint }") == "Type1")
        #expect(try firstMemberKeyVariant("foo = { 1 => uint }") == "Type1")
        #expect(try firstMemberKeyVariant("foo = { b ^ => uint }") == "Type1")
    }
}
