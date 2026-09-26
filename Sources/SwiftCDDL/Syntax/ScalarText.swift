// String helpers for the formatter. They work on Unicode scalars and bytes
// rather than on grapheme clusters, so that, for instance, a string ending in
// "\r\n" still ends with "\n".

extension String {
    /// Drops trailing Unicode whitespace.
    func trimmingTrailingWhitespace() -> String {
        var scalars = unicodeScalars[...]
        while let last = scalars.last, last.properties.isWhitespace {
            scalars = scalars.dropLast()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Drops leading Unicode whitespace.
    func trimmingLeadingWhitespace() -> String {
        var scalars = unicodeScalars[...]
        while let first = scalars.first, first.properties.isWhitespace {
            scalars = scalars.dropFirst()
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// Drops leading and trailing Unicode whitespace.
    func trimmingWhitespace() -> String {
        trimmingLeadingWhitespace().trimmingTrailingWhitespace()
    }

    /// Whether the string is empty after trimming whitespace.
    var isBlank: Bool {
        unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }

    /// Whether the last byte is the ASCII character `byte`.
    func endsWith(_ byte: Unicode.Scalar) -> Bool {
        utf8.last == UInt8(byte.value)
    }

    /// Whether the first byte is the ASCII character `byte`.
    func startsWith(_ byte: Unicode.Scalar) -> Bool {
        utf8.first == UInt8(byte.value)
    }

    /// Whether the string ends with `suffix`, compared byte-wise.
    func endsWithString(_ suffix: String) -> Bool {
        let s = Array(utf8)
        let t = Array(suffix.utf8)
        return s.count >= t.count && Array(s[(s.count - t.count)...]) == t
    }

    /// The lines of the string: splits at `\n`, drops the `\r` of a `\r\n`,
    /// and yields no final empty line for a trailing `\n`.
    func splitLines() -> [String] {
        if isEmpty { return [] }
        var current: [UInt8] = []
        var result: [String] = []
        for byte in utf8 {
            if byte == UInt8(ascii: "\n") {
                if current.last == UInt8(ascii: "\r") {
                    current.removeLast()
                }
                result.append(String(decoding: current, as: UTF8.self))
                current = []
            } else {
                current.append(byte)
            }
        }
        if !current.isEmpty {
            result.append(String(decoding: current, as: UTF8.self))
        }
        return result
    }

    /// Replaces every occurrence of the scalar `from`.
    func replacingScalar(_ from: Unicode.Scalar, with replacement: String) -> String {
        var out = ""
        for scalar in unicodeScalars {
            if scalar == from {
                out += replacement
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Removes the last Unicode scalar.
    mutating func removeLastScalar() {
        guard !isEmpty else { return }
        unicodeScalars.removeLast()
    }

    /// The number of non-overlapping occurrences of `needle`, compared
    /// byte-wise.
    func occurrences(of needle: String) -> Int {
        let hay = Array(utf8)
        let pat = Array(needle.utf8)
        guard !pat.isEmpty, hay.count >= pat.count else { return 0 }
        var count = 0
        var i = 0
        while i + pat.count <= hay.count {
            if Array(hay[i..<(i + pat.count)]) == pat {
                count += 1
                i += pat.count
            } else {
                i += 1
            }
        }
        return count
    }
}
