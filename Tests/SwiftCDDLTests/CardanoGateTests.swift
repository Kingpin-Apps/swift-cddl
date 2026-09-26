import Foundation
import Testing

@testable import SwiftCDDL

/// Stage 1 gates over the Cardano ledger CDDL (cardano-ledger @ dae0697) and
/// every other fixture.
@Suite struct CardanoGateTests {
    static let eras = ["shelley", "allegra", "mary", "alonzo", "babbage", "conway"]

    static let allFixtures: [String] = {
        var files: [String] = []
        for directory in ["cardano", "cddl", "lsp", "did"] {
            files.append(contentsOf: (try? Fixtures.cddlFiles(in: directory)) ?? [])
        }
        return files
    }()

    /// Gate 1: every era parses, standalone and with every reference resolved.
    @Test(arguments: eras)
    func eraParses(_ era: String) throws {
        let source = try Fixtures.read("cardano/\(era).cddl")
        let cddl = try parseOK(source)
        #expect(!cddl.rules.isEmpty)
        #expect(throws: Never.self) { try CDDL.fromSlice(Array(source.utf8)) }
    }

    @Test func conwayHas156Rules() throws {
        let cddl = try parseOK(try Fixtures.read("cardano/conway.cddl"))
        #expect(cddl.rules.count == 156)
        #expect(cddl.rules.first?.name() == "block")
        #expect(cddl.rules.contains { $0.name() == "transaction" })
    }

    /// Gate 2: formatting is a fixed point after one pass.
    @Test(arguments: allFixtures)
    func formatIsAFixedPoint(_ file: String) throws {
        let source = try Fixtures.read(file)
        guard let cddl = try? cddlFromStr(source) else {
            // Two editor-tooling fixtures are deliberately not valid CDDL.
            #expect(file == "lsp/formatting-test.cddl" || file == "lsp/trailing-comma-test.cddl", "\(file)")
            return
        }
        let once = cddl.description
        let twice = try parseOK(once).description
        #expect(twice == once, "\(file) formats unstably")
    }

    /// Gate 3: no comment is lost when formatting Conway.
    @Test func noCommentLostFormattingConway() throws {
        let source = try Fixtures.read("cardano/conway.cddl")
        let formatted = try parseOK(source).description
        let before = commentPayloads(source)
        let after = commentPayloads(formatted)
        #expect(before.count > 0)
        #expect(after.count == before.count, "comments in \(before.count), out \(after.count)")
        #expect(after == before)
    }

    /// No comment is lost formatting any era.
    @Test(arguments: eras)
    func noCommentLostFormattingEra(_ era: String) throws {
        let source = try Fixtures.read("cardano/\(era).cddl")
        let formatted = try parseOK(source).description
        #expect(commentPayloads(formatted) == commentPayloads(source))
    }

    /// Parsing Conway is fast enough to be unremarkable, even in a debug
    /// build.
    @Test func conwayParsesQuickly() throws {
        let source = try Fixtures.read("cardano/conway.cddl")
        let start = DispatchTime.now().uptimeNanoseconds
        _ = try cddlFromStr(source)
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
        #expect(seconds < 5, "conway took \(seconds)s")
    }
}
