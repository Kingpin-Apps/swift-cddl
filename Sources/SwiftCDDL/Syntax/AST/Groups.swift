// Group expressions: `Group`, `GroupChoice`, `GroupEntry`, `OptionalComma`,
// `Occurrence`, `Occur`, the entry payloads and member keys.

/// Group choices.
///
/// ```abnf
/// group = grpchoice * (S "//" S grpchoice)
/// ```
public struct Group: Hashable, Sendable {
    /// Group choices.
    public var groupChoices: [GroupChoice]
    /// Span.
    public var span: Span

    /// A group.
    public init(groupChoices: [GroupChoice] = [], span: Span = .zero) {
        self.groupChoices = groupChoices
        self.span = span
    }

    /// A group of one choice holding one entry.
    public init(entry: GroupEntry) {
        self.init(groupChoices: [GroupChoice(entries: [entry])], span: .zero)
    }
}

/// Group entries.
///
/// ```abnf
/// grpchoice = *(grpent optcom)
/// ```
///
/// Each entry is paired with whether a trailing comma follows it, as the
/// tuple `(GroupEntry, OptionalComma)`.
public struct GroupChoice: Hashable, Sendable {
    /// Group entries, each with its optional trailing comma.
    public var groupEntries: [(GroupEntry, OptionalComma)]
    /// Span.
    public var span: Span
    /// Comments before the choice.
    public var commentsBeforeGrpchoice: Comments?

    /// A group choice.
    public init(
        groupEntries: [(GroupEntry, OptionalComma)] = [],
        span: Span = .zero,
        commentsBeforeGrpchoice: Comments? = nil
    ) {
        self.groupEntries = groupEntries
        self.span = span
        self.commentsBeforeGrpchoice = commentsBeforeGrpchoice
    }

    /// A group choice from group entries, none followed by a comma.
    public init(entries: [GroupEntry]) {
        self.init(groupEntries: entries.map { ($0, OptionalComma()) }, span: .zero, commentsBeforeGrpchoice: nil)
    }

    public static func == (lhs: GroupChoice, rhs: GroupChoice) -> Bool {
        guard lhs.span == rhs.span, lhs.commentsBeforeGrpchoice == rhs.commentsBeforeGrpchoice,
            lhs.groupEntries.count == rhs.groupEntries.count
        else {
            return false
        }
        return zip(lhs.groupEntries, rhs.groupEntries).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(span)
        hasher.combine(commentsBeforeGrpchoice)
        hasher.combine(groupEntries.count)
        for (entry, comma) in groupEntries {
            hasher.combine(entry)
            hasher.combine(comma)
        }
    }
}

/// Group entry.
///
/// ```abnf
/// grpent = [occur S] [memberkey S] type
///       / [occur S] groupname [genericarg]  ; preempted by above
///       / [occur S] "(" S group S ")"
/// ```
public indirect enum GroupEntry: Hashable, Sendable {
    /// Value group entry type.
    case valueMemberKey(
        ge: ValueMemberKeyEntry,
        span: Span = .zero,
        leadingComments: Comments? = nil,
        trailingComments: Comments? = nil
    )
    /// Group entry from a named group or type.
    case typeGroupname(
        ge: TypeGroupnameEntry,
        span: Span = .zero,
        leadingComments: Comments? = nil,
        trailingComments: Comments? = nil
    )
    /// Parenthesized group with optional occurrence indicator.
    case inlineGroup(
        occur: Occurrence?,
        group: Group,
        span: Span = .zero,
        commentsBeforeGroup: Comments? = nil,
        commentsAfterGroup: Comments? = nil
    )

    /// The span of the entry, whichever form it takes.
    public var span: Span {
        switch self {
        case .valueMemberKey(_, let span, _, _), .typeGroupname(_, let span, _, _),
            .inlineGroup(_, _, let span, _, _):
            return span
        }
    }
}

/// Optional comma.
public struct OptionalComma: Hashable, Sendable {
    /// Whether a comma follows the entry.
    public var optionalComma: Bool
    /// Comments after the comma.
    public var trailingComments: Comments?

    /// An optional comma.
    public init(optionalComma: Bool = false, trailingComments: Comments? = nil) {
        self.optionalComma = optionalComma
        self.trailingComments = trailingComments
    }
}

/// Occurrence indicator.
public struct Occurrence: Hashable, Sendable {
    /// Occurrence indicator.
    public var occur: Occur
    /// Comments after the indicator.
    public var comments: Comments?

    /// An occurrence indicator.
    public init(occur: Occur, comments: Comments? = nil) {
        self.occur = occur
        self.comments = comments
    }
}

/// Value group entry type with optional occurrence indicator and optional
/// member key.
///
/// ```abnf
/// [occur S] [memberkey S] type
/// ```
public struct ValueMemberKeyEntry: Hashable, Sendable {
    /// Optional occurrence indicator.
    public var occur: Occurrence?
    /// Optional member key.
    public var memberKey: MemberKey?
    /// Entry type.
    public var entryType: Type

    /// A value member key entry.
    public init(occur: Occurrence? = nil, memberKey: MemberKey? = nil, entryType: Type) {
        self.occur = occur
        self.memberKey = memberKey
        self.entryType = entryType
    }
}

/// Group entry from a named type or group.
public struct TypeGroupnameEntry: Hashable, Sendable {
    /// Optional occurrence indicator.
    public var occur: Occurrence?
    /// Type or group name identifier.
    public var name: Identifier
    /// Optional generic arguments.
    public var genericArgs: GenericArgs?

    /// A type/group name entry.
    public init(occur: Occurrence? = nil, name: Identifier, genericArgs: GenericArgs? = nil) {
        self.occur = occur
        self.name = name
        self.genericArgs = genericArgs
    }
}

/// Member key.
///
/// ```abnf
/// memberkey = type1 S ["^" S] "=>"
///           / bareword S ":"
///           / value S ":"
/// ```
///
/// A literal key written in the arrow form (`0 => uint`) produces
/// ``MemberKey/type1(t1:isCut:span:commentsBeforeCut:commentsAfterCut:commentsAfterArrowmap:)``;
/// only the colon form (`0: uint`) produces
/// ``MemberKey/value(value:span:comments:commentsAfterColon:)``.
public indirect enum MemberKey: Hashable, Sendable {
    /// Type expression (the arrow form).
    case type1(
        t1: Type1,
        isCut: Bool,
        span: Span = .zero,
        commentsBeforeCut: Comments? = nil,
        commentsAfterCut: Comments? = nil,
        commentsAfterArrowmap: Comments? = nil
    )
    /// Bareword string type (the colon form).
    case bareword(
        ident: Identifier,
        span: Span = .zero,
        comments: Comments? = nil,
        commentsAfterColon: Comments? = nil
    )
    /// Value type (the colon form).
    case value(
        value: Value,
        span: Span = .zero,
        comments: Comments? = nil,
        commentsAfterColon: Comments? = nil
    )
    /// Not a member key: a type or group standing where one could be.
    case nonMemberKey(
        nonMemberKey: NonMemberKey,
        commentsBeforeTypeOrGroup: Comments? = nil,
        commentsAfterTypeOrGroup: Comments? = nil
    )
}

/// A type or group standing where a member key could be.
public indirect enum NonMemberKey: Hashable, Sendable {
    /// A group.
    case group(Group)
    /// A type.
    case type(Type)
}

/// Occurrence indicator.
///
/// ```abnf
/// occur = [uint] "*" [uint]
///       / "+"
///       / "?"
/// ```
///
/// Bounds are 64-bit on every platform.
public enum Occur: Hashable, Sendable {
    /// Occurrence indicator in the form n*m, where n is an optional lower
    /// limit and m is an optional upper limit.
    case exact(lower: UInt64?, upper: UInt64?, span: Span = .zero)
    /// Occurrence indicator in the form `*`, allowing zero or more
    /// occurrences.
    case zeroOrMore(span: Span = .zero)
    /// Occurrence indicator in the form `+`, allowing one or more
    /// occurrences.
    case oneOrMore(span: Span = .zero)
    /// Occurrence indicator in the form `?`, allowing an optional occurrence.
    case optional(span: Span = .zero)
}
