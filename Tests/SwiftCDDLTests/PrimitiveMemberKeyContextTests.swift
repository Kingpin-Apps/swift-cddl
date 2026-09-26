import Testing

@testable import SwiftCDDL

/// A prelude type or a literal matches a data item only when the item itself
/// is of that type (RFC 8610 Appendix C): a map is not a primitive value
/// merely because one of its keys is. The key-matching behaviour belongs to
/// member keys alone.
@Suite struct PrimitiveMemberKeyContextTests {
    // MARK: - Private helpers

    private func onePair(_ key: CBORNode, _ value: CBORNode) -> CBORNode {
        .map([(key: key, value: value)])
    }

    // MARK: - Tests

    @Test func primitiveIdentifierFindersOnlyRunForMemberKeys() async {
        let domains: [(String, CBORNode)] = [
            ("tstr", .text("key")),
            ("uint", .integer(1)),
            ("nint", .integer(-1)),
            ("int", .integer(1)),
            ("integer", .integer(-1)),
            ("unsigned", .integer(1)),
            // 1.5 is written in its shortest exact width.
            ("float", .float(1.5, width: .half)),
            ("number", .float(1.5, width: .half)),
            ("bool", .bool(true)),
            ("null", .null),
            ("bytes", .bytes([0xaa])),
            ("biguint", .tagged(2, .bytes([1]))),
            ("bignint", .tagged(3, .bytes([1]))),
            ("bigint", .tagged(2, .bytes([1]))),
        ]

        for (domain, key) in domains {
            let map = onePair(key, .integer(7))

            // RFC 8610 Appendix C requires the data item itself to match the
            // type. A CBOR map (major type 5) is not a primitive value merely
            // because one of its keys belongs to the primitive's domain.
            let root = await cborResult("m = \(domain)", map.encoded())
            #expect(root != nil, "root \(domain) value searched the enclosing map's keys")

            let nested = onePair(.text("outer"), map)
            let inner = await cborResult("m = { outer: \(domain) }", nested.encoded())
            #expect(inner != nil, "nested \(domain) value searched its own map's keys")

            // The same primitive remains a valid map-member key domain.
            let memberKey = await cborResult("m = { \(domain) => uint }", onePair(key, .integer(7)).encoded())
            #expect(memberKey == nil, "member-key \(domain) was rejected: \(String(describing: memberKey))")
        }
    }

    @Test func primitiveLiteralFindersOnlyRunForMemberKeys() async {
        let literals: [(String, CBORNode)] = [
            ("\"key\"", .text("key")),
            ("1", .integer(1)),
            ("-1", .integer(-1)),
            ("1.5", .float(1.5, width: .half)),
            ("h'AA'", .bytes([0xaa])),
        ]

        for (literal, key) in literals {
            let map = onePair(key, .integer(7))
            let root = await cborResult("m = \(literal)", map.encoded())
            #expect(root != nil, "root literal \(literal) searched the enclosing map's keys")

            let nested = onePair(.text("outer"), map)
            let inner = await cborResult("m = { outer: \(literal) }", nested.encoded())
            #expect(inner != nil, "nested literal \(literal) searched its own map's keys")

            let memberKey = await cborResult("m = { \(literal) => uint }", onePair(key, .integer(7)).encoded())
            #expect(memberKey == nil, "member-key literal \(literal) was rejected")
        }
    }

    @Test func repeatingPrimitiveMembersPreserveValueAndKeyContexts() async {
        let map = onePair(.text("key"), .integer(7))

        let repeated = await cborResult("m = [+ tstr]", CBORNode.array([map]).encoded())
        #expect(repeated != nil, "a repeated ordinary tstr searched the map's keys")

        let nested = await cborResult(
            "m = { outer: [+ tstr] }",
            onePair(.text("outer"), .array([map])).encoded()
        )
        #expect(nested != nil, "a nested repeated ordinary tstr searched its map's keys")

        await expectValid("m = { * tstr => uint }", onePair(.text("key"), .integer(7)).encoded())
    }

    @Test func mapAndAnyValuesRemainValidOutsideMemberKeyContext() async {
        let map = onePair(.text("key"), .integer(7)).encoded()

        await expectValid("m = any", map)
        await expectValid("m = { * any => any }", map)
    }

    @Test func optionalCompositeMemberMissesSkipTheirValueType() async {
        let arrayKey = CBORNode.array([.integer(1)])
        let map = onePair(arrayKey, .text("owned")).encoded()

        // Once the first optional member owns the only pair, the second member
        // is absent. Its uint value type must not be evaluated against the
        // enclosing map as a surrogate way to discover that absence.
        await expectValid("m = { ? [uint] => tstr, ? [uint] => uint }", map)
    }

    @Test func primitiveMemberValueErrorsPointToTheClaimedKey() async {
        let badMember = onePair(.text("key"), .text("bad")).encoded()
        let verdict = await cborResult("m = { tstr => uint }", badMember, comparePaths: true)
        guard case .validation(let errors)? = verdict else {
            Issue.record("expected validation errors, got \(String(describing: verdict))")
            return
        }
        let locations = errors.map(\.cborLocation)

        // Locations render keys in CDDL notation (`"key"`).
        #expect(locations.contains("/\"key\""), "expected a claimed-key location, got \(locations)")
        #expect(
            locations.allSatisfy { $0 != "/Text(\"bad\")" },
            "associated value was used as a path component: \(locations)"
        )
    }
}
