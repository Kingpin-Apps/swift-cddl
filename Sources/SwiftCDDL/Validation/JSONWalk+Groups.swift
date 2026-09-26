import Foundation

// Rules, types, groups and group entries walked against a JSON value
// (RFC 8610 Sections 2 and 3).

extension JSONLevel {
    /// Walks `walk` against the item this level holds.
    func walk(_ walk: Walk) async throws(JSONValidationError) {
        switch walk {
        case .root:
            try await walkRoot()
        case .rule(let rule):
            try await visitRule(rule)
        case .type(let t):
            try await visitType(t)
        case .typeChoice(let tc):
            try await visitTypeChoice(tc)
        case .type1(let t1):
            try await visitType1(t1)
        case .type2(let t2):
            try await visitType2(t2)
        case .group(let g):
            try await visitGroup(g)
        case .identifier(let ident):
            try await visitIdentifier(ident)
        case .value(let value):
            try await visitValue(value)
        case .range(let lower, let upper, let isInclusive):
            try await visitRange(lower, upper, isInclusive)
        case .control(let target, let ctrl, let controller):
            try await visitControlOperator(target, ctrl, controller)
        }
    }

    /// Walks the root rule: the one named as the root, or the first type rule
    /// of the schema that takes no generic parameters (RFC 8610 Section 3.1).
    private func walkRoot() async throws(JSONValidationError) {
        if let name = state.rootRule {
            let root = state.schema.cddl.rules.lazy.compactMap { rule -> TypeRule? in
                if case .type(let rule, _, _, _) = rule, rule.name.ident == name, !rule.isTypeChoiceAlternate,
                    rule.genericParams == nil
                {
                    return rule
                }
                return nil
            }.first
            if let rule = root {
                state.isRoot = true
                try await visitTypeRule(rule)
                state.isRoot = false
            } else {
                addError("the schema defines no non-generic type rule named \(name)")
            }
            return
        }

        for rule in state.schema.cddl.rules {
            if case .type(let rule, _, _, _) = rule, rule.genericParams == nil {
                state.isRoot = true
                try await visitTypeRule(rule)
                state.isRoot = false
                break
            }
        }
    }

    func visitRule(_ rule: Rule) async throws(JSONValidationError) {
        switch rule {
        case .type(let rule, _, _, _): try await visitTypeRule(rule)
        case .group(let rule, _, _, _): try await visitGroupRule(rule)
        }
    }

    func visitTypeChoice(_ tc: TypeChoice) async throws(JSONValidationError) {
        try await visitType1(tc.type1)
    }

    func visitType1(_ t1: Type1) async throws(JSONValidationError) {
        if let op = t1.operator {
            switch op.operator {
            case .rangeOp(let isInclusive, _):
                try await visitRange(t1.type2, op.type2, isInclusive)
            case .ctlOp(let ctrl, _):
                try await visitControlOperator(t1.type2, ctrl, op.type2)
            }
            return
        }
        try await visitType2(t1.type2)
    }

    func visitGroupEntry(_ entry: GroupEntry) async throws(JSONValidationError) {
        switch entry {
        case .valueMemberKey(let ge, _, _, _):
            try await visitValueMemberKeyEntry(ge)
        case .typeGroupname(let ge, _, _, _):
            try await visitTypeGroupnameEntry(ge)
        case .inlineGroup(let occur, let group, _, _, _):
            if let occur {
                visitOccurrence(occur)
            }
            try await visitGroup(group)
        }
    }

    func visitNonMemberKey(_ nmk: NonMemberKey) async throws(JSONValidationError) {
        switch nmk {
        case .group(let group): try await visitGroup(group)
        case .type(let t): try await visitType(t)
        }
    }

    func visitOccurrence(_ o: Occurrence) {
        state.occurrence = o.occur
    }

    func visitTypeRule(_ tr: TypeRule) async throws(JSONValidationError) {
        if let gp = tr.genericParams {
            let params = gp.params.map(\.param.ident)
            if let idx = state.genericRules.firstIndex(where: { $0.name == tr.name.ident }) {
                state.genericRules[idx].params = params
            } else {
                state.genericRules.append(GenericRule(name: tr.name.ident, params: params, args: []))
            }
        }

        // A generic parameter is in scope in the rule that declares it and
        // nowhere else (RFC 8610 Section 3.10).
        let enclosingGenericRule = state.evalGenericRule
        state.evalGenericRule = tr.genericParams != nil ? tr.name.ident : nil
        defer { state.evalGenericRule = enclosingGenericRule }

        try await typeRuleBody(tr)
    }

    func visitGroupRule(_ gr: GroupRule) async throws(JSONValidationError) {
        if let gp = gr.genericParams {
            let params = gp.params.map(\.param.ident)
            if let idx = state.genericRules.firstIndex(where: { $0.name == gr.name.ident }) {
                state.genericRules[idx].params = params
            } else {
                state.genericRules.append(GenericRule(name: gr.name.ident, params: params, args: []))
            }
        }

        let enclosingGenericRule = state.evalGenericRule
        state.evalGenericRule = gr.genericParams != nil ? gr.name.ident : nil
        defer { state.evalGenericRule = enclosingGenericRule }

        try await groupRuleBody(gr)
    }

    /// The body of a type rule, evaluated with the rule's own generic
    /// parameters in scope. A rule extended by `/=` is evaluated as the one type
    /// its definition and alternatives make together (RFC 8610 Section 3.9).
    private func typeRuleBody(_ tr: TypeRule) async throws(JSONValidationError) {
        let alternates = typeChoiceAlternatesFromIdent(state.schema, tr.name)
        if !alternates.isEmpty {
            state.isMultiTypeChoice = true
            if item.isArray {
                state.isMultiTypeChoiceTypeRuleValidatingArray = true
            }
            let own = tr.isTypeChoiceAlternate ? nil : tr.value
            try await visitType(extendedType(own, alternates))
            return
        }

        if tr.value.typeChoices.count > 1 && item.isArray {
            state.isMultiTypeChoiceTypeRuleValidatingArray = true
        }

        try await visitType(tr.value)
    }

    /// The body of a group rule: its definition and each alternative `//=`
    /// adds to it are alternatives of one choice.
    private func groupRuleBody(_ gr: GroupRule) async throws(JSONValidationError) {
        let alternates = groupChoiceAlternatesFromIdent(state.schema, gr.name)
        let hasAlternates = !alternates.isEmpty
        if hasAlternates {
            state.isMultiGroupChoice = true
        }

        let errorCount = errors.count
        let saved = hasAlternates ? alternativeState() : nil
        let baselineItemErrors = unvalidatedItemErrorCount()

        for ge in alternates {
            if let saved {
                restoreAlternativeState(saved)
            }
            let curErrors = errors.count
            try await visitGroupEntry(ge)
            if errors.count == curErrors && unvalidatedItemErrorCount() <= baselineItemErrors {
                errors.removeLast(errors.count - errorCount)
                return
            }
        }

        if let saved {
            restoreAlternativeState(saved)
        }

        let curErrors = errors.count
        try await visitGroupEntry(gr.entry)
        if hasAlternates && errors.count == curErrors && unvalidatedItemErrorCount() <= baselineItemErrors {
            errors.removeLast(curErrors - errorCount)
        }
    }

    // MARK: Types

    func visitType(_ t: Type) async throws(JSONValidationError) {
        // An array type written where a group entry stands for items of the
        // array being walked describes each of those items.
        if item.isArray && state.groupEntryIdx != nil {
            let namesArray = t.typeChoices.contains { tc in
                if case .array = tc.type1.type2 { return true }
                return false
            }
            if namesArray {
                try await validateArrayItems(.type(t))
                return
            }
        }

        if t.typeChoices.count > 1 {
            state.isMultiTypeChoice = true
        }

        let initialErrorCount = errors.count
        let descentCostBeforeChoice = descentCost
        var choiceValidationSucceeded = false

        // An entry standing for a run of items holds each item of the run to
        // its type: the alternatives are walked over the run in turn on this
        // level, each marking the items it admits.
        let itemWise =
            item.isArray && !state.isMultiTypeChoiceTypeRuleValidatingArray
            && occurrenceCoversMany(state.occurrence)

        for typeChoice in t.typeChoices {
            if itemWise {
                let errorCount = errors.count
                try await visitTypeChoice(typeChoice)

                if errors.count > errorCount {
                    var recorded = Array(errors[errorCount...])
                    errors.removeLast(errors.count - errorCount)
                    retainWithinReport(&recorded, paths, limits.maxReportBytes)
                    switch chargeDescent(descentCost, heldBytes(recorded), limits.maxDescentCost) {
                    case .success(let cost): descentCost = cost
                    case .failure(let reason): throw limitError(reason.reason)
                    }
                    errors.append(contentsOf: recorded)
                }

                if errors.count == errorCount && !state.hasFeatureErrors && state.disabledFeatures == nil {
                    errors.removeLast(errors.count - initialErrorCount)
                    descentCost = descentCostBeforeChoice
                    choiceValidationSucceeded = true
                }
                continue
            }

            // A lone choice is not an alternative to anything.
            if t.typeChoices.count == 1 {
                try await visitTypeChoice(typeChoice)
                return
            }

            let (choiceLevel, lent) = lendToChoice()
            let result: Result<Void, JSONValidationError>
            do {
                try await choiceLevel.visitTypeChoice(typeChoice)
                result = .success(())
            } catch {
                result = .failure(error)
            }
            reclaimFromChoice(lent)
            try result.get()

            var itemErrors = choiceLevel.takeUnvalidatedItemErrors()

            if choiceLevel.errors.isEmpty && itemErrors.isEmpty {
                if state.isMemberKey {
                    if choiceLevel.valuesToValidate != nil {
                        valuesToValidate = choiceLevel.valuesToValidate
                        choiceLevel.valuesToValidate = nil
                    }
                    if choiceLevel.objectValue != nil {
                        objectValue = choiceLevel.objectValue
                        choiceLevel.objectValue = nil
                    }
                    if choiceLevel.validatedKeys != nil {
                        validatedKeys = choiceLevel.validatedKeys
                        choiceLevel.validatedKeys = nil
                    }
                }

                if !choiceLevel.state.hasFeatureErrors || choiceLevel.state.disabledFeatures != nil {
                    errors.removeLast(errors.count - initialErrorCount)
                    descentCost = descentCostBeforeChoice
                    return
                }
            } else {
                var retained = choiceLevel.errors
                retained.append(contentsOf: itemErrors)
                itemErrors = []
                retainWithinReport(&retained, paths, limits.maxReportBytes)
                switch chargeDescent(descentCost, heldBytes(retained), limits.maxDescentCost) {
                case .success(let cost): descentCost = cost
                case .failure(let reason): throw limitError(reason.reason)
                }
                errors.append(contentsOf: retained)
            }
        }

        if choiceValidationSucceeded {
            errors.removeLast(errors.count - initialErrorCount)
            descentCost = descentCostBeforeChoice
        }
    }

    // MARK: Groups

    func visitGroup(_ g: Group) async throws(JSONValidationError) {
        if g.groupChoices.count > 1 {
            state.isMultiGroupChoice = true
        }

        // Map equality and inequality.
        if state.isCtrlMapEquality, let ctrl = state.ctrl, case .object(let o) = item {
            let entryCounts = entryCountsFromGroup(state.schema, g)
            let len = o.entries.count
            if ctrl == .eq || ctrl == .ne {
                if !validateEntryCount(entryCounts, len) {
                    for ec in entryCounts {
                        addError(mapEntryCountError(.json, ctrl, ec, len))
                    }
                    return
                }
            }
        }

        state.isCtrlMapEquality = false

        try await visitGroupChoices(g, false)
    }

    /// Evaluates the alternatives of a group, accepting the first that
    /// validates. `perChoiceArity` says that the entry counts in effect were
    /// derived from this very group.
    func visitGroupChoices(_ g: Group, _ perChoiceArity: Bool) async throws(JSONValidationError) {
        let restore = state.matchingOneOfSeveral
        state.matchingOneOfSeveral = state.matchingOneOfSeveral || g.groupChoices.count > 1
        defer { state.matchingOneOfSeveral = restore }
        try await visitGroupChoicesInner(g, perChoiceArity)
    }

    private func visitGroupChoicesInner(_ g: Group, _ perChoiceArity: Bool) async throws(JSONValidationError) {
        let initialErrorCount = errors.count
        let hasAlternatives = g.groupChoices.count > 1

        // A choice under an occurrence indicator covering more than one
        // occurrence stands for a run of matches, each looked for on its own.
        if hasAlternatives && item.isObject && occurrenceCoversMany(state.occurrence) {
            try await visitRepeatedMapGroupChoices(g)
            return
        }

        let saved = hasAlternatives ? alternativeState() : nil
        let baselineItemErrors = unvalidatedItemErrorCount()

        for groupChoice in g.groupChoices {
            if let saved {
                restoreAlternativeState(saved)
                if perChoiceArity && state.arrayFrame == nil {
                    state.entryCounts = entryCountsFromGroupChoice(state.schema, groupChoice)
                }
            }

            let errorCount = errors.count
            try await visitGroupChoice(groupChoice)
            if errors.count == errorCount && unvalidatedItemErrorCount() <= baselineItemErrors {
                errors.removeLast(errors.count - initialErrorCount)
                return
            }
        }
    }

    /// Number of members of the object being validated whose name an entry
    /// walked so far has matched.
    private func matchedMapKeyCount() -> Int {
        guard case .object(let o) = item, let keys = validatedKeys else { return 0 }
        return o.entries.filter { containsName(keys, $0.key) }.count
    }

    /// Matches the alternatives of a group against an object as many times as they
    /// go; a round that matches no further entry ends the run.
    private func visitRepeatedMapGroupChoices(_ g: Group) async throws(JSONValidationError) {
        let initialErrorCount = errors.count
        var matchedRounds = 0

        while true {
            let roundState = alternativeState()
            let matchedBefore = matchedMapKeyCount()
            var matchedThisRound = false

            for groupChoice in g.groupChoices {
                restoreAlternativeState(roundState)
                let errorCount = errors.count
                try await visitGroupChoice(groupChoice)
                if errors.count == errorCount && matchedMapKeyCount() > matchedBefore {
                    matchedThisRound = true
                    break
                }
            }

            if !matchedThisRound {
                restoreAlternativeState(roundState)
                break
            }
            matchedRounds += 1
        }

        errors.removeLast(errors.count - initialErrorCount)

        if validatedKeys == nil {
            validatedKeys = []
        }

        if matchedRounds == 0 && !occurrenceAdmitsAbsence(state.occurrence) {
            addError("group must match at least once")
        }
    }

    func visitGroupChoice(_ gc: GroupChoice) async throws(JSONValidationError) {
        if state.isGroupToChoiceEnum {
            let initialErrorCount = errors.count
            let typeChoices = typeChoicesFromGroupChoice(state.schema, gc)
            let saved = typeChoices.count > 1 ? alternativeState() : nil

            for tc in typeChoices {
                if let saved {
                    restoreAlternativeState(saved)
                }
                let errorCount = errors.count
                // Each type choice is validated as the type it is, so a group
                // nested inside it is not turned into a choice again.
                let previous = state.isGroupToChoiceEnum
                state.isGroupToChoiceEnum = false
                var failure: JSONValidationError?
                do {
                    try await visitTypeChoice(tc)
                } catch {
                    failure = error
                }
                for index in errorCount..<errors.count {
                    errors[index].isGroupToChoiceEnum = true
                }
                if case .validation(var issues)? = failure {
                    for index in issues.indices {
                        issues[index].isGroupToChoiceEnum = true
                    }
                    failure = .validation(issues)
                }
                state.isGroupToChoiceEnum = previous
                if let failure {
                    throw failure
                }
                if errors.count == errorCount {
                    errors.removeLast(errors.count - initialErrorCount)
                    return
                }
            }
            return
        }

        // Entries standing for items of an array describe a run of them, and
        // where that run is known it determines the item each entry answers
        // for.
        if let frame = state.arrayFrame, item.isArray, !state.isMemberKey, !occurrenceCoversMany(state.occurrence) {
            if groupChoiceArityIsExact(state.schema, gc) {
                try await visitArrayGroupChoice(gc, frame)
                return
            }
            if gc.groupEntries.count == 1 {
                state.groupEntryIdx = frame.cursor
                try await visitGroupEntry(gc.groupEntries[0].0)
                return
            }
            try await visitUnplacedGroupChoice(gc)
            return
        }

        try await visitUnplacedGroupChoice(gc)
    }

    /// Walks one alternative of a group whose entries cannot be placed within
    /// the array being validated.
    private func visitUnplacedGroupChoice(_ gc: GroupChoice) async throws(JSONValidationError) {
        let savedArrayFrame = state.arrayFrame
        state.arrayFrame = nil
        defer { state.arrayFrame = savedArrayFrame }
        try await visitGroupChoiceEntries(gc)
    }

    /// Walks the entries of one alternative of a group, each answering for its
    /// own position in the group.
    private func visitGroupChoiceEntries(_ gc: GroupChoice) async throws(JSONValidationError) {
        let base = state.groupEntryIdx ?? 0
        var accounted = 0
        let errorCount = errors.count

        for (ge, _) in gc.groupEntries {
            state.groupEntryIdx = base + accounted
            let accountsForItems = !entryAccountsForNoItems(state.schema, ge)
            try await visitGroupEntry(ge)

            if state.matchingOneOfSeveral && errors.count > errorCount {
                break
            }
            if accountsForItems {
                accounted += 1
            }
        }
    }

    /// Walks one alternative of a group whose entries stand for items of the
    /// array being validated, trying each way of splitting the run between
    /// the entries in turn.
    private func visitArrayGroupChoice(_ gc: GroupChoice, _ frame: ArrayFrame) async throws(JSONValidationError) {
        let entryArities = gc.groupEntries.map { groupEntryArities(state.schema, $0.0) }
        let plans = entryArityPlans(entryArities, UInt64(frame.budget), maxArityPlans)

        if plans.isEmpty {
            addError(arrayLengthError(groupChoiceArities(state.schema, gc), frame))
            return
        }

        let initialErrorCount = errors.count
        let saved = plans.count > 1 ? alternativeState() : nil
        let baselineItemErrors = unvalidatedItemErrorCount()

        let restoreMatchingOneOfSeveral = state.matchingOneOfSeveral
        state.matchingOneOfSeveral = state.matchingOneOfSeveral || plans.count > 1
        let stopAtFirstFailure = state.matchingOneOfSeveral

        let savedEntryCounts = state.entryCounts
        state.entryCounts = [EntryCount(count: UInt64(frame.len), entryOccurrence: nil)]
        defer {
            state.entryCounts = savedEntryCounts
            state.matchingOneOfSeveral = restoreMatchingOneOfSeveral
        }

        for plan in plans {
            if let saved {
                restoreAlternativeState(saved)
            }

            let errorCount = errors.count
            var cursor = frame.cursor

            for (idx, planned) in plan.enumerated() {
                let budget = Int(planned)
                if budget == 0 {
                    continue
                }
                let ge = gc.groupEntries[idx].0
                state.occurrence = nil
                state.groupEntryIdx = cursor
                state.arrayFrame = ArrayFrame(cursor: cursor, budget: budget, len: frame.len)
                try await visitGroupEntry(ge)
                cursor += budget

                if stopAtFirstFailure && errors.count > errorCount {
                    break
                }
            }

            state.arrayFrame = frame

            if errors.count == errorCount && unvalidatedItemErrorCount() <= baselineItemErrors {
                errors.removeLast(errors.count - initialErrorCount)
                break
            }
        }
    }

    /// Walks an array against the group of its array type with the arity-plan
    /// walk, reporting what does not match; run once the sequence matcher has
    /// found that the array does not match.
    func validateArrayGroupDetail(_ group: Group, _ a: [JSONNode]) async throws(JSONValidationError) {
        let len = a.count
        let entryCounts = entryCountsFromGroup(state.schema, group)

        if groupArityIsExact(state.schema, group) && !validateExactEntryCount(entryCounts, len) {
            if entryCounts.count > 1 {
                let counts = entryCounts.map { String($0.count) }.joined(separator: ", ")
                addError("expected array with length matching one of [\(counts)], got \(len)")
            } else {
                for ec in entryCounts {
                    addError("expected array with length \(ec.count), got \(len)")
                }
            }
            return
        }

        // An array nested inside another array must not disturb the enclosing
        // array's cursor.
        let savedEntryCounts = state.entryCounts
        let savedGroupEntryIdx = state.groupEntryIdx
        let savedValidArrayItems = state.validArrayItems
        let savedArrayErrors = arrayErrors
        let savedArrayFrame = state.arrayFrame
        state.entryCounts = nil
        state.groupEntryIdx = nil
        state.validArrayItems = nil
        arrayErrors = nil
        state.arrayFrame = nil

        state.arrayFrame = ArrayFrame(cursor: 0, budget: len, len: len)
        state.entryCounts = entryCounts

        try await visitGroupChoices(group, true)
        state.entryCounts = savedEntryCounts
        state.arrayFrame = savedArrayFrame

        if var itemErrors = arrayErrors {
            if let indices = state.validArrayItems {
                for idx in indices {
                    itemErrors.removeValue(forKey: idx)
                }
            }
            for key in itemErrors.keys.sorted() {
                errors.append(contentsOf: itemErrors[key]!)
            }
        }

        state.validArrayItems = savedValidArrayItems
        arrayErrors = savedArrayErrors
        state.groupEntryIdx = savedGroupEntryIdx
    }

    /// Walks an object against the group of its map type with the entry walk,
    /// reporting what does not match; run once the map matcher has found that
    /// the object does not match.
    func validateMapGroupDetail(_ group: Group, _ entries: [(key: String, value: JSONNode)]) async throws(JSONValidationError) {
        try await visitGroup(group)

        if valuesToValidate == nil {
            let keys = validatedKeys ?? []
            for entry in entries where !containsName(keys, entry.key) {
                addError("unexpected key \(debugString(entry.key))")
            }
        }
    }
}
