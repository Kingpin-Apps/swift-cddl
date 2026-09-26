import Testing

@testable import SwiftCDDL

/// Incremental definitions (RFC 8610 Appendix C) at parse time: a plain `=`
/// after an incremental `/=`
/// or `//=` of the same name is a duplicate definition. The validation
/// verdicts of those files belong to the validator stages.
@Suite struct IncrementalChoicesTests {
    @Test(arguments: [
        "r = {g}\ng //= (k: int)\ng = (j: int)\n",
        "g //= (k: int)\ng = (j: int)\n",
        "$$foo //= (k: int)\n$$foo = (j: int)\nroot = {$$foo}\n",
    ])
    func baseGroupDefinitionCannotFollowAnIncrementalGroupDefinition(_ schema: String) {
        let error = parseErr(schema)
        #expect(error.contains("already defined"), "unexpected parser error for \(schema.debugDescription): \(error)")
    }

    @Test(arguments: [
        "extended /= text\nextended = bool\n",
        "root = extended\nextended /= text\nextended = bool\n",
        "$foo /= int\n$foo = text\nroot = text\n",
        "a /= text\na = text\n",
        "a /= text\na<t> = int\n",
    ])
    func baseTypeDefinitionCannotFollowAnIncrementalTypeDefinition(_ schema: String) {
        let error = parseErr(schema)
        #expect(error.contains("already defined"), "unexpected parser error for \(schema.debugDescription): \(error)")
    }

    @Test(arguments: ["r = t\nt /= int\nt = (j: int)\n", "r = {g}\ng //= (k: int)\ng = tstr\n"])
    func baseDefinitionCannotChangeKindAfterAnIncrementalDefinition(_ schema: String) {
        let error = parseErr(schema)
        #expect(error.contains("already defined"), "unexpected parser error for \(schema.debugDescription): \(error)")
    }

    @Test func duplicateRuleErrorsCarryTheOffendingRulePosition() {
        for schema in [
            "a = int\nb = tstr\na = tstr\n",
            "t /= int\nx = tstr\nt = tstr\n",
            "g //= (k: int)\nx = tstr\ng = (j: int)\n",
            "t /= int\nx = tstr\nt = (j: int)\n",
            "g //= (k: int)\nx = tstr\ng = tstr\n",
        ] {
            let error = parseErr(schema)
            #expect(error.contains("already defined"), "unexpected parser error for \(schema.debugDescription): \(error)")
            #expect(error.contains("line: 3"), "duplicate-rule error lost the rule position: \(error)")
        }

        // The multibyte comment makes the byte range differ from a character
        // count, and the indented duplicate exercises the column.
        let schema = "a = int\n; é\n  a = tstr\n"
        do {
            _ = try parseCDDL(schema)
            Issue.record("expected a duplicate-rule rejection")
        } catch {
            guard case .parser(let position, let msg) = error else {
                Issue.record("unexpected parser error: \(error)")
                return
            }
            #expect(msg.short.contains("already defined"))
            #expect(position.line == 3)
            #expect(position.column == 3)
            // The range covers the redefining declaration, without the line
            // break the rule's span takes in.
            #expect(position.range == (15, 23))
            #expect(position.index == 15)
        }
    }

    @Test func incrementalDefinitionsAfterAPlainBaseStayValid() {
        for schema in [
            "a = text\na /= text\n",
            "a = bool\na /= text\na /= uint\n",
            "root = a<int>\na<t> = [t]\na<t> /= {k: t}\n",
        ] {
            #expect(throws: Never.self) { try cddlFromStr(schema) }
        }
    }

    @Test func incrementalGroupChainParses() {
        for schema in ["r = {g}\ng //= (k: int)\ng //= (j: int)\n", "g //= (k: int)\ng //= (j: int)\nr = {g}\n"] {
            #expect(throws: Never.self) { try cddlFromStr(schema) }
        }
    }

    /// Schemas built from incremental type choices all parse, and
    /// keep their incremental arms.
    @Test(arguments: [
        "\nextended = bool\nextended /= text\nextended /= uint\n",
        "\nroot = extended\nextended = bool\nextended /= text\nextended /= uint\n",
        "\nextended /= text\nextended /= uint\n",
        "\nroot = extended\nextended /= text\nextended /= uint\n",
        "root = a<int>\na<t> = [t]\na<t> /= {k: t}\n",
        "t = uint\nt /= [t]\n",
        "root = t\nt = uint\nt /= [t]\n",
        "t /= uint\nt /= [t]\n",
        "list = [* item]\nitem = int\nitem /= list\n",
        "a /= a\n",
        "root = a\na /= a\n",
    ])
    func incrementalTypeChoiceSchemasParse(_ schema: String) throws {
        let cddl = try parseOK(schema)
        #expect(cddl.rules.contains { $0.isChoiceAlternate() })
    }
}
