import Testing

@testable import SwiftCDDL

/// The scope of a group-to-choice enumeration (`&`, RFC 8610 Section 2.2.2):
/// only the entries of the enumerated group become choices. Maps and groups
/// nested inside an entry's type keep their own meaning, and errors raised
/// while matching an enumeration are marked as belonging to it.
@Suite struct GroupToChoiceScopeTests {
    // MARK: - Private helpers

    /// A map with text keys, in the order given. Documents here are written
    /// with their keys in sorted order.
    private func object(_ entries: [(String, CBORNode)]) -> CBORNode {
        .map(entries.map { (key: CBORNode.text($0.0), value: $0.1) })
    }

    private func assertValidation(
        _ schema: String,
        _ value: CBORNode,
        _ expected: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let verdict = await cborResult(schema, value.encoded(), sourceLocation: sourceLocation)
        #expect(
            (verdict == nil) == expected,
            "schema: \(schema)\nvalue: \(hexString(value.encoded()))\nexpected valid: \(expected)\nresult: \(String(describing: verdict))",
            sourceLocation: sourceLocation
        )
    }

    private func assertEnumerationDiagnostics(
        _ schema: String,
        _ value: CBORNode,
        _ expected: Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let verdict = await cborResult(schema, value.encoded(), sourceLocation: sourceLocation)
        guard case .validation(let errors)? = verdict else {
            Issue.record(
                "expected validation errors for \(schema), got \(String(describing: verdict))",
                sourceLocation: sourceLocation
            )
            return
        }

        #expect(!errors.isEmpty, sourceLocation: sourceLocation)
        #expect(
            errors.allSatisfy { $0.isGroupToChoiceEnum == expected },
            "schema: \(schema)\nerrors: \(errors)",
            sourceLocation: sourceLocation
        )
        for error in errors {
            let display = error.description
            #expect(
                display.contains("type choice in group to choice enumeration") == expected,
                "schema: \(schema)\nerror: \(display)",
                sourceLocation: sourceLocation
            )
            #expect(!error.reason.isEmpty, sourceLocation: sourceLocation)
            #expect(display.contains(error.reason), sourceLocation: sourceLocation)
        }
    }

    // MARK: - Tests

    @Test func groupToChoiceValidatesNestedMapsAsTypes() async {
        let schemas = [
            // The group-to-choice flag must not turn foo's map fields into
            // another enumeration.
            "root = &(a: { x: foo })\nfoo = { y: uint }",
            "root = &(a: { x: { y: uint } })",
            "root = &(a: wrapper)\nwrapper = { x: foo }\nfoo = { y: uint }",
            "root = &choices\nchoices = (a: { x: foo })\nfoo = { y: uint }",
            "root = &choices<foo>\nchoices<T> = (a: { x: T })\nfoo = { y: uint }",
        ]
        for schema in schemas {
            // {"x": {"y": 1}}
            await assertValidation(schema, object([("x", object([("y", .integer(1))]))]), true)
            let invalid: [CBORNode] = [
                // {"x": {"y": "invalid"}}
                object([("x", object([("y", .text("invalid"))]))]),
                // {"x": {}}
                object([("x", object([]))]),
                // {"x": {"y": 1, "extra": 2}}
                object([("x", object([("extra", .integer(2)), ("y", .integer(1))]))]),
                // {"x": 1}
                object([("x", .integer(1))]),
                // {"y": 1}
                object([("y", .integer(1))]),
                // 1
                .integer(1),
            ]
            for value in invalid {
                await assertValidation(schema, value, false)
            }
        }
    }

    @Test func nestedEnumerationsPreserveLaterGroupChoices() async {
        let schema = "root = &(a: &(zero: 0) // b: 1, c: { x: foo })\nfoo = { y: uint }"

        let valid: [CBORNode] = [.integer(0), .integer(1), object([("x", object([("y", .integer(1))]))])]
        for value in valid {
            await assertValidation(schema, value, true)
        }
        let invalid: [CBORNode] = [.integer(2), object([("x", object([("y", .text("invalid"))]))])]
        for value in invalid {
            await assertValidation(schema, value, false)
        }
    }

    @Test func groupToChoicePreservesNestedGroupsAndEnumerations() async {
        let schema = """

                root = &(a: { fields })
                fields = (x: foo, kind: &(first: 0, second: 1))
                foo = { y: uint }

            """

        // {"x": {"y": 1}, "kind": k}
        for kind: Int64 in [0, 1] {
            await assertValidation(
                schema,
                object([("kind", .integer(kind)), ("x", object([("y", .integer(1))]))]),
                true
            )
        }
        await assertValidation(
            schema,
            object([("kind", .integer(2)), ("x", object([("y", .integer(1))]))]),
            false
        )
        await assertValidation(schema, object([("x", object([("y", .integer(1))]))]), false)
    }

    @Test func groupToChoiceMarksAccumulatedValidationErrors() async {
        for schema in [
            "root = &(a: 1)",
            "root = &choices\nchoices = (a: 1)",
            "root = &choices<1>\nchoices<T> = (a: T)",
        ] {
            await assertEnumerationDiagnostics(schema, .integer(2), true)
        }
        await assertEnumerationDiagnostics(
            "root = &(a: { x: foo })\nfoo = { y: uint }",
            object([("x", object([("y", .text("invalid"))]))]),
            true
        )
        await assertEnumerationDiagnostics("root = 1", .integer(2), false)
    }

    @Test func groupToChoiceMarksReturnedValidationErrors() async {
        // Malformed regex controllers return errors directly instead of
        // accumulating them.
        for schema in [
            #"root = &(a: tstr .regexp "[")"#,
            "root = &choices\nchoices = (a: tstr .regexp \"[\")",
            "root = &choices<tstr>\nchoices<T> = (a: T .regexp \"[\")",
            "root = &(a: &(b: tstr .regexp \"[\"))",
        ] {
            await assertEnumerationDiagnostics(schema, .text("value"), true)
        }
        await assertEnumerationDiagnostics(#"root = tstr .regexp "[""#, .text("value"), false)
    }
}
