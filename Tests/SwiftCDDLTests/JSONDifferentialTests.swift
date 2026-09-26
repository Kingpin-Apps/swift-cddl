import Foundation
import Testing

@testable import SwiftCDDL

// The JSON validator held to the reference oracle over whole fixture
// documents and over single-edit mutations of them. Every document is
// validated here and by the oracle, and the verdicts, and for a mismatch the
// errors -- path and reason each -- have to agree. The suite runs only when
// `CDDL_ORACLE_BIN` names the oracle executable.

/// A deterministic generator of pseudo-random numbers (SplitMix64), so a run
/// mutates the same documents the same way every time.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func below(_ bound: Int) -> Int {
        Int(next() % UInt64(bound))
    }

    mutating func pick<T>(_ items: [T]) -> T {
        items[below(items.count)]
    }
}

/// A schema and the documents written against it.
private struct Corpus {
    var name: String
    var cddl: String
    var rule: String?
    var documents: [String]
}

/// The fixture schemas with JSON documents: the reputation example of RFC
/// 8610 Appendix H and the DID document examples.
private func fixtureCorpora() throws -> [Corpus] {
    var corpora = [
        Corpus(
            name: "reputon", cddl: try Fixtures.read("cddl/reputon.cddl"), rule: nil,
            documents: [try Fixtures.read("json/reputon.json")])
    ]
    let root = Fixtures.url("did")
    let manager = FileManager.default
    for directory in try manager.contentsOfDirectory(atPath: root.path).sorted() {
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: root.appendingPathComponent(directory).path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { continue }
        let files = try manager.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path).sorted()
        guard let schema = files.first(where: { $0.hasSuffix(".cddl") }) else { continue }
        let documents = try files.filter { $0.hasSuffix(".json") }.map { try Fixtures.read("did/\(directory)/\($0)") }
        if !documents.isEmpty {
            corpora.append(
                Corpus(
                    name: directory, cddl: try Fixtures.read("did/\(directory)/\(schema)"), rule: nil,
                    documents: documents))
        }
    }
    return corpora
}

// MARK: - Mutations

/// Scalars a value is replaced with: every kind, and the edges of the number
/// grammar.
private let replacementScalars = [
    "null", "true", "false", "0", "-0", "1", "-1", "255", "256", "65535", "65536", "4294967296",
    "18446744073709551615", "18446744073709551616", "-9223372036854775808", "-9223372036854775809",
    "1.5", "-1.5", "1e3", "1E-3", "1.0", "0.1", "1e300", "123456789012345678901234567890", "\"\"", "\"x\"",
    "\"did:example:123\"", "\"https://example.com/a\"", "\"2020-01-01T00:00:00Z\"", "\"\\u00e9\"", "\"e\\u0301\"",
    "[]", "{}", "[1]", "{\"a\":1}",
]

/// Characters an edit of the text inserts or substitutes.
private let editCharacters: [Character] = Array("{}[]\":,0123456789-+.eEtrufalsn \\x")

/// The paths to every value of `node`, as the steps to reach it.
private enum Step {
    case index(Int)
    case member(Int)
}

private func allPaths(_ node: JSONNode) -> [[Step]] {
    var paths: [[Step]] = []
    var pending: [(JSONNode, [Step])] = [(node, [])]
    while let (current, path) = pending.popLast() {
        paths.append(path)
        switch current {
        case .array(let array):
            for (idx, item) in array.items.enumerated() {
                pending.append((item, path + [.index(idx)]))
            }
        case .object(let object):
            for (idx, member) in object.members.enumerated() {
                pending.append((member.value, path + [.member(idx)]))
            }
        default:
            break
        }
    }
    return paths
}

/// `node` with the value at `path` replaced by what `change` makes of it; a
/// change returning `nil` removes the value from its container.
private func rewrite(_ node: JSONNode, _ path: ArraySlice<Step>, _ change: (JSONNode) -> JSONNode?) -> JSONNode? {
    guard let step = path.first else {
        return change(node)
    }
    switch (node, step) {
    case (.array(let array), .index(let idx)):
        var items = array.items
        if let replaced = rewrite(items[idx], path.dropFirst(), change) {
            items[idx] = replaced
        } else {
            items.remove(at: idx)
        }
        return .array(items)
    case (.object(let object), .member(let idx)):
        var members = object.members
        if let replaced = rewrite(members[idx].value, path.dropFirst(), change) {
            members[idx].value = replaced
        } else {
            members.remove(at: idx)
        }
        return .object(members)
    default:
        return node
    }
}

/// One edit of the value of `document`: a value replaced, removed, doubled,
/// or given a member or an item more.
private func structuralMutation(_ document: String, _ random: inout SplitMix64) -> String? {
    guard let node = try? JSONNode.parse(document) else { return nil }
    let paths = allPaths(node)
    let path = random.pick(paths)
    let kind = random.below(6)
    let replacement = random.pick(replacementScalars)
    let mutated = rewrite(node, path[...]) { value in
        switch kind {
        case 0, 1:
            return try? JSONNode.parse(replacement)
        case 2:
            return path.isEmpty ? value : nil
        case 3:
            if case .array(let array) = value, !array.items.isEmpty {
                return .array(array.items + [array.items[random.below(array.items.count)]])
            }
            if case .object(let object) = value, !object.members.isEmpty {
                let member = object.members[random.below(object.members.count)]
                return .object(object.members + [member])
            }
            return try? JSONNode.parse(replacement)
        case 4:
            if case .object(let object) = value {
                let name = random.pick(["id", "type", "controller", "extra", "", "@context", "rating"])
                return .object(object.members + [(key: name, value: (try? JSONNode.parse(replacement)) ?? .null)])
            }
            if case .array(let array) = value {
                return .array(array.items + [(try? JSONNode.parse(replacement)) ?? .null])
            }
            return .array([value])
        default:
            if case .string(let s) = value, !s.isEmpty {
                var scalars = Array(s.unicodeScalars)
                scalars.remove(at: random.below(scalars.count))
                var view = String.UnicodeScalarView()
                view.append(contentsOf: scalars)
                return .string(String(view))
            }
            if case .number(let n) = value {
                return try? JSONNode.parse(n.text + random.pick(["0", ".5", "e2", "e-2"]))
            }
            return .object([(key: "k", value: value)])
        }
    }
    return mutated?.description
}

/// One edit of the text of `document`: a character removed, inserted or
/// replaced.
private func textualMutation(_ document: String, _ random: inout SplitMix64) -> String {
    var characters = Array(document)
    guard !characters.isEmpty else { return String(random.pick(editCharacters)) }
    let at = random.below(characters.count)
    switch random.below(3) {
    case 0:
        characters.remove(at: at)
    case 1:
        characters.insert(random.pick(editCharacters), at: at)
    default:
        characters[at] = random.pick(editCharacters)
    }
    return String(characters)
}

// MARK: - The suite

@Suite(.enabled(if: OracleCheck.executable != nil, "set CDDL_ORACLE_BIN to the reference oracle to run"))
struct JSONDifferentialTests {
    /// Validates `json` against the corpus schema and returns the difference
    /// from the oracle, if any.
    private func divergence(_ corpus: Corpus, _ json: String) async throws -> String? {
        var verdict: JSONVerdict = nil
        do {
            try await validateJSON(cddl: corpus.cddl, json: json, rule: corpus.rule)
        } catch {
            verdict = error
        }
        return try JSONOracleCheck.divergence(
            cddl: corpus.cddl, json: json, rule: corpus.rule, verdict: verdict, compareErrors: true)
    }

    /// Every fixture document is settled as the oracle settles it.
    @Test func fixtureDocumentsAgreeWithTheOracle() async throws {
        var checked = 0
        for corpus in try fixtureCorpora() {
            for document in corpus.documents {
                checked += 1
                if let difference = try await divergence(corpus, document) {
                    Issue.record("\(corpus.name): \(difference)")
                }
            }
        }
        #expect(checked == 37)
    }

    /// Single-edit mutations of every fixture document, of its value and of
    /// its text, are settled as the oracle settles them.
    @Test func mutatedFixtureDocumentsAgreeWithTheOracle() async throws {
        var random = SplitMix64(state: 0x5EED_CDD1_2026)
        let corpora = try fixtureCorpora()
        var checked = 0
        var divergences = 0
        var verdicts: [Bool: Int] = [:]
        // `CDDL_JSON_FUZZ_ROUNDS` runs more rounds than the default twelve.
        let rounds = ProcessInfo.processInfo.environment["CDDL_JSON_FUZZ_ROUNDS"].flatMap { Int($0) } ?? 12
        for round in 0..<rounds {
            for corpus in corpora {
                for document in corpus.documents {
                    let mutated: String
                    if round % 3 == 2 {
                        mutated = textualMutation(document, &random)
                    } else {
                        guard let edited = structuralMutation(document, &random) else { continue }
                        mutated = edited
                    }
                    checked += 1
                    verdicts[(try? JSONNode.parse(mutated)) != nil, default: 0] += 1
                    if let difference = try await divergence(corpus, mutated) {
                        divergences += 1
                        Issue.record("\(corpus.name) mutated to \(mutated.prefix(400)): \(difference)")
                    }
                }
            }
        }
        #expect(checked >= 300, "only \(checked) mutations were checked")
        #expect(divergences == 0, "\(divergences) of \(checked) mutations diverged")
        #expect((verdicts[true] ?? 0) >= 200, "too few mutations read as JSON: \(verdicts)")
    }

    /// Mutations of small documents against small schemas that exercise the
    /// number grammar, strings, arrays and objects.
    @Test func mutatedSmallDocumentsAgreeWithTheOracle() async throws {
        let corpora = [
            Corpus(name: "numbers", cddl: "r = [* (int / float / tstr)]", rule: nil, documents: ["[1, -2, 3.5, \"x\"]"]),
            Corpus(name: "uint", cddl: "r = { a: uint, ? b: [* uint .size 2] }", rule: nil, documents: [#"{"a":1,"b":[1,2]}"#]),
            Corpus(name: "float", cddl: "r = [float, float .lt 10.5, 0.0..1.0]", rule: nil, documents: ["[1.5, 2.5, 0.5]"]),
            Corpus(name: "text", cddl: "r = { * tstr => tstr .size (1..3) }", rule: nil, documents: [#"{"a":"x","b":"yz"}"#]),
            Corpus(
                name: "choice", cddl: "r = [* (a // b)]\na = (0, tstr)\nb = (1, uint)", rule: nil,
                documents: [#"[0, "x", 1, 2]"#]),
            Corpus(name: "time", cddl: "r = [time, tdate, uri]", rule: nil, documents: [#"[1, "2020-01-01T00:00:00Z", "a:b"]"#]),
        ]
        var random = SplitMix64(state: 0x0DD5_1235)
        var checked = 0
        var divergences = 0
        let rounds = ProcessInfo.processInfo.environment["CDDL_JSON_FUZZ_ROUNDS"].flatMap { Int($0) } ?? 20
        for _ in 0..<rounds {
            for corpus in corpora {
                for document in corpus.documents {
                    let mutated =
                        random.below(4) == 0
                        ? textualMutation(document, &random) : (structuralMutation(document, &random) ?? document)
                    checked += 1
                    if let difference = try await divergence(corpus, mutated) {
                        divergences += 1
                        Issue.record("\(corpus.name) mutated to \(mutated): \(difference)")
                    }
                }
            }
        }
        #expect(checked == 6 * rounds)
        #expect(divergences == 0)
    }
}
