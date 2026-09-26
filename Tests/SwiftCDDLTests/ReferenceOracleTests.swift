import Foundation
import Testing

@testable import SwiftCDDL

/// Byte-for-byte comparison of the parser and formatter with a reference
/// oracle, over every fixture, over an optional corpus, and over randomly
/// mutated fixtures.
///
/// Opt-in: the tests run only when `CDDL_SYNTAX_ORACLE_BIN` names the oracle
/// executable. The oracle reads CDDL on standard input and, given `fmt`,
/// prints the formatted document or `ERROR <description>\n<debug
/// description>`; given `spans`, prints the `spanDump` layout; given `batch`,
/// reads a JSON array of inputs and prints a JSON array of `[fmt, spans]`
/// pairs. `CDDL_SYNTAX_ORACLE_CORPUS` may name a JSON array of further
/// inputs.
@Suite(.enabled(if: ReferenceOracle.executable != nil))
struct ReferenceOracleTests {
    static let fixtureFiles: [String] = {
        var files: [String] = []
        for directory in ["cardano", "cddl", "lsp", "did"] {
            files.append(contentsOf: (try? Fixtures.cddlFiles(in: directory)) ?? [])
        }
        return files
    }()

    @Test(arguments: fixtureFiles)
    func formattedOutputMatchesTheOracle(_ file: String) throws {
        let source = try Fixtures.read(file)
        #expect(ReferenceOracle.rendered(source).fmt == (try ReferenceOracle.run(["fmt"], input: source)))
    }

    @Test(arguments: fixtureFiles)
    func spansMatchTheOracle(_ file: String) throws {
        let source = try Fixtures.read(file)
        #expect(ReferenceOracle.rendered(source).spans == (try ReferenceOracle.run(["spans"], input: source)))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CDDL_SYNTAX_ORACLE_CORPUS"] != nil))
    func corpusMatchesTheOracle() throws {
        let url = URL(fileURLWithPath: ProcessInfo.processInfo.environment["CDDL_SYNTAX_ORACLE_CORPUS"]!)
        let inputs = try JSONDecoder().decode([String].self, from: Data(contentsOf: url))
        try ReferenceOracle.compareBatch(inputs)
    }

    /// Fixtures with one to three random edits each (deletions, insertions
    /// and substitutions of grammar-significant characters), so that error
    /// positions and messages are compared as well as successful parses.
    @Test func mutatedFixturesMatchTheOracle() throws {
        var generator = SeededGenerator(seed: 8610)
        let alphabet = Array("()[]{}<>,:;=/*+?^~&#.\"'\n \t-_$@0123456789abcxyzeEpP\\")
        var inputs: [String] = []
        for file in Self.fixtureFiles where !file.hasPrefix("cardano/") {
            let source = try Fixtures.read(file)
            guard !source.isEmpty else { continue }
            for _ in 0..<25 {
                var characters = Array(source)
                for _ in 0..<Int.random(in: 1...3, using: &generator) {
                    let index = Int.random(in: 0...characters.count, using: &generator)
                    let roll = Double.random(in: 0..<1, using: &generator)
                    if roll < 0.4 {
                        if index < characters.count { characters.remove(at: index) }
                    } else if roll < 0.8 {
                        characters.insert(alphabet.randomElement(using: &generator)!, at: index)
                    } else if index < characters.count {
                        characters[index] = alphabet.randomElement(using: &generator)!
                    }
                }
                inputs.append(String(characters))
            }
        }
        try ReferenceOracle.compareBatch(inputs)
    }
}

enum ReferenceOracle {
    static var executable: String? {
        ProcessInfo.processInfo.environment["CDDL_SYNTAX_ORACLE_BIN"]
    }

    /// This package's own `fmt` and `spans` renderings of `input`.
    static func rendered(_ input: String) -> (fmt: String, spans: String) {
        do {
            let cddl = try parseCDDL(input)
            return (cddl.description, spanDump(cddl))
        } catch {
            let text = "ERROR \(error.description)\n\(error.debugDescription)"
            return (text, text)
        }
    }

    /// Runs the oracle with `arguments`, feeding it `input`.
    static func run(_ arguments: [String], input: String) throws -> String {
        #if os(macOS) || os(Linux)
            let inputURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cddl-oracle-\(UUID().uuidString).in")
            try Data(input.utf8).write(to: inputURL)
            defer { try? FileManager.default.removeItem(at: inputURL) }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable!)
            process.arguments = arguments
            let stdout = Pipe()
            process.standardInput = try FileHandle(forReadingFrom: inputURL)
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: output, as: UTF8.self)
        #else
            throw OracleUnavailable()
        #endif
    }

    /// Compares every input's renderings with the oracle's `batch` output.
    static func compareBatch(_ inputs: [String], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let request = String(decoding: try JSONEncoder().encode(inputs), as: UTF8.self)
        let response = try run(["batch"], input: request)
        let expected = try JSONDecoder().decode([[String]].self, from: Data(response.utf8))
        try #require(expected.count == inputs.count, sourceLocation: sourceLocation)

        var mismatches = 0
        for (input, want) in zip(inputs, expected) {
            let (fmt, spans) = rendered(input)
            if fmt != want[0] || spans != want[1] {
                mismatches += 1
                if mismatches <= 10 {
                    Issue.record(
                        "mismatch for \(input.debugDescription)\n--- fmt\n\(fmt)\n--- oracle fmt\n\(want[0])\n--- spans\n\(spans)\n--- oracle spans\n\(want[1])",
                        sourceLocation: sourceLocation
                    )
                }
            }
        }
        #expect(mismatches == 0, "\(mismatches) of \(inputs.count) inputs differ", sourceLocation: sourceLocation)
    }

    struct OracleUnavailable: Error {}
}

/// A deterministic random number generator (SplitMix64).
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
