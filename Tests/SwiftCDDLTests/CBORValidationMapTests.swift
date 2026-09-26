import Testing

@testable import SwiftCDDL

/// The bytes of `literal`, where `\xNN` stands for the byte with hex value NN
/// and every other character for its ASCII byte.
private func escapedBytes(_ literal: String) -> [UInt8] {
    let characters = Array(literal.utf8)
    var out: [UInt8] = []
    var index = 0
    while index < characters.count {
        if characters[index] == UInt8(ascii: "\\"), index + 3 < characters.count,
            characters[index + 1] == UInt8(ascii: "x")
        {
            out.append(contentsOf: hexBytes(String(decoding: characters[(index + 2)...(index + 3)], as: UTF8.self)))
            index += 4
        } else {
            out.append(characters[index])
            index += 1
        }
    }
    return out
}

/// A float in the shortest width that holds it exactly, as preferred
/// serialization encodes it (RFC 8949 Section 4.1).
private func shortestFloat(_ value: Double) -> CBORNode {
    if doubleToHalf(value) != nil {
        return .float(value, width: .half)
    }
    if Double(Float(value)) == value {
        return .float(value, width: .single)
    }
    return .float(value)
}

/// The encoding of a map holding one entry, `key` to `value`.
private func onePair(_ key: CBORNode, _ value: CBORNode) -> [UInt8] {
    CBORNode.map([(key: key, value: value)]).encoded()
}

/// Expects `bytes` to match `cddl`, with `comment` explaining a failure.
private func expectMatch(
    _ cddl: String,
    _ bytes: [UInt8],
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await cborResult(cddl, bytes, sourceLocation: sourceLocation)
    #expect(
        verdict == nil, "\(comment.map { "\($0): " } ?? "")expected a match, got \(verdict.map { "\($0)" } ?? "")",
        sourceLocation: sourceLocation)
}

/// Expects `bytes` not to match `cddl`, with `comment` explaining a failure.
private func expectMismatch(
    _ cddl: String,
    _ bytes: [UInt8],
    _ comment: Comment? = nil,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let verdict = await cborResult(cddl, bytes, sourceLocation: sourceLocation)
    #expect(verdict != nil, comment ?? "expected a mismatch", sourceLocation: sourceLocation)
}

/// The rendered failure of validating `bytes`, expected to be a failure;
/// empty when the document matched.
private func failureText(
    _ cddl: String,
    _ bytes: [UInt8],
    sourceLocation: SourceLocation = #_sourceLocation
) async -> String {
    guard let error = await expectInvalid(cddl, bytes, sourceLocation: sourceLocation) else { return "" }
    return error.description
}

/// Matching of map data items against groups: the assignment of each
/// physical key/value pair to one group entry (RFC 8610 Appendix C), greedy
/// occurrences (Appendix A), cuts (Section 3.5.4), and key domains of the
/// prelude types (Appendix D).
@Suite
struct CBORValidationMapTests {
    @Test func validateOptionalTypeDomainMapEntryAbsent() async {
        // `?` permits the entry to be absent (RFC 8610 Section 3.2), so the
        // empty map matches a map whose sole entry is an optional type-domain
        // entry.
        let emptyMap = escapedBytes(#"\xa0"#)
        let oneEntry = escapedBytes(#"\xa1\x61\x61\x01"#)  // {"a": 1}

        await expectMatch("m = { ? tstr => uint }", emptyMap)
        // A present entry still validates.
        await expectMatch("m = { ? tstr => uint }", oneEntry)
        // A present entry with a bad value type still fails.
        let badValue = escapedBytes(#"\xa1\x61\x61\x61\x62"#)  // {"a": "b"}
        await expectMismatch("m = { ? tstr => uint }", badValue)

        // Other key types take the same path.
        await expectMatch("m = { ? int => uint }", emptyMap)
        await expectMatch("m = { ? bool => uint }", emptyMap)
        await expectMatch("m = { ? bytes => uint }", emptyMap)

        // An entry without an occurrence indicator still requires a match.
        await expectMismatch("m = { tstr => uint }", emptyMap)

        // An absent optional entry alongside entries that consume the keys.
        let intEntry = escapedBytes(#"\xa1\x01\x02"#)  // {1: 2}
        let textAndInt = escapedBytes(#"\xa2\x61\x61\x01\x01\x02"#)  // {"a": 1, 1: 2}
        await expectMatch("m = { ? tstr => uint, int => int }", intEntry)
        await expectMatch("m = { ? tstr => uint, ? int => int }", intEntry)
        await expectMatch("m = { ? tstr => uint, int => int }", textAndInt)
        await expectMatch("m = { ? tstr => uint, ? int => int }", emptyMap)
    }

    @Test func validateSingleTypeDomainMapEntriesDoNotReuseConsumedKeys() async {
        let nameOnly = escapedBytes(#"\xa1\x64name\x63bob"#)  // {"name": "bob"}
        let nameAndA = escapedBytes(#"\xa2\x64name\x63bob\x61a\x05"#)  // {"name": "bob", "a": 5}
        let nameAndBadA = escapedBytes(#"\xa2\x64name\x63bob\x61a\x63bad"#)  // {"name": "bob", "a": "bad"}

        let optional = "m = { name: tstr, ? tstr => uint }"
        await expectMatch(optional, nameOnly)
        await expectMatch(optional, nameAndA)
        await expectMismatch(optional, nameAndBadA)

        // An entry without an occurrence indicator requires one unconsumed
        // matching key.
        let required = "m = { name: tstr, tstr => uint }"
        await expectMatch(required, nameAndA)
        await expectMismatch(required, nameOnly)
    }

    @Test func validateOptionalTypeDomainMissSkipsCompositeValue() async {
        let emptyMap = escapedBytes(#"\xa0"#)
        let nameOnly = escapedBytes(#"\xa1\x64name\x63bob"#)  // {"name": "bob"}

        // A missing optional member skips the whole entry; its value type is
        // not evaluated against the enclosing map or a consumed value.
        await expectMatch("m = { ? tstr => [uint] }", emptyMap)
        await expectMatch("m = { ? any => [uint] }", emptyMap)
        await expectMatch("m = { name: tstr, ? tstr => [uint] }", nameOnly)
    }

    @Test func validateOptionalPrimitiveDomainsDoNotReuseConsumedKeys() async {
        let cases: [(String, CBORNode)] = [
            ("m = { ? tstr => tstr, ? tstr => uint }", .text("k")),
            ("m = { ? int => tstr, ? int => uint }", .integer(1)),
            ("m = { ? bool => tstr, ? bool => uint }", .bool(true)),
            ("m = { ? null => tstr, ? null => uint }", .null),
            ("m = { ? bytes => tstr, ? bytes => uint }", .bytes([1])),
            ("m = { ? float => tstr, ? float => uint }", shortestFloat(1.5)),
            ("m = { ? biguint => tstr, ? biguint => uint }", .tagged(2, .bytes([1]))),
            ("m = { ? bignint => tstr, ? bignint => uint }", .tagged(3, .bytes([1]))),
        ]

        for (cddl, key) in cases {
            await expectMatch(cddl, onePair(key, .text("owned")), "schema \(cddl) failed")
        }

        // A bignum domain treats a genuine optional miss like every other
        // primitive domain; bignum entries without an indicator stay required.
        let emptyMap = escapedBytes(#"\xa0"#)
        await expectMatch("m = { ? biguint => uint }", emptyMap)
        await expectMatch("m = { ? bignint => uint }", emptyMap)
        await expectMismatch("m = { biguint => uint }", emptyMap)
        await expectMismatch("m = { bignint => uint }", emptyMap)
    }

    @Test func validateSingleTypeDomainMapEntriesDoNotHideEquivalentPairs() async {
        let cddl = "m = { ? tstr => tstr, ? tstr => uint }"

        // A map with duplicate keys is not valid CBOR (RFC 8949 Section 5.6);
        // the second pair stays uncovered rather than disappearing behind the
        // first claim.
        let duplicateTextKeys = escapedBytes(#"\xa2\x61a\x61x\x61a\x63bad"#)
        var message = await failureText(cddl, duplicateTextKeys)
        #expect(message.contains("unexpected key"))

        // A claim for the first text pair does not make an equivalent second
        // pair count as consumed when the following optional member has a
        // disjoint key domain.
        message = await failureText("m = { ? tstr => tstr, ? int => uint }", duplicateTextKeys)
        #expect(message.contains("unexpected key"))

        message = await failureText("m = { a: tstr, ? tstr => uint }", duplicateTextKeys)
        #expect(message.contains("unexpected key"))

        // A literal lookup allocates a still-unconsumed equivalent pair rather
        // than adding a second claim for the first pair.
        let duplicateAfterPriorClaim = escapedBytes(#"\xa2\x61a\x61x\x61a\x41z"#)
        message = await failureText("m = { ? tstr => tstr, a: tstr, ? tstr => uint }", duplicateAfterPriorClaim)
        #expect(message.contains("expected type tstr"))

        // A generic child validating the same map propagates both claim
        // ledgers.
        message = await failureText(
            "g<K, V> = (K => V)\nm = { g<tstr, tstr>, a: tstr, ? tstr => uint }", duplicateAfterPriorClaim)
        #expect(message.contains("expected type tstr"))

        // Once the only pair is claimed, a later optional literal is absent,
        // and a later required literal cannot reuse the pair.
        let oneClaimedLiteral = escapedBytes(#"\xa1\x61a\x61x"#)
        await expectMatch("m = { ? tstr => tstr, ? a: uint }", oneClaimedLiteral)
        await expectMismatch("m = { ? tstr => tstr, a: uint }", oneClaimedLiteral)

        // +0 and -0 are equivalent map keys (RFC 8949 Section 5.6.1), so this
        // is also a duplicate-key map, and the second pair stays uncovered.
        let equivalentFloatKeys = escapedBytes(#"\xa2\xf9\x00\x00\x61x\xf9\x80\x00\x63bad"#)
        message = await failureText("m = { ? float => tstr, ? float => uint }", equivalentFloatKeys)
        #expect(message.contains("unexpected key"))

        // A generic child shares the parent's physical ledger, so it selects
        // the second pair and exposes that pair's byte string value.
        message = await failureText(
            "g<K, V> = (K => V)\nm = { ? tstr => tstr, g<tstr, tstr>, ? tstr => uint }", duplicateAfterPriorClaim)
        #expect(message.contains("expected type tstr"), "\(message)")
    }

    @Test func validateNanMapKeysHavePhysicalPairIdentity() async {
        let oneNaNText = escapedBytes(#"\xa1\xf9\x7e\x00\x61x"#)  // {NaN: "x"}

        // RFC 8610 Appendix C matches a map by assigning its physical pairs to
        // group entries. A claimed pair stays claimed although a NaN key is
        // not equal to itself, whatever width encodes it.
        let nanEncodings = [
            oneNaNText,
            escapedBytes(#"\xa1\xfa\x7f\xc0\x00\x00\x61x"#),
            escapedBytes(#"\xa1\xfb\x7f\xf8\x00\x00\x00\x00\x00\x00\x61x"#),
        ]
        for encoded in nanEncodings {
            await expectMatch("m = { ? float => tstr }", encoded)
            await expectMatch("m = { ? float => tstr, ? float => uint }", encoded)
        }

        // Repeating entries use the same ledger: the first member owns the
        // only pair, leaving width zero for the repetition.
        await expectMatch("m = { * float => tstr }", oneNaNText)
        await expectMatch("m = { ? float => tstr, * float => uint }", oneNaNText)
        await expectMismatch("m = { ? float => tstr, + float => uint }", oneNaNText)

        // RFC 8949 Section 5.6.1 makes NaNs with different significands
        // distinct keys, so these are two physical occurrences.
        let twoDistinctNaNs = escapedBytes(#"\xa2\xf9\x7e\x00\x01\xf9\x7e\x01\x02"#)
        await expectMatch("m = { 2*2 float => uint }", twoDistinctNaNs)

        // Ordinary float keys as a control for the same paths.
        let finiteFloat = escapedBytes(#"\xa1\xf9\x3e\x00\x61x"#)  // {1.5: "x"}
        await expectMatch("m = { ? float => tstr, ? float => uint }", finiteFloat)

        // Owning the NaN pair does not hide a different, unclaimed pair from
        // the final closed-map check. The key renders in CDDL notation.
        let nanAndInteger = escapedBytes(#"\xa2\xf9\x7e\x00\x61x\x01\x02"#)
        let message = await failureText("m = { ? float => tstr }", nanAndInteger)
        #expect(message.contains("unexpected key 1"))
    }

    @Test func validateNanCompositeMapKeysHavePhysicalPairIdentity() async {
        // A composite value holding a NaN is not equal to itself either, so
        // ownership is by the index of the outer entry, not value equality.
        let arrayKey = escapedBytes(#"\xa1\x81\xf9\x7e\x00\x61x"#)  // {[NaN]: "x"}
        await expectMatch("m = { ? [float] => tstr }", arrayKey)
        await expectMatch("m = { ? [float] => tstr, ? [float] => uint }", arrayKey)

        // The ledger is local to each map, including a nested map used as the
        // outer map's key.
        let mapKey = escapedBytes(#"\xa1\xa1\xf9\x7e\x00\x01\x61x"#)  // {{NaN: 1}: "x"}
        await expectMatch("m = { ? { float => uint } => tstr }", mapKey)
    }

    @Test func validateGenericMapClaimsShareParentPhysicalOwnership() async {
        let oneTextPair = escapedBytes(#"\xa1\x61a\x61x"#)  // {"a": "x"}
        let zeroOrMore = "g<K, V> = (* K => V)\nm = { ? tstr => tstr, g<tstr, tstr> }"
        let oneOrMore = "g<K, V> = (+ K => V)\nm = { ? tstr => tstr, g<tstr, tstr> }"

        // A named group matches as its parenthesized definition does (RFC 8610
        // Appendix C) and sees the pair the preceding member claimed: `*` can
        // take width zero, `+` cannot.
        await expectMatch(zeroOrMore, oneTextPair)
        await expectMismatch(oneOrMore, oneTextPair)

        // A generic child's NaN claim is transferred by physical index.
        let oneNaNText = escapedBytes(#"\xa1\xf9\x7e\x00\x61x"#)
        await expectMatch("g<K, V> = (? K => V)\nm = { g<float, tstr> }", oneNaNText)
    }

    @Test func validateRepeatingMapEntriesAreGreedy() async {
        let oneTextUint = escapedBytes(#"\xa1\x61a\x01"#)  // {"a": 1}

        // RFC 8610 Appendix A makes occurrences greedy: the first entry
        // consumes the only pair, so the required entry cannot match it.
        await expectMismatch("m = { * any => any, tstr => uint }", oneTextUint)
        await expectMatch("m = { tstr => uint, * any => any }", oneTextUint)

        // A positive lower bound consumes the pair as well.
        await expectMismatch("m = { + any => uint, tstr => uint }", oneTextUint)
        await expectMismatch("m = { 1*1 any => uint, tstr => uint }", oneTextUint)

        // The wildcard-first allocation matches when the direct member is
        // optional.
        await expectMatch("m = { * any => any, ? tstr => uint }", oneTextUint)
    }

    @Test func validateRepeatingMapEntriesCountOnlyUnconsumedMatches() async {
        let aOnly = escapedBytes(#"\xa1\x61a\x01"#)  // {"a": 1}
        let intOnly = escapedBytes(#"\xa1\x01\x01"#)  // {1: 1}
        let intAndBytes = escapedBytes(#"\xa2\x01\x01\x41\xaa\x05"#)  // {1: 1, h'aa': 5}
        let aB = escapedBytes(#"\xa2\x61a\x01\x61b\x02"#)
        let aBC = escapedBytes(#"\xa3\x61a\x01\x61b\x02\x61c\x03"#)
        let aBCD = escapedBytes(#"\xa4\x61a\x01\x61b\x02\x61c\x03\x61d\x04"#)
        let aBCDE = escapedBytes(#"\xa5\x61a\x01\x61b\x02\x61c\x03\x61d\x04\x61e\x05"#)

        // The occurrence counts this member's unconsumed matches, not the size
        // of the map.
        await expectMatch("m = { a: uint, * tstr => uint }", aOnly)
        await expectMismatch("m = { a: uint, + tstr => uint }", aOnly)
        await expectMatch("m = { * tstr => uint, int => uint }", intOnly)
        await expectMismatch("m = { + tstr => uint, int => uint }", intOnly)

        // Byte string keys: a zero-width repetition matches a nonempty map, a
        // matching pair still validates, and `+` still requires a match.
        await expectMatch("m = { 1: uint, * bytes => any }", intOnly)
        await expectMatch("m = { 1: uint, * bytes => any }", intAndBytes)
        await expectMismatch("m = { 1: uint, + bytes => any }", intOnly)

        // Bounded occurrences count only the pairs left after `a`.
        let bounded = "m = { a: uint, 2*3 tstr => uint }"
        await expectMismatch(bounded, aB)
        await expectMatch(bounded, aBC)
        await expectMatch(bounded, aBCD)
        await expectMismatch(bounded, aBCDE)

        await expectMatch("m = { a: uint, *2 tstr => uint }", aOnly)
        await expectMatch("m = { a: uint, *2 tstr => uint }", aBC)
        await expectMismatch("m = { a: uint, *2 tstr => uint }", aBCD)
        await expectMismatch("m = { a: uint, 2* tstr => uint }", aB)
        await expectMatch("m = { a: uint, 2* tstr => uint }", aBC)

        // A bounded repetition stops at its upper bound, leaving the rest to
        // a later member.
        await expectMatch("m = { 1*1 tstr => uint, tstr => uint }", aB)
        await expectMatch("m = { *2 tstr => uint, tstr => uint }", aBC)
        await expectMatch("m = { 2*3 tstr => uint, tstr => uint }", aBCD)
    }

    @Test func validateRepeatingMapMemberCandidatesAreEntryLocal() async {
        let textValue = escapedBytes(#"\xa1\x61a\x61x"#)  // {"a": "x"}
        let textAndIntValues = escapedBytes(#"\xa2\x61a\x61x\x01\x02"#)  // {"a": "x", 1: 2}

        // A repeating member's candidate values belong to that entry only, so
        // a later optional miss takes its zero-width path (RFC 8610 Section
        // 3.2).
        await expectMatch("m = { * tstr => tstr, ? int => [uint] }", textValue)
        await expectMatch("m = { + tstr => tstr, ? int => [uint] }", textValue)
        await expectMatch("m = { 1*2 tstr => tstr, ? int => [uint] }", textValue)

        // The following direct member, when present, validates its own value.
        await expectMatch("m = { * tstr => tstr, int => uint }", textAndIntValues)
        await expectMatch("m = { + tstr => tstr, int => uint }", textAndIntValues)
        await expectMatch("m = { 1*2 tstr => tstr, int => uint }", textAndIntValues)

        // Values are still enforced once the key matches.
        await expectMismatch("m = { * tstr => uint }", textValue)
    }

    @Test func validateEmptyRepeatingMapMemberCandidateBatchIsEntryLocal() async {
        let badTextValue = escapedBytes(#"\xa1\x61a\x63bad"#)  // {"a": "bad"}
        let goodTextValue = escapedBytes(#"\xa1\x61a\x01"#)  // {"a": 1}

        // An empty repetition does not suppress a following direct value.
        await expectMismatch("m = { 0*2 int => tstr, ? tstr => uint }", badTextValue)
        await expectMatch("m = { 0*2 int => tstr, ? tstr => uint }", goodTextValue)

        // The wildcard is greedy (RFC 8610 Appendix A); once it owns the pair,
        // the optional entry is absent and does not revalidate the value.
        await expectMatch("m = { * any => any, ? tstr => uint }", badTextValue)
    }

    @Test func validatePrimitiveNumericMapMemberKeyDomains() async {
        func pair(_ key: CBORNode) -> [UInt8] {
            onePair(key, .integer(1))
        }

        // RFC 8610 Appendix D: uint and unsigned are major type 0, nint major
        // type 1, int their union, and number int / float.
        let accepted: [(String, CBORNode)] = [
            ("uint", .integer(0)),
            ("unsigned", .integer(1)),
            ("nint", .integer(-1)),
            ("int", .integer(1)),
            ("int", .integer(-1)),
            ("number", .integer(0)),
            ("number", shortestFloat(1.5)),
            ("number", shortestFloat(.infinity)),
            ("number", shortestFloat(.nan)),
        ]
        let rejected: [(String, CBORNode)] = [
            ("uint", .integer(-1)),
            ("unsigned", .integer(-1)),
            ("nint", .integer(0)),
            ("nint", .integer(1)),
            ("int", shortestFloat(1.5)),
            ("number", .bool(true)),
        ]
        for (keyType, key) in rejected {
            await expectMismatch(
                "m = { ? \(keyType) => uint }", pair(key), "single \(keyType) member accepted a key outside its domain")
        }
        for (keyType, key) in accepted {
            await expectMatch(
                "m = { ? \(keyType) => uint }", pair(key), "single \(keyType) member rejected a key in its domain")
        }

        // Repeating members use the same domains.
        let repeatingAccepted: [(String, CBORNode)] = [
            ("uint", .integer(0)),
            ("nint", .integer(-1)),
            ("number", .integer(-1)),
            ("number", shortestFloat(1.5)),
        ]
        for (keyType, key) in repeatingAccepted {
            await expectMatch(
                "m = { + \(keyType) => uint }", pair(key), "repeating \(keyType) member rejected a key in its domain")
        }
        let repeatingRejected: [(String, CBORNode)] = [("uint", .integer(-1)), ("nint", .integer(0))]
        for (keyType, key) in repeatingRejected {
            await expectMismatch(
                "m = { + \(keyType) => uint }", pair(key),
                "repeating \(keyType) member accepted a key outside its domain")
        }

        // A wrong-sign key stays unclaimed, so a disjoint later member can own
        // the pair, on both the single and the repeating path.
        let negativeKey = pair(.integer(-1))
        await expectMatch("m = { ? uint => any, nint => uint }", negativeKey)
        await expectMatch("m = { * uint => any, nint => uint }", negativeKey)

        let zeroKey = pair(.integer(0))
        await expectMatch("m = { ? nint => any, uint => uint }", zeroKey)
        await expectMatch("m = { * nint => any, uint => uint }", zeroKey)
    }

    @Test func validateRepeatingMapMemberCandidatesAreEntryLocalAcrossGroupChoices() async {
        let textValue = escapedBytes(#"\xa1\x61a\x61x"#)  // {"a": "x"}

        // Entry-local candidates also hold across group choices, including
        // after an alternative that failed.
        await expectMatch("m = { (+ tstr => uint // * tstr => tstr), ? int => [uint] }", textValue)
        await expectMatch("m = { * tstr => tstr, (? int => [uint] // ? int => uint) }", textValue)
    }

    @Test func validateRepeatingMapEntryCountsCoverPrimitiveKeyPaths() async {
        let cases: [(String, String, String, CBORNode)] = [
            ("any", "any", "any", .text("a")),
            ("tstr", "tstr", "tstr", .text("a")),
            ("int", "int", "int", .integer(1)),
            ("uint", "uint", "uint", .integer(1)),
            ("nint", "nint", "nint", .integer(-1)),
            ("number/int", "int", "number", .integer(1)),
            ("number/float", "number", "number", shortestFloat(1.5)),
            ("bool", "bool", "bool", .bool(true)),
            ("null", "null", "null", .null),
            ("bytes", "bytes", "bytes", .bytes([1])),
            ("float", "float", "float", shortestFloat(1.5)),
            ("biguint", "biguint", "biguint", .tagged(2, .bytes([1]))),
            ("bignint", "bignint", "bignint", .tagged(3, .bytes([1]))),
            ("bigint/tag 2", "bigint", "bigint", .tagged(2, .bytes([1]))),
            ("bigint/tag 3", "bigint", "bigint", .tagged(3, .bytes([1]))),
        ]

        for (caseName, consumingKeyType, repeatingKeyType, key) in cases {
            let bytes = onePair(key, .integer(1))

            // The optional member greedily consumes the only pair, leaving the
            // repetition width zero: `*` accepts that, `+` does not.
            await expectMatch(
                "m = { ? \(consumingKeyType) => any, * \(repeatingKeyType) => uint }", bytes,
                "zero-or-more \(caseName) case failed")
            await expectMismatch(
                "m = { ? \(consumingKeyType) => any, + \(repeatingKeyType) => uint }", bytes,
                "one-or-more \(caseName) case unexpectedly matched")
        }
    }

    @Test func validateSingleMapEntryClaimsAreTransactionalAcrossGroupChoices() async {
        let oneTextValue = escapedBytes(#"\xa1\x61a\x61x"#)  // {"a": "x"}

        // A failed alternative leaves no claim hiding the pair from the next
        // alternative or from the final closed-map check.
        let message = await failureText("m = { tstr => uint // ? tstr => bytes }", oneTextValue)
        #expect(message.contains("unexpected key"))

        // The second alternative can own the pair after the first fails on
        // its value.
        await expectMatch("m = { tstr => uint // tstr => tstr }", oneTextValue)
    }

    @Test func validateOptionalMapEntriesAreGreedy() async {
        let cases: [(String, CBORNode)] = [
            ("m = { ? tstr => any, tstr => any }", .text("a")),
            ("m = { ? int => any, int => any }", .integer(1)),
            ("m = { ? bool => any, bool => any }", .bool(true)),
            ("m = { ? null => any, null => any }", .null),
            ("m = { ? bytes => any, bytes => any }", .bytes([1])),
            ("m = { ? float => any, float => any }", shortestFloat(1.5)),
            ("m = { ? biguint => any, biguint => any }", .tagged(2, .bytes([1]))),
            ("m = { ? bignint => any, bignint => any }", .tagged(3, .bytes([1]))),
        ]

        for (cddl, key) in cases {
            await expectMismatch(cddl, onePair(key, .integer(1)), "schema \(cddl) unexpectedly matched")
        }

        let textPair = escapedBytes(#"\xa1\x61a\x01"#)  // {"a": 1}
        await expectMismatch("m = { ? tstr => any, a: any }", textPair)
        await expectMismatch("m = { ? a: any, tstr => any }", textPair)
    }

    @Test func validateOptionalArrowValueFailureCanFallThrough() async {
        let textValue = escapedBytes(#"\xa1\x61a\x61x"#)  // {"a": "x"}

        // RFC 8610 Section 3.5.4: without a cut, a failing value type of the
        // optional entry leaves the pair to a later matching entry.
        await expectMatch("m = { ? tstr => uint, tstr => tstr }", textValue)

        // The colon form carries a cut: once `a` matches, the bad value is
        // final.
        await expectMismatch("m = { ? a: uint, tstr => tstr }", textValue)

        // The extensible-map example of RFC 8610 Section 3.5.4.
        let extensionValue = escapedBytes(#"\xa1\x6coptional-key\x68nonsense"#)
        await expectMatch(#"m = { ? "optional-key" => int, * tstr => any }"#, extensionValue)
        await expectMismatch(#"m = { ? "optional-key": int, * tstr => any }"#, extensionValue)
    }

    @Test func validateOptionalSingleMapEntryAssignmentConsidersValues() async {
        let cddl = "m = { ? tstr => any, tstr => tstr }"

        // Both keys are in the same domain; the text-valued pair goes to the
        // required member and the integer-valued pair to the optional one, in
        // either encoding order.
        let textValueFirst = escapedBytes(#"\xa2\x61a\x61x\x61b\x01"#)
        let integerValueFirst = escapedBytes(#"\xa2\x61a\x01\x61b\x61x"#)

        await expectMatch(cddl, textValueFirst)
        await expectMatch(cddl, integerValueFirst)

        // Members without an indicator use the same policy.
        await expectMatch("m = { tstr => any, tstr => tstr }", textValueFirst)

        // An allocation may need a cycle longer than one exchange.
        let threeWaySchema = "m = { ? tstr => (int / bool), ? tstr => any, tstr => int }"
        let threeWayAssignment = escapedBytes(#"\xa3\x61a\x01\x61b\xf5\x61c\x41\x00"#)
        await expectMatch(threeWaySchema, threeWayAssignment)

        // Generic group children allocate the same physical map.
        let genericSchema = "g<K, V> = (? K => V)\nm = { g<tstr, 1..2>, tstr => 1, * any => any }"
        let requiredValueFirst = escapedBytes(#"\xa2\x61a\x01\x61b\x02"#)
        let genericValueFirst = escapedBytes(#"\xa2\x61b\x02\x61a\x01"#)
        await expectMatch(genericSchema, requiredValueFirst)
        await expectMatch(genericSchema, genericValueFirst)

        // Independent generic children both select pair 0 at first; the
        // second is moved to a compatible free pair.
        let twoGenericSchema = "g<K, V> = (? K => V)\nh<K, V> = (? K => V)\nm = { g<tstr, any>, h<tstr, any> }"
        let twoGenericPairs = escapedBytes(#"\xa2\x61a\x01\x61b\x02"#)
        await expectMatch(twoGenericSchema, twoGenericPairs)

        // Matching can move the earlier broad child so the narrower one keeps
        // pair 0.
        let twoGenericSwapSchema = "g<K, V> = (? K => V)\nh<K, V> = (? K => V)\nm = { g<tstr, any>, h<tstr, int> }"
        let integerThenBool = escapedBytes(#"\xa2\x61a\x01\x61b\xf5"#)
        await expectMatch(twoGenericSwapSchema, integerThenBool)

        // Two uses of one generic rule are distinct instantiations.
        let repeatedGenericSchema = "g<K, V> = (? K => V)\nm = { g<tstr, any>, g<tstr, int> }"
        let twoBoolValues = escapedBytes(#"\xa2\x61a\xf5\x61b\xf4"#)
        await expectMismatch(repeatedGenericSchema, twoBoolValues)

        let repeatedIdenticalSchema = "g<K, V> = (? K => V)\nm = { g<tstr, any>, g<tstr, any> }"
        await expectMatch(repeatedIdenticalSchema, twoBoolValues)

        let twoGenericCycleSchema =
            "g<K, V> = (? K => V)\nh<K, V> = (? K => V)\nm = { g<tstr, (int / bool)>, h<tstr, any>, tstr => int }"
        await expectMatch(twoGenericCycleSchema, threeWayAssignment)

        // Parent and generic children share one ledger: either text-key order
        // leaves the byte-key pair to the later required member.
        let genericThenDisjointSchema =
            "g<K, V> = (? K => V)\nh<K, V> = (? K => V)\nm = { g<tstr, int>, h<tstr, int>, bytes => any }"
        let textByteText = escapedBytes(#"\xa3\x61a\x01\x41\x00\xf5\x61b\x02"#)
        let textByteTextReversed = escapedBytes(#"\xa3\x61b\x02\x41\x00\xf5\x61a\x01"#)
        await expectMatch(genericThenDisjointSchema, textByteText)
        await expectMatch(genericThenDisjointSchema, textByteTextReversed)

        // A failed assignment search changes nothing: the next alternative
        // starts from its checkpoint and can claim both pairs.
        await expectMatch("m = { (? tstr => tstr, tstr => bytes) // * any => any }", textValueFirst)
    }

    @Test func validateMapUnexpectedEntriesRejected() async {
        // An entry no group member matches is an unexpected key, including when
        // the only member is optional and absent.
        let emptyMap = escapedBytes(#"\xa0"#)
        let k1 = escapedBytes(#"\xa1\x61\x6b\x01"#)  // {"k": 1}
        let a1 = escapedBytes(#"\xa1\x61\x61\x01"#)  // {"a": 1}
        let k1A2 = escapedBytes(#"\xa2\x61\x6b\x01\x61\x61\x02"#)  // {"k": 1, "a": 2}
        let intEntry = escapedBytes(#"\xa1\x01\x02"#)  // {1: 2}

        await expectMatch("m = { ? k: uint }", emptyMap)
        await expectMatch("m = { ? k: uint }", k1)
        await expectMismatch("m = { ? k: uint }", a1)
        await expectMismatch("m = { ? k: uint }", k1A2)
        // An absent optional type-domain entry does not excuse a key of
        // another domain.
        await expectMismatch("m = { ? tstr => uint }", intEntry)
    }

    /// `* any => any`, the extension point idiom of RFC 8610, admits unknown
    /// extra entries.
    @Test func validateMapAnyKeyPermitsExtraEntries() async {
        let emptyMap = escapedBytes(#"\xa0"#)
        let k1 = escapedBytes(#"\xa1\x61\x6b\x01"#)  // {"k": 1}
        let k1Z9 = escapedBytes(#"\xa2\x61\x6b\x01\x61\x7a\x09"#)  // {"k": 1, "z": 9}
        let k1ZText = escapedBytes(#"\xa2\x61\x6b\x01\x61\x7a\x61\x61"#)  // {"k": 1, "z": "a"}
        let intKeyed = escapedBytes(#"\xa2\x01\x02\x03\x04"#)  // {1: 2, 3: 4}

        // The specific member before the extension point. RFC 8610 Appendix A
        // makes a leading wildcard greedy, and Section 3.5.3 calls that
        // general-before-specific overlap pathological.
        await expectMatch("m = { k: uint, * any => any }", k1)
        await expectMatch("m = { k: uint, * any => any }", k1Z9)
        await expectMismatch("m = { * any => any, k: uint }", k1Z9)
        // RFC 8610 Section 3.5.1 makes the bareword before `:` a text key, so
        // `* any: any` stands for entries under the key "any" only.
        await expectMismatch("m = { k: uint, * any: any }", k1Z9)
        let k1Any9 = escapedBytes(#"\xa2\x61\x6b\x01\x63\x61\x6e\x79\x09"#)  // {"k": 1, "any": 9}
        await expectMatch("m = { k: uint, * any: any }", k1Any9)
        await expectMatch("m = { * any => any }", emptyMap)
        // `any` keys are not limited to text keys.
        await expectMatch("m = { * any => any }", intKeyed)
        // `+` still requires an entry.
        await expectMismatch("m = { + any => any }", emptyMap)
        await expectMatch("m = { + any => any }", k1)
        // An `any` key does not excuse a value type mismatch.
        await expectMismatch("m = { k: uint, * any => uint }", k1ZText)
        // A map without the extension member stays closed.
        await expectMismatch("m = { k: uint }", k1Z9)
    }

    /// A wrong value type under a key carrying a cut (the colon form, RFC 8610
    /// Section 3.5.4) is not rescued by a `* any => any` member, and the error
    /// names the value type mismatch.
    @Test func validateMapAnyKeyDoesNotRescueCutValueMismatch() async {
        let kWrongZ = escapedBytes(#"\xa2\x61\x6b\x61\x73\x61\x7a\x09"#)  // {"k": "s", "z": 9}
        for cddl in ["m = { k: uint, * any => any }", "m = { k: uint, any => any }"] {
            let message = await failureText(cddl, kWrongZ)
            #expect(
                message.contains(#"expected type uint, got Text("s")"#),
                "schema \(cddl): expected a value-type error for k, got: \(message)")
        }
    }

    /// A validator can be pointed at a named type rule instead of the first.
    @Test func validateAgainstANamedRootRule() async throws {
        let schema = try cddlFromStr("first = tstr\nsecond = uint\n")
        let one = try decodeCBOR([0x01])

        let byDefault = CBORValidator(cddl: schema, cbor: one)
        await #expect(throws: CBORValidationError.self, "the first rule is the default root") {
            try await byDefault.validate()
        }

        let second = CBORValidator(cddl: schema, cbor: one)
        second.setRootRule("second")
        try await second.validate()

        let missing = CBORValidator(cddl: schema, cbor: one)
        missing.setRootRule("missing")
        await #expect(throws: CBORValidationError.self) {
            try await missing.validate()
        }
    }
}
