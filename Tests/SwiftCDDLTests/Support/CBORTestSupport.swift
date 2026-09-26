import Foundation
import Testing

@testable import SwiftCDDL

// Helpers shared by the CBOR validation tests.
//
// Every document validated through `cborResult` or `nodeResult` is also run
// through the reference oracle when `CDDL_ORACLE_BIN` names its executable,
// and the two verdicts are compared, so running the suite with the variable
// set is the differential test over every ported vector.

/// What validating a document ended with: `nil` when it matched.
typealias CBORVerdict = CBORValidationError?

/// Validates the CBOR `bytes` against `cddl`, parsing the schema and decoding
/// the document as the one-call entry point does, and returns the failure, or
/// `nil` when the document matches.
///
/// `rule` selects the root rule; without it the first type rule is the root.
/// When the reference oracle is configured and the call uses no enabled
/// features, the oracle's verdict is compared with this one; `comparePaths`
/// also compares the locations of the errors.
@discardableResult
func cborResult(
    _ cddl: String,
    _ bytes: [UInt8],
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    comparePaths: Bool = false,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> CBORVerdict {
    var verdict: CBORVerdict = nil
    do {
        try await validateCBOR(cddl: cddl, cbor: bytes, rule: rule, enabledFeatures: enabledFeatures)
    } catch {
        verdict = error
    }
    if enabledFeatures == nil {
        OracleCheck.compare(
            cddl: cddl,
            bytes: bytes,
            rule: rule,
            verdict: verdict,
            comparePaths: comparePaths,
            sourceLocation: sourceLocation
        )
    }
    return verdict
}

/// Validates the data item `node` against the parsed `cddl`, as a validator
/// built from a node does, and returns the failure, or `nil` when it matches.
/// The oracle, when configured, is handed the node's encoding.
@discardableResult
func nodeResult(
    _ cddl: String,
    _ node: CBORNode,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    comparePaths: Bool = false,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> CBORVerdict {
    let schema: CDDL
    do {
        schema = try cddlFromStr(cddl)
    } catch {
        Issue.record("schema does not parse: \(error)", sourceLocation: sourceLocation)
        return .cddlParsing(error.description)
    }
    let validator = CBORValidator(cddl: schema, cbor: node, enabledFeatures: enabledFeatures)
    if let rule {
        validator.setRootRule(rule)
    }
    var verdict: CBORVerdict = nil
    do {
        try await validator.validate()
    } catch {
        verdict = error
    }
    if enabledFeatures == nil {
        OracleCheck.compare(
            cddl: cddl,
            bytes: node.encoded(),
            rule: rule,
            verdict: verdict,
            comparePaths: comparePaths,
            sourceLocation: sourceLocation
        )
    }
    return verdict
}

/// Expects `bytes` to match `cddl`.
func expectValid(
    _ cddl: String,
    _ bytes: [UInt8],
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await cborResult(
        cddl, bytes, rule: rule, enabledFeatures: enabledFeatures, sourceLocation: sourceLocation)
    #expect(verdict == nil, "expected a match, got \(verdict.map { "\($0)" } ?? "")", sourceLocation: sourceLocation)
}

/// Expects `bytes` not to match `cddl`, and returns the failure.
@discardableResult
func expectInvalid(
    _ cddl: String,
    _ bytes: [UInt8],
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> CBORValidationError? {
    let verdict = await cborResult(
        cddl, bytes, rule: rule, enabledFeatures: enabledFeatures, sourceLocation: sourceLocation)
    #expect(verdict != nil, "expected a mismatch", sourceLocation: sourceLocation)
    return verdict
}

/// The errors of a failure that is a mismatch, or an empty list (recording an
/// issue) for any other failure.
func issues(
    _ verdict: CBORVerdict,
    sourceLocation: SourceLocation = #_sourceLocation
) -> [CBORValidationIssue] {
    guard let verdict else {
        Issue.record("expected validation errors, the document matched", sourceLocation: sourceLocation)
        return []
    }
    guard let issues = verdict.issues else {
        Issue.record("expected validation errors, got \(verdict)", sourceLocation: sourceLocation)
        return []
    }
    return issues
}

/// Comparison of verdicts with the reference oracle.
enum OracleCheck {
    static var executable: String? {
        ProcessInfo.processInfo.environment["CDDL_ORACLE_BIN"]
    }

    /// What the oracle printed for one document.
    struct Output: Decodable {
        struct Error: Decodable {
            var path: String
            var reason: String
        }
        var valid: Bool?
        var errors: [Error]?
        var parseError: String?
    }

    /// The rule the root is chosen by when no rule is named: the first type
    /// rule that takes no generic parameters.
    static func defaultRootRule(_ cddl: String) -> String? {
        guard let schema = try? cddlFromStr(cddl) else { return nil }
        for rule in schema.rules {
            if case .type(let rule, _, _, _) = rule, rule.genericParams == nil {
                return rule.name.ident
            }
        }
        return nil
    }

    /// Runs the oracle over one document.
    static func run(cddl: String, rule: String, bytes: [UInt8]) throws -> Output? {
        #if os(macOS) || os(Linux)
            guard let executable else { return nil }
            let cddlURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cddl-verdict-\(UUID().uuidString).cddl")
            try Data(cddl.utf8).write(to: cddlURL)
            defer { try? FileManager.default.removeItem(at: cddlURL) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--cddl", cddlURL.path, "--rule", rule, "--cbor-hex", hexString(bytes)]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return try JSONDecoder().decode(Output.self, from: output)
        #else
            return nil
        #endif
    }

    /// Records an issue when the oracle's verdict differs from `verdict`.
    static func compare(
        cddl: String,
        bytes: [UInt8],
        rule: String?,
        verdict: CBORVerdict,
        comparePaths: Bool,
        sourceLocation: SourceLocation
    ) {
        guard executable != nil else { return }
        // `.abnf` and `.abnfb` matching is not provided, so there is no verdict
        // of this implementation to compare.
        if case .unsupported? = verdict { return }
        guard let rule = rule ?? defaultRootRule(cddl) else { return }
        let output: Output?
        do {
            output = try run(cddl: cddl, rule: rule, bytes: bytes)
        } catch {
            Issue.record("the reference oracle did not run: \(error)", sourceLocation: sourceLocation)
            return
        }
        guard let output, let valid = output.valid else { return }
        #expect(
            valid == (verdict == nil),
            "reference oracle verdict differs: oracle valid=\(valid) \(output.errors?.map { "\($0.path): \($0.reason)" } ?? []), this implementation: \(verdict.map { "\($0)" } ?? "valid")",
            sourceLocation: sourceLocation
        )
        if comparePaths, !valid, let oracleErrors = output.errors, let issues = verdict?.issues {
            #expect(
                oracleErrors.map(\.path) == issues.map(\.cborLocation),
                "reference oracle error paths differ",
                sourceLocation: sourceLocation
            )
        }
    }
}
