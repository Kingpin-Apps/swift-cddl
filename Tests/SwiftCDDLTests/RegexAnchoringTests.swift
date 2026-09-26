import Testing

@testable import SwiftCDDL

// `.regexp` (RFC 8610 Section 3.8.3), `.pcre` and `.iregexp` (RFC 9485) hold
// a text string to the pattern with `$` matching at the very end of the text
// only, never before a newline that ends it, and with `\n` the only line
// terminator.

private struct RegexCase: CustomTestStringConvertible, Sendable {
    var control: String
    /// The pattern as the CDDL text literal spells it.
    var pattern: String
    /// The text string, as a JSON string literal.
    var json: String
    var valid: Bool

    var testDescription: String { ".\(control) \(pattern) against \(json)" }
}

private let cases: [RegexCase] = [
    RegexCase(control: "regexp", pattern: #"^[a-z]+$"#, json: #""abc\n""#, valid: false),
    RegexCase(control: "regexp", pattern: #"^[a-z]+$"#, json: #""abc""#, valid: true),
    RegexCase(control: "regexp", pattern: #"^[a-z]+$"#, json: #""abc\r""#, valid: false),
    RegexCase(control: "regexp", pattern: #"^a$"#, json: #""a\r\n""#, valid: false),
    RegexCase(control: "regexp", pattern: #"[a-z]+"#, json: #""abc\n""#, valid: true),
    RegexCase(control: "regexp", pattern: #"[a-z]+"#, json: #""123""#, valid: false),
    RegexCase(control: "regexp", pattern: #"a.c"#, json: #""a\rc""#, valid: true),
    RegexCase(control: "regexp", pattern: #"a.c"#, json: #""a\nc""#, valid: false),
    RegexCase(control: "regexp", pattern: #"(?m)^b$"#, json: #""a\nb\n""#, valid: true),
    RegexCase(control: "regexp", pattern: #"[$]"#, json: #""$""#, valid: true),
    RegexCase(control: "regexp", pattern: #"^a\\$$"#, json: #""a$""#, valid: true),
    RegexCase(control: "regexp", pattern: #"^[]$]+$"#, json: #""]$\n""#, valid: false),
    RegexCase(control: "pcre", pattern: #"[a-z]+"#, json: #""abc\n""#, valid: false),
    RegexCase(control: "pcre", pattern: #"[a-z]+"#, json: #""abc""#, valid: true),
    RegexCase(control: "pcre", pattern: #"a$"#, json: #""a\n""#, valid: false),
    RegexCase(control: "pcre", pattern: #"[a-z]+\\n"#, json: #""abc\n""#, valid: true),
    RegexCase(control: "iregexp", pattern: #"[a-z]+"#, json: #""abc\n""#, valid: false),
    RegexCase(control: "iregexp", pattern: #"[a-z]+"#, json: #""abc""#, valid: true),
    RegexCase(control: "iregexp", pattern: #"a.c"#, json: #""a\rc""#, valid: true),
]

@Suite struct RegexAnchoringTests {
    @Test(arguments: cases)
    fileprivate func jsonVerdict(_ regexCase: RegexCase) async {
        let cddl = "a = tstr .\(regexCase.control) \"\(regexCase.pattern)\"\n"
        var valid = true
        do {
            try await validateJSON(cddl: cddl, json: regexCase.json)
        } catch {
            valid = false
        }
        #expect(valid == regexCase.valid)
    }

    @Test(arguments: cases)
    fileprivate func cborVerdict(_ regexCase: RegexCase) async throws {
        let cddl = "a = tstr .\(regexCase.control) \"\(regexCase.pattern)\"\n"
        guard case .string(let text) = try JSONNode.parse(regexCase.json) else {
            Issue.record("the document is not a JSON string")
            return
        }
        let validator = CBORValidator(cddl: try cddlFromStr(cddl), cbor: .textString(text))
        var valid = true
        do {
            try await validator.validate()
        } catch {
            valid = false
        }
        #expect(valid == regexCase.valid)
    }

    @Test func dollarRewriting() {
        #expect(anchoringDollarAtEndOfText("^a$") == #"^a\z"#)
        #expect(anchoringDollarAtEndOfText(#"a\$"#) == #"a\$"#)
        #expect(anchoringDollarAtEndOfText("[$]$") == #"[$]\z"#)
        #expect(anchoringDollarAtEndOfText("[]$]$") == #"[]$]\z"#)
        #expect(anchoringDollarAtEndOfText("(?m)^a$") == "(?m)^a$")
        #expect(anchoringDollarAtEndOfText("(?i-m)a$") == #"(?i-m)a\z"#)
    }
}
