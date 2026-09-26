import Foundation

// The map matcher (RFC 8610 Appendix C) and the array sequence matcher
// (RFC 8610 Appendix A), which decide whether an object or an array matches
// its type; where one does not, the entry walk reports what is wrong in
// detail.

extension JSONLevel {
    // MARK: Map matcher
    //
    // A map is matched by assigning its physical key/value pairs to the entries
    // of the group:
    // 1. entries are matched in order against the pairs not yet claimed, and a
    //    claim is by physical pair index, never by key equality;
    // 2. an entry standing for a run of pairs (`*`, `+`, `n*m`) greedily claims
    //    the complete pairs (key and value) it admits, up to its upper bound;
    // 3. an entry standing for a single pair claims the first pair whose key it
    //    admits; if that pair's value fails, the single claims made so far are
    //    reassigned (maximum bipartite matching) so that each keeps a distinct
    //    pair it admits in full; failing that, an optional entry without a cut
    //    leaves the pair for later entries (RFC 8610 Section 3.5.4) and
    //    anything else fails;
    // 4. a group spliced into the map (inline, named, generic) shares the
    //    ledger; its group choices are prioritized choice, and an occurrence on
    //    it repeats it greedily;
    // 5. an alternative of the map's own group matches only once every pair is
    //    claimed.

    /// Records a failure of the map matcher at the map itself.
    private func mapNoteFailure(_ ctx: inout MapMatchCtx, _ reason: String) {
        let errorCount = errors.count
        addError(reason)
        ctx.errors = Array(errors[errorCount...])
        errors.removeLast(errors.count - errorCount)
    }

    /// Matches a group spliced into a map: prioritized choice over its choices.
    private func mapMatchGroup(
        _ group: Group,
        _ entries: [(key: String, value: JSONNode)],
        _ claims: inout MapClaims,
        _ ctx: inout MapMatchCtx
    ) async throws(JSONValidationError) -> Bool {
        for gc in group.groupChoices {
            var trial = claims
            if try await mapMatchGroupChoice(gc, entries, &trial, &ctx) {
                claims = trial
                return true
            }
        }
        return false
    }

    /// Matches the entries of one alternative of a map's own group, in order;
    /// a failing entry does not end the walk, so that every entry the map fails
    /// is reported.
    func mapMatchTopGroupChoice(
        _ gc: GroupChoice,
        _ entries: [(key: String, value: JSONNode)],
        _ claims: inout MapClaims,
        _ ctx: inout MapMatchCtx
    ) async throws(JSONValidationError) -> Bool {
        var matched = true
        var collected: [ErrorRecord] = []
        for (entry, _) in gc.groupEntries {
            if !(try await mapMatchEntry(entry, entries, &claims, &ctx)) {
                matched = false
                collected.append(contentsOf: ctx.errors)
                ctx.errors = []
            }
        }
        if !matched {
            ctx.errors = collected
        }
        return matched
    }

    /// Matches the entries of one group choice, in order.
    private func mapMatchGroupChoice(
        _ gc: GroupChoice,
        _ entries: [(key: String, value: JSONNode)],
        _ claims: inout MapClaims,
        _ ctx: inout MapMatchCtx
    ) async throws(JSONValidationError) -> Bool {
        for (entry, _) in gc.groupEntries {
            if !(try await mapMatchEntry(entry, entries, &claims, &ctx)) {
                return false
            }
        }
        return true
    }

    /// Matches one group entry of a map group.
    private func mapMatchEntry(
        _ entry: GroupEntry,
        _ entries: [(key: String, value: JSONNode)],
        _ claims: inout MapClaims,
        _ ctx: inout MapMatchCtx
    ) async throws(JSONValidationError) -> Bool {
        if case .valueMemberKey(let ge, _, _, _) = entry {
            // An unwrapped map rule contributes the referenced rule's group to
            // the map's group (RFC 8610 Section 3.7).
            if ge.memberKey == nil, ge.entryType.typeChoices.count == 1 {
                let tc = ge.entryType.typeChoices[0]
                if tc.type1.operator == nil, case .unwrap(let ident, let genericArgs, _, _) = tc.type1.type2,
                    let rule = unwrapRuleFromIdent(state.schema, ident), case .type = rule
                {
                    let (min, max) = occurrenceBounds(ge.occur?.occur)
                    var count = 0
                    while max.map({ count < $0 }) ?? true {
                        let before = claims.claimedCount
                        var trial = claims
                        if !(try await mapMatchUnwrap(ident, genericArgs, rule, entries, &trial, &ctx)) {
                            break
                        }
                        claims = trial
                        count += 1
                        if claims.claimedCount == before {
                            count = Swift.max(count, min)
                            break
                        }
                    }
                    return count >= min
                }
            }
            return try await mapMatchMember(ge, entries, &claims, &ctx)
        }

        // A group spliced into the map, under its occurrence indicator: greedy
        // repetition, where a failed iteration rewinds only itself.
        let (min, max) = occurrenceBounds(groupEntryOccur(entry))
        var count = 0
        while max.map({ count < $0 }) ?? true {
            let before = claims.claimedCount
            var trial = claims
            if !(try await mapMatchGroupOnce(entry, entries, &trial, &ctx)) {
                break
            }
            claims = trial
            count += 1
            if claims.claimedCount == before {
                // A zero-width iteration: stop to guarantee termination.
                count = Swift.max(count, min)
                break
            }
        }
        return count >= min
    }

    /// Matches one iteration of a group spliced into a map.
    private func mapMatchGroupOnce(
        _ entry: GroupEntry,
        _ entries: [(key: String, value: JSONNode)],
        _ claims: inout MapClaims,
        _ ctx: inout MapMatchCtx
    ) async throws(JSONValidationError) -> Bool {
        switch entry {
        case .inlineGroup(_, let group, _, _, _):
            return try await mapMatchGroup(group, entries, &claims, &ctx)
        case .typeGroupname(let ge, _, _, _):
            let schema = state.schema
            let grule = groupRuleFromIdent(schema, ge.name)
            let alternates = groupChoiceAlternatesFromIdent(schema, ge.name)
            if grule == nil && alternates.isEmpty {
                // An undefined group socket is an empty group (RFC 8610
                // Section 3.9).
                if ge.name.socket == .group {
                    return true
                }
                mapNoteFailure(&ctx, "\(ge.name) does not name a group, so it names no entry of a map")
                return false
            }

            let key = (ge.name.ident, claims.claimedCount)
            if ctx.activeGroupRefs.contains(where: { $0 == key }) {
                mapNoteFailure(&ctx, "rule \(ge.name) is defined in terms of itself without consuming any data")
                return false
            }
            let descentCost = try checkRuleNesting(ge.name)
            let outerDescentCost = self.descentCost
            ruleNesting += 1
            self.descentCost = descentCost
            ctx.activeGroupRefs.append(key)

            let rule = ruleFromIdent(schema, ge.name)
            let saved = seqEnterGeneric(ge.name.ident, rule, ge.genericArgs)
            defer {
                seqLeaveGeneric(saved)
                ctx.activeGroupRefs.removeLast()
                ruleNesting -= 1
                self.descentCost = outerDescentCost
            }

            // The rule's definition and each alternative `//=` adds to it are
            // the alternatives of one prioritized choice.
            var candidates: [GroupEntry] = []
            if let grule {
                candidates.append(grule.entry)
            }
            candidates.append(contentsOf: alternates)
            for alt in candidates {
                var trial = claims
                if try await mapMatchEntry(alt, entries, &trial, &ctx) {
                    claims = trial
                    return true
                }
            }
            return false
        case .valueMemberKey:
            return try await mapMatchEntry(entry, entries, &claims, &ctx)
        }
    }

    /// Matches an unwrapped map rule (RFC 8610 Section 3.7) in place: the group
    /// inside the referenced map rule is matched against the same map.
    private func mapMatchUnwrap(
        _ ident: Identifier,
        _ genericArgs: GenericArgs?,
        _ rule: Rule,
        _ entries: [(key: String, value: JSONNode)],
        _ claims: inout MapClaims,
        _ ctx: inout MapMatchCtx
    ) async throws(JSONValidationError) -> Bool {
        let key = (ident.ident, claims.claimedCount)
        if ctx.activeGroupRefs.contains(where: { $0 == key }) {
            mapNoteFailure(&ctx, "rule \(ident) is defined in terms of itself without consuming any data")
            return false
        }
        let descentCost = try checkRuleNesting(ident)
        let outerDescentCost = self.descentCost
        ruleNesting += 1
        self.descentCost = descentCost
        ctx.activeGroupRefs.append(key)

        let saved = seqEnterGeneric(ident.ident, rule, genericArgs)
        defer {
            seqLeaveGeneric(saved)
            ctx.activeGroupRefs.removeLast()
            ruleNesting -= 1
            self.descentCost = outerDescentCost
        }

        if case .type(let typeRule, _, _, _) = rule {
            for tc in typeRule.value.typeChoices {
                if case .map(let group, _, _, _) = tc.type1.type2 {
                    var trial = claims
                    if try await mapMatchGroup(group, entries, &trial, &ctx) {
                        claims = trial
                        return true
                    }
                }
            }
        }
        return false
    }

    /// Whether the name of an object member is one the entry's member key
    /// admits. A member name is a string.
    private func mapKeyAdmitted(
        _ ge: ValueMemberKeyEntry,
        _ key: String,
        _ generics: ([GenericRule], String?)?
    ) async throws(JSONValidationError) -> Bool {
        switch ge.memberKey {
        case nil, .nonMemberKey?:
            return false
        case .bareword(let ident, _, _, _)?:
            return sameText(key, ident.ident)
        case .value(let value, _, _, _)?:
            if case .text(let t) = value {
                return sameText(t, key)
            }
            return false
        case .type1(let t1, _, _, _, _, _)?:
            if t1.operator == nil {
                switch t1.type2 {
                case .textValue(let value, _):
                    return sameText(value, key)
                case .uintValue, .intValue, .floatValue, .utf8ByteString, .b16ByteString, .b64ByteString:
                    return false
                default:
                    break
                }
            }
            let saved = (state.genericRules, state.evalGenericRule)
            if let (genericRules, evalGenericRule) = generics {
                state.genericRules = genericRules
                state.evalGenericRule = evalGenericRule
            }
            defer {
                if generics != nil {
                    state.genericRules = saved.0
                    state.evalGenericRule = saved.1
                }
            }
            return try await keyAdmitted(key, .type1(t1))
        }
    }

    /// Whether the value of an object member is one the entry's type admits,
    /// with what it reported when it is not.
    private func mapValueAdmitted(
        _ ge: ValueMemberKeyEntry,
        _ key: String,
        _ value: JSONNode,
        _ generics: ([GenericRule], String?)?
    ) async throws(JSONValidationError) -> (Bool, [ErrorRecord]) {
        let level = try childAt(value, .key(key))
        level.state.isMultiTypeChoice = state.isMultiTypeChoice
        level.state.isMultiGroupChoice = state.isMultiGroupChoice
        if let (genericRules, evalGenericRule) = generics {
            level.state.genericRules = genericRules
            level.state.evalGenericRule = evalGenericRule
        }
        try await level.walk(.type(ge.entryType))

        var recorded = level.errors
        level.errors = []
        recorded.append(contentsOf: level.takeUnvalidatedItemErrors())
        return (recorded.isEmpty, recorded)
    }

    /// Matches a value member key entry against the pairs not yet claimed.
    private func mapMatchMember(
        _ ge: ValueMemberKeyEntry,
        _ entries: [(key: String, value: JSONNode)],
        _ claims: inout MapClaims,
        _ ctx: inout MapMatchCtx
    ) async throws(JSONValidationError) -> Bool {
        guard let memberKey = ge.memberKey else {
            mapNoteFailure(&ctx, "an entry of a map needs a member key, got \(ge.entryType)")
            return false
        }
        let keyDesc = trimmingJSONKeyDelimiters(memberKey.description)
        let occur = ge.occur?.occur
        let (min, max) = occurrenceBounds(occur)
        let cut = memberKeyHasCut(ge)

        // A member key whose bounds are of different kinds denotes no set of
        // keys.
        if case .type1(let t1, _, _, _, _, _) = memberKey,
            let (lower, upper, _) = memberKeyRange(state, t1, limits.maxRuleNesting),
            case .success(let l) = resolveBound(lower), case .success(let u) = resolveBound(upper)
        {
            switch (l, u) {
            case (.int, .float), (.float, .int):
                mapNoteFailure(
                    &ctx,
                    "invalid cddl range. upper and lower values must both be integers or both be floats. got \(l) and \(u)"
                )
                return false
            default:
                break
            }
        }

        if occurrenceCoversMany(occur) {
            var count = 0
            var valueErrors: [ErrorRecord] = []
            for idx in entries.indices {
                if let max, count >= max {
                    break
                }
                if claims.claimed[idx] {
                    continue
                }
                let (k, v) = entries[idx]
                if !(try await mapKeyAdmitted(ge, k, nil)) {
                    continue
                }
                let (ok, recorded) = try await mapValueAdmitted(ge, k, v, nil)
                if ok {
                    claims.claimed[idx] = true
                    count += 1
                } else if cut {
                    ctx.errors = recorded
                    return false
                } else {
                    if valueErrors.isEmpty {
                        valueErrors = recorded
                    }
                    if ctx.pairFailures[idx] == nil {
                        ctx.pairFailures[idx] = recorded
                    }
                }
            }

            if let reason = memberKeyCountError(.json, occur, count, keyDesc), count < min {
                mapNoteFailure(&ctx, reason)
                ctx.errors = valueErrors + ctx.errors
                return false
            }
            return true
        }

        // A single occurrence: the first pair whose key the entry admits.
        var candidates: [Int] = []
        for idx in entries.indices where !claims.claimed[idx] {
            if try await mapKeyAdmitted(ge, entries[idx].key, nil) {
                candidates.append(idx)
            }
        }

        guard let first = candidates.first else {
            if min == 0 {
                return true
            }
            mapNoteFailure(&ctx, "object requires entry with key \(keyDesc)")
            return false
        }

        let generics = (state.genericRules, state.evalGenericRule)
        let (k, v) = entries[first]
        let (ok, recorded) = try await mapValueAdmitted(ge, k, v, nil)
        if ok {
            claims.claimed[first] = true
            claims.singles.append(
                MapSingleClaim(entry: ge, genericRules: generics.0, evalGenericRule: generics.1, pair: first))
            return true
        }

        // The value of the pair the key selected fails. Another one-to-one
        // assignment of the single claims may still hold.
        let current = MapSingleClaim(entry: ge, genericRules: generics.0, evalGenericRule: generics.1, pair: first)
        if try await mapReassignSingles(current, candidates, entries, &claims) {
            return true
        }

        // An optional entry without a cut matches a complete pair, not the key
        // alone (RFC 8610 Section 3.5.4): the pair is left for a later entry.
        if min == 0 && !cut {
            if ctx.pairFailures[first] == nil {
                ctx.pairFailures[first] = recorded
            }
            ctx.declinedPairs.insert(first)
            return true
        }

        ctx.errors = recorded
        return false
    }

    /// Reassigns the single claims, together with `current`, so that each holds
    /// a distinct pair it admits in full. Commits only a complete assignment.
    private func mapReassignSingles(
        _ current: MapSingleClaim,
        _ candidates: [Int],
        _ entries: [(key: String, value: JSONNode)],
        _ claims: inout MapClaims
    ) async throws(JSONValidationError) -> Bool {
        if claims.singles.isEmpty && candidates.count < 2 {
            return false
        }

        var pairs = claims.singles.map(\.pair)
        for c in candidates where !pairs.contains(c) {
            pairs.append(c)
        }

        var members = claims.singles
        members.append(current)
        let currentSlot = members.count - 1

        var compatibility = [[Bool]](repeating: [Bool](repeating: false, count: pairs.count), count: members.count)
        for (m, member) in members.enumerated() {
            let generics = (member.genericRules, member.evalGenericRule)
            for (p, pair) in pairs.enumerated() {
                if m != currentSlot && member.pair == pair {
                    compatibility[m][p] = true
                    continue
                }
                if m == currentSlot && pair == member.pair {
                    continue
                }
                let (k, v) = entries[pair]
                if !(try await mapKeyAdmitted(member.entry, k, generics)) {
                    continue
                }
                compatibility[m][p] = try await mapValueAdmitted(member.entry, k, v, generics).0
            }
        }

        var owners = [Int?](repeating: nil, count: pairs.count)
        for m in members.indices {
            var visited = [Bool](repeating: false, count: pairs.count)
            if !augmentAssignment(m, compatibility, &visited, &owners) {
                return false
            }
        }

        for claim in claims.singles {
            claims.claimed[claim.pair] = false
        }
        for (p, owner) in owners.enumerated() {
            if let m = owner {
                members[m].pair = pairs[p]
                claims.claimed[pairs[p]] = true
            }
        }
        claims.singles = members
        return true
    }

    // MARK: Array sequence matcher
    //
    // Matching a group against an array is sequence matching over the array's
    // items with a cursor:
    // 1. a leaf entry consumes exactly one item;
    // 2. a group (inline, group-rule reference or unwrap) matches a
    //    subsequence;
    // 3. an occurrence indicator greedily quantifies its entry (no
    //    backtracking out of a repetition: `*a a` never matches anything);
    // 4. `//` is prioritized choice that locks in the first successful
    //    alternative.
    // Leaf checks delegate to the single-item walk on a level of their own.
    // The matcher functions return the new cursor on a match, `nil` on a
    // (silent, speculative) mismatch, and throw only for fatal errors.

    /// Matches a group against `elems[cursor...]`: prioritized choice over its
    /// choices.
    private func seqMatchGroup(_ group: Group, _ elems: [JSONNode], _ cursor: Int, _ ctx: inout ArraySeqCtx) async throws(JSONValidationError) -> Int? {
        for gc in group.groupChoices {
            if let end = try await seqMatchGroupChoice(gc, elems, cursor, &ctx) {
                return end
            }
        }
        return nil
    }

    /// Matches a single group choice: folds its entries over the cursor.
    func seqMatchGroupChoice(_ gc: GroupChoice, _ elems: [JSONNode], _ cursor: Int, _ ctx: inout ArraySeqCtx) async throws(JSONValidationError) -> Int? {
        var cur = cursor
        for (entry, _) in gc.groupEntries {
            guard let next = try await seqMatchEntry(entry, elems, cur, &ctx) else {
                return nil
            }
            cur = next
        }
        return cur
    }

    /// Matches a group entry under its occurrence indicator: greedily up to the
    /// upper bound, a failed iteration rewinding only itself, then requires the
    /// lower bound.
    private func seqMatchEntry(_ entry: GroupEntry, _ elems: [JSONNode], _ cursor: Int, _ ctx: inout ArraySeqCtx) async throws(JSONValidationError) -> Int? {
        let (min, max) = occurrenceBounds(groupEntryOccur(entry))
        var cur = cursor
        var count = 0
        while max.map({ count < $0 }) ?? true {
            guard let next = try await seqMatchEntryOnce(entry, elems, cur, &ctx) else {
                break
            }
            count += 1
            if next == cur {
                // A zero-width iteration: no further progress is possible.
                count = Swift.max(count, min)
                break
            }
            cur = next
        }
        return count >= min ? cur : nil
    }

    /// Matches a single iteration of a group entry, ignoring its occurrence
    /// indicator.
    private func seqMatchEntryOnce(_ entry: GroupEntry, _ elems: [JSONNode], _ cursor: Int, _ ctx: inout ArraySeqCtx) async throws(JSONValidationError) -> Int? {
        switch entry {
        case .inlineGroup(_, let group, _, _, _):
            return try await seqMatchGroup(group, elems, cursor, &ctx)
        case .typeGroupname(let ge, _, _, _):
            let schema = state.schema
            let grule = groupRuleFromIdent(schema, ge.name)
            let alternates = groupChoiceAlternatesFromIdent(schema, ge.name)
            if grule != nil || !alternates.isEmpty {
                return try await seqMatchGroupRef(ge, grule, alternates, elems, cursor, &ctx)
            }

            // A leaf: one item against the named type.
            let walk: Walk
            if ge.genericArgs != nil {
                walk = .type2(.typename(ident: ge.name, genericArgs: ge.genericArgs, span: ge.name.span))
            } else {
                // A type rule named as an entry for a single item is resolved by
                // stepping into the item, so it costs no rule reference; an entry
                // standing for a run resolves the name against each item.
                let coversMany = occurrenceCoversMany(ge.occur?.occur)
                let isGenericParam =
                    state.evalGenericRule.map { name in
                        state.genericRules.contains { $0.name == name && $0.params.contains(ge.name.ident) }
                    } ?? false
                if let r = ruleOrSocketFromIdent(schema, ge.name), case .type = r, !isGenericParam, !coversMany,
                    !state.isColonShortcutPresent
                {
                    walk = .rule(r)
                } else {
                    walk = .identifier(ge.name)
                }
            }
            return try await seqMatchLeaf(elems, cursor, &ctx, walk)
        case .valueMemberKey(let ge, _, _, _):
            // An unwrapped array or map rule contributes the referenced rule's
            // group as a subsequence (RFC 8610 Section 3.7).
            if ge.entryType.typeChoices.count == 1 {
                let tc = ge.entryType.typeChoices[0]
                if tc.type1.operator == nil, case .unwrap(let ident, let genericArgs, _, _) = tc.type1.type2,
                    let rule = unwrapRuleFromIdent(state.schema, ident), case .type(let typeRule, _, _, _) = rule,
                    typeRule.value.typeChoices.contains(where: { tc in
                        switch tc.type1.type2 {
                        case .array, .map: return true
                        default: return false
                        }
                    })
                {
                    return try await seqMatchUnwrap(ident, genericArgs, rule, elems, cursor, &ctx)
                }
            }
            // A leaf: member keys are annotation only in an array.
            return try await seqMatchLeaf(elems, cursor, &ctx, .type(ge.entryType))
        }
    }

    /// Records, as the matcher's failure at `cursor`, a rule reference that
    /// re-enters itself without consuming any item.
    private func seqNoteSelfReference(_ ident: Identifier, _ cursor: Int, _ ctx: inout ArraySeqCtx) {
        let errorCount = errors.count
        addError("rule \(ident) is defined in terms of itself without consuming any data")
        let recorded = Array(errors[errorCount...])
        errors.removeLast(errors.count - errorCount)
        ctx.noteFailure(cursor, recorded)
    }

    /// Instantiates a generic rule reference for the matcher, returning the
    /// state to restore afterwards.
    func seqEnterGeneric(_ name: String, _ rule: Rule?, _ genericArgs: GenericArgs?) -> (String?, [GenericRule]?) {
        let previousEval = state.evalGenericRule
        var previousRules: [GenericRule]?
        if let ga = genericArgs, let rule {
            let resolvedArgs = state.resolvedGenericArgs(ga)
            let genericRules = state.genericRulesForInstantiation(rule, name, resolvedArgs)
            previousRules = state.genericRules
            state.genericRules = genericRules
            state.evalGenericRule = name
        }
        return (previousEval, previousRules)
    }

    func seqLeaveGeneric(_ saved: (String?, [GenericRule]?)) {
        state.evalGenericRule = saved.0
        if let previous = saved.1 {
            state.genericRules = previous
        }
    }

    /// Matches a group-rule reference (possibly generic, possibly with `//=`
    /// alternatives) as a subsequence.
    private func seqMatchGroupRef(
        _ ge: TypeGroupnameEntry,
        _ grule: GroupRule?,
        _ alternates: [GroupEntry],
        _ elems: [JSONNode],
        _ cursor: Int,
        _ ctx: inout ArraySeqCtx
    ) async throws(JSONValidationError) -> Int? {
        let key = (ge.name.ident, cursor)
        if ctx.activeGroupRefs.contains(where: { $0 == key }) {
            seqNoteSelfReference(ge.name, cursor, &ctx)
            return nil
        }
        let descentCost = try checkRuleNesting(ge.name)
        let outerDescentCost = self.descentCost
        ruleNesting += 1
        self.descentCost = descentCost
        ctx.activeGroupRefs.append(key)

        let rule = ruleFromIdent(state.schema, ge.name)
        let saved = seqEnterGeneric(ge.name.ident, rule, ge.genericArgs)
        defer {
            seqLeaveGeneric(saved)
            ctx.activeGroupRefs.removeLast()
            ruleNesting -= 1
            self.descentCost = outerDescentCost
        }

        if let grule, let end = try await seqMatchEntry(grule.entry, elems, cursor, &ctx) {
            return end
        }
        for alt in alternates {
            if let end = try await seqMatchEntry(alt, elems, cursor, &ctx) {
                return end
            }
        }
        return nil
    }

    /// Matches an unwrapped rule (RFC 8610 Section 3.7) as a subsequence: the
    /// group inside the referenced array or map rule is matched in place.
    private func seqMatchUnwrap(
        _ ident: Identifier,
        _ genericArgs: GenericArgs?,
        _ rule: Rule,
        _ elems: [JSONNode],
        _ cursor: Int,
        _ ctx: inout ArraySeqCtx
    ) async throws(JSONValidationError) -> Int? {
        let key = (ident.ident, cursor)
        if ctx.activeGroupRefs.contains(where: { $0 == key }) {
            seqNoteSelfReference(ident, cursor, &ctx)
            return nil
        }
        let descentCost = try checkRuleNesting(ident)
        let outerDescentCost = self.descentCost
        ruleNesting += 1
        self.descentCost = descentCost
        ctx.activeGroupRefs.append(key)

        let saved = seqEnterGeneric(ident.ident, rule, genericArgs)
        defer {
            seqLeaveGeneric(saved)
            ctx.activeGroupRefs.removeLast()
            ruleNesting -= 1
            self.descentCost = outerDescentCost
        }

        if case .type(let typeRule, _, _, _) = rule {
            for tc in typeRule.value.typeChoices {
                switch tc.type1.type2 {
                case .array(let group, _, _, _), .map(let group, _, _, _):
                    if let end = try await seqMatchGroup(group, elems, cursor, &ctx) {
                        return end
                    }
                default:
                    break
                }
            }
        }
        return nil
    }

    /// Validates `elems[cursor]` against a leaf entry on a level of its own.
    /// Failures are silent: recorded in the context for later reporting.
    private func seqMatchLeaf(_ elems: [JSONNode], _ cursor: Int, _ ctx: inout ArraySeqCtx, _ walk: Walk) async throws(JSONValidationError) -> Int? {
        guard cursor < elems.count else {
            return nil
        }
        let level = try childAt(elems[cursor], .index(cursor))
        level.state.ctrl = state.ctrl
        try await level.walk(walk)

        var recorded = level.errors
        level.errors = []
        recorded.append(contentsOf: level.takeUnvalidatedItemErrors())
        if recorded.isEmpty {
            return cursor + 1
        }
        ctx.noteFailure(cursor, recorded)
        return nil
    }

    // MARK: Array items

    /// Validates the items of the array this level holds against `token`, the
    /// items an entry answers for.
    func validateArrayItems(_ token: JSONItemToken) async throws(JSONValidationError) {
        guard case .array(let array) = item else { return }
        let a = array.items

        // Member keys are annotation only in an array.
        if state.isMemberKey {
            return
        }

        // Where the run of items the entry accounts for is known, the entry
        // answers for exactly that run, and for nothing outside it.
        let offset: Int
        let end: Int
        var placedCounts: [EntryCount]?
        if let frame = state.arrayFrame, frame.len == a.count {
            offset = Swift.min(frame.cursor, a.count)
            end = Swift.min(frame.cursor + frame.budget, a.count)
            placedCounts = [EntryCount(count: UInt64(frame.budget), entryOccurrence: nil)]
        } else if state.occurrence != nil {
            offset = Swift.min(state.groupEntryIdx ?? 0, a.count)
            end = a.count
        } else {
            offset = 0
            end = a.count
        }
        let covered = a[offset..<end]

        switch validateArrayOccurrence(state.occurrence, placedCounts ?? state.entryCounts, covered.count) {
        case .failure(let failure):
            for e in failure.messages {
                addError(e)
            }
        case .success((let iterItems, let allowEmptyArray)):
            if iterItems {
                for (coveredIdx, v) in covered.enumerated() {
                    let idx = offset + coveredIdx
                    if let indices = state.validArrayItems, state.isMultiTypeChoice, indices.contains(idx) {
                        continue
                    }

                    let level = try await walkItem(v, idx, token)

                    if state.isMultiTypeChoice && level.errors.isEmpty {
                        if state.validArrayItems == nil {
                            state.validArrayItems = [idx]
                        } else {
                            state.validArrayItems!.append(idx)
                        }
                        continue
                    }

                    appendArrayErrors(idx, level.errors)
                }
            } else if let idx = state.groupEntryIdx {
                if idx < a.count {
                    let level = try await walkItem(a[idx], idx, token)
                    errors.append(contentsOf: level.errors)
                } else if !allowEmptyArray {
                    addError(token.errorMessage(idx))
                }
            } else if !state.isMultiTypeChoice || state.entryCounts == nil {
                // Outside an array group the array cannot be matched item by
                // item against this token; the array itself does not match.
                addError("\(token.errorMessage(nil)), got \(item.elidedRendering)")
            }
        }
    }

    /// Walks the item at `idx` of the array this level holds against what
    /// `token` holds each item to, on a level of its own.
    private func walkItem(_ value: JSONNode, _ idx: Int, _ token: JSONItemToken) async throws(JSONValidationError) -> JSONLevel {
        let level = try childAt(value, .index(idx))
        level.state.isMultiTypeChoice = state.isMultiTypeChoice
        level.state.ctrl = state.ctrl
        switch token.walk {
        case .success(let walk):
            try await level.walk(walk)
        case .failure(let failure):
            level.addError(failure.reason)
        }
        return level
    }
}

/// A member key's rendering without the delimiters that follow the key.
private func trimmingJSONKeyDelimiters(_ text: String) -> String {
    var scalars = text.unicodeScalars[...]
    while let last = scalars.last, last == " " || last == ":" || last == "=" || last == ">" || last == "^" {
        scalars = scalars.dropLast()
    }
    return String(String.UnicodeScalarView(scalars))
}
