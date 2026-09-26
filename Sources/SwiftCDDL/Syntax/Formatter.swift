// The CDDL formatter.
//
// Formatting is comment-preserving: every comment the parser attached to the
// AST is written back, and a `;` comment always ends its line so that it can
// never absorb the syntax that follows it. Formatting a formatted document
// again changes nothing.

extension CDDL {
    /// The document formatted as CDDL text.
    public func formatted() -> String {
        description
    }
}

/// Formats a parsed document back into CDDL text.
func format(_ cddl: CDDL) -> String {
    cddl.description
}

// MARK: - Comment helpers

extension Comments: CustomStringConvertible {
    public var description: String {
        if allNewline() {
            return ""
        }
        var out = ""
        for (i, comment) in comments.enumerated() {
            if comment == "\n" {
                out += "\n"
            } else {
                out += ";" + comment
                let nextIsNewline = i + 1 < comments.count && comments[i + 1] == "\n"
                if !nextIsNewline {
                    out += "\n"
                }
            }
        }
        return out
    }
}

/// True when the slot holds at least one comment with text in it.
func hasText(_ comments: Comments?) -> Bool {
    comments?.anyNonNewline() ?? false
}

/// Appends a comment block, guaranteeing it starts on a fresh line and ends
/// with one.
func pushCommentBlock(_ dst: inout String, _ comments: Comments, _ indent: String) {
    guard comments.anyNonNewline() else { return }
    if !dst.isEmpty && !dst.endsWith("\n") {
        dst += "\n"
    }
    for comment in comments.comments where comment != "\n" {
        dst += indent + ";" + comment + "\n"
    }
}

/// Appends a comment that trails text already present on the current line,
/// then closes the line so the comment cannot absorb what comes next.
func pushTrailingComment(_ dst: inout String, _ comments: Comments) {
    guard comments.anyNonNewline() else { return }
    var first = true
    for comment in comments.comments where comment != "\n" {
        if first && !dst.isEmpty && !dst.endsWith("\n") && !dst.endsWith(" ") {
            dst += " "
        } else if !dst.endsWith("\n") {
            dst += "\n"
        }
        dst += ";" + comment + "\n"
        first = false
    }
}

/// Appends a bracketed group together with the comments just inside its
/// delimiters. The opening delimiter is already in `dst`; the caller appends
/// the closing one.
func pushGroupWithComments(
    _ dst: inout String,
    _ group: Group,
    _ commentsBeforeGroup: Comments?,
    _ commentsAfterGroup: Comments?
) {
    var openedOnItsOwnLine = false

    if let comments = commentsBeforeGroup, comments.anyNonNewline() {
        openedOnItsOwnLine = true
        pushTrailingComment(&dst, comments)
        dst += "\t"
        dst += group.description.trimmingLeadingWhitespace()
    } else {
        dst += group.description
    }

    if let comments = commentsAfterGroup {
        pushCommentBlock(&dst, comments, "\t")
    }

    if (openedOnItsOwnLine || group.hasComments()) && !dst.endsWith("\n") {
        dst += "\n"
    }
}

/// Appends `block` with every one of its non-blank lines indented by
/// `indent`.
func pushIndented(_ dst: inout String, _ block: String, _ indent: String) {
    for line in block.splitLines() where !line.isBlank {
        dst += indent + line + "\n"
    }
}

// MARK: - Documents and rules

extension CDDL: CustomStringConvertible {
    public var description: String {
        let cddl = self
        return withLargeStack { cddl.formattedOnCurrentThread() }
    }

    private func formattedOnCurrentThread() -> String {
        var output = ""

        if let comments {
            output += comments.description
        }

        var previousSingleLineType = false
        var previousCommentsAfterRule = false

        for (idx, rule) in rules.enumerated() {
            if rule.hasCommentsAfterRule() {
                output += rule.description
                // Comments that follow a rule are kept apart from the next
                // rule by a blank line, so that formatting is idempotent.
                if idx + 1 < rules.count && !output.endsWithString("\n\n") {
                    output += "\n"
                }
                previousCommentsAfterRule = true
            } else if idx == rules.count - 1 || rule.hasSingleLineType() {
                output += rule.description.trimmingTrailingWhitespace() + "\n"
                previousSingleLineType = true
                previousCommentsAfterRule = false
            } else if previousSingleLineType && !previousCommentsAfterRule {
                output += "\n" + rule.description.trimmingTrailingWhitespace() + "\n\n"
                previousSingleLineType = false
                previousCommentsAfterRule = false
            } else {
                output += rule.description.trimmingTrailingWhitespace() + "\n\n"
                previousCommentsAfterRule = false
            }
        }

        return output
    }
}

extension Identifier: CustomStringConvertible {
    public var description: String {
        if let socket {
            return socket.description + ident
        }
        return ident
    }
}

extension Rule {
    func hasCommentsAfterRule() -> Bool {
        hasText(commentsAfterRule())
    }

    func hasSingleLineType() -> Bool {
        guard case .type(let rule, _, _, _) = self else { return false }
        let typeChoices = rule.value.typeChoices
        let typeCheck: (TypeChoice) -> Bool = { tc in
            switch tc.type1.type2 {
            case .typename, .floatValue, .intValue, .uintValue, .textValue, .b16ByteString, .b64ByteString:
                return true
            default:
                return false
            }
        }
        return typeChoices.count <= 2 && typeChoices.allSatisfy(typeCheck)
    }
}

extension Rule: CustomStringConvertible {
    public var description: String {
        var ruleStr = ""
        let before: Comments?
        let after: Comments?
        switch self {
        case .type(let rule, _, let b, let a):
            before = b
            after = a
            if let before, before.anyNonNewline() {
                ruleStr += before.description
            }
            ruleStr += rule.description
        case .group(let rule, _, let b, let a):
            before = b
            after = a
            if let before, before.anyNonNewline() {
                ruleStr += before.description
            }
            ruleStr += rule.description
        }

        if let after, after.anyNonNewline() {
            // A comment on the rule's own line is parsed as the trailing
            // comment of its last type choice, so the comments that follow the
            // rule start on a line of their own.
            if after.comments.first == "\n" {
                ruleStr += after.description
            } else if ruleStr.endsWith("\n") {
                ruleStr += after.description
            } else {
                ruleStr += "\n" + after.description
            }
        }
        return ruleStr
    }
}

extension TypeRule: CustomStringConvertible {
    public var description: String {
        var out = name.description
        if let genericParams {
            out += genericParams.description
        }
        if let commentsBeforeAssignt {
            out += commentsBeforeAssignt.description
        }
        out += isTypeChoiceAlternate ? " /= " : " = "
        if let commentsAfterAssignt {
            out += commentsAfterAssignt.description
        }
        out += value.description
        return out
    }
}

extension GroupRule: CustomStringConvertible {
    public var description: String {
        var out = name.description
        if let genericParams {
            out += genericParams.description
        }
        if let commentsBeforeAssigng {
            out += commentsBeforeAssigng.description
        }
        out += isGroupChoiceAlternate ? " //= " : " = "
        out += entry.description
        if let commentsAfterAssigng {
            out += commentsAfterAssigng.description
        }
        return out
    }
}

extension GenericParams: CustomStringConvertible {
    public var description: String {
        var out = "<"
        for (idx, param) in params.enumerated() {
            if idx != 0 {
                out += ", "
            }
            if let comments = param.commentsBeforeIdent {
                out += comments.description
            }
            out += param.param.description
            if let comments = param.commentsAfterIdent {
                out += comments.description
            }
        }
        out += ">"
        return out
    }
}

extension GenericArgs: CustomStringConvertible {
    public var description: String {
        var out = "<"
        for (idx, arg) in args.enumerated() {
            if idx != 0 {
                out += ", "
            }
            if let comments = arg.commentsBeforeType {
                pushTrailingComment(&out, comments)
            }
            out += arg.arg.description
            if let comments = arg.commentsAfterType {
                pushTrailingComment(&out, comments)
            }
        }
        out += ">"
        return out
    }
}

// MARK: - Types

extension Type: CustomStringConvertible {
    public var description: String {
        var out = ""
        for (idx, tc) in typeChoices.enumerated() {
            if idx == 0 {
                out += tc.type1.description
                if let comments = tc.commentsAfterType {
                    pushTrailingComment(&out, comments)
                }
                continue
            }

            if let comments = tc.commentsBeforeType {
                pushCommentBlock(&out, comments, "")
            }

            // A `/` that lands on a line already closed by a comment starts
            // the choice at the margin instead of after a separating space.
            if out.endsWith("\n") {
                out += "\t/ " + tc.type1.description
            } else if typeChoices.count > 2 {
                out += "\n\t/ " + tc.type1.description
            } else {
                out += " / " + tc.type1.description
            }

            if let comments = tc.commentsAfterType {
                pushTrailingComment(&out, comments)
            }
        }
        return out
    }
}

extension Type1: CustomStringConvertible {
    public var description: String {
        var out = type2.description

        var isTypename = false
        if case .typename = type2 {
            isTypename = true
        }

        if isTypename && self.operator != nil {
            out += " "
        }

        if let o = self.operator {
            if let comments = o.commentsBeforeOperator {
                out += comments.description
            }
            out += o.operator.description
            if let comments = o.commentsAfterOperator {
                out += comments.description
            }
            if isTypename {
                out += " "
            }
            out += o.type2.description
        }

        // The trailing comment belongs to the whole type1, so it follows the
        // operator's own type when there is one.
        if let comments = commentsAfterType {
            pushTrailingComment(&out, comments)
        }
        return out
    }
}

extension RangeCtlOp: CustomStringConvertible {
    public var description: String {
        switch self {
        case .rangeOp(let isInclusive, _): return isInclusive ? ".." : "..."
        case .ctlOp(let ctrl, _): return ctrl.description
        }
    }
}

extension Type2: CustomStringConvertible {
    public var description: String {
        switch self {
        case .intValue(let value, _):
            return value.description
        case .uintValue(let value, _):
            return String(value)
        case .floatValue(let value, let notation, _):
            return FloatLiteralValue(value, notation: notation).description
        case .textValue(let value, _):
            return "\"" + writeEscapedText(value, quote: "\"") + "\""
        case .utf8ByteString(let value, _):
            return ByteValue.utf8(value).description
        case .b16ByteString(let value, _):
            return ByteValue.b16(value).description
        case .b64ByteString(let value, _):
            return ByteValue.b64(value).description
        case .typename(let ident, let genericArgs, _):
            if let genericArgs {
                return ident.description + genericArgs.description
            }
            return ident.description
        case .parenthesizedType(let pt, _, let before, let after):
            var out = "("
            if let before, before.anyNonNewline() {
                pushTrailingComment(&out, before)
                out += "\t"
                out += pt.description.trimmingLeadingWhitespace()
            } else {
                out += pt.description
            }
            if let after {
                pushCommentBlock(&out, after, "")
            }
            out += ")"
            return out
        case .map(let group, _, let before, let after):
            var out = "{"
            pushGroupWithComments(&out, group, before, after)
            out += "}"
            return out
        case .array(let group, _, let before, let after):
            var out = "["
            pushGroupWithComments(&out, group, before, after)
            out += "]"
            return out
        case .unwrap(let ident, let genericArgs, _, let comments):
            // The unwrap prefix is part of the type.
            var out = "~"
            if let comments {
                out += comments.description
            }
            out += ident.description
            if let genericArgs {
                out += genericArgs.description
            }
            return out
        case .choiceFromInlineGroup(let group, _, let comments, let before, let after):
            var out = "&"
            if let comments {
                out += comments.description
            }
            out += "("
            pushGroupWithComments(&out, group, before, after)
            if out.endsWith("\n") {
                out += ")"
            } else if group.groupChoices.count == 1 && group.groupChoices[0].groupEntries.count == 1 {
                out += " )"
            } else {
                out += ")"
            }
            return out
        case .choiceFromGroup(let ident, let genericArgs, _, let comments):
            var out = "&"
            if let comments {
                out += comments.description
            }
            out += ident.description
            if let genericArgs {
                out += genericArgs.description
            }
            return out
        case .taggedData(let tag, let t, _, let before, let after):
            var out = "#6"
            if let tag {
                out += "." + tag.description
            }
            out += "("
            if let before {
                pushTrailingComment(&out, before)
            }
            out += t.description
            if let after {
                pushCommentBlock(&out, after, "")
            }
            out += ")"
            return out
        case .dataMajorType(let mt, let constraint, _):
            if let constraint {
                return "#\(mt).\(constraint)"
            }
            return "#\(mt)"
        case .any:
            return "#"
        }
    }
}

// MARK: - Comment presence

// Whether a subtree renders any comment text. The compact group layouts join
// entries onto one line and strip newlines, both of which would let a `;`
// comment absorb the syntax that follows it, so a subtree that carries a
// comment anywhere is laid out one entry per line instead.

extension Type {
    func hasComments() -> Bool {
        typeChoices.contains { tc in
            hasText(tc.commentsBeforeType) || hasText(tc.commentsAfterType) || tc.type1.hasComments()
        }
    }
}

extension Type1 {
    func hasComments() -> Bool {
        if hasText(commentsAfterType) || type2.hasComments() {
            return true
        }
        guard let o = self.operator else { return false }
        return hasText(o.commentsBeforeOperator) || hasText(o.commentsAfterOperator) || o.type2.hasComments()
    }
}

extension Type2 {
    func hasComments() -> Bool {
        switch self {
        case .parenthesizedType(let t, _, let before, let after), .taggedData(_, let t, _, let before, let after):
            return hasText(before) || hasText(after) || t.hasComments()
        case .map(let group, _, let before, let after), .array(let group, _, let before, let after):
            return hasText(before) || hasText(after) || group.hasComments()
        case .choiceFromInlineGroup(let group, _, let comments, let before, let after):
            return hasText(comments) || hasText(before) || hasText(after) || group.hasComments()
        case .unwrap(_, _, _, let comments), .choiceFromGroup(_, _, _, let comments):
            return hasText(comments)
        default:
            return false
        }
    }
}

extension MemberKey {
    func hasComments() -> Bool {
        switch self {
        case .type1(let t1, _, _, let beforeCut, let afterCut, let afterArrowmap):
            return hasText(beforeCut) || hasText(afterCut) || hasText(afterArrowmap) || t1.hasComments()
        case .bareword(_, _, let comments, let afterColon), .value(_, _, let comments, let afterColon):
            return hasText(comments) || hasText(afterColon)
        case .nonMemberKey(let nonMemberKey, let before, let after):
            if hasText(before) || hasText(after) {
                return true
            }
            switch nonMemberKey {
            case .group(let g): return g.hasComments()
            case .type(let t): return t.hasComments()
            }
        }
    }
}

extension GroupEntry {
    func hasComments() -> Bool {
        switch self {
        case .valueMemberKey(let ge, _, let leading, let trailing):
            return hasText(leading) || hasText(trailing) || hasText(ge.occur?.comments)
                || (ge.memberKey?.hasComments() ?? false) || ge.entryType.hasComments()
        case .typeGroupname(let ge, _, let leading, let trailing):
            return hasText(leading) || hasText(trailing) || hasText(ge.occur?.comments)
        case .inlineGroup(let occur, let group, _, let before, let after):
            return hasText(before) || hasText(after) || hasText(occur?.comments) || group.hasComments()
        }
    }

    func hasTrailingComments() -> Bool {
        switch self {
        case .valueMemberKey(_, _, _, let trailing), .typeGroupname(_, _, _, let trailing):
            return hasText(trailing)
        case .inlineGroup:
            return false
        }
    }
}

extension GroupChoice {
    func hasComments() -> Bool {
        hasText(commentsBeforeGrpchoice)
            || groupEntries.contains { ge, oc in ge.hasComments() || hasText(oc.trailingComments) }
    }

    func hasEntriesWithCommentsBeforeComma() -> Bool {
        for (entry, comma) in groupEntries {
            if case .valueMemberKey(let vmke, _, _, _) = entry {
                if vmke.entryType.typeChoices.contains(where: { $0.type1.commentsAfterType != nil })
                    && comma.optionalComma
                {
                    return true
                }
            }
            if case .typeGroupname(_, _, _, let trailing) = entry {
                if trailing != nil && comma.optionalComma {
                    return true
                }
            }
        }
        return false
    }
}

extension Group {
    func hasComments() -> Bool {
        groupChoices.contains { $0.hasComments() }
    }
}

extension OptionalComma {
    func hasTrailingComments() -> Bool {
        hasText(trailingComments)
    }
}

// MARK: - Groups

extension Group: CustomStringConvertible {
    public var description: String {
        // A group carrying comments anywhere is laid out one entry per line.
        if hasComments() {
            var out = "\n"
            for (idx, gc) in groupChoices.enumerated() {
                var lines = gc.description.splitLines().filter { !$0.isBlank }[...]

                // Comment lines that open a choice document the choice itself,
                // so they are written before the `//` separator.
                if idx > 0 {
                    while let line = lines.first, line.trimmingLeadingWhitespace().startsWith(";") {
                        out += "\t" + line.trimmingLeadingWhitespace() + "\n"
                        lines = lines.dropFirst()
                    }
                }

                if let first = lines.first {
                    lines = lines.dropFirst()
                    if idx == 0 {
                        out += "\t" + first.trimmingLeadingWhitespace() + "\n"
                    } else {
                        out += "\t// " + first.trimmingLeadingWhitespace() + "\n"
                    }
                } else if idx > 0 {
                    out += "\t//\n"
                }

                for line in lines {
                    out += line + "\n"
                }
            }
            return out
        }

        var out = ""
        for (idx, gc) in groupChoices.enumerated() {
            // Rendered once and reused: rendering it again for the first choice
            // would double the cost at every level of nesting.
            let rendered = gc.description
            var gcStr = rendered

            if groupChoices.count > 2 && gc.groupEntries.count <= 3 && !gc.hasEntriesWithCommentsBeforeComma() {
                gcStr = gcStr.replacingScalar("\n", with: "")
            }

            if idx == 0 {
                if groupChoices.count > 2 && gc.groupEntries.count <= 3 {
                    out += "\n\t"
                    if gcStr.endsWith(" ") {
                        gcStr.removeLastScalar()
                    }
                    if groupChoices.count > 2 && gc.hasEntriesWithCommentsBeforeComma() {
                        gcStr = gcStr.replacingScalar("\n", with: "\n\t\t")
                        out += gcStr.trimmingWhitespace()
                    } else {
                        out += gcStr.trimmingLeadingWhitespace()
                    }
                } else {
                    out += rendered
                }

                if groupChoices.count > 2 && gc.groupEntries.count <= 3 {
                    out += "\n"
                }
                continue
            }

            gcStr = gcStr.trimmingWhitespace()

            if groupChoices.count > 2 && gc.hasEntriesWithCommentsBeforeComma() {
                gcStr = gcStr.replacingScalar("\n", with: "\n\t\t")
            }

            if groupChoices.count <= 2 {
                out += "// " + gcStr + " "
            } else {
                out += "\t// " + gcStr + "\n"
            }
        }
        return out
    }
}

extension GroupChoice: CustomStringConvertible {
    public var description: String {
        // One entry per line whenever a comment is present anywhere below.
        if hasComments() {
            var out = "\n"
            if let comments = commentsBeforeGrpchoice {
                pushCommentBlock(&out, comments, "\t")
            }
            for (entry, optionalComma) in groupEntries {
                var rendered = entry.description + optionalComma.description
                if !rendered.endsWith("\n") {
                    rendered += "\n"
                }
                pushIndented(&out, rendered, "\t")
            }
            return out
        }

        var out = ""

        // Entries carrying their own doc comments are laid out one per line.
        let hasEntryDocComments = groupEntries.contains { ge, _ in
            switch ge {
            case .valueMemberKey(_, _, let leading, let trailing), .typeGroupname(_, _, let leading, let trailing):
                return hasText(leading) || hasText(trailing)
            case .inlineGroup:
                return false
            }
        }

        if hasEntryDocComments {
            if let comments = commentsBeforeGrpchoice, comments.anyNonNewline() {
                out += comments.description
            }

            for (ge, _) in groupEntries {
                if !out.endsWith("\n") {
                    out += "\n"
                }

                let leading: Comments?
                let core: String
                let trailing: Comments?
                switch ge {
                case .valueMemberKey(let vmke, _, let l, let t):
                    leading = l
                    core = vmke.description
                    trailing = t
                case .typeGroupname(let tge, _, let l, let t):
                    leading = l
                    core = tge.description
                    trailing = t
                case .inlineGroup:
                    out += ge.description + ",\n"
                    continue
                }

                if let leading, leading.anyNonNewline() {
                    out += leading.description
                }
                out += core + ","
                if let trailing, trailing.anyNonNewline() {
                    out += " " + trailing.description
                } else {
                    out += "\n"
                }
            }
            return out
        }

        if groupEntries.count == 1 {
            out += " " + groupEntries[0].0.description + groupEntries[0].1.description
            if !groupEntries[0].1.hasTrailingComments() {
                out += " "
            }
            return out
        }

        if let comments = commentsBeforeGrpchoice {
            out += comments.description
        }

        // Entries with comments written before their commas.
        var entriesWithCommentBeforeComma: [Bool] = []
        for (entry, comma) in groupEntries {
            if case .valueMemberKey(_, _, _, let trailing?) = entry, trailing.anyNonNewline(), comma.optionalComma {
                entriesWithCommentBeforeComma.append(true)
                continue
            }
            if case .typeGroupname(_, _, _, let trailing?) = entry, trailing.anyNonNewline(), comma.optionalComma {
                entriesWithCommentBeforeComma.append(true)
                continue
            }
            entriesWithCommentBeforeComma.append(false)
        }

        let hasTrailingCommentsAfterComma = groupEntries.contains { $0.1.hasTrailingComments() }
        let multiline = groupEntries.count > 3 || (groupEntries.count <= 3 && hasTrailingCommentsAfterComma)

        out += multiline ? "\n" : " "

        let anyBeforeComma = entriesWithCommentBeforeComma.contains(true)
        for (idx, ge) in groupEntries.enumerated() {
            if multiline {
                out += "\t"
            }

            if anyBeforeComma {
                if idx == 0 {
                    if entriesWithCommentBeforeComma[idx] {
                        out += ge.0.description
                    } else {
                        out += ge.0.description + "\n"
                    }
                } else if entriesWithCommentBeforeComma[idx] {
                    out += ", " + ge.0.description
                } else if idx != groupEntries.count - 1 {
                    out += ", " + ge.0.description.trimmingTrailingWhitespace() + "\n"
                } else {
                    out += ", " + ge.0.description.trimmingTrailingWhitespace()
                }
            } else {
                out += ge.0.description.trimmingTrailingWhitespace() + ge.1.description.trimmingTrailingWhitespace()
                if groupEntries.count <= 3 && !hasTrailingCommentsAfterComma {
                    out += " "
                }
            }

            if idx == groupEntries.count - 1 && groupEntries.count > 3 {
                out += "\n"
                break
            }

            if groupEntries.count > 3 && !anyBeforeComma {
                out += "\n"
            }
        }

        return out
    }
}

extension OptionalComma: CustomStringConvertible {
    public var description: String {
        var out = optionalComma ? "," : ""
        if let trailingComments {
            pushTrailingComment(&out, trailingComments)
        }
        return out
    }
}

extension GroupEntry: CustomStringConvertible {
    public var description: String {
        switch self {
        case .valueMemberKey(let ge, _, let leading, let trailing):
            var out = ""
            if let leading {
                pushCommentBlock(&out, leading, "")
            }
            out += ge.description
            if let trailing {
                pushTrailingComment(&out, trailing)
            }
            return out
        case .typeGroupname(let ge, _, let leading, let trailing):
            var out = ""
            if let leading {
                pushCommentBlock(&out, leading, "")
            }
            out += ge.description
            if let trailing {
                pushTrailingComment(&out, trailing)
            }
            return out
        case .inlineGroup(let occur, let group, _, let before, let after):
            var out = ""
            if let occur {
                out += occur.occur.description + " "
                if let comments = occur.comments {
                    out += comments.description
                }
            }
            out += "("
            pushGroupWithComments(&out, group, before, after)
            out += ")"
            return out
        }
    }
}

extension Occurrence: CustomStringConvertible {
    public var description: String {
        var out = occur.description
        if let comments {
            out += comments.description
        }
        return out
    }
}

extension ValueMemberKeyEntry: CustomStringConvertible {
    public var description: String {
        var out = ""
        if let occur {
            out += occur.description + " "
        }
        if let memberKey {
            out += memberKey.description + " "
        }
        out += entryType.description
        return out
    }
}

extension TypeGroupnameEntry: CustomStringConvertible {
    public var description: String {
        var out = ""
        if let occur {
            out += occur.description + " "
        }
        out += name.description
        if let genericArgs {
            out += genericArgs.description
        }
        return out
    }
}

extension MemberKey: CustomStringConvertible {
    public var description: String {
        switch self {
        case .type1(let t1, let isCut, _, let beforeCut, let afterCut, let afterArrowmap):
            var out = t1.description + " "
            if let beforeCut, beforeCut.anyNonNewline() {
                out += beforeCut.description
            }
            if isCut {
                out += "^ "
            }
            if let afterCut, afterCut.anyNonNewline() {
                out += afterCut.description
            }
            out += "=>"
            if let afterArrowmap, afterArrowmap.anyNonNewline() {
                out += " " + afterArrowmap.description
            }
            return out
        case .bareword(let ident, _, let comments, let afterColon):
            var out = ident.description
            if let comments, comments.anyNonNewline() {
                out += " " + comments.description
            }
            out += ":"
            if let afterColon, afterColon.anyNonNewline() {
                out += " " + afterColon.description
            }
            return out
        case .value(let value, _, let comments, let afterColon):
            var out = value.description
            if let comments, comments.anyNonNewline() {
                out += " " + comments.description
            }
            out += ":"
            if let afterColon, afterColon.anyNonNewline() {
                out += " " + afterColon.description
            }
            return out
        case .nonMemberKey(let nonMemberKey, let before, let after):
            var out = ""
            if let before {
                out += before.description
            }
            switch nonMemberKey {
            case .group(let g): out += g.description
            case .type(let t): out += t.description
            }
            if let after {
                out += after.description
            }
            return out
        }
    }
}

extension Occur: CustomStringConvertible {
    public var description: String {
        switch self {
        case .zeroOrMore:
            return "*"
        case .exact(let lower, let upper, _):
            if let lower {
                if let upper {
                    return "\(lower)*\(upper)"
                }
                return "\(lower)*"
            }
            if let upper {
                return "*\(upper)"
            }
            return "*"
        case .oneOrMore:
            return "+"
        case .optional:
            return "?"
        }
    }
}
