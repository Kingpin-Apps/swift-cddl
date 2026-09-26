// Hex text for test inputs.

/// Bytes from a hex string; whitespace is ignored.
func hexBytes(_ hex: String) -> [UInt8] {
    let digits = Array(hex.utf8).filter { !($0 == 0x20 || $0 == 0x0a || $0 == 0x09 || $0 == 0x0d) }
    precondition(digits.count % 2 == 0, "odd number of hex digits")
    func value(_ c: UInt8) -> UInt8 {
        switch c {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return c - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return c - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return c - UInt8(ascii: "A") + 10
        default: preconditionFailure("not a hex digit")
        }
    }
    var out: [UInt8] = []
    out.reserveCapacity(digits.count / 2)
    var index = 0
    while index < digits.count {
        out.append(value(digits[index]) << 4 | value(digits[index + 1]))
        index += 2
    }
    return out
}

/// Lower-case hex of `bytes`.
func hexString(_ bytes: [UInt8]) -> String {
    bytes.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined()
}
