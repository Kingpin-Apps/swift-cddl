import Foundation
import Testing

@testable import SwiftCDDL

/// The member key each syntactic form produces (RFC 8610 Section 3.5.1 and
/// Appendix B `memberkey`): the arrow form is a type key and keeps its cut,
/// the colon form with a literal is a value key, and a bareword with a colon
/// is a bareword key. The validator tells cut and uncut keys apart by this.
@Suite struct MemberKeyFormsTests {
    // MARK: - Private helpers

    private func firstMemberKey(_ source: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> MemberKey {
        let cddl = try cddlFromStr(source)
        let group = try #require(
            arrayOrMapGroup(typeRule(cddl, 0)?.value),
            "expected a map",
            sourceLocation: sourceLocation
        )
        return try #require(memberKeyOf(group, 0), "expected a value member key", sourceLocation: sourceLocation)
    }

    // MARK: - Tests

    @Test func arrowFormLiteralKeyIsAType1Key() throws {
        #expect(memberKeyVariant(try firstMemberKey("a = { 0 => uint }")) == "Type1")
    }

    @Test func colonFormLiteralKeyIsAValueKey() throws {
        #expect(memberKeyVariant(try firstMemberKey("a = { 0: uint }")) == "Value")
    }

    @Test func barewordKeyIsABarewordKey() throws {
        #expect(memberKeyVariant(try firstMemberKey("a = { b: uint }")) == "Bareword")
    }

    /// A value key carries no cut indicator, which is why the arrow form
    /// cannot be collapsed into it.
    @Test func arrowFormPreservesTheCutIndicator() throws {
        let key = try firstMemberKey("a = { 0 ^ => uint }")
        guard case .type1(_, let isCut, _, _, _, _) = key else {
            Issue.record("expected a type1 key, got \(memberKeyVariant(key))")
            return
        }
        #expect(isCut, "cut indicator was lost")
    }

    /// Collapsing the arrow form into a value key would also rewrite the
    /// source, since a value key renders with a trailing colon.
    @Test func memberKeyFormsRoundTripUnchanged() throws {
        for source in ["a = { 0 => uint }", "a = { 0 ^ => uint }", "a = { 0: uint }", "a = { b: uint }"] {
            let cddl = try cddlFromStr(source)
            #expect(cddl.description.trimmingCharacters(in: .whitespacesAndNewlines) == source)
        }
    }
}
