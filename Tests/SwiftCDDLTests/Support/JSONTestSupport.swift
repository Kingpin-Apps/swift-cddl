import Foundation
import Testing

@testable import SwiftCDDL

// Helpers shared by the JSON validation tests.
//
// Every document validated through `jsonResult` or `jsonNodeResult` is also
// run through the reference oracle when `CDDL_ORACLE_BIN` names its
// executable, and the two verdicts are compared -- and, for a document that
// does not match, the errors too -- so running the suite with the variable set
// is the differential test over every ported vector.

/// What validating a JSON document ended with: `nil` when it matched.
typealias JSONVerdict = JSONValidationError?

/// Validates the JSON `json` against `cddl`, parsing both as the one-call
/// entry point does, and returns the failure, or `nil` when the document
/// matches.
///
/// `rule` selects the root rule; without it the first type rule is the root.
/// When the reference oracle is configured and the call uses no enabled
/// features, the oracle's verdict is compared with this one.
@discardableResult
func jsonResult(
    _ cddl: String,
    _ json: String,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    limits: ValidationLimits = ValidationLimits(),
    compareErrors: Bool = true,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> JSONVerdict {
    var verdict: JSONVerdict = nil
    do {
        try await validateJSON(cddl: cddl, json: json, rule: rule, enabledFeatures: enabledFeatures, limits: limits)
    } catch {
        verdict = error
    }
    if enabledFeatures == nil && limits == ValidationLimits() {
        JSONOracleCheck.compare(
            cddl: cddl,
            json: json,
            rule: rule,
            verdict: verdict,
            compareErrors: compareErrors,
            sourceLocation: sourceLocation
        )
    }
    return verdict
}

/// Validates the value `node` against the parsed `cddl`, as a validator built
/// from a node does, and returns the failure, or `nil` when it matches.
@discardableResult
func jsonNodeResult(
    _ cddl: String,
    _ node: JSONNode,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> JSONVerdict {
    let schema: CDDL
    do {
        schema = try cddlFromStr(cddl)
    } catch {
        Issue.record("schema does not parse: \(error)", sourceLocation: sourceLocation)
        return .cddlParsing(error.description)
    }
    let validator = JSONValidator(cddl: schema, json: node, enabledFeatures: enabledFeatures)
    if let rule {
        validator.setRootRule(rule)
    }
    var verdict: JSONVerdict = nil
    do {
        try await validator.validate()
    } catch {
        verdict = error
    }
    if enabledFeatures == nil {
        JSONOracleCheck.compare(
            cddl: cddl,
            json: node.description,
            rule: rule,
            verdict: verdict,
            compareErrors: true,
            sourceLocation: sourceLocation
        )
    }
    return verdict
}

/// Expects `json` to match `cddl`.
func expectJSONValid(
    _ cddl: String,
    _ json: String,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await jsonResult(
        cddl, json, rule: rule, enabledFeatures: enabledFeatures, sourceLocation: sourceLocation)
    #expect(verdict == nil, "expected a match, got \(verdict.map { "\($0)" } ?? "")", sourceLocation: sourceLocation)
}

/// Expects `json` not to match `cddl`, and returns the failure.
@discardableResult
func expectJSONInvalid(
    _ cddl: String,
    _ json: String,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> JSONValidationError? {
    let verdict = await jsonResult(
        cddl, json, rule: rule, enabledFeatures: enabledFeatures, sourceLocation: sourceLocation)
    #expect(verdict != nil, "expected a mismatch", sourceLocation: sourceLocation)
    return verdict
}

/// The errors of a failure that is a mismatch, or an empty list (recording an
/// issue) for any other failure.
func jsonIssues(
    _ verdict: JSONVerdict,
    sourceLocation: SourceLocation = #_sourceLocation
) -> [JSONValidationIssue] {
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

/// Comparison of JSON verdicts with the reference oracle.
enum JSONOracleCheck {
    /// Runs the oracle over one document.
    static func run(cddl: String, rule: String, json: String) throws -> OracleCheck.Output? {
        #if os(macOS) || os(Linux)
            guard let executable = OracleCheck.executable else { return nil }
            let directory = FileManager.default.temporaryDirectory
            let cddlURL = directory.appendingPathComponent("cddl-verdict-\(UUID().uuidString).cddl")
            let jsonURL = directory.appendingPathComponent("cddl-verdict-\(UUID().uuidString).json")
            try Data(cddl.utf8).write(to: cddlURL)
            try Data(json.utf8).write(to: jsonURL)
            defer {
                try? FileManager.default.removeItem(at: cddlURL)
                try? FileManager.default.removeItem(at: jsonURL)
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--cddl", cddlURL.path, "--rule", rule, "--json-file", jsonURL.path]
            let stdout = Pipe()
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return try JSONDecoder().decode(OracleCheck.Output.self, from: output)
        #else
            return nil
        #endif
    }

    /// The errors of `verdict` as the oracle prints them: a path and a reason
    /// each, a fault in the schema marked as such.
    static func printedErrors(_ verdict: JSONVerdict) -> [String]? {
        switch verdict {
        case nil:
            return []
        case .validation(let issues)?:
            return issues.map { "\($0.jsonLocation): \($0.reason)" }
        case .invalidSchema(let issue)?:
            return ["\(issue.jsonLocation): invalid schema: \(issue.reason)"]
        default:
            return nil
        }
    }

    /// Whether the oracle's verdict, and with `compareErrors` its errors,
    /// agree with `verdict`; `nil` when there is nothing to compare.
    static func divergence(
        cddl: String,
        json: String,
        rule: String?,
        verdict: JSONVerdict,
        compareErrors: Bool
    ) throws -> String? {
        // `.abnf` and `.abnfb` matching is not provided, so there is no verdict
        // of this implementation to compare.
        if case .unsupported? = verdict { return nil }
        guard let rule = rule ?? OracleCheck.defaultRootRule(cddl) else { return nil }
        guard let output = try run(cddl: cddl, rule: rule, json: json), let valid = output.valid else {
            return nil
        }
        if valid != (verdict == nil) {
            return
                "reference oracle verdict differs: oracle valid=\(valid) \(output.errors?.map { "\($0.path): \($0.reason)" } ?? []), this implementation: \(verdict.map { "\($0)" } ?? "valid")"
        }
        if compareErrors, !valid, let oracleErrors = output.errors, let mine = printedErrors(verdict) {
            let theirs = oracleErrors.map { "\($0.path): \($0.reason)" }
            if theirs != mine {
                return "reference oracle errors differ:\n  oracle: \(theirs)\n  this implementation: \(mine)"
            }
        }
        return nil
    }

    /// Records an issue when the oracle's verdict differs from `verdict`.
    static func compare(
        cddl: String,
        json: String,
        rule: String?,
        verdict: JSONVerdict,
        compareErrors: Bool,
        sourceLocation: SourceLocation
    ) {
        guard OracleCheck.executable != nil else { return }
        do {
            if let difference = try divergence(
                cddl: cddl, json: json, rule: rule, verdict: verdict, compareErrors: compareErrors)
            {
                Issue.record("\(difference)", sourceLocation: sourceLocation)
            }
        } catch {
            Issue.record("the reference oracle did not run: \(error)", sourceLocation: sourceLocation)
        }
    }
}
