import Foundation
import Testing

@testable import SwiftCDDL

/// Test fixtures bundled with the test target.
enum Fixtures {
    static var root: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    static func url(_ relativePath: String) -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func read(_ relativePath: String) throws -> String {
        try String(contentsOf: url(relativePath), encoding: .utf8)
    }

    /// The `.cddl` files of a fixture directory, sorted by name.
    static func cddlFiles(in directory: String) throws -> [String] {
        let names = try FileManager.default.contentsOfDirectory(atPath: url(directory).path)
        return names.filter { $0.hasSuffix(".cddl") }.sorted().map { "\(directory)/\($0)" }
    }
}

/// Parses `input` or records the error and fails the test.
func parseOK(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> CDDL {
    do {
        return try cddlFromStr(input)
    } catch {
        Issue.record("Failed to parse CDDL: \(error)", sourceLocation: sourceLocation)
        throw error
    }
}

/// Parses `input`, expecting a failure, and returns the error's text.
func parseErr(_ input: String, sourceLocation: SourceLocation = #_sourceLocation) -> String {
    do {
        _ = try cddlFromStr(input)
        Issue.record("expected \(input.debugDescription) to fail to parse", sourceLocation: sourceLocation)
        return ""
    } catch {
        return error.description
    }
}

/// Every span of a document in preorder, one `tag start end line` per line
/// (the layout the reference oracle's `spans` mode prints).
func spanDump(_ cddl: CDDL) -> String {
    var out = ""

    func sp(_ tag: String, _ s: Span) {
        out += "\(tag) \(s.start) \(s.end) \(s.line)\n"
    }

    func type(_ ty: Type) {
        sp("type", ty.span)
        for tc in ty.typeChoices {
            type1(tc.type1)
        }
    }

    func type1(_ x: Type1) {
        sp("type1", x.span)
        type2(x.type2)
        if let o = x.operator {
            switch o.operator {
            case .rangeOp(_, let span), .ctlOp(_, let span): sp("op", span)
            }
            type2(o.type2)
        }
    }

    func genericArgs(_ g: GenericArgs?) {
        guard let g else { return }
        sp("gargs", g.span)
        for a in g.args {
            type1(a.arg)
        }
    }

    func type2(_ x: Type2) {
        switch x {
        case .typename(let ident, let ga, let span):
            sp("typename", span)
            sp("ident", ident.span)
            genericArgs(ga)
        case .unwrap(let ident, let ga, let span, _), .choiceFromGroup(let ident, let ga, let span, _):
            sp("t2name", span)
            sp("ident", ident.span)
            genericArgs(ga)
        case .parenthesizedType(let pt, let span, _, _):
            sp("paren", span)
            type(pt)
        case .taggedData(_, let t, let span, _, _):
            sp("tag", span)
            type(t)
        case .map(let g, let span, _, _), .array(let g, let span, _, _), .choiceFromInlineGroup(let g, let span, _, _, _):
            sp("container", span)
            group(g)
        default:
            sp("leaf", x.span)
        }
    }

    func occurrence(_ o: Occurrence?) {
        guard let o else { return }
        switch o.occur {
        case .exact(_, _, let span), .zeroOrMore(let span), .oneOrMore(let span), .optional(let span):
            sp("occur", span)
        }
    }

    func group(_ x: Group) {
        sp("group", x.span)
        for gc in x.groupChoices {
            sp("gc", gc.span)
            for (e, c) in gc.groupEntries {
                entry(e)
                out += "comma \(c.optionalComma)\n"
            }
        }
    }

    func entry(_ e: GroupEntry) {
        switch e {
        case .valueMemberKey(let ge, let span, _, _):
            sp("vmk", span)
            occurrence(ge.occur)
            if let mk = ge.memberKey {
                switch mk {
                case .type1(let x, let isCut, let span, _, _, _):
                    sp("mk-t1 \(isCut)", span)
                    type1(x)
                case .bareword(let ident, let span, _, _):
                    sp("mk-bw", span)
                    sp("ident", ident.span)
                case .value(let value, let span, _, _):
                    sp("mk-v \(value)", span)
                default:
                    break
                }
            }
            type(ge.entryType)
        case .typeGroupname(let ge, let span, _, _):
            sp("tgn", span)
            occurrence(ge.occur)
            sp("ident", ge.name.span)
            genericArgs(ge.genericArgs)
        case .inlineGroup(let occur, let g, let span, _, _):
            sp("inline", span)
            occurrence(occur)
            group(g)
        }
    }

    for rule in cddl.rules {
        switch rule {
        case .type(let rule, let span, _, _):
            sp("rule", span)
            sp("name", rule.name.span)
            if let gp = rule.genericParams {
                sp("gparams", gp.span)
                for p in gp.params {
                    sp("ident", p.param.span)
                }
            }
            type(rule.value)
        case .group(let rule, let span, _, _):
            sp("grule", span)
            sp("name", rule.name.span)
            if let gp = rule.genericParams {
                sp("gparams", gp.span)
                for p in gp.params {
                    sp("ident", p.param.span)
                }
            }
            entry(rule.entry)
        }
    }
    return out
}

/// The comment payloads of a CDDL document, in source order. A `;` inside a
/// text or byte-string literal does not start a comment.
func commentPayloads(_ cddl: String) -> [String] {
    let bytes = Array(cddl.utf8)
    var payloads: [String] = []
    var i = 0
    while i < bytes.count {
        switch bytes[i] {
        case UInt8(ascii: ";"):
            let start = i
            i += 1
            while i < bytes.count && bytes[i] != UInt8(ascii: "\n") {
                i += 1
            }
            payloads.append(String(decoding: bytes[(start + 1)..<i], as: UTF8.self).trimmingTrailingWhitespace())
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            let quote = bytes[i]
            i += 1
            while i < bytes.count && bytes[i] != quote {
                if bytes[i] == UInt8(ascii: "\\") {
                    i += 1
                }
                i += 1
            }
            i += 1
        default:
            i += 1
        }
    }
    return payloads
}

/// The document with its comments removed, each replaced by a newline.
func stripComments(_ cddl: String) -> String {
    let bytes = Array(cddl.utf8)
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
        switch bytes[i] {
        case UInt8(ascii: ";"):
            while i < bytes.count && bytes[i] != UInt8(ascii: "\n") {
                i += 1
            }
            out.append(UInt8(ascii: "\n"))
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            let quote = bytes[i]
            let start = i
            i += 1
            while i < bytes.count && bytes[i] != quote {
                if bytes[i] == UInt8(ascii: "\\") {
                    i += 1
                }
                i += 1
            }
            i += 1
            out.append(contentsOf: bytes[start..<min(i, bytes.count)])
        default:
            out.append(bytes[i])
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// The grammar a document expresses, with comments and whitespace outside
/// literals dropped.
func grammarOnly(_ cddl: String) -> String {
    let bytes = Array(cddl.utf8)
    var out: [UInt8] = []
    var i = 0
    while i < bytes.count {
        switch bytes[i] {
        case UInt8(ascii: ";"):
            while i < bytes.count && bytes[i] != UInt8(ascii: "\n") {
                i += 1
            }
        case UInt8(ascii: "\""), UInt8(ascii: "'"):
            let quote = bytes[i]
            let start = i
            i += 1
            while i < bytes.count && bytes[i] != quote {
                if bytes[i] == UInt8(ascii: "\\") {
                    i += 1
                }
                i += 1
            }
            i += 1
            out.append(contentsOf: bytes[start..<min(i, bytes.count)])
        case 0x20, 0x09, 0x0A, 0x0C, 0x0D:
            i += 1
        default:
            out.append(bytes[i])
            i += 1
        }
    }
    return String(decoding: out, as: UTF8.self)
}

/// Collects every literal a document holds, in source order, as the variant
/// and payload it parsed to (a float by value only).
struct Literals: Visitor {
    var values: [String] = []

    mutating func visitValue(_ value: Value) throws {
        switch value {
        case .float(let float):
            values.append("FLOAT(\(float.value))")
        default:
            values.append(String(reflecting: value))
        }
    }
}

func literals(_ cddl: CDDL) -> [String] {
    var collected = Literals()
    try? collected.visitCDDL(cddl)
    return collected.values
}

// MARK: - AST accessors

/// The type rule at `index`, or nil.
func typeRule(_ cddl: CDDL, _ index: Int) -> TypeRule? {
    guard index < cddl.rules.count, case .type(let rule, _, _, _) = cddl.rules[index] else { return nil }
    return rule
}

/// The group rule at `index`, or nil.
func groupRule(_ cddl: CDDL, _ index: Int) -> GroupRule? {
    guard index < cddl.rules.count, case .group(let rule, _, _, _) = cddl.rules[index] else { return nil }
    return rule
}

/// The type rule named `name`.
func findType(_ cddl: CDDL, _ name: String) -> Type? {
    for rule in cddl.rules {
        if case .type(let rule, _, _, _) = rule, rule.name.ident == name {
            return rule.value
        }
    }
    return nil
}

/// The group of a map or array type2.
func containerGroup(_ t2: Type2) -> Group? {
    switch t2 {
    case .map(let group, _, _, _), .array(let group, _, _, _): return group
    default: return nil
    }
}

/// The group of the map or array the first choice of `ty` is.
func arrayOrMapGroup(_ ty: Type?) -> Group? {
    guard let ty, let first = ty.typeChoices.first else { return nil }
    return containerGroup(first.type1.type2)
}

/// The first type2 of a type rule.
func firstType2(_ rule: TypeRule?) -> Type2? {
    rule?.value.typeChoices.first?.type1.type2
}

/// The member key of a value member key entry.
func memberKey(_ entry: GroupEntry) -> MemberKey? {
    if case .valueMemberKey(let ge, _, _, _) = entry {
        return ge.memberKey
    }
    return nil
}

/// The member key of entry `entryIndex` of the first choice of `group`.
func memberKeyOf(_ group: Group?, _ entryIndex: Int) -> MemberKey? {
    guard let group, let gc = group.groupChoices.first, entryIndex < gc.groupEntries.count else { return nil }
    return memberKey(gc.groupEntries[entryIndex].0)
}

/// A short name of a member key's form.
func memberKeyVariant(_ mk: MemberKey?) -> String {
    switch mk {
    case .bareword?: return "Bareword"
    case .type1?: return "Type1"
    case .value?: return "Value"
    case .nonMemberKey?: return "NonMemberKey"
    case nil: return "none"
    }
}

/// The first comment of a slot.
func commentFirst(_ comments: Comments?) -> String? {
    comments?.comments.first
}

/// The trailing comment of entry `ei` of choice `ci`.
func entryTrailing(_ group: Group?, _ ci: Int, _ ei: Int) -> String? {
    guard let group else { return nil }
    switch group.groupChoices[ci].groupEntries[ei].0 {
    case .valueMemberKey(_, _, _, let trailing), .typeGroupname(_, _, _, let trailing):
        return commentFirst(trailing)
    case .inlineGroup:
        Issue.record("unexpected group entry kind")
        return nil
    }
}

/// The leading comment of the rule named `name`.
func ruleLeading(_ cddl: CDDL, _ name: String) -> String? {
    for rule in cddl.rules {
        switch rule {
        case .type(let r, _, let before, _) where r.name.ident == name: return commentFirst(before)
        case .group(let r, _, let before, _) where r.name.ident == name: return commentFirst(before)
        default: continue
        }
    }
    return nil
}

/// The trailing comment of the type choice at `index`.
func choiceTrailing(_ ty: Type?, _ index: Int) -> String? {
    commentFirst(ty?.typeChoices[index].commentsAfterType)
}
