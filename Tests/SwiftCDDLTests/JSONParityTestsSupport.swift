import Foundation
import Testing

@testable import SwiftCDDL

/// Documents, schemas and checks shared by the JSON parity tests: a rejection
/// both validators can reach is worded in one place, and a type states the
/// same thing wherever it stands.
enum JSONParityFixture {
    /// `levels` nested containers opened by `open` and closed by `close` around
    /// `leaf`.
    static func nested(_ levels: Int, _ open: String, _ close: String, _ leaf: String) -> String {
        String(repeating: open, count: levels) + leaf + String(repeating: close, count: levels)
    }

    /// `levels` nested single-element arrays around an empty array.
    static func nestedEmptyArrays(_ levels: Int) -> String {
        nested(levels, "[", "]", "[]")
    }

    /// The reasons `json` was rejected for; empty when it matched.
    static func reasons(
        _ cddl: String,
        _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [String] {
        await errors(cddl, json, sourceLocation: sourceLocation).map(\.reason)
    }

    /// The locations of every error `json` was rejected for, in the order they
    /// are reported.
    static func locations(
        _ cddl: String,
        _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [String] {
        await errors(cddl, json, sourceLocation: sourceLocation).map(\.jsonLocation)
    }

    /// The errors `json` was rejected with; any failure other than a mismatch
    /// is recorded as an issue.
    static func errors(
        _ cddl: String,
        _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [JSONValidationIssue] {
        let verdict = await jsonResult(cddl, json, sourceLocation: sourceLocation)
        guard let verdict else { return [] }
        guard let issues = verdict.issues else {
            Issue.record("expected validation errors, got \(verdict)", sourceLocation: sourceLocation)
            return []
        }
        return issues
    }

    /// Whether `json` matches `schema`, where the verdict has to be a settled
    /// one: a match or a mismatch, never a fault in the schema itself.
    static func settled(
        _ schema: String,
        _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let verdict = await jsonResult(schema, json, sourceLocation: sourceLocation)
        guard let verdict else { return true }
        if verdict.issues == nil {
            Issue.record("\(schema): \(verdict)", sourceLocation: sourceLocation)
        }
        return false
    }

    /// Whether both validators settle `schema` alike for a document that maps
    /// onto both data models, and what they settle it as.
    static func settledAlike(
        _ schema: String,
        _ node: CBORNode,
        _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let cbor = await CBORParityFixture.settled(schema, node, sourceLocation: sourceLocation)
        let other = await settled(schema, json, sourceLocation: sourceLocation)
        #expect(
            cbor == other, "\(schema) against \(json) was settled differently by the two validators",
            sourceLocation: sourceLocation)
        return other
    }

    /// Validates `json` against `schema` under `limits`.
    static func limited(_ schema: String, _ json: String, _ limits: ValidationLimits) async -> JSONVerdict {
        await jsonResult(schema, json, limits: limits)
    }

    // MARK: - Placements

    /// The three places a type named `x` is used from: the root, an object
    /// value and an array item, each with the document placed to match.
    static func placementsOfX(_ schema: String, _ json: String) -> [(schema: String, json: String)] {
        [
            ("root = x\n\(schema)", json),
            ("root = {v: x}\n\(schema)", "{\"v\":\(json)}"),
            ("root = [x]\n\(schema)", "[\(json)]"),
        ]
    }

    /// Holds a type expression to the documents it admits and the documents it
    /// refuses, at the root, in the value of an object member and in an item of
    /// an array: a type states the same thing wherever it stands.
    static func assertSettledInEveryPlacement(
        _ prelude: String,
        _ typeExpr: String,
        admitted: [String],
        refused: [String],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let placements: [(String, (String) -> String)] = [
            ("root = \(typeExpr)\(prelude)", { $0 }),
            ("root = { k: \(typeExpr) }\(prelude)", { "{\"k\":\($0)}" }),
            ("root = [\(typeExpr)]\(prelude)", { "[\($0)]" }),
        ]
        for (schema, wrap) in placements {
            for document in admitted {
                let got = await reasons(schema, wrap(document), sourceLocation: sourceLocation)
                #expect(got == [], "refused \(wrap(document)) against \(schema)", sourceLocation: sourceLocation)
            }
            for document in refused {
                let got = await reasons(schema, wrap(document), sourceLocation: sourceLocation)
                #expect(!got.isEmpty, "admitted \(wrap(document)) against \(schema)", sourceLocation: sourceLocation)
            }
        }
    }

    /// The one reason a document is refused for, in every placement of `x`.
    static func reasonsInEveryPlacement(
        _ schema: String,
        _ json: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [(schema: String, reason: String)] {
        var out: [(schema: String, reason: String)] = []
        for (placed, document) in placementsOfX(schema, json) {
            let got = await reasons(placed, document, sourceLocation: sourceLocation)
            #expect(got.count == 1, "against \(placed): \(got)", sourceLocation: sourceLocation)
            out.append((placed, got.first ?? ""))
        }
        return out
    }
}
