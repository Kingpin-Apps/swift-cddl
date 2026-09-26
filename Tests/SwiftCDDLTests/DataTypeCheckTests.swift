import Testing

@testable import SwiftCDDL

/// The text checks behind the `uri` (RFC 3986), `tdate` (RFC 3339) and
/// base64url (RFC 4648 Section 5) prelude types: each case pairs an input with
/// the exact diagnostic expected for it, or `nil` when the input is accepted.
@Suite struct DataTypeCheckTests {
    /// The full URI diagnostic for a reason.
    private static func uriError(_ reason: String) -> String {
        "expected URI data type, decoding error: " + reason
    }

    /// Absolute URIs, relative references and malformed references (RFC 3986).
    static let uriCases: [(String, String?)] = [
        ("http://example.com", nil),
        ("https://user:pa%20ss@example.com:8080/a/b?q=1&r=%2F#frag", nil),
        ("HTTP://EXAMPLE.COM/", nil),
        ("mailto:someone@example.org", nil),
        ("urn:isbn:0451450523", nil),
        ("a+b-c.d:rest", nil),
        ("file:///etc/hosts", nil),
        ("http://[::1]/", nil),
        ("http://[2001:db8::7]:443/x", nil),
        ("http://[::ffff:192.0.2.1]", nil),
        ("http://[1:2:3:4:5:6:7:8]", nil),
        ("http://192.168.0.1:0/", nil),
        ("http://h:65535", nil),
        ("http://h:/", nil),
        ("http://@h", nil),
        ("http://u:@h", nil),
        ("s:?#", nil),
        ("x:%41%7e", nil),
        ("tel:+1-816-555-1212", nil),
        ("", uriError("not URI")),
        ("/relative/path", uriError("not URI")),
        ("relative", uriError("not URI")),
        ("//example.com/path", uriError("not URI")),
        ("?query", uriError("not URI")),
        ("#fragment", uriError("not URI")),
        ("../up", uriError("not URI")),
        ("1http://example.com", uriError("schemeless path URI reference starts with colon segment")),
        (":no-scheme", uriError("schemeless path URI reference starts with colon segment")),
        ("1a:b", uriError("schemeless path URI reference starts with colon segment")),
        ("/a:b", uriError("schemeless path URI reference starts with colon segment")),
        ("http://ex ample.com", uriError("invalid host IPv4 or registered name character")),
        ("http://exa%mple.com", uriError("invalid host IPv4 or registered name character")),
        ("http://[::1", uriError("invalid host IPv4 or registered name character")),
        ("http://[::1]x", uriError("invalid host IPv4 or registered name character")),
        ("http://[::g]", uriError("invalid host IPv6 character")),
        ("http://[1::2::3]", uriError("invalid host IPv6 format")),
        ("http://[]", uriError("invalid host IPv6 format")),
        ("http://[1:2:3:4:5:6:7:8:9]", uriError("invalid host IPv6 format")),
        ("http://[::256.1.1.1]", uriError("invalid host IPv6 format")),
        ("http://[v1.fe80::a+en1]", uriError("host address mechanism not supported")),
        ("http://[v1.bad%]", uriError("invalid host IPvFuture character")),
        ("http://h:8a", uriError("invalid port character")),
        ("http://h:65536", uriError("port overflow")),
        ("http://a@b@c", uriError("invalid host IPv4 or registered name character")),
        ("http://u%zz@h", uriError("invalid username percent encoding")),
        ("http://us^er@h", uriError("invalid username character")),
        ("http://u:p%4@h", uriError("invalid password percent encoding")),
        ("http://u:p^@h", uriError("invalid password character")),
        ("http://h/pa th", uriError("invalid path character")),
        ("http://h/%GG", uriError("invalid path percent encoding")),
        ("http://h/%4", uriError("invalid path percent encoding")),
        ("http://h/?a b", uriError("invalid query character")),
        ("http://h/?%x1", uriError("invalid query percent encoding")),
        ("http://h/#a#b", uriError("invalid fragment character")),
        ("http://h/#%zz", uriError("invalid fragment percent encoding")),
        ("http://h/caf\u{e9}", uriError("invalid path character")),
    ]

    /// RFC 3339 `date-time` values, valid and invalid.
    static let dateTimeCases: [(String, String?)] = [
        ("1985-04-12T23:20:50.52Z", nil),
        ("1996-12-19T16:39:57-08:00", nil),
        ("1990-12-31T23:59:60Z", nil),
        ("1990-12-31T15:59:60-08:00", nil),
        ("1937-01-01T12:00:27.87+00:20", nil),
        ("2020-02-29t00:00:00z", nil),
        ("2020-02-29 00:00:00Z", nil),
        ("0000-02-29T00:00:00Z", nil),
        ("9999-12-31T23:59:59.999999999999+23:59", nil),
        ("2023-06-15T12:30:45.1234567891234-00:00", nil),
        ("2023-06-15T12:30:59.5Z", nil),
        ("2023-06-15T12:30:60.5Z", nil),
        ("2023-06-15T12:30:45\u{2212}05:00", nil),
        ("2023-06-15T12:30:45+05:00", nil),
        ("2023-06-15", "premature end of input"),
        ("", "premature end of input"),
        ("2023-06-15T12:30:45", "premature end of input"),
        ("2023-06-15T12:30:45+05", "premature end of input"),
        ("2023-06-15T12:30:45+05:", "premature end of input"),
        ("2023-06-15T12:30:45+05:3", "premature end of input"),
        ("2023-06-15T12:30:45.", "premature end of input"),
        ("2023-06-15T12:30:45.Z", "input contains invalid characters"),
        ("2023-06-15T12:30:45ZZ", "trailing input"),
        ("2023-06-15T12:30:45Z ", "trailing input"),
        ("2023-06-15T12:30:45+0500", "input contains invalid characters"),
        ("2023-06-15T12:30:45+05:60", "input is out of range"),
        ("2023-06-15T12:30:45+24:00", "input is out of range"),
        ("2023-06-15T12:30:45+5:00", "input contains invalid characters"),
        ("2023-06-15T12:30:45 +05:00", "input contains invalid characters"),
        ("2023-06-15X12:30:45Z", "input contains invalid characters"),
        ("2023/06/15T12:30:45Z", "input contains invalid characters"),
        ("20a3-06-15T12:30:45Z", "input contains invalid characters"),
        ("2023-02-29T00:00:00Z", "input is out of range"),
        ("1900-02-29T00:00:00Z", "input is out of range"),
        ("2023-04-31T00:00:00Z", "input is out of range"),
        ("2023-13-01T00:00:00Z", "input is out of range"),
        ("2023-00-10T00:00:00Z", "input is out of range"),
        ("2023-06-00T00:00:00Z", "input is out of range"),
        ("2023-06-15T24:00:00Z", "input is out of range"),
        ("2023-06-15T12:60:00Z", "input is out of range"),
        ("2023-06-15T12:30:61Z", "input is out of range"),
        ("2023-02-30X12:30:45Z", "input is out of range"),
    ]

    /// Unpadded base64url text (RFC 4648 Section 5).
    static let base64URLCases: [(String, String?)] = [
        ("", nil),
        ("AA", nil),
        ("AAA", nil),
        ("AAAA", nil),
        ("Zm9vYmFy", nil),
        ("Zm9vYg", nil),
        ("-_-_", nil),
        ("_w", nil),
        ("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", nil),
        ("!AAA", "Invalid symbol 33, offset 0."),
        ("AA!A", "Invalid symbol 33, offset 2."),
        ("A", "Invalid input length: 1"),
        ("AAAAA", "Invalid input length: 5"),
        ("AAAAA!", "Invalid symbol 33, offset 5."),
        ("AAAA!", "Invalid symbol 33, offset 4."),
        ("QQ==", "Invalid padding"),
        ("QQ=", "Invalid padding"),
        ("Q===", "Invalid symbol 61, offset 1."),
        ("=AAA", "Invalid symbol 61, offset 0."),
        ("QUI=", "Invalid padding"),
        ("QUI=A", "Invalid symbol 61, offset 3."),
        ("AB", "Invalid last symbol 0x42 ('B') at offset 1, decoded as 0b00000001."),
        ("AAB", "Invalid last symbol 0x42 ('B') at offset 2, decoded as 0b00000001."),
        ("A_", "Invalid last symbol 0x5f ('_') at offset 1, decoded as 0b00111111."),
        ("AAAB==", "Invalid symbol 61, offset 4."),
        ("YWJj+/", "Invalid symbol 43, offset 4."),
        ("YW Jj", "Invalid symbol 32, offset 2."),
        ("\u{e9}A", "Invalid symbol 195, offset 0."),
        ("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA/AAAAAA", "Invalid symbol 47, offset 41."),
    ]

    @Test(arguments: uriCases)
    func uri(_ input: String, _ expected: String?) {
        #expect(uriMismatch(input) == expected, "input: \(input)")
    }

    @Test(arguments: dateTimeCases)
    func dateTime(_ input: String, _ expected: String?) {
        #expect(rfc3339ParseError(input) == expected, "input: \(input)")
    }

    @Test(arguments: base64URLCases)
    func base64URL(_ input: String, _ expected: String?) {
        #expect(base64URLDecodeError(input) == expected, "input: \(input)")
    }

    /// A path may hold at most 65,535 segments.
    @Test func uriPathSegmentLimit() {
        #expect(uriMismatch("a:x" + String(repeating: "/", count: 65_534)) == nil)
        #expect(
            uriMismatch("a:x" + String(repeating: "/", count: 65_535))
                == Self.uriError("exceeded maximum path length")
        )
    }
}
