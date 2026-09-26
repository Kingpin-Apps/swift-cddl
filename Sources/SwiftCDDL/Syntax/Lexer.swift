// Source positions, and the parsing-expression-grammar (PEG) machinery the
// hand-written CDDL grammar in `Grammar.swift` runs on.
//
// The machine offers the PEG operations (sequence, optional, repeat,
// lookahead, atomic regions), an implicit skip of whitespace and comments
// between the operands of a non-atomic sequence, a token queue from which the
// parse tree is built, and furthest-failure bookkeeping from which parse
// errors name the rules that were expected at the point of failure.

/// Lexer position.
struct Position: Sendable, Hashable, CustomStringConvertible, CustomDebugStringConvertible {
    /// Line number (1-based).
    var line: Int
    /// Column number (1-based, counted in characters).
    var column: Int
    /// Byte range of the token the position refers to.
    var range: (Int, Int)
    /// Byte index into the input.
    var index: Int

    /// A position.
    init(line: Int = 1, column: Int = 1, range: (Int, Int) = (0, 0), index: Int = 0) {
        self.line = line
        self.column = column
        self.range = range
        self.index = index
    }

    static func == (lhs: Position, rhs: Position) -> Bool {
        lhs.line == rhs.line && lhs.column == rhs.column && lhs.range == rhs.range
            && lhs.index == rhs.index
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(line)
        hasher.combine(column)
        hasher.combine(range.0)
        hasher.combine(range.1)
        hasher.combine(index)
    }

    /// Structured rendering, which error messages embed.
    var debugDescription: String {
        "Position { line: \(line), column: \(column), range: (\(range.0), \(range.1)), index: \(index) }"
    }

    var description: String { debugDescription }
}

/// The rules of the CDDL grammar, in declaration order, with the implicit
/// end-of-input rule `EOI` first. Expected-rule lists in errors are sorted in
/// this order.
enum GrammarRule: Int, Comparable, Sendable, CaseIterable {
    case EOI
    case cddl
    case WHITESPACE
    case COMMENT
    case S
    case NEWLINE
    case rule
    case assign_t
    case assign_g
    case assign
    case assign_t_choice
    case assign_g_choice
    case generic_params
    case generic_param
    case generic_args
    case generic_arg
    case type_expr
    case type_choice
    case type_choice_op
    case type1
    case range_op
    case range_op_inclusive
    case range_op_exclusive
    case control_op
    case control_name
    case controller
    case type2
    case tag_expr
    case tag_value
    case group
    case group_choice
    case group_choice_op
    case optcom
    case group_entry
    case entry_delimiter
    case cut
    case arrowmap
    case colon
    case member_key
    case occur
    case occur_exact
    case occur_range
    case occur_zero_or_more
    case occur_one_or_more
    case occur_optional
    case id
    case typename
    case groupname
    case bareword
    case socket_type
    case socket_group
    case EALPHA
    case EALPHA_START
    case ALPHA
    case DIGIT
    case value
    case number
    case uint_value
    case int_value
    case float_value
    case hexfloat
    case text_value
    case text_inner
    case text_char
    case escape_sequence
    case bytes_value
    case bytes_b64
    case bytes_b16
    case bytes_h_quoted
    case bytes_utf8
    case BYTE_STRING_INNER
    case bytes_escape
    case BASE64_INNER
    case HEX_INNER
    case QUOTE
    case prelude_type

    static func < (lhs: GrammarRule, rhs: GrammarRule) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// One node of the parse tree: the rule that matched and the byte range it
/// covers, with the nodes of the rules it matched in turn.
struct Pair: Sendable {
    let rule: GrammarRule
    let start: Int
    let end: Int
    let children: [Pair]
}

/// The failure of a whole-input parse: the furthest position any rule was
/// attempted at, and the rules expected or rejected there.
struct GrammarFailure: Sendable {
    let position: Int
    let positives: [GrammarRule]
    let negatives: [GrammarRule]
}

/// The state of a PEG parse over UTF-8 bytes.
final class GrammarState {
    enum Lookahead {
        case none
        case positive
        case negative
    }

    enum Atomicity {
        case atomic
        case compoundAtomic
        case nonAtomic
    }

    enum QueueToken {
        case start(endTokenIndex: Int, inputPos: Int)
        case end(startTokenIndex: Int, rule: GrammarRule, inputPos: Int)
    }

    let input: [UInt8]
    var pos: Int = 0
    var queue: [QueueToken] = []
    var lookahead: Lookahead = .none
    var atomicity: Atomicity = .nonAtomic
    var posAttempts: [GrammarRule] = []
    var negAttempts: [GrammarRule] = []
    var attemptPos: Int = 0

    init(input: [UInt8]) {
        self.input = input
    }

    // MARK: - Combinators

    /// Runs `f` as the named rule `rule`: records a parse tree node for it
    /// when it matches outside a lookahead or atomic region, and tracks the
    /// attempt for error reporting when it fails.
    @inline(__always)
    func rule(_ rule: GrammarRule, _ f: () -> Bool) -> Bool {
        let actualPos = pos
        let index = queue.count

        let posAttemptsIndex: Int
        let negAttemptsIndex: Int
        if actualPos == attemptPos {
            posAttemptsIndex = posAttempts.count
            negAttemptsIndex = negAttempts.count
        } else {
            posAttemptsIndex = 0
            negAttemptsIndex = 0
        }

        if lookahead == .none && atomicity != .atomic {
            queue.append(.start(endTokenIndex: 0, inputPos: actualPos))
        }

        let attempts = attemptsAt(actualPos)

        if f() {
            if lookahead == .negative {
                track(rule, actualPos, posAttemptsIndex, negAttemptsIndex, attempts)
            }
            if lookahead == .none && atomicity != .atomic {
                let newIndex = queue.count
                queue[index] = .start(endTokenIndex: newIndex, inputPos: actualPos)
                queue.append(.end(startTokenIndex: index, rule: rule, inputPos: pos))
            }
            return true
        } else {
            if lookahead != .negative {
                track(rule, actualPos, posAttemptsIndex, negAttemptsIndex, attempts)
            }
            if lookahead == .none && atomicity != .atomic {
                queue.removeSubrange(index...)
            }
            return false
        }
    }

    private func attemptsAt(_ position: Int) -> Int {
        attemptPos == position ? posAttempts.count + negAttempts.count : 0
    }

    private func track(
        _ rule: GrammarRule,
        _ position: Int,
        _ posAttemptsIndex: Int,
        _ negAttemptsIndex: Int,
        _ prevAttempts: Int
    ) {
        if atomicity == .atomic {
            return
        }

        // If nested rules made no progress, there is no use to report them;
        // it's only useful to track the current rule, the exception being when
        // only one attempt has been made during the children rules.
        let currAttempts = attemptsAt(position)
        if currAttempts > prevAttempts && currAttempts - prevAttempts == 1 {
            return
        }

        if position == attemptPos {
            posAttempts.removeSubrange(min(posAttemptsIndex, posAttempts.count)...)
            negAttempts.removeSubrange(min(negAttemptsIndex, negAttempts.count)...)
        }

        if position > attemptPos {
            posAttempts.removeAll()
            negAttempts.removeAll()
            attemptPos = position
        }

        if position == attemptPos {
            if lookahead != .negative {
                posAttempts.append(rule)
            } else {
                negAttempts.append(rule)
            }
        }
    }

    /// A sequence: restores the position and the token queue when `f`
    /// fails.
    @inline(__always)
    func sequence(_ f: () -> Bool) -> Bool {
        let tokenIndex = queue.count
        let initialPos = pos
        if f() {
            return true
        }
        pos = initialPos
        if queue.count > tokenIndex {
            queue.removeSubrange(tokenIndex...)
        }
        return false
    }

    /// An optional expression: always succeeds.
    @inline(__always)
    func optional(_ f: () -> Bool) -> Bool {
        _ = f()
        return true
    }

    /// Zero or more repetitions of `f`.
    @inline(__always)
    func repeatLoop(_ f: () -> Bool) -> Bool {
        while f() {}
        return true
    }

    /// A positive or negative lookahead: runs `f` without consuming input
    /// or recording parse tree nodes.
    @inline(__always)
    func lookahead(_ isPositive: Bool, _ f: () -> Bool) -> Bool {
        let initialLookahead = lookahead
        if isPositive {
            lookahead = initialLookahead == .negative ? .negative : .positive
        } else {
            lookahead = initialLookahead == .negative ? .positive : .negative
        }
        let initialPos = pos
        let result = f()
        pos = initialPos
        lookahead = initialLookahead
        return isPositive ? result : !result
    }

    /// Runs `f` with the given atomicity: no implicit skipping inside atomic
    /// regions, and no parse tree nodes inside fully atomic ones.
    @inline(__always)
    func atomic(_ newAtomicity: Atomicity, _ f: () -> Bool) -> Bool {
        let initialAtomicity = atomicity
        let shouldToggle = atomicity != newAtomicity
        if shouldToggle {
            atomicity = newAtomicity
        }
        let result = f()
        if shouldToggle {
            atomicity = initialAtomicity
        }
        return result
    }

    // MARK: - Terminals

    /// Matches a literal string.
    @inline(__always)
    func matchString(_ string: StaticString) -> Bool {
        let count = string.utf8CodeUnitCount
        guard pos + count <= input.count else { return false }
        let base = string.utf8Start
        for offset in 0..<count where input[pos + offset] != base[offset] {
            return false
        }
        pos += count
        return true
    }

    /// Matches a literal string with ASCII case folding.
    func matchInsensitive(_ string: StaticString) -> Bool {
        let count = string.utf8CodeUnitCount
        guard pos + count <= input.count else { return false }
        let base = string.utf8Start
        for offset in 0..<count {
            if asciiLower(input[pos + offset]) != asciiLower(base[offset]) {
                return false
            }
        }
        pos += count
        return true
    }

    @inline(__always)
    private func asciiLower(_ c: UInt8) -> UInt8 {
        (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(c) ? c + 32 : c
    }

    /// Matches one byte of an ASCII range.
    @inline(__always)
    func matchRange(_ lower: UInt8, _ upper: UInt8) -> Bool {
        guard pos < input.count else { return false }
        let c = input[pos]
        guard c >= lower && c <= upper else { return false }
        pos += 1
        return true
    }

    /// Matches any one character.
    func skipAny() -> Bool {
        guard pos < input.count else { return false }
        let lead = input[pos]
        let width: Int
        if lead < 0x80 {
            width = 1
        } else if lead >> 5 == 0b110 {
            width = 2
        } else if lead >> 4 == 0b1110 {
            width = 3
        } else {
            width = 4
        }
        pos = min(pos + width, input.count)
        return true
    }

    /// Matches the start of the input.
    func startOfInput() -> Bool {
        pos == 0
    }

    /// Advances to the first occurrence of `byte`, or to the end of the
    /// input.
    func skipUntil(_ byte: UInt8) -> Bool {
        while pos < input.count && input[pos] != byte {
            pos += 1
        }
        return true
    }

    // MARK: - Results

    /// The parse tree of a successful parse, from the token queue.
    func pairs() -> [Pair] {
        var index = 0
        var result: [Pair] = []
        while index < queue.count {
            let (pair, next) = buildPair(at: index)
            result.append(pair)
            index = next
        }
        return result
    }

    private func buildPair(at index: Int) -> (Pair, Int) {
        guard case .start(let endIndex, let startPos) = queue[index],
            case .end(_, let rule, let endPos) = queue[endIndex]
        else {
            preconditionFailure("malformed token queue")
        }
        var children: [Pair] = []
        var cursor = index + 1
        while cursor < endIndex {
            let (child, next) = buildPair(at: cursor)
            children.append(child)
            cursor = next
        }
        return (Pair(rule: rule, start: startPos, end: endPos, children: children), endIndex + 1)
    }

    /// The failure of the parse: the furthest attempt and the rules expected there.
    func failure() -> GrammarFailure {
        GrammarFailure(
            position: attemptPos,
            positives: Array(Set(posAttempts)).sorted(),
            negatives: Array(Set(negAttempts)).sorted()
        )
    }
}
