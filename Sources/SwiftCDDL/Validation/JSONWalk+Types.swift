import BigInt
import Foundation

// Types matched against a JSON value: ranges and the forms of `type2` (RFC
// 8610 Sections 2.2 and 3).

extension JSONLevel {
    // MARK: Ranges

    func visitRange(_ lower: Type2, _ upper: Type2, _ isInclusive: Bool) async throws(JSONValidationError) {
        if item.isArray {
            try await validateArrayItems(.range(lower, upper, isInclusive))
            return
        }

        // A bound is the value it denotes, whether it is written as a literal,
        // as a parenthesized expression, or as a name that resolves to one.
        let l: RangeBound
        let u: RangeBound
        switch (resolveBound(lower), resolveBound(upper)) {
        case (.success(let lb), .success(let ub)):
            l = lb
            u = ub
        case (.success, .failure(let uErr)):
            addError("invalid cddl range. upper value must be a numeric type. got \(upper). Error: \(uErr)")
            return
        case (.failure(let lErr), .success):
            addError("invalid cddl range. lower value must be a numeric type. got \(lower). Error: \(lErr)")
            return
        case (.failure(let lErr), .failure(let uErr)):
            addError(
                "invalid cddl range. upper and lower values must be numeric types. got \(lower) and \(upper). Error: \(lErr) and \(uErr)"
            )
            return
        }

        switch (l, u) {
        case (.int(let l), .int(let u)):
            intRange(l, u, isInclusive)
        case (.float(let l), .float(let u)):
            floatRange(l, u, isInclusive)
        default:
            // Bounds of different kinds do not denote a range; the resolved
            // bounds are reported, so that one reached through a rule reference
            // names the value the mismatch is about.
            addError(
                "invalid cddl range. upper and lower values must both be integers or both be floats. got \(l) and \(u)")
        }
    }

    private func intRange(_ l: BigInt, _ u: BigInt, _ isInclusive: Bool) {
        switch item {
        case .string(let s):
            switch state.ctrl {
            case .size?:
                // Under `.size` a range bounds the length of the string rather
                // than denoting a set of values it is drawn from.
                let len = s.utf8.count
                let sLen = BigInt(len)
                if isInclusive {
                    if sLen < l || sLen > u {
                        addError("expected \"\(s)\" string length to be in the range \(l) <= value <= \(u), got \(len)")
                    }
                } else if sLen < l || sLen >= u {
                    addError("expected \"\(s)\" string length to be in the range \(l) <= value < \(u), got \(len)")
                }
            case .ne?:
                // A range denotes a set of numbers, so no string is one of them
                // and the exclusion holds.
                break
            default:
                addError("string value cannot be validated against a range without the .size control operator")
            }
        case .number(let n):
            let got = n.description
            let rangeText = "\(l)\(isInclusive ? ".." : "...")\(u)"

            // Under `.size` a range bounds the byte width the value is
            // represented in: the control holds when it fits the widest.
            if state.ctrl == .size {
                let widest = isInclusive ? u : u - 1
                if l > widest {
                    addError("invalid cddl range. the .size range (\(rangeText)) admits no byte width")
                } else if !(n.uint64.map { uintFitsInSize(BigInt($0), widest) } ?? false) {
                    addError("expected value .size (\(rangeText)), got \(got)")
                }
                return
            }

            // An integer range denotes integers, so a number that is not one is
            // never a member of it.
            let value = n.integer

            // The controller of `.ne` is a type; a range excludes each value it
            // contains.
            if state.ctrl == .ne {
                if let i = value, isInclusive ? (i >= l && i <= u) : (i >= l && i < u) {
                    addError("expected value .ne (\(rangeText)), got \(got)")
                }
                return
            }

            // A comparison resolves a range controller to the member it has to
            // hold against; an integer range holds only integers.
            if let ctrl = state.ctrl, let comparison = Comparison(ctrl) {
                switch value.map({ comparison.holdsAgainstIntRange($0, l, u, isInclusive) }) {
                case .some(.some(true)):
                    break
                case .some(.none):
                    addError("invalid cddl range. the range (\(rangeText)) holds no values to compare against")
                default:
                    addError("expected value \(ctrl) (\(rangeText)), got \(got)")
                }
                return
            }

            let inRange = value.map { isInclusive ? ($0 >= l && $0 <= u) : ($0 >= l && $0 < u) } ?? false
            if !inRange {
                addError(
                    "expected integer to be in range \(l) <= value \(isInclusive ? "<=" : "<") \(u), got \(got)")
            }
        default:
            // An integer range denotes integers, so the exclusion holds for
            // anything else.
            if state.ctrl == .ne {
                return
            }
            let op = isInclusive ? "<=" : "<"
            addError("expected value to be in range \(l) \(op) value \(op) \(u), got \(item.elidedRendering)")
        }
    }

    private func floatRange(_ l: Double, _ u: Double, _ isInclusive: Bool) {
        // A float range denotes floating point values, and a number read as an
        // integer is not one of them.
        if case .number(let n) = item, n.isFloat {
            let got = n.description
            let f = n.double
            // Negated so that a NaN, which compares false against every bound,
            // is rejected.
            let inRange = isInclusive ? (f >= l && f <= u) : (f >= l && f < u)

            if state.ctrl == .ne {
                if inRange {
                    addError(
                        "expected value .ne (\(floatDebug(l))\(isInclusive ? ".." : "...")\(floatDebug(u))), got \(got)"
                    )
                }
                return
            }

            if let ctrl = state.ctrl, let comparison = Comparison(ctrl) {
                let rangeText = "\(floatDebug(l))\(isInclusive ? ".." : "...")\(floatDebug(u))"
                switch comparison.holdsAgainstFloatRange(f, l, u, isInclusive) {
                case true?:
                    break
                case false?:
                    addError("expected value \(ctrl) (\(rangeText)), got \(got)")
                case nil:
                    addError("invalid cddl range. the range (\(rangeText)) holds no values to compare against")
                }
                return
            }

            if !inRange {
                addError(
                    "expected float to be in range \(floatDebug(l)) <= value \(isInclusive ? "<=" : "<") \(floatDebug(u)), got \(got)"
                )
            }
            return
        }

        if state.ctrl == .ne {
            return
        }
        addError(
            "expected value to be in range \(floatDebug(l)) <= value \(isInclusive ? "<=" : "<") \(floatDebug(u)), got \(item.elidedRendering)"
        )
    }

    // MARK: Type2

    func visitType2(_ t2: Type2) async throws(JSONValidationError) {
        // Matching one type against one value is a step of the walk.
        try chargeWork()

        switch t2 {
        case .textValue(let value, _):
            try await visitValue(.text(value))
        case .map(let group, _, _, _):
            try await visitMapType(t2, group)
        case .array(let group, _, _, _):
            try await visitArrayType(t2, group)
        case .choiceFromGroup(let ident, let genericArgs, _, _):
            try await visitChoiceFromGroup(ident, genericArgs)
        case .choiceFromInlineGroup(let group, _, _, _, _):
            state.isGroupToChoiceEnum = true
            try await visitGroup(group)
            state.isGroupToChoiceEnum = false
        case .typename(let ident, let genericArgs, _):
            try await visitTypename(ident, genericArgs)
        case .intValue(let value, _):
            try await visitValue(.int(value))
        case .uintValue(let value, _):
            try await visitValue(.uint(value))
        case .floatValue(let value, let notation, _):
            try await visitValue(.float(FloatLiteralValue(value, notation: notation)))
        case .parenthesizedType(let pt, _, _, _):
            try await visitType(pt)
        case .unwrap(let ident, let genericArgs, _, _):
            try await visitUnwrap(ident, genericArgs)
        case .any:
            break
        // What a byte string literal means depends on the control operator it
        // is reached under, so it is weighed where that operator is read rather
        // than refused here for the type JSON has no value of.
        case .utf8ByteString(let value, _):
            try await visitValue(.byte(.utf8(value)))
        case .b16ByteString(let value, _):
            try await visitValue(.byte(.b16(value)))
        case .b64ByteString(let value, _):
            try await visitValue(.byte(.b64(value)))
        case .taggedData, .dataMajorType:
            // The JSON data model has no tags and no major types.
            addError("unsupported data type for validating JSON, got \(typeHead(t2))")
        }
    }

    private func visitMapType(_ t2: Type2, _ group: Group) async throws(JSONValidationError) {
        switch item {
        case .object(let object):
            let entries = object.entries

            // A group with no entries names no member at all, so the only
            // object it admits is the empty one.
            if group.groupChoices.count == 1 && group.groupChoices[0].groupEntries.isEmpty && !entries.isEmpty {
                addError("expected empty map, got \(item.elidedRendering)")
                return
            }

            // The map matcher decides whether the object matches; each
            // alternative of the map's own group is held to every member.
            var ctx = MapMatchCtx()
            var failureErrors: [ErrorRecord] = []
            // "unexpected key" reports for members whose value no entry was
            // tried against: nothing else explains them.
            var unexplainedKeys: [ErrorRecord] = []
            for gc in group.groupChoices {
                var claims = MapClaims(entries.count)
                if try await mapMatchTopGroupChoice(gc, entries, &claims, &ctx) {
                    if claims.claimed.allSatisfy({ $0 }) {
                        state.isCutPresent = false
                        cutValue = nil
                        return
                    }

                    let errorCount = errors.count
                    for (pair, entry) in entries.enumerated() where !claims.claimed[pair] {
                        // What the member's value failed against, where an entry
                        // admitted its name, says why no entry claimed it.
                        var explained = false
                        if let recorded = ctx.pairFailures.removeValue(forKey: pair) {
                            errors.append(contentsOf: recorded)
                            explained = !ctx.declinedPairs.contains(pair)
                        }
                        addError("unexpected key \(debugString(entry.key))")
                        if !explained, let error = errors.last {
                            unexplainedKeys.append(error)
                        }
                    }
                    failureErrors.append(contentsOf: errors[errorCount...])
                    errors.removeLast(errors.count - errorCount)
                } else {
                    failureErrors.append(contentsOf: ctx.errors)
                    ctx.errors = []
                }
            }

            // The object does not match. Where its values are all scalars, the
            // entry walk reports what is wrong in detail; it is not run over
            // members that nest further data, which the matcher has already
            // walked. Where it finds nothing to report, or was not run, the
            // matcher's own account is reported.
            let errorCount = errors.count
            if entries.allSatisfy({ $0.value.isScalar }) {
                try await validateMapGroupDetail(group, entries)
            }
            if errors.count == errorCount {
                errors.append(contentsOf: failureErrors)
            } else {
                // A member that no alternative could claim is reported as such
                // even where the entry walk explained the failure otherwise.
                for error in unexplainedKeys
                where !errors[errorCount...].contains(where: { $0.reason == error.reason && $0.location == error.location }) {
                    errors.append(error)
                }
            }

            state.isCutPresent = false
            cutValue = nil
        case .array:
            try await validateArrayItems(.map(t2))
        default:
            addError(expectedTypeError(.json, t2, item.elidedRendering))
        }
    }

    private func visitArrayType(_ t2: Type2, _ group: Group) async throws(JSONValidationError) {
        guard case .array(let array) = item else {
            addError(expectedTypeError(.json, t2, item.elidedRendering))
            return
        }
        let a = array.items
        let len = a.count

        // A group with no entries names no item at all, so the only array it
        // admits is the empty one.
        if group.groupChoices.count == 1 && group.groupChoices[0].groupEntries.isEmpty && len != 0 {
            addError("expected empty array, got \(item.elidedRendering)")
            return
        }

        // RFC 8610 Appendix A: the array matches when its item sequence matches
        // the group. Each group choice of the array's own group is held to the
        // whole array, reading `[g1 // g2]` as the choice of `[g1]` and `[g2]`.
        var ctx = ArraySeqCtx()
        var matched: Int?
        for gc in group.groupChoices {
            let end = try await seqMatchGroupChoice(gc, a, 0, &ctx)
            if end == len {
                return
            }
            if let end, end > (matched ?? -1) {
                matched = end
            }
        }

        // The array does not match. Where its items are all scalars, the
        // arity-plan walk reports what is wrong in detail; otherwise, or where
        // it finds nothing to report, the matcher's account is.
        let errorCount = errors.count
        if a.allSatisfy({ $0.isScalar }) {
            try await validateArrayGroupDetail(group, a)
        }
        if errors.count == errorCount {
            let stoppedAt = matched ?? 0
            if let (idx, recorded) = ctx.bestFailure, idx >= stoppedAt, !recorded.isEmpty {
                ctx.bestFailure = nil
                errors.append(contentsOf: recorded)
            } else if let end = matched {
                addError(
                    "array validation failed: group \(group) matched the first \(end) item(s), but the array has \(len) items"
                )
            } else {
                addError("array validation failed: item sequence does not match group \(group)")
            }
        }
    }

    /// Resolves a generic rule reference (`name<args>`), `&name<args>` or
    /// `~name<args>` against the value already held, on a level of its own.
    private func visitGenericReference(
        _ ident: Identifier,
        _ rule: Rule,
        _ ga: GenericArgs,
        groupToChoice: Bool
    ) async throws(JSONValidationError) {
        let resolvedArgs = state.resolvedGenericArgs(ga)
        let genericRules = state.genericRulesForInstantiation(rule, ident.ident, resolvedArgs)
        let descentCost = try checkRuleNesting(ident)

        let level = sameItem()
        level.ruleNesting = ruleNesting + 1
        level.descentCost = descentCost
        level.state.genericRules = genericRules
        level.state.evalGenericRule = ident.ident
        if groupToChoice {
            level.state.isGroupToChoiceEnum = true
        }
        level.state.isMultiTypeChoice = state.isMultiTypeChoice
        try await level.walk(.rule(rule))

        errors.append(contentsOf: level.errors)
        adoptMatchedMapKeys(level)
    }

    private func visitChoiceFromGroup(_ ident: Identifier, _ genericArgs: GenericArgs?) async throws(JSONValidationError) {
        if let ga = genericArgs, let rule = ruleFromIdent(state.schema, ident) {
            try await visitGenericReference(ident, rule, ga, groupToChoice: true)
            return
        }

        if groupRuleFromIdent(state.schema, ident) == nil {
            addError("rule \(ident) must be a group rule to turn it into a choice")
            return
        }

        state.isGroupToChoiceEnum = true
        try await visitIdentifier(ident)
        state.isGroupToChoiceEnum = false
    }

    private func visitTypename(_ ident: Identifier, _ genericArgs: GenericArgs?) async throws(JSONValidationError) {
        if let ga = genericArgs, let rule = ruleFromIdent(state.schema, ident) {
            try await visitGenericReference(ident, rule, ga, groupToChoice: false)
            return
        }

        // A name extended by `/=` stands for the choice of its definition and
        // the alternatives, evaluated where the name is resolved.
        if !typeChoiceAlternatesFromIdent(state.schema, ident).isEmpty {
            state.isMultiTypeChoice = true
        }

        try await visitIdentifier(ident)
    }

    private func visitUnwrap(_ ident: Identifier, _ genericArgs: GenericArgs?) async throws(JSONValidationError) {
        // An unwrapped prelude tag name stands for the type the tag encloses.
        if case .taggedData(_, let t, _, _, _)? = tagFromToken(lookupIdent(ident.ident)) {
            try await visitType(t)
            return
        }

        if let ga = genericArgs, let rule = unwrapRuleFromIdent(state.schema, ident) {
            try await visitGenericReference(ident, rule, ga, groupToChoice: false)
            return
        }

        // The rule an unwrapped name resolves to is matched against the value
        // already held, so the reference is a hop like a type name's.
        if let rule = unwrapRuleFromIdent(state.schema, ident) {
            try await visitRuleAgainstItem(ident, rule)
            return
        }

        addError("cannot unwrap identifier \(ident), rule not found")
    }
}
