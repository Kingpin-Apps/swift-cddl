import Foundation
import Testing

@testable import SwiftCDDL

/// Documents, schemas and checks shared by the CBOR parity tests: a rejection
/// the validator can reach is worded in one place, and a type states the same
/// thing wherever it stands.
enum CBORParityFixture {
    // MARK: - Data items

    static func int(_ value: Int64) -> CBORNode {
        .integer(value)
    }

    static func text(_ value: String) -> CBORNode {
        .text(value)
    }

    static func array(_ items: [CBORNode]) -> CBORNode {
        .array(items)
    }

    /// A map with text keys, in the order given.
    static func map(_ entries: [(String, CBORNode)]) -> CBORNode {
        .map(entries.map { (key: CBORNode.text($0.0), value: $0.1) })
    }

    /// A float in the narrowest width that holds it exactly (RFC 8949
    /// Section 4.2.2), which is how a float data item is encoded when no width
    /// is asked for.
    static func float(_ value: Double) -> CBORNode {
        if value.isNaN || value.isInfinite || value == 0 {
            return .float(value, width: .half)
        }
        let single = Float(value)
        guard Double(single) == value else {
            return .float(value, width: .double)
        }
        let magnitude = abs(value)
        if magnitude <= 65504 {
            if magnitude >= 0x1p-14 {
                // Eleven significant bits in the normal range of a half.
                let scaled = Double(sign: .plus, exponent: 10 - magnitude.exponent, significand: magnitude)
                if scaled == scaled.rounded() {
                    return .float(value, width: .half)
                }
            } else {
                // A subnormal half is a multiple of 2^-24.
                let scaled = magnitude * 0x1p24
                if scaled == scaled.rounded() {
                    return .float(value, width: .half)
                }
            }
        }
        return .float(value, width: .single)
    }

    /// `levels` nested single-element arrays around `leaf`.
    static func nestedArrays(_ levels: Int, _ leaf: CBORNode) -> CBORNode {
        var value = leaf
        for _ in 0..<levels {
            value = .array([value])
        }
        return value
    }

    /// `levels` nested single-entry maps around `leaf`, every key the text
    /// `"k"`.
    static func nestedMaps(_ levels: Int, _ leaf: CBORNode) -> CBORNode {
        var value = leaf
        for _ in 0..<levels {
            value = map([("k", value)])
        }
        return value
    }

    /// `levels` nested single-element arrays around an empty array. Every level
    /// is one step into a nested item and the empty array at the bottom is
    /// none.
    static func nestedEmptyArrays(_ levels: Int) -> CBORNode {
        nestedArrays(levels, .array([]))
    }

    // MARK: - Schemas

    /// A schema whose every level of data resolves `hops` chained rule
    /// references before reaching the array that nests the next level.
    static func chainedAliases(_ hops: Int) -> String {
        var schema = "\nx = [* r0]\n"
        for alias in 0..<(hops - 1) {
            schema += "r\(alias) = r\(alias + 1)\n"
        }
        schema += "r\(hops - 1) = x\n"
        return schema
    }

    /// The schema of a map type with `entries` entries `f0: uint, f1: uint, ...`.
    static func wideMapSchema(_ entries: Int) -> String {
        var schema = "x = {\n"
        for index in 0..<entries {
            schema += "  f\(index): uint,\n"
        }
        schema += "}\n"
        return schema
    }

    /// The head a map type of `entries` entries renders as: the first
    /// `maxRenderedGroupEntries` of them, and a count of the rest.
    static func wideMapHead(_ entries: Int) -> String {
        let kept = (0..<min(entries, maxRenderedGroupEntries)).map { "f\($0): uint" }
        if entries > maxRenderedGroupEntries {
            return "{ \(kept.joined(separator: ", ")), \u{2026} \(entries - maxRenderedGroupEntries) more }"
        }
        return "{ \(kept.joined(separator: ", ")) }"
    }

    // MARK: - Verdicts

    /// The reasons the document `node` was rejected for, validated from its
    /// encoding; empty when it matched.
    static func reasons(
        _ cddl: String,
        _ node: CBORNode,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [String] {
        let verdict = await cborResult(cddl, node.encoded(), sourceLocation: sourceLocation)
        return reasons(of: verdict, sourceLocation: sourceLocation)
    }

    /// The reasons of a verdict that is a match or a mismatch; any other
    /// failure is recorded as an issue.
    static func reasons(
        of verdict: CBORVerdict,
        sourceLocation: SourceLocation = #_sourceLocation
    ) -> [String] {
        guard let verdict else { return [] }
        guard let issues = verdict.issues else {
            Issue.record("expected validation errors, got \(verdict)", sourceLocation: sourceLocation)
            return []
        }
        return issues.map(\.reason)
    }

    /// The locations of every error the document `node` was rejected for, in
    /// the order they are reported.
    static func locations(
        _ cddl: String,
        _ node: CBORNode,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [String] {
        let verdict = await cborResult(cddl, node.encoded(), sourceLocation: sourceLocation)
        guard let verdict else { return [] }
        guard let issues = verdict.issues else {
            Issue.record("expected validation errors, got \(verdict)", sourceLocation: sourceLocation)
            return []
        }
        return issues.map(\.cborLocation)
    }

    /// The errors the document given as its `bytes` was rejected with.
    static func errors(
        _ cddl: String,
        _ bytes: [UInt8],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [CBORValidationIssue] {
        let verdict = await cborResult(cddl, bytes, sourceLocation: sourceLocation)
        guard let verdict else { return [] }
        guard let issues = verdict.issues else {
            Issue.record("expected validation errors, got \(verdict)", sourceLocation: sourceLocation)
            return []
        }
        return issues
    }

    /// Whether `node` matches `schema`, where the verdict has to be a settled
    /// one: a match or a mismatch, never a fault in the schema itself.
    static func settled(
        _ schema: String,
        _ node: CBORNode,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Bool {
        let verdict = await cborResult(schema, node.encoded(), sourceLocation: sourceLocation)
        guard let verdict else { return true }
        if verdict.issues == nil {
            Issue.record("\(schema): \(verdict)", sourceLocation: sourceLocation)
        }
        return false
    }

    /// Validates `bytes` against `schema` under `limits`.
    static func limited(
        _ schema: String,
        _ bytes: [UInt8],
        _ limits: ValidationLimits
    ) async -> CBORVerdict {
        do {
            try await validateCBOR(cddl: schema, cbor: bytes, limits: limits)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Placements

    /// The three places a type named `x` is used from: the root, a map value
    /// and an array item, each with the document placed to match.
    static func placementsOfX(_ schema: String, _ node: CBORNode) -> [(schema: String, node: CBORNode)] {
        [
            ("root = x\n\(schema)", node),
            ("root = {v: x}\n\(schema)", map([("v", node)])),
            ("root = [x]\n\(schema)", .array([node])),
        ]
    }

    /// Holds a type expression to the documents it admits and the documents it
    /// refuses, at the root, in the value of a map entry and in an item of an
    /// array: a type states the same thing wherever it stands.
    static func assertSettledInEveryPlacement(
        _ prelude: String,
        _ typeExpr: String,
        admitted: [CBORNode],
        refused: [CBORNode],
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let placements: [(String, (CBORNode) -> CBORNode)] = [
            ("root = \(typeExpr)\(prelude)", { $0 }),
            ("root = { k: \(typeExpr) }\(prelude)", { map([("k", $0)]) }),
            ("root = [\(typeExpr)]\(prelude)", { .array([$0]) }),
        ]
        for (schema, wrap) in placements {
            for value in admitted {
                let document = wrap(value)
                let got = await reasons(schema, document, sourceLocation: sourceLocation)
                #expect(got == [], "refused \(hexString(document.encoded())) against \(schema)", sourceLocation: sourceLocation)
            }
            for value in refused {
                let document = wrap(value)
                let got = await reasons(schema, document, sourceLocation: sourceLocation)
                #expect(!got.isEmpty, "admitted \(hexString(document.encoded())) against \(schema)", sourceLocation: sourceLocation)
            }
        }
    }

    /// The one reason a document is refused for, in every placement of `x`.
    static func reasonsInEveryPlacement(
        _ schema: String,
        _ node: CBORNode,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> [(schema: String, reason: String)] {
        var out: [(schema: String, reason: String)] = []
        for (placed, document) in placementsOfX(schema, node) {
            let got = await reasons(placed, document, sourceLocation: sourceLocation)
            #expect(got.count == 1, "against \(placed): \(got)", sourceLocation: sourceLocation)
            out.append((placed, got.first ?? ""))
        }
        return out
    }
}
