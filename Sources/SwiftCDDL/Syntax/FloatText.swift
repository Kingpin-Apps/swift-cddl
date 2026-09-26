import Foundation

// Reading and writing of float literals (RFC 8610 Appendix B: `number =
// hexfloat / (int ["." fraction] ["e" exponent])`): shortest round-trip
// decimal digits in plain and in exponent notation, decimal parsing, and exact
// parsing of hexadecimal floats.

/// The shortest decimal digits that read back as `value`, and the position of
/// the decimal point relative to them (`0.d1d2… × 10^point`).
private func shortestDigits(_ value: Double) -> (negative: Bool, digits: [UInt8], point: Int) {
    let negative = value.sign == .minus
    if value == 0 {
        return (negative, [], 0)
    }

    // Swift's description is the shortest round-tripping representation; only
    // its layout differs from the one written here, so the digits are read
    // back out of it.
    var text = Array(abs(value).description.utf8)
    var exponent = 0
    if let e = text.firstIndex(where: { $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) {
        let expText = String(decoding: text[(e + 1)...], as: UTF8.self)
        exponent = Int(expText) ?? 0
        text = Array(text[..<e])
    }

    var digits: [UInt8] = []
    var intDigits = 0
    var seenPoint = false
    for c in text {
        if c == UInt8(ascii: ".") {
            seenPoint = true
            continue
        }
        digits.append(c)
        if !seenPoint {
            intDigits += 1
        }
    }

    var point = intDigits + exponent
    while let first = digits.first, first == UInt8(ascii: "0") {
        digits.removeFirst()
        point -= 1
    }
    while let last = digits.last, last == UInt8(ascii: "0") {
        digits.removeLast()
    }
    return (negative, digits, point)
}

/// A finite `Double` as the shortest round-trip digits written out in full,
/// without an exponent (`1e20` is `100000000000000000000`, `1.5` is `1.5`,
/// `2.0` is `2`).
func plainDecimalDescription(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value.sign == .minus ? "-inf" : "inf" }

    let (negative, digits, point) = shortestDigits(value)
    var out = negative ? "-" : ""
    if digits.isEmpty {
        return out + "0"
    }

    let digitText = String(decoding: digits, as: UTF8.self)
    if point <= 0 {
        out += "0." + String(repeating: "0", count: -point) + digitText
    } else if point >= digits.count {
        out += digitText + String(repeating: "0", count: point - digits.count)
    } else {
        out += String(decoding: digits[..<point], as: UTF8.self) + "."
            + String(decoding: digits[point...], as: UTF8.self)
    }
    return out
}

/// A finite `Double` as the shortest round-trip digits in exponent notation,
/// with no fraction for a single digit (`1e300`, `1.5e-300`, `0e0`).
func exponentialDescription(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value.sign == .minus ? "-inf" : "inf" }

    let (negative, digits, point) = shortestDigits(value)
    var out = negative ? "-" : ""
    if digits.isEmpty {
        return out + "0e0"
    }
    out += String(UnicodeScalar(digits[0]))
    if digits.count > 1 {
        out += "." + String(decoding: digits[1...], as: UTF8.self)
    }
    out += "e" + String(point - 1)
    return out
}

/// A finite `Double` as the shortest round-trip digits laid out the way a JSON
/// number is written back (RFC 8259 Section 6): plain decimal with at least one
/// fraction digit from 1e-5 up to below 1e16 (`1.0`, `0.00001`, `12.5`),
/// exponent notation with a signed exponent outside it (`1e+16`, `1.5e-7`),
/// and `-0.0` for negative zero.
func jsonNumberText(_ value: Double) -> String {
    if value.isNaN { return "NaN" }
    if value.isInfinite { return value.sign == .minus ? "-inf" : "inf" }

    let (negative, digits, point) = shortestDigits(value)
    var out = negative ? "-" : ""
    if digits.isEmpty {
        return out + "0.0"
    }

    let length = digits.count
    let text = String(decoding: digits, as: UTF8.self)
    if point >= length && point <= 16 {
        out += text + String(repeating: "0", count: point - length) + ".0"
    } else if point > 0 && point <= 16 {
        out += String(decoding: digits[..<point], as: UTF8.self) + "."
            + String(decoding: digits[point...], as: UTF8.self)
    } else if point > -5 && point <= 0 {
        out += "0." + String(repeating: "0", count: -point) + text
    } else {
        let exponent = point - 1
        out += String(decoding: digits[..<1], as: UTF8.self)
        if length > 1 {
            out += "." + String(decoding: digits[1...], as: UTF8.self)
        }
        out += (exponent < 0 ? "e-" : "e+") + String(abs(exponent))
    }
    return out
}

/// Parses a decimal float: an optional sign, then `inf`, `infinity` or `nan`
/// in any case, or a decimal with at least one digit, an optional fraction and
/// an optional exponent. Out-of-range magnitudes read as an infinity.
func parseDecimalFloat(_ text: String) -> Double? {
    var bytes = Array(text.utf8)
    var negative = false
    if let first = bytes.first, first == UInt8(ascii: "+") || first == UInt8(ascii: "-") {
        negative = first == UInt8(ascii: "-")
        bytes.removeFirst()
    }

    let lower = String(decoding: bytes, as: UTF8.self).lowercased()
    if lower == "inf" || lower == "infinity" {
        return negative ? -Double.infinity : Double.infinity
    }
    if lower == "nan" {
        return Double.nan
    }

    var index = 0
    var mantissaDigits = 0
    while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
        index += 1
        mantissaDigits += 1
    }
    if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
        index += 1
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
            index += 1
            mantissaDigits += 1
        }
    }
    guard mantissaDigits > 0 else { return nil }
    if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
        index += 1
        if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        var expDigits = 0
        while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
            index += 1
            expDigits += 1
        }
        guard expDigits > 0 else { return nil }
    }
    guard index == bytes.count else { return nil }

    guard let magnitude = Double(String(decoding: bytes, as: UTF8.self)) else { return nil }
    return negative ? -magnitude : magnitude
}

/// Parses a hexadecimal float literal such as `0x1.8p3` (RFC 8610 Appendix B
/// `hexfloat`), failing when it is malformed or when its value is not exactly
/// representable as a `Double`.
func parseHexf64(_ text: String) -> Double? {
    guard let (negative, mantissa, exponent) = parseHexfParts(Array(text.utf8)) else {
        return nil
    }
    return convertHexf64(negative: negative, mantissa: mantissa, exponent: exponent)
}

private func hexDigitValue(_ c: UInt8) -> UInt8? {
    switch c {
    case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
    case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
    case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
    default: return nil
    }
}

private func parseHexfParts(_ input: [UInt8]) -> (Bool, UInt64, Int)? {
    var s = input[...]
    guard let first = s.first else { return nil }
    var negative = false
    if first == UInt8(ascii: "+") {
        s = s.dropFirst()
    } else if first == UInt8(ascii: "-") {
        negative = true
        s = s.dropFirst()
    }

    guard s.count >= 2, s[s.startIndex] == UInt8(ascii: "0"),
        s[s.startIndex + 1] == UInt8(ascii: "x") || s[s.startIndex + 1] == UInt8(ascii: "X")
    else {
        return nil
    }
    s = s.dropFirst(2)

    var acc: UInt64 = 0
    var digitSeen = false
    while let c = s.first, let digit = hexDigitValue(c) {
        s = s.dropFirst()
        digitSeen = true
        if acc >> 60 != 0 {
            return nil
        }
        acc = acc << 4 | UInt64(digit)
    }

    var nfracs = 0
    var nzeroes = 0
    var fracDigitSeen = false
    if s.first == UInt8(ascii: ".") {
        s = s.dropFirst()
        while let c = s.first, let digit = hexDigitValue(c) {
            s = s.dropFirst()
            fracDigitSeen = true
            if digit == 0 {
                let (next, overflow) = nzeroes.addingReportingOverflow(1)
                if overflow { return nil }
                nzeroes = next
            } else {
                let (nnewdigits, o1) = nzeroes.addingReportingOverflow(1)
                if o1 { return nil }
                let (nextFracs, o2) = nfracs.addingReportingOverflow(nnewdigits)
                if o2 { return nil }
                nfracs = nextFracs
                nzeroes = 0
                if acc != 0 {
                    if nnewdigits >= 16 || acc >> UInt64(64 - nnewdigits * 4) != 0 {
                        return nil
                    }
                    acc = acc << UInt64(nnewdigits * 4)
                }
                acc |= UInt64(digit)
            }
        }
    }

    if !(digitSeen || fracDigitSeen) {
        return nil
    }

    guard let p = s.first, p == UInt8(ascii: "p") || p == UInt8(ascii: "P") else {
        return nil
    }
    s = s.dropFirst()

    guard let signOrDigit = s.first else { return nil }
    var negativeExponent = false
    if signOrDigit == UInt8(ascii: "+") {
        s = s.dropFirst()
    } else if signOrDigit == UInt8(ascii: "-") {
        negativeExponent = true
        s = s.dropFirst()
    }

    var expDigitSeen = false
    var exponent = 0
    while true {
        guard let c = s.first else {
            if expDigitSeen { break }
            return nil
        }
        guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) else {
            return nil
        }
        s = s.dropFirst()
        expDigitSeen = true
        if acc != 0 {
            let (m, o1) = exponent.multipliedReportingOverflow(by: 10)
            if o1 { return nil }
            let (a, o2) = m.addingReportingOverflow(Int(c - UInt8(ascii: "0")))
            if o2 { return nil }
            exponent = a
        }
    }
    if negativeExponent {
        exponent = -exponent
    }

    if acc == 0 {
        return (negative, 0, 0)
    }
    let (scaled, o1) = nfracs.multipliedReportingOverflow(by: 4)
    if o1 { return nil }
    let (finalExponent, o2) = exponent.subtractingReportingOverflow(scaled)
    if o2 { return nil }
    return (negative, acc, finalExponent)
}

private func convertHexf64(negative: Bool, mantissa inputMantissa: UInt64, exponent inputExponent: Int) -> Double? {
    if inputExponent < -0xffff || inputExponent > 0xffff {
        return nil
    }

    let trailing = inputMantissa.trailingZeroBitCount & 63
    let mantissa = inputMantissa >> UInt64(trailing)
    let exponent = inputExponent + trailing

    let leading = mantissa.leadingZeroBitCount
    let normalexp = exponent + (63 - leading)
    // f64: MIN_EXP = -1021, MAX_EXP = 1024, MANTISSA_DIGITS = 53.
    let minExp = -1021
    let maxExp = 1024
    let mantissaDigits = 53
    let mantissaSize: Int
    if normalexp < minExp - mantissaDigits {
        return nil
    } else if normalexp < minExp - 1 {
        mantissaSize = mantissaDigits - minExp + normalexp + 1
    } else if normalexp < maxExp {
        mantissaSize = mantissaDigits
    } else {
        return nil
    }

    let shifted = mantissaSize >= 64 ? 0 : mantissa >> UInt64(mantissaSize)
    guard shifted == 0 else { return nil }
    var value = Double(mantissa)
    if negative {
        value = -value
    }
    return value * pow(2.0, Double(exponent))
}
