// Attachment of `;` comments to the AST.
//
// Comments are bound to the AST in two passes:
//
// 1. An anchor merge (`merge`): every comment token of the parse tree is
//    bound to exactly one leading or trailing slot of the AST by source
//    position.
// 2. A leftover pass (`attach_comments`): the comments the merge could not
//    bind are placed by a cursor that walks each rule's AST in source order,
//    or kept before the first rule or after the rule they follow, so that no
//    comment is ever dropped.

// MARK: - Comment tokens and anchors

/// A source-ordered comment token. `lo` is the `;`; `hi` is the end of the
/// comment text; `pure` means the comment stands alone on its line.
struct CommentTok: Sendable {
    let lo: Int
    let hi: Int
    let line: Int
    let pure: Bool
    let text: String
}

/// Tight source position of an anchor slot.
struct AnchorPos: Sendable {
    let lo: Int
    let hi: Int
    let lineHi: Int
}

/// Which AST comment field an anchor writes.
enum SlotKind: Sendable, Equatable {
    /// `Rule.commentsBeforeRule`
    case ruleLeading
    /// `TypeChoice.commentsBeforeType` (choices after the first only)
    case choiceLeading
    /// `TypeChoice.commentsAfterType`
    case choiceTrailing
    /// `GroupChoice.commentsBeforeGrpchoice` (multi-choice groups only)
    case grpChoiceLeading
    /// `GroupEntry` leading comments
    case entryLeading
    /// `GroupEntry` trailing comments
    case entryTrailing

    var isLeading: Bool {
        switch self {
        case .ruleLeading, .choiceLeading, .grpChoiceLeading, .entryLeading: return true
        default: return false
        }
    }

    var isTrailing: Bool {
        self == .choiceTrailing || self == .entryTrailing
    }
}

/// One comment-anchor slot.
struct Anchor: Sendable {
    let pos: AnchorPos
    let kind: SlotKind
}

/// The comment tokens of the parse tree, in source order.
func collectCommentToks(_ pair: Pair, _ source: SourceText) -> [CommentTok] {
    var spans: [(Int, Int)] = []
    func collect(_ pair: Pair) {
        for inner in pair.children {
            if inner.rule == .COMMENT {
                spans.append((inner.start, inner.end))
            } else {
                collect(inner)
            }
        }
    }
    collect(pair)

    return spans.map { lo, hi in
        let lineStart = source.lineStart(of: lo)
        let pure = source.text(lineStart, lo).trimmingWhitespace().isEmpty
        return CommentTok(lo: lo, hi: hi, line: source.line(of: lo), pure: pure, text: source.text(lo + 1, hi))
    }
}

private func leadingPos(_ source: SourceText, _ lo: Int) -> AnchorPos {
    AnchorPos(lo: lo, hi: lo, lineHi: source.line(of: lo))
}

private func trailingPos(_ source: SourceText, _ lo: Int, _ hi: Int) -> AnchorPos {
    AnchorPos(lo: lo, hi: hi, lineHi: source.line(of: hi))
}

/// Tight span of a `Type2`: its own span, with the greedy end of a name-led
/// form replaced by the end of the name or of its generic arguments.
func type2TightSpan(_ t2: Type2) -> Span {
    switch t2 {
    case .typename(let ident, let genericArgs, let span),
        .unwrap(let ident, let genericArgs, let span, _),
        .choiceFromGroup(let ident, let genericArgs, let span, _):
        let end = genericArgs?.span.end ?? ident.span.end
        return Span(span.start, end, span.line)
    default:
        return t2.span
    }
}

/// Byte offset just past a `Type1`'s rightmost real token.
func type1TightEnd(_ t1: Type1) -> Int {
    if let op = t1.operator {
        return type2TightSpan(op.type2).end
    }
    return type2TightSpan(t1.type2).end
}

/// Byte offset just past a `GroupEntry`'s rightmost real token.
func entryTightEnd(_ entry: GroupEntry) -> Int {
    switch entry {
    case .valueMemberKey(let ge, let span, _, _):
        if let last = ge.entryType.typeChoices.last {
            return type1TightEnd(last.type1)
        }
        return span.end
    case .typeGroupname(let ge, _, _, _):
        return ge.genericArgs?.span.end ?? ge.name.span.end
    case .inlineGroup(_, _, let span, _, _):
        return span.end
    }
}

typealias AnchorCallback = (AnchorPos, SlotKind, inout Comments?) -> Void

/// Walks the AST once, invoking `callback` for every comment-anchor slot in
/// source order with the slot's tight position, its kind and the slot itself.
func visitAnchorSlots(_ rules: inout [Rule], _ source: SourceText, _ callback: AnchorCallback) {
    for index in rules.indices {
        visitRule(&rules[index], source, callback)
    }
}

private func visitRule(_ rule: inout Rule, _ source: SourceText, _ callback: AnchorCallback) {
    switch rule {
    case .type(var typeRule, let span, var before, let after):
        rule = .type(rule: typeRule, span: span)
        callback(leadingPos(source, span.start), .ruleLeading, &before)
        visitType(&typeRule.value, source, callback)
        rule = .type(rule: typeRule, span: span, commentsBeforeRule: before, commentsAfterRule: after)
    case .group(var groupRule, let span, var before, let after):
        rule = .type(rule: TypeRule(name: groupRule.name, value: Type()), span: span)
        callback(leadingPos(source, span.start), .ruleLeading, &before)
        visitGroupEntry(&groupRule.entry, source, callback)
        rule = .group(rule: groupRule, span: span, commentsBeforeRule: before, commentsAfterRule: after)
    }
}

private func visitType(_ ty: inout Type, _ source: SourceText, _ callback: AnchorCallback) {
    for index in ty.typeChoices.indices {
        let lo = ty.typeChoices[index].type1.span.start
        let tight = type1TightEnd(ty.typeChoices[index].type1)
        if index > 0 {
            callback(leadingPos(source, lo), .choiceLeading, &ty.typeChoices[index].commentsBeforeType)
        }
        callback(trailingPos(source, lo, tight), .choiceTrailing, &ty.typeChoices[index].commentsAfterType)
        visitType2(&ty.typeChoices[index].type1.type2, source, callback)
        if ty.typeChoices[index].type1.operator != nil {
            visitType2(&ty.typeChoices[index].type1.operator!.type2, source, callback)
        }
    }
}

private func visitType2(_ t2: inout Type2, _ source: SourceText, _ callback: AnchorCallback) {
    switch t2 {
    case .map(var group, let span, let before, let after):
        t2 = .any(span: span)
        visitGroup(&group, source, callback)
        t2 = .map(group: group, span: span, commentsBeforeGroup: before, commentsAfterGroup: after)
    case .array(var group, let span, let before, let after):
        t2 = .any(span: span)
        visitGroup(&group, source, callback)
        t2 = .array(group: group, span: span, commentsBeforeGroup: before, commentsAfterGroup: after)
    case .choiceFromInlineGroup(var group, let span, let comments, let before, let after):
        t2 = .any(span: span)
        visitGroup(&group, source, callback)
        t2 = .choiceFromInlineGroup(
            group: group,
            span: span,
            comments: comments,
            commentsBeforeGroup: before,
            commentsAfterGroup: after
        )
    case .parenthesizedType(var pt, let span, let before, let after):
        t2 = .any(span: span)
        visitType(&pt, source, callback)
        t2 = .parenthesizedType(pt: pt, span: span, commentsBeforeType: before, commentsAfterType: after)
    case .taggedData(let tag, var t, let span, let before, let after):
        t2 = .any(span: span)
        visitType(&t, source, callback)
        t2 = .taggedData(tag: tag, t: t, span: span, commentsBeforeType: before, commentsAfterType: after)
    default:
        break
    }
}

private func visitGroup(_ group: inout Group, _ source: SourceText, _ callback: AnchorCallback) {
    // Group-choice leading slots exist only for true `//` alternatives; in a
    // single-choice group a comment before the first entry belongs to the
    // entry.
    let multi = group.groupChoices.count > 1
    for gcIndex in group.groupChoices.indices {
        if multi {
            callback(
                leadingPos(source, group.groupChoices[gcIndex].span.start),
                .grpChoiceLeading,
                &group.groupChoices[gcIndex].commentsBeforeGrpchoice
            )
        }
        for entryIndex in group.groupChoices[gcIndex].groupEntries.indices {
            visitGroupEntry(&group.groupChoices[gcIndex].groupEntries[entryIndex].0, source, callback)
        }
    }
}

private func visitGroupEntry(_ entry: inout GroupEntry, _ source: SourceText, _ callback: AnchorCallback) {
    let tight = entryTightEnd(entry)
    switch entry {
    case .valueMemberKey(var ge, let span, var leading, var trailing):
        entry = .inlineGroup(occur: nil, group: Group(), span: span)
        let lo = span.start
        callback(leadingPos(source, lo), .entryLeading, &leading)
        callback(trailingPos(source, lo, tight), .entryTrailing, &trailing)
        visitType(&ge.entryType, source, callback)
        entry = .valueMemberKey(ge: ge, span: span, leadingComments: leading, trailingComments: trailing)
    case .typeGroupname(let ge, let span, var leading, var trailing):
        let lo = span.start
        callback(leadingPos(source, lo), .entryLeading, &leading)
        callback(trailingPos(source, lo, tight), .entryTrailing, &trailing)
        entry = .typeGroupname(ge: ge, span: span, leadingComments: leading, trailingComments: trailing)
    case .inlineGroup(let occur, var group, let span, let before, let after):
        entry = .inlineGroup(occur: nil, group: Group(), span: span)
        visitGroup(&group, source, callback)
        entry = .inlineGroup(occur: occur, group: group, span: span, commentsBeforeGroup: before, commentsAfterGroup: after)
    }
}

/// Tight `(lo, close_hi)` extents of every bracketed container (array, map,
/// inline group), used by the enclosing-container guard of the merge.
func collectContainerExtents(_ rules: [Rule]) -> [(Int, Int)] {
    var out: [(Int, Int)] = []

    func inType(_ ty: Type) {
        for tc in ty.typeChoices {
            inType2(tc.type1.type2)
            if let op = tc.type1.operator {
                inType2(op.type2)
            }
        }
    }

    func inType2(_ t2: Type2) {
        switch t2 {
        case .map(let group, let span, _, _), .array(let group, let span, _, _),
            .choiceFromInlineGroup(let group, let span, _, _, _):
            out.append((span.start, span.end))
            inGroup(group)
        case .parenthesizedType(let pt, _, _, _):
            inType(pt)
        case .taggedData(_, let t, _, _, _):
            inType(t)
        default:
            break
        }
    }

    func inGroup(_ group: Group) {
        for gc in group.groupChoices {
            for (entry, _) in gc.groupEntries {
                inEntry(entry)
            }
        }
    }

    func inEntry(_ entry: GroupEntry) {
        switch entry {
        case .valueMemberKey(let ge, _, _, _):
            inType(ge.entryType)
        case .inlineGroup(_, let group, let span, _, _):
            out.append((span.start, span.end))
            inGroup(group)
        case .typeGroupname:
            break
        }
    }

    for rule in rules {
        switch rule {
        case .type(let rule, _, _, _): inType(rule.value)
        case .group(let rule, _, _, _): inEntry(rule.entry)
        }
    }
    return out
}

/// Binds each comment to exactly one anchor by source position. Returns the
/// comment texts per anchor, and the comments that bind nowhere.
func mergeComments(
    _ comments: [CommentTok],
    _ anchors: [Anchor],
    _ containers: [(Int, Int)]
) -> ([[String]], [CommentTok]) {
    var assigned: [[String]] = Array(repeating: [], count: anchors.count)
    var orphans: [CommentTok] = []

    // Lines carrying a stand-alone comment, for the leading-contiguity test.
    let pureLines = Set(comments.filter(\.pure).map(\.line))

    for c in comments {
        // Step 1, trailing: the nearest same-line preceding tight token; on an
        // equal `hi` the outermost (smallest `lo`) wins; on a full tie the
        // entry wins.
        if !c.pure {
            var best: Int?
            for (i, a) in anchors.enumerated()
            where a.kind.isTrailing && a.pos.hi <= c.lo && a.pos.lineHi == c.line {
                guard let b = best else {
                    best = i
                    continue
                }
                let current = anchors[b]
                // `max_by` keeps the last maximum.
                if compareTrailing(a, current) >= 0 {
                    best = i
                }
            }
            if let i = best {
                assigned[i].append(c.text)
                continue
            }
        }

        // Step 2, leading: the first following leading anchor, subject to the
        // enclosing-container guard and the upward-contiguity rule.
        guard let i = anchors.firstIndex(where: { $0.kind.isLeading && $0.pos.lo > c.hi }) else {
            orphans.append(c)
            continue
        }
        let a = anchors[i]

        // The innermost enclosing container is the one with the greatest `lo`
        // (`max_by_key` keeps the last maximum).
        var enclosingClose: Int?
        var enclosingLo = Int.min
        for (lo, hi) in containers where lo < c.lo && c.lo < hi {
            if lo >= enclosingLo {
                enclosingLo = lo
                enclosingClose = hi
            }
        }
        let escapesContainer = enclosingClose.map { $0 < a.pos.lo } ?? false

        var contiguous = true
        if c.line + 1 < a.pos.lineHi {
            for l in (c.line + 1)..<a.pos.lineHi where !pureLines.contains(l) {
                contiguous = false
                break
            }
        }

        if contiguous && !escapesContainer {
            assigned[i].append(c.text)
        } else {
            orphans.append(c)
        }
    }

    return (assigned, orphans)
}

/// Ordering of two trailing anchors for the merge's `max_by`: by `hi`, then
/// by smaller `lo`, then entry slots over choice slots.
private func compareTrailing(_ a: Anchor, _ b: Anchor) -> Int {
    if a.pos.hi != b.pos.hi {
        return a.pos.hi < b.pos.hi ? -1 : 1
    }
    if a.pos.lo != b.pos.lo {
        // Smaller `lo` is greater.
        return a.pos.lo > b.pos.lo ? -1 : 1
    }
    let aEntry = a.kind == .entryTrailing
    let bEntry = b.kind == .entryTrailing
    if aEntry == bEntry {
        return 0
    }
    return aEntry ? 1 : -1
}

// MARK: - Leftover pass

/// A `;`-comment found in the source, with whether only whitespace precedes
/// it on its line.
struct SourceComment: Sendable {
    let start: Int
    let text: String
    let ownLine: Bool
}

/// Scans the source for `;` comments, skipping over text and byte-string
/// literals.
func harvestComments(_ source: SourceText) -> [SourceComment] {
    let bytes = source.bytes
    var comments: [SourceComment] = []
    var i = 0
    while i < bytes.count {
        switch bytes[i] {
        case UInt8(ascii: ";"):
            let start = i
            var ownLine = true
            var back = start
            while back > 0 {
                back -= 1
                let b = bytes[back]
                if b == UInt8(ascii: "\n") { break }
                if !(b == UInt8(ascii: " ") || b == UInt8(ascii: "\t") || b == UInt8(ascii: "\r")) {
                    ownLine = false
                    break
                }
            }
            i += 1
            while i < bytes.count && bytes[i] != UInt8(ascii: "\n") {
                i += 1
            }
            comments.append(SourceComment(start: start, text: source.text(start + 1, i), ownLine: ownLine))
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            let quote = bytes[i]
            i += 1
            while i < bytes.count && bytes[i] != quote {
                if bytes[i] == UInt8(ascii: "\\") && i + 1 < bytes.count {
                    i += 1
                }
                i += 1
            }
            if i < bytes.count {
                i += 1
            }
        default:
            i += 1
        }
    }
    return comments
}

/// The offset just past the last byte in `spanStart..<spanEnd` that is
/// neither whitespace nor part of a `;` comment.
func semanticEnd(_ source: SourceText, _ spanStart: Int, _ spanEnd: Int) -> Int {
    let bytes = source.bytes
    var i = spanStart
    var lastReal = spanStart
    var inString: UInt8?
    while i < spanEnd {
        let c = bytes[i]
        if let quote = inString {
            if c == UInt8(ascii: "\\") && i + 1 < spanEnd {
                i += 2
                lastReal = i
                continue
            }
            if c == quote {
                inString = nil
            }
            i += 1
            lastReal = i
        } else if c == UInt8(ascii: ";") {
            while i < spanEnd && bytes[i] != UInt8(ascii: "\n") {
                i += 1
            }
        } else if c == UInt8(ascii: " ") || c == UInt8(ascii: "\t") || c == UInt8(ascii: "\n")
            || c == UInt8(ascii: "\r")
        {
            i += 1
        } else if c == UInt8(ascii: "\"") || c == UInt8(ascii: "'") {
            inString = c
            i += 1
            lastReal = i
        } else {
            i += 1
            lastReal = i
        }
    }
    return lastReal
}

/// Appends `new` to a comment slot, creating it when it is still empty.
func pushComments(_ slot: inout Comments?, _ new: [String]) {
    guard !new.isEmpty else { return }
    if slot == nil {
        slot = Comments(new)
    } else {
        slot!.comments.append(contentsOf: new)
    }
}

/// An ordered cursor over the comments that fall inside one rule body,
/// consumed as the AST for that rule is walked in source order.
struct CommentCursor {
    let source: SourceText
    var items: [SourceComment]
    var next: Int = 0

    var isEmpty: Bool { next >= items.count }

    /// The run of pending comments before `limit` that share a line with the
    /// text preceding them.
    mutating func takeTrailingBefore(_ limit: Int) -> [String] {
        var taken: [String] = []
        while next < items.count {
            let comment = items[next]
            if comment.start >= limit || comment.ownLine {
                break
            }
            taken.append(comment.text)
            next += 1
        }
        return taken
    }

    /// Every remaining pending comment before `limit`.
    mutating func takeBefore(_ limit: Int) -> [String] {
        var taken: [String] = []
        while next < items.count {
            let comment = items[next]
            if comment.start >= limit {
                break
            }
            taken.append(comment.text)
            next += 1
        }
        return taken
    }

    func semanticEndOf(_ span: Span) -> Int {
        semanticEnd(source, span.start, span.end)
    }

    /// Distributes the comments inside a group across its entries. Returns
    /// the comments that belong to the enclosing construct: those before the
    /// first entry and those after the last one.
    mutating func walkGroup(_ group: inout Group, _ regionEnd: Int) -> ([String], [String]) {
        if isEmpty {
            return ([], [])
        }

        var bounds: [(Int, Int)] = []
        for gc in group.groupChoices {
            for (ge, _) in gc.groupEntries {
                let span = ge.span
                bounds.append((span.start, semanticEndOf(span)))
            }
        }

        if bounds.isEmpty {
            return (takeBefore(regionEnd), [])
        }

        let beforeGroup = takeTrailingBefore(bounds[0].0)
        var pendingLeading = takeBefore(bounds[0].0)
        var afterGroup: [String] = []

        var idx = 0
        for gcIndex in group.groupChoices.indices {
            for entryIndex in group.groupChoices[gcIndex].groupEntries.indices {
                let leading = pendingLeading
                pendingLeading = []
                walkGroupEntry(&group.groupChoices[gcIndex].groupEntries[entryIndex].0, bounds[idx].1, leading)

                let next = idx + 1 < bounds.count ? bounds[idx + 1].0 : regionEnd

                // A comment on the entry's own line documents that entry. It
                // goes after the separating comma.
                let trailing = takeTrailingBefore(next)
                if group.groupChoices[gcIndex].groupEntries[entryIndex].1.optionalComma {
                    pushComments(&group.groupChoices[gcIndex].groupEntries[entryIndex].1.trailingComments, trailing)
                } else {
                    pushTrailingSlot(&group.groupChoices[gcIndex].groupEntries[entryIndex].0, trailing)
                }

                let leadingForNext = takeBefore(next)
                if idx + 1 < bounds.count {
                    pendingLeading = leadingForNext
                } else {
                    afterGroup = leadingForNext
                }
                idx += 1
            }
        }

        return (beforeGroup, afterGroup)
    }

    /// Places `leading` on `entry` and distributes the comments inside the
    /// entry's own text.
    mutating func walkGroupEntry(_ entry: inout GroupEntry, _ entryEnd: Int, _ leading: [String]) {
        switch entry {
        case .valueMemberKey(var ge, let span, var leadingComments, let trailingComments):
            entry = .inlineGroup(occur: nil, group: Group(), span: span)
            pushComments(&leadingComments, leading)
            defer {
                entry = .valueMemberKey(
                    ge: ge,
                    span: span,
                    leadingComments: leadingComments,
                    trailingComments: trailingComments
                )
            }
            if isEmpty {
                return
            }

            let (beforeType, afterType) = walkType(&ge.entryType, entryEnd)
            // Between the member key and the type there is only the key's own
            // separator, so anything found there follows the separator.
            switch ge.memberKey {
            case .bareword(let ident, let mkSpan, let comments, var afterColon):
                pushComments(&afterColon, beforeType)
                ge.memberKey = .bareword(ident: ident, span: mkSpan, comments: comments, commentsAfterColon: afterColon)
            case .value(let value, let mkSpan, let comments, var afterColon):
                pushComments(&afterColon, beforeType)
                ge.memberKey = .value(value: value, span: mkSpan, comments: comments, commentsAfterColon: afterColon)
            case .type1(let t1, let isCut, let mkSpan, let beforeCut, let afterCut, var afterArrowmap):
                pushComments(&afterArrowmap, beforeType)
                ge.memberKey = .type1(
                    t1: t1,
                    isCut: isCut,
                    span: mkSpan,
                    commentsBeforeCut: beforeCut,
                    commentsAfterCut: afterCut,
                    commentsAfterArrowmap: afterArrowmap
                )
            default:
                pushComments(&leadingComments, beforeType)
            }

            // The entry ends where its type ends, so a comment after the last
            // type choice trails the entry itself.
            if let last = ge.entryType.typeChoices.indices.last {
                pushComments(&ge.entryType.typeChoices[last].type1.commentsAfterType, afterType)
            } else {
                pushComments(&leadingComments, afterType)
            }
        case .typeGroupname(let ge, let span, var leadingComments, let trailingComments):
            pushComments(&leadingComments, leading)
            entry = .typeGroupname(ge: ge, span: span, leadingComments: leadingComments, trailingComments: trailingComments)
        case .inlineGroup(let occur, var group, let span, var before, var after):
            entry = .inlineGroup(occur: nil, group: Group(), span: span)
            // An inline group entry carries no leading slot of its own; the
            // slot just inside its parenthesis keeps the comment on it.
            pushComments(&before, leading)
            defer {
                entry = .inlineGroup(occur: occur, group: group, span: span, commentsBeforeGroup: before, commentsAfterGroup: after)
            }
            if isEmpty {
                return
            }
            let (b, a) = walkGroup(&group, entryEnd)
            pushComments(&before, b)
            pushComments(&after, a)
        }
    }

    /// Distributes the comments inside a type expression across its type
    /// choices. Returns the comments before the first choice and those after
    /// the last one.
    mutating func walkType(_ ty: inout Type, _ regionEnd: Int) -> ([String], [String]) {
        if isEmpty {
            return ([], [])
        }

        let bounds = ty.typeChoices.map { ($0.type1.span.start, semanticEndOf($0.type1.span)) }

        if bounds.isEmpty {
            return (takeBefore(regionEnd), [])
        }

        var beforeType = takeTrailingBefore(bounds[0].0)
        beforeType.append(contentsOf: takeBefore(bounds[0].0))

        var pendingLeading: [String] = []
        var afterType: [String] = []

        for idx in ty.typeChoices.indices {
            pushComments(&ty.typeChoices[idx].commentsBeforeType, pendingLeading)
            pendingLeading = []
            walkType1(&ty.typeChoices[idx].type1)

            let next = idx + 1 < bounds.count ? bounds[idx + 1].0 : regionEnd

            pushComments(&ty.typeChoices[idx].type1.commentsAfterType, takeTrailingBefore(next))

            let leadingForNext = takeBefore(next)
            if idx + 1 < bounds.count {
                pendingLeading = leadingForNext
            } else {
                afterType = leadingForNext
            }
        }

        return (beforeType, afterType)
    }

    mutating func walkType1(_ type1: inout Type1) {
        if isEmpty {
            return
        }
        walkType2(&type1.type2)
        if type1.operator != nil {
            walkType2(&type1.operator!.type2)
        }
    }

    mutating func walkType2(_ type2: inout Type2) {
        if isEmpty {
            return
        }

        switch type2 {
        case .array(var group, let span, var before, var after):
            type2 = .any(span: span)
            let (b, a) = walkGroup(&group, max(span.end - 1, 0))
            pushComments(&before, b)
            pushComments(&after, a)
            type2 = .array(group: group, span: span, commentsBeforeGroup: before, commentsAfterGroup: after)
        case .map(var group, let span, var before, var after):
            type2 = .any(span: span)
            let (b, a) = walkGroup(&group, max(span.end - 1, 0))
            pushComments(&before, b)
            pushComments(&after, a)
            type2 = .map(group: group, span: span, commentsBeforeGroup: before, commentsAfterGroup: after)
        case .choiceFromInlineGroup(var group, let span, let comments, var before, var after):
            type2 = .any(span: span)
            let (b, a) = walkGroup(&group, max(span.end - 1, 0))
            pushComments(&before, b)
            pushComments(&after, a)
            type2 = .choiceFromInlineGroup(
                group: group,
                span: span,
                comments: comments,
                commentsBeforeGroup: before,
                commentsAfterGroup: after
            )
        case .parenthesizedType(var pt, let span, var before, var after):
            type2 = .any(span: span)
            let (b, a) = walkType(&pt, max(span.end - 1, 0))
            pushComments(&before, b)
            pushComments(&after, a)
            type2 = .parenthesizedType(pt: pt, span: span, commentsBeforeType: before, commentsAfterType: after)
        case .taggedData(let tag, var t, let span, var before, var after):
            type2 = .any(span: span)
            let (b, a) = walkType(&t, max(span.end - 1, 0))
            pushComments(&before, b)
            pushComments(&after, a)
            type2 = .taggedData(tag: tag, t: t, span: span, commentsBeforeType: before, commentsAfterType: after)
        case .typename(let ident, var genericArgs?, let span):
            walkGenericArgs(&genericArgs)
            type2 = .typename(ident: ident, genericArgs: genericArgs, span: span)
        case .unwrap(let ident, var genericArgs?, let span, let comments):
            walkGenericArgs(&genericArgs)
            type2 = .unwrap(ident: ident, genericArgs: genericArgs, span: span, comments: comments)
        case .choiceFromGroup(let ident, var genericArgs?, let span, let comments):
            walkGenericArgs(&genericArgs)
            type2 = .choiceFromGroup(ident: ident, genericArgs: genericArgs, span: span, comments: comments)
        default:
            break
        }
    }

    /// Distributes the comments inside a generic argument list across its
    /// arguments.
    mutating func walkGenericArgs(_ args: inout GenericArgs) {
        if isEmpty {
            return
        }

        let bounds = args.args.map { ($0.arg.span.start, semanticEndOf($0.arg.span)) }
        if bounds.isEmpty {
            return
        }

        let regionEnd = max(args.span.end - 1, 0)

        var pendingLeading = takeTrailingBefore(bounds[0].0)
        pendingLeading.append(contentsOf: takeBefore(bounds[0].0))

        for idx in args.args.indices {
            pushComments(&args.args[idx].commentsBeforeType, pendingLeading)
            pendingLeading = []
            walkType1(&args.args[idx].arg)

            let next = idx + 1 < bounds.count ? bounds[idx + 1].0 : regionEnd

            pushComments(&args.args[idx].commentsAfterType, takeTrailingBefore(next))

            let leadingForNext = takeBefore(next)
            if idx + 1 < bounds.count {
                pendingLeading = leadingForNext
            } else {
                pushComments(&args.args[idx].commentsAfterType, leadingForNext)
            }
        }
    }
}

/// The slot for a comment trailing an entry that is not followed by a comma.
/// An inline group has no such slot, so the comment goes just inside its
/// closing parenthesis.
private func pushTrailingSlot(_ entry: inout GroupEntry, _ comments: [String]) {
    guard !comments.isEmpty else { return }
    switch entry {
    case .valueMemberKey(let ge, let span, let leading, var trailing):
        pushComments(&trailing, comments)
        entry = .valueMemberKey(ge: ge, span: span, leadingComments: leading, trailingComments: trailing)
    case .typeGroupname(let ge, let span, let leading, var trailing):
        pushComments(&trailing, comments)
        entry = .typeGroupname(ge: ge, span: span, leadingComments: leading, trailingComments: trailing)
    case .inlineGroup(let occur, let group, let span, let before, var after):
        pushComments(&after, comments)
        entry = .inlineGroup(occur: occur, group: group, span: span, commentsBeforeGroup: before, commentsAfterGroup: after)
    }
}

/// Places the comments the anchor merge left over (`attach_comments`).
func attachComments(_ cddl: inout CDDL, _ source: SourceText, orphans: OrphanOffsets) {
    let orphanSet = Set(orphans)
    let comments = harvestComments(source).filter { orphanSet.contains($0.start) }
    if comments.isEmpty {
        return
    }

    let ruleBounds: [(Int, Int)] = cddl.rules.map { rule in
        let span = rule.span
        return (span.start, semanticEnd(source, span.start, span.end))
    }

    var header: [String] = []
    var after: [[String]] = Array(repeating: [], count: cddl.rules.count)
    var inside: [[SourceComment]] = Array(repeating: [], count: cddl.rules.count)

    for comment in comments {
        let cs = comment.start

        if let ri = ruleBounds.firstIndex(where: { $0.0 <= cs && cs < $0.1 }) {
            inside[ri].append(comment)
            continue
        }

        if ruleBounds.isEmpty || cs < ruleBounds[0].0 {
            header.append(comment.text)
            continue
        }

        if let pi = ruleBounds.lastIndex(where: { $0.1 <= cs }) {
            after[pi].append(comment.text)
        } else {
            header.append(comment.text)
        }
    }

    if !header.isEmpty {
        var existing = cddl.comments?.comments ?? []
        existing.append(contentsOf: header)
        cddl.comments = Comments(existing)
    }

    for i in cddl.rules.indices {
        if !inside[i].isEmpty {
            var cursor = CommentCursor(source: source, items: inside[i])
            switch cddl.rules[i] {
            case .type(var rule, let span, let before, let afterRule):
                let bodyEnd = semanticEnd(source, span.start, span.end)
                let (b, a) = cursor.walkType(&rule.value, bodyEnd)
                pushComments(&rule.commentsAfterAssignt, b)
                if let last = rule.value.typeChoices.indices.last {
                    pushComments(&rule.value.typeChoices[last].type1.commentsAfterType, a)
                }
                cddl.rules[i] = .type(rule: rule, span: span, commentsBeforeRule: before, commentsAfterRule: afterRule)
            case .group(var rule, let span, let before, let afterRule):
                let bodyEnd = semanticEnd(source, span.start, span.end)
                let entryEnd = cursor.semanticEndOf(rule.entry.span)
                cursor.walkGroupEntry(&rule.entry, max(entryEnd, bodyEnd), [])
                // Anything the entry walk could not claim sits between the
                // assignment and the entry itself.
                let leftover = cursor.takeBefore(bodyEnd)
                pushComments(&rule.commentsBeforeAssigng, leftover)
                cddl.rules[i] = .group(rule: rule, span: span, commentsBeforeRule: before, commentsAfterRule: afterRule)
            }

            // A comment the walk could not place is kept next to its rule,
            // ahead of the comments that genuinely follow the rule.
            let stranded = cursor.takeBefore(Int.max)
            if !stranded.isEmpty {
                after[i].insert(contentsOf: stranded, at: 0)
            }
        }

        if after[i].isEmpty {
            continue
        }
        let bucket = after[i]
        switch cddl.rules[i] {
        case .type(let rule, let span, let before, let existing):
            var comments = existing?.comments ?? []
            comments.append(contentsOf: bucket)
            cddl.rules[i] = .type(rule: rule, span: span, commentsBeforeRule: before, commentsAfterRule: Comments(comments))
        case .group(let rule, let span, let before, let existing):
            var comments = existing?.comments ?? []
            comments.append(contentsOf: bucket)
            cddl.rules[i] = .group(rule: rule, span: span, commentsBeforeRule: before, commentsAfterRule: Comments(comments))
        }
    }
}
