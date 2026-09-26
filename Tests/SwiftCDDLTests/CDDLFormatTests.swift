import Foundation
import Testing

@testable import SwiftCDDL

/// Parsing and formatting of whole documents: comments, literals and member
/// key forms survive a format round trip, and formatting is a fixed point.
@Suite struct CDDLFormatTests {
    @Test func verifyCDDLCompiles() throws {
        for file in try Fixtures.cddlFiles(in: "cddl") {
            #expect(throws: Never.self, "\(file)") { try cddlFromStr(try Fixtures.read(file), printStderr: true) }
        }
    }

    /// Outer-level comments survive the format round trip.
    @Test func commentsRoundTripThroughFormat() throws {
        let input = """
            ; top comment
            foo = uint  ; trailing comment

            ; before bar
            bar = tstr

            ; standalone between

            ; another floating
            baz = int

            """
        let formatted = try parseOK(input).description
        for marker in ["; top comment", "; trailing comment", "; before bar", "; standalone between", "; another floating"] {
            #expect(formatted.contains(marker), "expected formatted output to contain \(marker), got:\n\(formatted)")
        }
        _ = try parseOK(formatted)
    }

    static let groupEntryComments = """
        arr = [
          ; before first
          first: int, ; trailing first
          ; between entries
          second: tstr
          ; before closing bracket
        ]

        m = { ; after opening brace
          ; before key
          key: uint, ; trailing key
          other: tstr
          ; before closing brace
        }

        nested = [
          outer: [
            ; inside nested group
            inner: int ; trailing inner
          ],
          ; after nested entry
          tail: uint
        ]

        choices = [
          ; before first choice
          a: int
          ; before second choice
          // b: tstr
        ]

        grp = (
          ; inside a group rule
          p: int, ; trailing p
          q: uint
          ; before closing paren
        )

        ops = uint .size 4 ; trailing a control operator
          / tstr

        """

    /// Every comment on a group entry comes out, unchanged and in order.
    @Test func commentsOnGroupEntriesSurviveFormatRoundTrip() throws {
        let formatted = try parseOK(Self.groupEntryComments).description
        #expect(commentPayloads(formatted) == commentPayloads(Self.groupEntryComments), "got:\n\(formatted)")
        let reformatted = try parseOK(formatted).description
        #expect(reformatted == formatted, "formatting is not idempotent")
    }

    /// Comments leave the grammar of the document untouched.
    @Test func commentsNeverAbsorbTheSyntaxThatFollowsThem() throws {
        let withComments = try parseOK(Self.groupEntryComments).description
        let withoutComments = try parseOK(stripComments(Self.groupEntryComments)).description
        #expect(grammarOnly(withComments) == grammarOnly(withoutComments), "commented output was:\n\(withComments)")
    }

    /// Comments in type-level positions survive the round trip.
    @Test func commentsInTypeLevelPositionsSurviveFormatRoundTrip() throws {
        let input = """
            gen<a> = [ * a ]

            useg = gen<int ; inside a generic argument
              >

            mk = { ; after the brace
              int ; before the arrow
              => uint,
              bare ; before the colon
              : tstr,
              "v" : ; after the colon
                uint
            }

            occ = [ * ; after an occurrence indicator
              int ]

            choice = &( ; inside a group enumeration
              a, b
              ; before its closing paren
            )

            tag = #6.24( ; inside a tagged type
              bytes
              ; before its closing paren
            )

            paren = ( ; inside a parenthesized type
              int / tstr
              ; before its closing paren
            )

            a = int
            b = int

            """
        let formatted = try parseOK(input).description
        #expect(commentPayloads(formatted) == commentPayloads(input), "got:\n\(formatted)")

        let withoutComments = try parseOK(stripComments(input)).description
        #expect(grammarOnly(formatted) == grammarOnly(withoutComments), "commented output was:\n\(formatted)")

        let reformatted = try parseOK(formatted).description
        #expect(reformatted == formatted, "formatting is not idempotent")
    }

    /// A semicolon inside a literal does not start a comment.
    @Test func aSemicolonInsideALiteralDoesNotStartAComment() throws {
        let input = "lit = { \"x;y\": uint, \"a\": h'3b' } ; a real comment\n"
        let formatted = try parseOK(input).description
        #expect(formatted.contains("\"x;y\""), "got:\n\(formatted)")
        #expect(commentPayloads(formatted) == [" a real comment"], "got:\n\(formatted)")
        _ = try parseOK(formatted)
    }

    /// Every comment in every vendored schema survives formatting, twice over.
    @Test func commentsSurviveFormatForEveryVendoredSchema() throws {
        for file in try Fixtures.cddlFiles(in: "cddl") {
            let source = try Fixtures.read(file)
            let formatted = try parseOK(source).description
            #expect(commentPayloads(formatted) == commentPayloads(source), "\(file) lost or altered a comment")
            let reformatted = try parseOK(formatted).description
            #expect(reformatted == formatted, "\(file) formats unstably")
        }
    }

    /// The two memberkey forms are not interchangeable, and separators
    /// survive.
    @Test func memberKeyFormAndCommasSurviveFormatRoundTrip() throws {
        let input = """
            index = uint
            outer = { data_set : { * index => index }, keyed : [ * index => index ], ? plain: uint }
            arrowed = { index => uint, "lit" => uint }

            """
        let formatted = try parseOK(input).description
        #expect(formatted.contains("data_set:"), "got:\n\(formatted)")
        #expect(!formatted.contains("data_set =>"), "got:\n\(formatted)")
        #expect(formatted.contains("keyed:"), "got:\n\(formatted)")
        #expect(formatted.contains("index =>"), "got:\n\(formatted)")
        #expect(formatted.occurrences(of: ",") == 3, "got:\n\(formatted)")
        #expect(throws: Never.self) { try CDDL.fromSlice(Array(formatted.utf8)) }
    }

    /// Text literals are re-escaped for the output.
    @Test func textLiteralsRoundTripThroughFormat() throws {
        let input = """
            backslash = "x\\\\:y"
            quote = "say \\"hi\\""
            control = "a\\tb\\nc"
            mapkey = { "k\\"1": uint }
            del = "x\\u{7f}y"
            c1 = "x\\u{85}y"
            nonascii = "x\\u{a0}y"

            """
        let formatted = try parseOK(input).description
        for marker in [
            "\"x\\\\:y\"",
            "\"say \\\"hi\\\"\"",
            "\"a\\tb\\nc\"",
            "\"k\\\"1\"",
            "\"x\\u007Fy\"",
            "\"x\\u0085y\"",
            "\"x\u{a0}y\"",
        ] {
            #expect(formatted.contains(marker), "expected formatted output to contain \(marker), got:\n\(formatted)")
        }
        for raw in ["\u{7f}", "\u{85}"] {
            #expect(!formatted.unicodeScalars.contains(raw.unicodeScalars.first!), "expected \(raw.debugDescription) to be escaped")
        }
        #expect(try parseOK(formatted).description == formatted)
    }

    /// The unwrap prefix survives formatting.
    @Test func unwrapPrefixRoundTripsThroughFormat() throws {
        let input = """
            a = [ int ]
            b<t> = [ t ]
            unwrapped = ~a
            generic = ~b<int>
            keyed = { k: ~a }
            plain = { k: a }

            """
        let formatted = try parseOK(input).description
        for marker in ["unwrapped = ~a", "generic = ~b<int>", "keyed = { k: ~a }"] {
            #expect(formatted.contains(marker), "got:\n\(formatted)")
        }
        #expect(formatted.contains("plain = { k: a }"), "got:\n\(formatted)")
        #expect(formatted.occurrences(of: "~") == 3, "got:\n\(formatted)")
        #expect(try parseOK(formatted).description == formatted)
    }

    /// Member key forms and separators nested in groups survive formatting.
    @Test func memberKeyFormsNestedInGroupsSurviveFormatRoundTrip() throws {
        let input = """
            nested = { ( k: { * uint => uint }, j: uint ) }
            choices = { a: 1, b: 2, // c: 3 }

            """
        let formatted = try parseOK(input).description
        for marker in ["k: {", "j: uint", "uint => uint"] {
            #expect(formatted.contains(marker), "got:\n\(formatted)")
        }
        #expect(!formatted.contains("k =>"), "got:\n\(formatted)")
        #expect(!formatted.contains("j =>"), "got:\n\(formatted)")
        #expect(formatted.contains("a: 1, b: 2, // c: 3"), "got:\n\(formatted)")
        #expect(formatted.occurrences(of: ",") == 3, "got:\n\(formatted)")
        #expect(try parseOK(formatted).description == formatted)
    }

    /// Float literals keep their type through format.
    @Test func floatLiteralsKeepTheirTypeThroughFormat() throws {
        let input = """
            zero = 0.0
            negative-zero = -0.0
            integral = 1.0
            scaled = 100.0
            exponent = 1.0e2
            fraction = 1.5
            range = 1.0..2.0
            control = float .eq 3.0
            key = { 1.0 => int }
            whole = 1

            """
        let cddl = try parseOK(input)
        let formatted = cddl.description
        let reparsed = try parseOK(formatted)
        #expect(literals(reparsed) == literals(cddl), "format rewrote a literal:\n\(formatted)")

        for marker in [
            "zero = 0.0",
            "negative-zero = -0.0",
            "integral = 1.0",
            "scaled = 100.0",
            "exponent = 1.0e2",
            "fraction = 1.5",
            "range = 1.0..2.0",
            "control = float .eq 3.0",
            "key = { 1.0 => int }",
            "whole = 1\n",
        ] {
            #expect(formatted.contains(marker), "got:\n\(formatted)")
        }
        #expect(reparsed.description == formatted)
    }

    /// A mantissa followed by an exponent alone is a float literal.
    @Test func floatLiteralsCarryAnExponentWithoutAFraction() throws {
        let cases: [(String, Double)] = [
            ("1e300", 1e300),
            ("1E-5", 1e-5),
            ("-2e10", -2e10),
            ("5e-324", 5e-324),
            ("1e+3", 1e3),
            ("0e0", 0.0),
            ("1.5e10", 1.5e10),
        ]
        for (literal, value) in cases {
            let cddl = try parseOK("scaled = \(literal)\n")
            #expect(literals(cddl) == ["FLOAT(\(value))"], "\(literal) denotes \(value)")
            let formatted = cddl.description
            let reparsed = try parseOK(formatted)
            #expect(literals(reparsed) == literals(cddl), "got:\n\(formatted)")
            #expect(reparsed.description == formatted)
        }
    }

    /// A float literal is written back in the notation it was read in.
    @Test func floatLiteralsAreWrittenInTheNotationTheyWereReadIn() throws {
        let notations = [
            "1e300", "-1e300", "5e-324", "1.5e-300", "1e21", "1e-7", "1e20", "1e-6", "1e2", "1.0e2", "1E5", "1e+5",
            "123.456e3", "1.5", "0.0", "-0.0", "100.0", "0x1.91eb851eb851fp+1", "0x1p-10", "-0x1.8p3",
        ]
        for notation in notations {
            for input in [
                "scaled = \(notation)\n",
                "scaled = [\(notation)]\n",
                "scaled = { k: \(notation) }\n",
                "scaled = { \(notation) => int }\n",
                "scaled = { \(notation): int }\n",
                "scaled = float .eq \(notation)\n",
                "scaled = \(notation) / int\n",
            ] {
                let cddl = try parseOK(input)
                let formatted = cddl.description
                #expect(formatted.contains(notation), "\(notation) is written back as itself, got:\n\(formatted)")
                let reparsed = try parseOK(formatted)
                #expect(literals(reparsed) == literals(cddl), "got:\n\(formatted)")
                #expect(reparsed.description == formatted)
            }
        }
    }

    /// A value no document spelled is written in the canonical spelling.
    @Test func floatValuesThatNoLiteralWroteAreWrittenCanonically() throws {
        let cases: [(Double, String)] = [
            (1e300, "1.0e300"),
            (-1e300, "-1.0e300"),
            (5e-324, "5.0e-324"),
            (1.5e-300, "1.5e-300"),
            (1e21, "1.0e21"),
            (1e-7, "1.0e-7"),
            (1e20, "100000000000000000000.0"),
            (1e-6, "0.000001"),
            (1.5, "1.5"),
            (0.0, "0.0"),
            (-0.0, "-0.0"),
            (100.0, "100.0"),
        ]
        for (value, expected) in cases {
            let written = Type2(value).description
            #expect(written == expected, "\(value) is written as \(expected)")
            let cddl = try parseOK("scaled = \(written)\n")
            #expect(literals(cddl) == ["FLOAT(\(value))"])
        }
    }

    /// Digits whose magnitude a 64-bit float cannot hold are refused.
    @Test func floatLiteralsBeyondTheFloatRangeAreRefused() throws {
        for literal in ["1.0e400", "-1.0e400", "1e400", "-1e309", "1.7976931348623159e308"] {
            let err = parseErr("scaled = \(literal)\n")
            #expect(err.contains("Float literal out of range"), "\(literal) is refused for its range, got:\n\(err)")
        }

        for (literal, value) in [
            ("1.7976931348623157e308", Double.greatestFiniteMagnitude),
            ("-1.7976931348623157e308", -Double.greatestFiniteMagnitude),
            ("1e308", 1e308),
        ] {
            let cddl = try parseOK("scaled = \(literal)\n")
            #expect(literals(cddl) == ["FLOAT(\(value))"])
            let reparsed = try parseOK(cddl.description)
            #expect(literals(reparsed) == literals(cddl))
        }
    }

    /// Every fixture survives parse, format, parse, with the formatted output
    /// still resolving every rule reference it names, and formatting is a
    /// fixed point.
    @Test func verifyCDDLFixturesRoundTripThroughFormat() throws {
        for file in try Fixtures.cddlFiles(in: "cddl") {
            let formatted = try parseOK(try Fixtures.read(file)).description
            #expect(throws: Never.self, "\(file) does not round-trip through format") {
                try CDDL.fromSlice(Array(formatted.utf8))
            }
            let reformatted = try parseOK(formatted).description
            #expect(reformatted == formatted, "formatting \(file) is not idempotent")
        }
    }

    /// A parse failure is returned, and rendered on request.
    @Test func parseFailuresAreReturnedAndRenderedOnRequest() throws {
        let input = "start = {\n"

        let returned = parseErr(input)
        #expect(returned.contains("parsing error"), "got: \(returned)")

        do {
            _ = try CDDL.fromSlice(Array(input.utf8))
            Issue.record("the input does not parse")
        } catch {
            #expect(error.description.contains("parsing error"), "got: \(error)")
        }

        do {
            _ = try parseCDDL(input)
            Issue.record("the input does not parse")
        } catch {
            let rendered = renderParserError(error, input: input)
            for marker in ["error: parser errors", "start = {", "^"] {
                #expect(rendered.contains(marker), "expected the rendering to contain \(marker), got:\n\(rendered)")
            }
        }
    }
}
