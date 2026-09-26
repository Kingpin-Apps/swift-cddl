// The top-level AST types: the document, its rules,
// identifiers, generic parameters and arguments, spans and comments.

/// Starting byte index, ending byte index and line number of a node.
///
public struct Span: Hashable, Sendable, CustomDebugStringConvertible {
    /// Byte offset of the first byte of the node.
    public var start: Int
    /// Byte offset one past the last byte of the node.
    public var end: Int
    /// 1-based line the node starts on.
    public var line: Int

    /// A span.
    public init(_ start: Int, _ end: Int, _ line: Int) {
        self.start = start
        self.end = end
        self.line = line
    }

    /// The default span `(0, 0, 0)` of a node no document spelled.
    public static let zero = Span(0, 0, 0)

    public var debugDescription: String { "(\(start), \(end), \(line))" }
}

/// The comments attached to one position of the AST, each without its
/// leading `;`. An entry that is exactly `"\n"` stands for a blank line.
///
public struct Comments: Hashable, Sendable {
    /// The comment texts.
    public var comments: [String]

    /// Comments with the given texts.
    public init(_ comments: [String] = []) {
        self.comments = comments
    }

    func anyNonNewline() -> Bool {
        comments.contains { $0 != "\n" }
    }

    func allNewline() -> Bool {
        comments.allSatisfy { $0 == "\n" }
    }
}

/// CDDL AST.
///
/// ```abnf
/// cddl = S 1*(rule S)
/// ```
///
/// The rules of a document nest as deeply as its source does, and releasing
/// a nested value takes a stack frame per level. The document therefore keeps
/// its rules in storage that, when the last copy of the document goes away,
/// releases a deeply nested AST on a thread with a large stack rather than on
/// whichever thread dropped the document. A rule or type copied out of the
/// document and outliving it is released where its last copy goes away.
public struct CDDL: Hashable, Sendable {
    private var storage: Storage

    /// Zero or more production rules.
    public var rules: [Rule] {
        get { storage.rules }
        _modify {
            makeStorageUnique()
            yield &storage.rules
        }
    }

    /// Comments before the first rule.
    public var comments: Comments? {
        get { storage.comments }
        set {
            makeStorageUnique()
            storage.comments = newValue
        }
    }

    /// A document.
    public init(rules: [Rule] = [], comments: Comments? = nil) {
        self.storage = Storage(rules: rules, comments: comments, nesting: nil)
    }

    /// A document parsed from a source whose brackets nest `nesting` levels
    /// deep at most.
    init(rules: [Rule], comments: Comments?, nesting: Int) {
        self.storage = Storage(rules: rules, comments: comments, nesting: nesting)
    }

    private mutating func makeStorageUnique() {
        if !isKnownUniquelyReferenced(&storage) {
            storage = Storage(rules: storage.rules, comments: storage.comments, nesting: storage.nesting)
        }
    }

    public static func == (lhs: CDDL, rhs: CDDL) -> Bool {
        lhs.storage === rhs.storage || (lhs.rules == rhs.rules && lhs.comments == rhs.comments)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(rules)
        hasher.combine(comments)
    }

    /// The rules and comments of a document. Mutated only through a
    /// uniquely referenced ``CDDL``.
    private final class Storage: @unchecked Sendable {
        var rules: [Rule]
        var comments: Comments?
        /// How deeply the source of the rules nests, when known.
        let nesting: Int?

        init(rules: [Rule], comments: Comments?, nesting: Int?) {
            self.rules = rules
            self.comments = comments
            self.nesting = nesting
        }

        deinit {
            if let nesting, nesting <= shallowNestingBound {
                return
            }
            if rules.isEmpty {
                return
            }
            let doomed = UncheckedBox(rules)
            rules = []
            withLargeStack {
                doomed.value = []
            }
        }
    }
}

/// The deepest bracket nesting of a source whose AST is released on the
/// thread that drops it.
let shallowNestingBound = 64

/// The deepest nesting of brackets -- `(`, `[`, `{` and `<` -- in `bytes`, not
/// counting brackets inside text strings, byte strings or comments. Only an
/// estimate of how deeply the AST nests is needed, so an unbalanced source
/// reads as whatever depth it reaches.
func bracketNesting(_ bytes: [UInt8]) -> Int {
    var depth = 0
    var deepest = 0
    var index = 0
    while index < bytes.count {
        let byte = bytes[index]
        switch byte {
        case UInt8(ascii: "("), UInt8(ascii: "["), UInt8(ascii: "{"), UInt8(ascii: "<"):
            depth += 1
            deepest = max(deepest, depth)
        case UInt8(ascii: ")"), UInt8(ascii: "]"), UInt8(ascii: "}"):
            depth = max(0, depth - 1)
        case UInt8(ascii: ">"):
            // The `>` of an arrow `=>` closes nothing.
            if index == 0 || bytes[index - 1] != UInt8(ascii: "=") {
                depth = max(0, depth - 1)
            }
        case UInt8(ascii: ";"):
            while index < bytes.count && bytes[index] != UInt8(ascii: "\n") {
                index += 1
            }
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            index += 1
            while index < bytes.count && bytes[index] != byte {
                if bytes[index] == UInt8(ascii: "\\") {
                    index += 1
                }
                index += 1
            }
        default:
            break
        }
        index += 1
    }
    return deepest
}

/// Identifier for a type name, group name or bareword, with an optional
/// socket.
///
/// ```abnf
/// id = EALPHA *(*("-" / ".") (EALPHA / DIGIT))
/// ```
///
/// Two identifiers are equal when their socket prefix and name read as the
/// same string; the span takes no part in equality.
public struct Identifier: Hashable, Sendable {
    /// Identifier.
    public var ident: String
    /// Optional socket.
    public var socket: SocketPlug?
    /// Span.
    public var span: Span

    /// An identifier.
    public init(ident: String, socket: SocketPlug? = nil, span: Span = .zero) {
        self.ident = ident
        self.socket = socket
        self.span = span
    }

    /// An identifier from a literal name, reading a `$` or `$$` prefix as a
    /// socket. The prefix is kept in `ident` as well.
    public init(_ ident: String) {
        var socket: SocketPlug?
        if ident.hasPrefix("$$") {
            socket = .group
        } else if ident.hasPrefix("$") {
            socket = .type
        }
        self.init(ident: ident, socket: socket, span: Span(0, 0, 0))
    }

    /// The identifier of a standard prelude token, or the empty identifier.
    init(token: Token) {
        self.init(token.inStandardPrelude() ?? "")
    }

    private var namePrefix: String {
        switch socket {
        case .type: return "$"
        case .group: return "$$"
        case nil: return ""
        }
    }

    public static func == (lhs: Identifier, rhs: Identifier) -> Bool {
        let lhsPrefix = lhs.namePrefix.utf8
        let rhsPrefix = rhs.namePrefix.utf8
        let lhsIdent = lhs.ident.utf8
        let rhsIdent = rhs.ident.utf8
        guard lhsPrefix.count + lhsIdent.count == rhsPrefix.count + rhsIdent.count else {
            return false
        }
        return Array(lhsPrefix).appending(contentsOf: lhsIdent) == Array(rhsPrefix).appending(contentsOf: rhsIdent)
    }

    public func hash(into hasher: inout Hasher) {
        for byte in namePrefix.utf8 {
            hasher.combine(byte)
        }
        for byte in ident.utf8 {
            hasher.combine(byte)
        }
    }
}

extension Identifier: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self.init(value)
    }
}

/// Type or group expression.
///
/// ```abnf
/// rule = typename [genericparm] S assignt S type
///     / groupname [genericparm] S assigng S grpent
/// ```
public enum Rule: Hashable, Sendable {
    /// Type expression.
    case type(
        rule: TypeRule,
        span: Span = .zero,
        commentsBeforeRule: Comments? = nil,
        commentsAfterRule: Comments? = nil
    )
    /// Group expression.
    case group(
        rule: GroupRule,
        span: Span = .zero,
        commentsBeforeRule: Comments? = nil,
        commentsAfterRule: Comments? = nil
    )

    /// The span of the rule.
    public var span: Span {
        switch self {
        case .type(_, let span, _, _), .group(_, let span, _, _):
            return span
        }
    }

    /// Returns the name of the rule, with its socket prefix.
    func name() -> String {
        switch self {
        case .type(let rule, _, _, _): return rule.name.description
        case .group(let rule, _, _, _): return rule.name.description
        }
    }

    /// Returns the comments appearing on their own line(s) immediately before
    /// the rule, if any.
    func commentsBeforeRule() -> Comments? {
        switch self {
        case .type(_, _, let comments, _), .group(_, _, let comments, _):
            return comments
        }
    }

    /// Returns the comments following the rule, if any.
    func commentsAfterRule() -> Comments? {
        switch self {
        case .type(_, _, _, let comments), .group(_, _, _, let comments):
            return comments
        }
    }

    /// Returns whether the rule extends an existing type or group rule with
    /// additional choices.
    func isChoiceAlternate() -> Bool {
        switch self {
        case .type(let rule, _, _, _): return rule.isTypeChoiceAlternate
        case .group(let rule, _, _, _): return rule.isGroupChoiceAlternate
        }
    }
}

extension Rule {
    /// The name the rule defines, with its socket prefix if it has one.
    public var ruleName: Identifier {
        switch self {
        case .type(let rule, _, _, _): return rule.name
        case .group(let rule, _, _, _): return rule.name
        }
    }

    /// The type rule, if this is one.
    public var typeRule: TypeRule? {
        if case .type(let rule, _, _, _) = self { return rule }
        return nil
    }

    /// The group rule, if this is one.
    public var groupRule: GroupRule? {
        if case .group(let rule, _, _, _) = self { return rule }
        return nil
    }
}

/// Type rule.
///
/// ```abnf
/// typename [genericparm] S assignt S type
/// ```
public struct TypeRule: Hashable, Sendable {
    /// Type name identifier.
    public var name: Identifier
    /// Optional generic parameters.
    public var genericParams: GenericParams?
    /// Extends an existing type choice (`/=`).
    public var isTypeChoiceAlternate: Bool
    /// Type value.
    public var value: Type
    /// Comments before the assignment token.
    public var commentsBeforeAssignt: Comments?
    /// Comments after the assignment token.
    public var commentsAfterAssignt: Comments?

    /// A type rule.
    public init(
        name: Identifier,
        genericParams: GenericParams? = nil,
        isTypeChoiceAlternate: Bool = false,
        value: Type,
        commentsBeforeAssignt: Comments? = nil,
        commentsAfterAssignt: Comments? = nil
    ) {
        self.name = name
        self.genericParams = genericParams
        self.isTypeChoiceAlternate = isTypeChoiceAlternate
        self.value = value
        self.commentsBeforeAssignt = commentsBeforeAssignt
        self.commentsAfterAssignt = commentsAfterAssignt
    }
}

/// Group rule.
///
/// ```abnf
/// groupname [genericparm] S assigng S grpent
/// ```
public struct GroupRule: Hashable, Sendable {
    /// Group name identifier.
    public var name: Identifier
    /// Optional generic parameters.
    public var genericParams: GenericParams?
    /// Extends an existing group choice (`//=`).
    public var isGroupChoiceAlternate: Bool
    /// Group entry.
    public var entry: GroupEntry
    /// Comments before the assignment token.
    public var commentsBeforeAssigng: Comments?
    /// Comments after the assignment token.
    public var commentsAfterAssigng: Comments?

    /// A group rule.
    public init(
        name: Identifier,
        genericParams: GenericParams? = nil,
        isGroupChoiceAlternate: Bool = false,
        entry: GroupEntry,
        commentsBeforeAssigng: Comments? = nil,
        commentsAfterAssigng: Comments? = nil
    ) {
        self.name = name
        self.genericParams = genericParams
        self.isGroupChoiceAlternate = isGroupChoiceAlternate
        self.entry = entry
        self.commentsBeforeAssigng = commentsBeforeAssigng
        self.commentsAfterAssigng = commentsAfterAssigng
    }
}

/// Generic parameters.
///
/// ```abnf
/// genericparm = "<" S id S *("," S id S ) ">"
/// ```
public struct GenericParams: Hashable, Sendable {
    /// List of generic parameters.
    public var params: [GenericParam]
    /// Span.
    public var span: Span

    /// Generic parameters.
    public init(params: [GenericParam] = [], span: Span = .zero) {
        self.params = params
        self.span = span
    }
}

/// Generic parameter.
public struct GenericParam: Hashable, Sendable {
    /// Generic parameter.
    public var param: Identifier
    /// Comments before the identifier.
    public var commentsBeforeIdent: Comments?
    /// Comments after the identifier.
    public var commentsAfterIdent: Comments?

    /// A generic parameter.
    public init(param: Identifier, commentsBeforeIdent: Comments? = nil, commentsAfterIdent: Comments? = nil) {
        self.param = param
        self.commentsBeforeIdent = commentsBeforeIdent
        self.commentsAfterIdent = commentsAfterIdent
    }
}

/// Generic arguments.
///
/// ```abnf
/// genericarg = "<" S type1 S *("," S type1 S ) ">"
/// ```
public struct GenericArgs: Hashable, Sendable {
    /// Generic arguments.
    public var args: [GenericArg]
    /// Span.
    public var span: Span

    /// Generic arguments.
    public init(args: [GenericArg] = [], span: Span = .zero) {
        self.args = args
        self.span = span
    }
}

/// Generic argument.
public struct GenericArg: Hashable, Sendable {
    /// Generic argument.
    public var arg: Type1
    /// Comments before the argument.
    public var commentsBeforeType: Comments?
    /// Comments after the argument.
    public var commentsAfterType: Comments?

    /// A generic argument.
    public init(arg: Type1, commentsBeforeType: Comments? = nil, commentsAfterType: Comments? = nil) {
        self.arg = arg
        self.commentsBeforeType = commentsBeforeType
        self.commentsAfterType = commentsAfterType
    }
}

extension Array {
    fileprivate func appending<S: Sequence>(contentsOf other: S) -> [Element] where S.Element == Element {
        var copy = self
        copy.append(contentsOf: other)
        return copy
    }
}
