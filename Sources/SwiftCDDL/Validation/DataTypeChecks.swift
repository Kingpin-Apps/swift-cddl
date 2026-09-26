// Text checks behind the standard prelude types that constrain the content of
// a text or byte string: `uri` (RFC 3986), `tdate` (RFC 3339) and the
// base64url text of `b64url` (RFC 4648 Section 5). Each check answers `nil`
// for acceptable input or the diagnostic text reported for it.

// MARK: - URI (RFC 3986)

/// Why `text` is not an absolute URI (RFC 3986 Section 3), or `nil` when it is
/// one.
///
/// The text is parsed as a URI reference (RFC 3986 Section 4.1); a reference
/// without a scheme (a relative reference) is rejected with "not URI".
func uriMismatch(_ text: String) -> String? {
    let prefix = "expected URI data type, decoding error: "
    do {
        let hasScheme = try URIReferenceScanner(Array(text.utf8)).scan()
        return hasScheme ? nil : prefix + "not URI"
    } catch {
        return prefix + error.rawValue
    }
}

/// The ways a URI reference can be malformed, with their diagnostic text.
private enum URIFault: String, Error {
    case schemelessPathStartsWithColonSegment = "schemeless path URI reference starts with colon segment"
    case hostAddressMechanismNotSupported = "host address mechanism not supported"
    case invalidRegisteredNameCharacter = "invalid host IPv4 or registered name character"
    case invalidIPv6Character = "invalid host IPv6 character"
    case invalidIPv6Format = "invalid host IPv6 format"
    case invalidIPvFutureCharacter = "invalid host IPvFuture character"
    case invalidPasswordCharacter = "invalid password character"
    case invalidPasswordPercentEncoding = "invalid password percent encoding"
    case invalidUsernameCharacter = "invalid username character"
    case invalidUsernamePercentEncoding = "invalid username percent encoding"
    case invalidPortCharacter = "invalid port character"
    case portOverflow = "port overflow"
    case exceededMaximumPathLength = "exceeded maximum path length"
    case invalidPathCharacter = "invalid path character"
    case invalidPathPercentEncoding = "invalid path percent encoding"
    case invalidQueryCharacter = "invalid query character"
    case invalidQueryPercentEncoding = "invalid query percent encoding"
    case invalidFragmentCharacter = "invalid fragment character"
    case invalidFragmentPercentEncoding = "invalid fragment percent encoding"
}

/// Byte classes of the RFC 3986 grammar, one flag per byte value.
private enum URIByteClass {
    static let alphaDigit = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
    /// `unreserved` and `sub-delims` (RFC 3986 Section 2).
    static let unreservedAndSubDelims = alphaDigit + "-._~!$&'()*+,;="

    /// `ALPHA / DIGIT / "+" / "-" / "."` (RFC 3986 Section 3.1).
    static let scheme = table(alphaDigit + "+-.")
    /// `reg-name` characters plus `%` (RFC 3986 Section 3.2.2).
    static let registeredName = table(unreservedAndSubDelims + "%")
    /// The characters after `v` and the version in an `IPvFuture` literal.
    static let ipvFuture = table(unreservedAndSubDelims + ":")
    /// `userinfo` characters plus `%` (RFC 3986 Section 3.2.1).
    static let userInfo = table(unreservedAndSubDelims + ":%")
    /// `pchar` plus `%` (RFC 3986 Section 3.3).
    static let path = table(unreservedAndSubDelims + ":@%")
    /// Query and fragment characters plus `%` (RFC 3986 Sections 3.4 and 3.5).
    static let queryOrFragment = table(unreservedAndSubDelims + ":@/?%")

    private static func table(_ members: String) -> [Bool] {
        var flags = [Bool](repeating: false, count: 256)
        for byte in members.utf8 {
            flags[Int(byte)] = true
        }
        return flags
    }
}

/// The value of an ASCII hexadecimal digit.
private func hexValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
    default: return nil
    }
}

private func isASCIIAlpha(_ byte: UInt8) -> Bool {
    (byte | 0x20) >= UInt8(ascii: "a") && (byte | 0x20) <= UInt8(ascii: "z")
}

/// A single left-to-right pass over a URI reference (RFC 3986 Section 4.1):
/// optional scheme, optional authority, path, optional query and fragment.
private struct URIReferenceScanner {
    let bytes: [UInt8]

    init(_ bytes: [UInt8]) {
        self.bytes = bytes
    }

    /// Validates the reference and tells whether it has a scheme.
    func scan() throws(URIFault) -> Bool {
        var index = 0
        let hasScheme = schemeEnd().map { end in
            index = end + 1
            return true
        } ?? false

        var hasAuthority = false
        if index + 1 < bytes.count, bytes[index] == UInt8(ascii: "/"), bytes[index + 1] == UInt8(ascii: "/") {
            hasAuthority = true
            index = try scanAuthority(from: index + 2)
        }

        let (pathEnd, firstSegmentHasColon) = try scanPath(from: index)
        index = pathEnd
        if !hasScheme && !hasAuthority && firstSegmentHasColon {
            throw .schemelessPathStartsWithColonSegment
        }

        if index < bytes.count, bytes[index] == UInt8(ascii: "?") {
            index = try scanQueryOrFragment(
                from: index + 1,
                stopAtHash: true,
                invalidCharacter: .invalidQueryCharacter,
                invalidPercentEncoding: .invalidQueryPercentEncoding
            )
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "#") {
            index = try scanQueryOrFragment(
                from: index + 1,
                stopAtHash: false,
                invalidCharacter: .invalidFragmentCharacter,
                invalidPercentEncoding: .invalidFragmentPercentEncoding
            )
        }
        return hasScheme
    }

    /// The index of the `:` ending a leading scheme, or `nil` when the text
    /// does not start with `scheme ":"`.
    private func schemeEnd() -> Int? {
        guard let first = bytes.first, isASCIIAlpha(first) else {
            return nil
        }
        for index in bytes.indices {
            let byte = bytes[index]
            if byte == UInt8(ascii: ":") {
                return index
            }
            if !URIByteClass.scheme[Int(byte)] {
                return nil
            }
        }
        return nil
    }

    /// Whether the two bytes after a `%` at `index`, before `end`, are
    /// hexadecimal digits.
    private func percentEncodingIsValid(at index: Int, end: Int) -> Bool {
        index + 2 < end && hexValue(bytes[index + 1]) != nil && hexValue(bytes[index + 2]) != nil
    }

    // MARK: Authority

    /// Validates the authority starting at `start` (RFC 3986 Section 3.2) and
    /// returns the index just past it.
    private func scanAuthority(from start: Int) throws(URIFault) -> Int {
        var atIndex: Int?
        var lastColonIndex: Int?
        var end = bytes.count
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "@") {
                if atIndex == nil {
                    atIndex = index
                    lastColonIndex = nil
                }
            } else if byte == UInt8(ascii: ":") {
                lastColonIndex = index
            } else if byte == UInt8(ascii: "]") {
                lastColonIndex = nil
            } else if byte == UInt8(ascii: "/") || byte == UInt8(ascii: "?") || byte == UInt8(ascii: "#") {
                end = index
                break
            }
            index += 1
        }

        var hostStart = start
        if let atIndex {
            try scanUserInfo(start, atIndex)
            hostStart = atIndex + 1
        }
        if let lastColonIndex {
            try scanHost(hostStart, lastColonIndex)
            try scanPort(lastColonIndex + 1, end)
        } else {
            try scanHost(hostStart, end)
        }
        return end
    }

    /// Validates `userinfo` (RFC 3986 Section 3.2.1): a username, then after
    /// the first `:` a password.
    private func scanUserInfo(_ start: Int, _ end: Int) throws(URIFault) {
        var inPassword = false
        var index = start
        while index < end {
            let byte = bytes[index]
            if !URIByteClass.userInfo[Int(byte)] {
                throw inPassword ? .invalidPasswordCharacter : .invalidUsernameCharacter
            }
            if byte == UInt8(ascii: "%") {
                guard percentEncodingIsValid(at: index, end: end) else {
                    throw inPassword ? .invalidPasswordPercentEncoding : .invalidUsernamePercentEncoding
                }
                index += 3
                continue
            }
            if byte == UInt8(ascii: ":") {
                inPassword = true
            }
            index += 1
        }
    }

    /// Validates a host (RFC 3986 Section 3.2.2): an IP literal in brackets,
    /// or an IPv4 address or registered name. `IPvFuture` literals are
    /// recognised but not supported.
    private func scanHost(_ start: Int, _ end: Int) throws(URIFault) {
        guard start < end else {
            return
        }
        if bytes[start] == UInt8(ascii: "["), bytes[end - 1] == UInt8(ascii: "]") {
            if end - start >= 3, bytes[start + 1] | 0x20 == UInt8(ascii: "v"), hexValue(bytes[start + 2]) != nil {
                for index in (start + 3)..<(end - 1) where !URIByteClass.ipvFuture[Int(bytes[index])] {
                    throw .invalidIPvFutureCharacter
                }
                throw .hostAddressMechanismNotSupported
            }
            let literal = Array(bytes[(start + 1)..<(end - 1)])
            for byte in literal where hexValue(byte) == nil && byte != UInt8(ascii: ":") && byte != UInt8(ascii: ".") {
                throw .invalidIPv6Character
            }
            guard IPv6TextParser.accepts(literal) else {
                throw .invalidIPv6Format
            }
            return
        }
        var index = start
        while index < end {
            let byte = bytes[index]
            guard URIByteClass.registeredName[Int(byte)] else {
                throw .invalidRegisteredNameCharacter
            }
            if byte == UInt8(ascii: "%") {
                guard percentEncodingIsValid(at: index, end: end) else {
                    throw .invalidRegisteredNameCharacter
                }
                index += 3
            } else {
                index += 1
            }
        }
    }

    /// Validates a port (RFC 3986 Section 3.2.3), which must fit 16 bits.
    private func scanPort(_ start: Int, _ end: Int) throws(URIFault) {
        var port: UInt16 = 0
        for index in start..<end {
            let byte = bytes[index]
            guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
                throw .invalidPortCharacter
            }
            let (shifted, multiplyOverflow) = port.multipliedReportingOverflow(by: 10)
            guard !multiplyOverflow else {
                throw .portOverflow
            }
            let (sum, addOverflow) = shifted.addingReportingOverflow(UInt16(byte - UInt8(ascii: "0")))
            guard !addOverflow else {
                throw .portOverflow
            }
            port = sum
        }
    }

    // MARK: Path, query and fragment

    /// Validates the path starting at `start` (RFC 3986 Section 3.3). Returns
    /// the index just past it and whether its first segment contains a `:`.
    private func scanPath(from start: Int) throws(URIFault) -> (end: Int, firstSegmentHasColon: Bool) {
        var index = start
        if index < bytes.count, bytes[index] == UInt8(ascii: "/") {
            index += 1
        }
        var segmentNumber: UInt16 = 1
        var firstSegmentHasColon = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "?") || byte == UInt8(ascii: "#") {
                return (index, firstSegmentHasColon)
            }
            if byte == UInt8(ascii: "/") {
                guard segmentNumber < UInt16.max else {
                    throw .exceededMaximumPathLength
                }
                segmentNumber += 1
                index += 1
                continue
            }
            guard URIByteClass.path[Int(byte)] else {
                throw .invalidPathCharacter
            }
            if byte == UInt8(ascii: "%") {
                guard percentEncodingIsValid(at: index, end: bytes.count) else {
                    throw .invalidPathPercentEncoding
                }
                index += 3
                continue
            }
            if byte == UInt8(ascii: ":") && segmentNumber == 1 {
                firstSegmentHasColon = true
            }
            index += 1
        }
        return (index, firstSegmentHasColon)
    }

    /// Validates a query (RFC 3986 Section 3.4), which ends at `#`, or a
    /// fragment (Section 3.5), which runs to the end.
    private func scanQueryOrFragment(
        from start: Int,
        stopAtHash: Bool,
        invalidCharacter: URIFault,
        invalidPercentEncoding: URIFault
    ) throws(URIFault) -> Int {
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if stopAtHash && byte == UInt8(ascii: "#") {
                return index
            }
            guard URIByteClass.queryOrFragment[Int(byte)] else {
                throw invalidCharacter
            }
            if byte == UInt8(ascii: "%") {
                guard percentEncodingIsValid(at: index, end: bytes.count) else {
                    throw invalidPercentEncoding
                }
                index += 3
            } else {
                index += 1
            }
        }
        return index
    }
}

/// Recognises the textual IPv6 address forms of RFC 4291 Section 2.2 (as
/// referenced by `IPv6address` in RFC 3986 Section 3.2.2): up to eight
/// hexadecimal groups of at most four digits, at most one `::`, and an
/// optional trailing dotted IPv4 address. Each read either succeeds and
/// advances, or fails and leaves the position unchanged.
private struct IPv6TextParser {
    let bytes: [UInt8]
    var position = 0

    static func accepts(_ bytes: [UInt8]) -> Bool {
        var parser = IPv6TextParser(bytes: bytes)
        return parser.readAddress() && parser.position == bytes.count
    }

    private mutating func readGiven(_ byte: UInt8) -> Bool {
        guard position < bytes.count, bytes[position] == byte else {
            return false
        }
        position += 1
        return true
    }

    private func digitValue(_ byte: UInt8, radix: UInt32) -> UInt32? {
        guard let value = hexValue(byte), UInt32(value) < radix else {
            return nil
        }
        return UInt32(value)
    }

    /// A number of at most `maxDigits` digits; more digits fail the read.
    private mutating func readNumber(radix: UInt32, maxDigits: Int, allowZeroPrefix: Bool, limit: UInt32) -> UInt32? {
        let saved = position
        guard position < bytes.count, let first = digitValue(bytes[position], radix: radix) else {
            return nil
        }
        position += 1
        var result = first
        var digitCount = 1
        while position < bytes.count, let digit = digitValue(bytes[position], radix: radix) {
            position += 1
            if digitCount >= maxDigits {
                position = saved
                return nil
            }
            result = result * radix + digit
            digitCount += 1
        }
        if (!allowZeroPrefix && first == 0 && digitCount > 1) || result > limit {
            position = saved
            return nil
        }
        return result
    }

    /// A dotted-decimal IPv4 address without leading zeros.
    private mutating func readIPv4() -> Bool {
        let saved = position
        for group in 0..<4 {
            if group > 0 && !readGiven(UInt8(ascii: ".")) {
                position = saved
                return false
            }
            if readNumber(radix: 10, maxDigits: 3, allowZeroPrefix: false, limit: 255) == nil {
                position = saved
                return false
            }
        }
        return true
    }

    /// One separator-prefixed item (no separator before the first item).
    private mutating func readSeparated(_ index: Int, _ item: (inout IPv6TextParser) -> Bool) -> Bool {
        let saved = position
        if index > 0 && !readGiven(UInt8(ascii: ":")) {
            return false
        }
        if item(&self) {
            return true
        }
        position = saved
        return false
    }

    /// Reads up to `limit` groups; returns how many 16-bit groups were read
    /// and whether the last item was an embedded IPv4 address.
    private mutating func readGroups(limit: Int) -> (count: Int, endedWithIPv4: Bool) {
        for index in 0..<limit {
            if index < limit - 1 && readSeparated(index, { $0.readIPv4() }) {
                return (index + 2, true)
            }
            let hasGroup = readSeparated(index) {
                $0.readNumber(radix: 16, maxDigits: 4, allowZeroPrefix: true, limit: 0xFFFF) != nil
            }
            if !hasGroup {
                return (index, false)
            }
        }
        return (limit, false)
    }

    mutating func readAddress() -> Bool {
        let saved = position
        let head = readGroups(limit: 8)
        if head.count == 8 {
            return true
        }
        if head.endedWithIPv4 {
            position = saved
            return false
        }
        // Fewer than eight groups: the rest must follow a `::` elision, which
        // stands for at least one zero group.
        guard readGiven(UInt8(ascii: ":")), readGiven(UInt8(ascii: ":")) else {
            position = saved
            return false
        }
        _ = readGroups(limit: 8 - (head.count + 1))
        return true
    }
}

// MARK: - Date-time (RFC 3339)

/// The ways an RFC 3339 date-time can fail to parse, with their diagnostic
/// text.
private enum DateTimeFault: String, Error {
    case outOfRange = "input is out of range"
    case invalid = "input contains invalid characters"
    case tooShort = "premature end of input"
    case tooLong = "trailing input"
}

/// Why `text` is not an RFC 3339 `date-time` (Section 5.6), or `nil` when it
/// is one.
///
/// The `T` separator and `Z` offset may be lower case, a space may separate
/// date and time, a leap second (`:60`) is accepted at any minute, fractional
/// seconds may have any number of digits, the offset hour is limited to 23,
/// and U+2212 MINUS SIGN is accepted in the offset.
func rfc3339ParseError(_ text: String) -> String? {
    do {
        try parseRFC3339(Array(text.utf8))
        return nil
    } catch {
        return error.rawValue
    }
}

private func parseRFC3339(_ bytes: [UInt8]) throws(DateTimeFault) {
    guard bytes.count >= 19 else {
        throw .tooShort
    }
    func digit(_ index: Int) throws(DateTimeFault) -> Int {
        let byte = bytes[index]
        guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else {
            throw .invalid
        }
        return Int(byte - UInt8(ascii: "0"))
    }
    func expect(_ index: Int, _ allowed: String) throws(DateTimeFault) {
        guard allowed.utf8.contains(bytes[index]) else {
            throw .invalid
        }
    }

    let year = try digit(0) * 1000 + digit(1) * 100 + digit(2) * 10 + digit(3)
    try expect(4, "-")
    let month = try digit(5) * 10 + digit(6)
    try expect(7, "-")
    let day = try digit(8) * 10 + digit(9)
    guard (1...12).contains(month), day >= 1, day <= daysInMonth(year: year, month: month) else {
        throw .outOfRange
    }
    try expect(10, "tT ")

    let hour = try digit(11) * 10 + digit(12)
    try expect(13, ":")
    let minute = try digit(14) * 10 + digit(15)
    try expect(16, ":")
    var second = try digit(17) * 10 + digit(18)
    var nanosecond = 0
    if second == 60 {
        second = 59
        nanosecond = 1_000_000_000
    }

    var index = 19
    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        index += 1
        nanosecond += try fractionNanoseconds(bytes, &index)
    }
    guard hour < 24, minute < 60, second < 60,
          nanosecond < 1_000_000_000 || second == 59,
          nanosecond < 2_000_000_000 else {
        throw .outOfRange
    }

    let offset = try offsetSeconds(bytes, &index)
    guard index == bytes.count else {
        throw .tooLong
    }
    guard offset > -86_400, offset < 86_400 else {
        throw .outOfRange
    }
}

/// The days in a month of the proleptic Gregorian calendar.
private func daysInMonth(year: Int, month: Int) -> Int {
    switch month {
    case 2:
        let isLeap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return isLeap ? 29 : 28
    case 4, 6, 9, 11:
        return 30
    default:
        return 31
    }
}

/// `time-secfrac` digits after the `.` as nanoseconds; digits past the ninth
/// are read and ignored.
private func fractionNanoseconds(_ bytes: [UInt8], _ index: inout Int) throws(DateTimeFault) -> Int {
    func isDigit(_ position: Int) -> Bool {
        position < bytes.count && bytes[position] >= UInt8(ascii: "0") && bytes[position] <= UInt8(ascii: "9")
    }
    guard index < bytes.count else {
        throw .tooShort
    }
    guard isDigit(index) else {
        throw .invalid
    }
    var value = 0
    var count = 0
    while count < 9 && isDigit(index) {
        value = value * 10 + Int(bytes[index] - UInt8(ascii: "0"))
        count += 1
        index += 1
    }
    for _ in count..<9 {
        value *= 10
    }
    while isDigit(index) {
        index += 1
    }
    return value
}

/// `time-offset` (`Z`, or a sign, two hour digits, `:` and two minute
/// digits) in seconds east of UTC.
private func offsetSeconds(_ bytes: [UInt8], _ index: inout Int) throws(DateTimeFault) -> Int {
    guard index < bytes.count else {
        throw .tooShort
    }
    let lead = bytes[index]
    if lead == UInt8(ascii: "Z") || lead == UInt8(ascii: "z") {
        index += 1
        return 0
    }
    let isNegative: Bool
    if lead == UInt8(ascii: "+") {
        isNegative = false
        index += 1
    } else if lead == UInt8(ascii: "-") {
        isNegative = true
        index += 1
    } else if bytes.count - index >= 3, bytes[index] == 0xE2, bytes[index + 1] == 0x88, bytes[index + 2] == 0x92 {
        // U+2212 MINUS SIGN
        isNegative = true
        index += 3
    } else {
        throw .invalid
    }

    func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
    guard bytes.count - index >= 2 else {
        throw .tooShort
    }
    guard isDigit(bytes[index]), isDigit(bytes[index + 1]) else {
        throw .invalid
    }
    let hours = Int(bytes[index] - UInt8(ascii: "0")) * 10 + Int(bytes[index + 1] - UInt8(ascii: "0"))
    index += 2

    guard index < bytes.count else {
        throw .tooShort
    }
    guard bytes[index] == UInt8(ascii: ":") else {
        throw .invalid
    }
    index += 1

    guard bytes.count - index >= 2 else {
        throw .tooShort
    }
    let tens = bytes[index]
    let units = bytes[index + 1]
    guard isDigit(tens), isDigit(units) else {
        throw .invalid
    }
    guard tens <= UInt8(ascii: "5") else {
        throw .outOfRange
    }
    let minutes = Int(tens - UInt8(ascii: "0")) * 10 + Int(units - UInt8(ascii: "0"))
    index += 2

    let seconds = hours * 3600 + minutes * 60
    return isNegative ? -seconds : seconds
}

// MARK: - base64url (RFC 4648 Section 5)

/// Why `text` is not unpadded base64url (RFC 4648 Section 5, with the padding
/// omitted as Section 3.2 permits), or `nil` when it decodes.
///
/// Padding characters are rejected, a single leftover symbol is an invalid
/// length, and the unused low bits of the final symbol must be zero.
func base64URLDecodeError(_ text: String) -> String? {
    let bytes = Array(text.utf8)
    let padding = UInt8(ascii: "=")
    let remainder = bytes.count % 4

    if remainder == 1, let last = bytes.last, last != padding, base64URLValue(last) == nil {
        return invalidSymbol(last, bytes.count - 1)
    }

    // Every complete quad except the final one is decoded in bulk.
    let bulkEnd = max(0, bytes.count - remainder - (remainder == 0 ? 4 : 0))
    for index in 0..<bulkEnd where base64URLValue(bytes[index]) == nil {
        return invalidSymbol(bytes[index], index)
    }

    // The final (possibly partial) quad.
    var symbolCount = 0
    var paddingCount = 0
    var firstPaddingOffset = 0
    var lastSymbol: UInt8 = 0
    var lastSymbolValue: UInt8 = 0
    var accumulator: UInt32 = 0
    for (offset, byte) in bytes[bulkEnd...].enumerated() {
        if byte == padding {
            if offset < 2 {
                return invalidSymbol(byte, bulkEnd + offset)
            }
            if paddingCount == 0 {
                firstPaddingOffset = offset
            }
            paddingCount += 1
            continue
        }
        if paddingCount > 0 {
            return invalidSymbol(padding, bulkEnd + firstPaddingOffset)
        }
        guard let value = base64URLValue(byte) else {
            return invalidSymbol(byte, bulkEnd + offset)
        }
        lastSymbol = byte
        lastSymbolValue = value
        accumulator |= UInt32(value) << UInt32(26 - 6 * symbolCount)
        symbolCount += 1
    }
    if !bytes.isEmpty && symbolCount < 2 {
        return "Invalid input length: \(bulkEnd + symbolCount)"
    }
    if paddingCount > 0 {
        return "Invalid padding"
    }
    let decodedByteCount = symbolCount * 6 / 8
    let unusedBitsMask = UInt32.max >> UInt32(decodedByteCount * 8)
    if accumulator & unusedBitsMask != 0 {
        let hex = String(lastSymbol, radix: 16)
        let binary = String(lastSymbolValue, radix: 2)
        let paddedBinary = String(repeating: "0", count: max(0, 8 - binary.count)) + binary
        let hexField = "0x" + hex
        let paddedHex = String(repeating: " ", count: max(0, 4 - hexField.count)) + hexField
        let character = Character(Unicode.Scalar(lastSymbol))
        return "Invalid last symbol \(paddedHex) ('\(character)') at offset \(bulkEnd + symbolCount - 1), "
            + "decoded as 0b\(paddedBinary)."
    }
    return nil
}

/// The 6-bit value of a base64url symbol (RFC 4648 Table 2).
private func base64URLValue(_ byte: UInt8) -> UInt8? {
    switch byte {
    case UInt8(ascii: "A")...UInt8(ascii: "Z"): return byte - UInt8(ascii: "A")
    case UInt8(ascii: "a")...UInt8(ascii: "z"): return byte - UInt8(ascii: "a") + 26
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0") + 52
    case UInt8(ascii: "-"): return 62
    case UInt8(ascii: "_"): return 63
    default: return nil
    }
}

private func invalidSymbol(_ byte: UInt8, _ offset: Int) -> String {
    "Invalid symbol \(byte), offset \(offset)."
}
