import Foundation

// The walk of a CDDL schema against a JSON document.
//
// The walk descends the document one level at a time. Each level is a
// `JSONLevel`: the value it holds, where in the document that value is, the
// state the schema walk has reached against it, and what it has reported. A
// step into a nested value builds a level for that value and walks it in an
// asynchronous call, whose frame lives on the heap, so the nesting of the
// document and of the schema costs memory and never stack.

/// What the items of an array are each matched against.
enum JSONItemToken {
    case value(Value)
    case range(Type2, Type2, Bool)
    /// A map type, which each item is held to as a whole: an item is that
    /// object or it is not, and an object carrying a member the group does not
    /// name is not.
    case map(Type2)
    case identifier(Identifier)
    case taggedData(Type2)
    case control(Type2, ControlOperator, Type2)
    /// A type naming an array among its alternatives, matched against each
    /// item as the one type it is.
    case type(Type)

    func errorMessage(_ idx: Int?) -> String {
        let token: ArrayItemToken
        switch self {
        case .value(let value): token = .value(value)
        case .range(let lower, let upper, let isInclusive): token = .range(lower, upper, isInclusive)
        case .map(let t2): token = .map(t2)
        case .identifier(let ident): token = .identifier(ident)
        case .taggedData(let t2): token = .taggedData(t2)
        case .control(let target, let ctrl, let controller): token = .control(target, ctrl, controller)
        case .type(let t): token = .type(t)
        }
        return token.errorMessage(.json, idx)
    }

    /// The walk one item of the array is given, or the error a tagged type
    /// reports against it: the JSON data model has no tagged values.
    var walk: Result<Walk, TaggedItemError> {
        switch self {
        case .value(let value): return .success(.value(value))
        case .range(let lower, let upper, let isInclusive): return .success(.range(lower, upper, isInclusive))
        case .map(let t2): return .success(.type2(t2))
        case .identifier(let ident): return .success(.identifier(ident))
        case .taggedData(let t2):
            return .failure(TaggedItemError(reason: "tagged data is not supported in arrays, got \(typeHead(t2))"))
        case .control(let target, let ctrl, let controller): return .success(.control(target, ctrl, controller))
        case .type(let t): return .success(.type(t))
        }
    }
}

/// The reason a tagged type admits no item of a JSON array.
struct TaggedItemError: Error {
    var reason: String
}

/// The validation state one alternative of a choice consumes as it is
/// evaluated, captured before the first alternative and reinstated before each
/// subsequent one.
struct JSONAlternativeState {
    var groupEntryIdx: Int?
    var entryCounts: [EntryCount]?
    var occurrence: Occur?
    var advanceToNextEntry: Bool
    var validArrayItems: [Int]?
    var arrayErrors: [Int: [ErrorRecord]]?
    var validatedKeys: [String]?
    var valuesToValidate: [JSONNode]?
    var objectValue: JSONNode?
    var arrayFrame: ArrayFrame?
}

/// What a step of the walk holds while it walks one JSON value.
final class JSONLevel {
    /// Shared validation state.
    var state: ValidationState
    /// The value this level holds.
    let item: JSONNode
    /// Where in the document `item` is.
    var location: PathId
    var errors: [ErrorRecord] = []
    /// An object member value hoisted from an earlier step of the walk.
    var objectValue: JSONNode?
    /// The member name a cut was detected on.
    var cutValue: String?
    /// Object member names that have already been validated.
    var validatedKeys: [String]?
    /// Object member values that have yet to be validated.
    var valuesToValidate: [JSONNode]?
    /// Errors of array items, keyed by item index; drained in index order.
    var arrayErrors: [Int: [ErrorRecord]]?
    /// The implementation limits the walk runs under.
    let limits: ValidationLimits
    /// Rule references being resolved against the value this level holds.
    var ruleNesting = 0
    /// What the descent to the value has cost.
    var descentCost = 0
    /// Nesting levels of the document stepped into to reach the value.
    var dataNesting = 0
    /// Values synthesised from the document that are open above this level.
    var embeddedDepth = 0
    /// The run's work budget.
    let work: WorkBudget
    /// The locations the walk has stepped along.
    let paths: PathArena

    init(
        state: ValidationState,
        item: JSONNode,
        location: PathId,
        limits: ValidationLimits,
        work: WorkBudget,
        paths: PathArena
    ) {
        self.state = state
        self.item = item
        self.location = location
        self.limits = limits
        self.work = work
        self.paths = paths
    }

    /// The level holding the document of `validator`.
    convenience init(root validator: JSONValidator, paths: PathArena) {
        self.init(
            state: validator.state,
            item: validator.json,
            location: .root,
            limits: validator.storedLimits,
            work: validator.work,
            paths: paths
        )
    }

    /// A copy of this level.
    func clone() -> JSONLevel {
        let level = JSONLevel(state: state, item: item, location: location, limits: limits, work: work, paths: paths)
        level.errors = errors
        level.objectValue = objectValue
        level.cutValue = cutValue
        level.validatedKeys = validatedKeys
        level.valuesToValidate = valuesToValidate
        level.arrayErrors = arrayErrors
        level.ruleNesting = ruleNesting
        level.descentCost = descentCost
        level.dataNesting = dataNesting
        level.embeddedDepth = embeddedDepth
        return level
    }

    // MARK: Errors

    /// Records a validation error against the position the walk has reached.
    func addError(_ reason: String) {
        errors.append(
            ErrorRecord(
                reason: reason,
                location: location,
                isMultiTypeChoice: state.isMultiTypeChoice,
                isMultiGroupChoice: state.isMultiGroupChoice,
                isGroupToChoiceEnum: state.isGroupToChoiceEnum,
                typeGroupNameEntry: state.typeGroupNameEntry
            ))
    }

    /// An error against the position the walk has reached, rendered for a
    /// report handed out on its own.
    func validationError(_ reason: String) -> JSONValidationIssue {
        JSONValidationIssue(
            reason: reason,
            jsonLocation: paths.render(location),
            isMultiTypeChoice: state.isMultiTypeChoice,
            isMultiGroupChoice: state.isMultiGroupChoice,
            isGroupToChoiceEnum: state.isGroupToChoiceEnum,
            typeGroupNameEntry: state.typeGroupNameEntry
        )
    }

    /// The error a breached implementation limit reports: the whole report,
    /// since nothing below the point it was reached was examined.
    func limitError(_ reason: String) -> JSONValidationError {
        .validation([validationError(reason)])
    }

    /// The error a fault in the schema reports, raised rather than recorded.
    func schemaError(_ reason: String) -> JSONValidationError {
        .invalidSchema(validationError(reason))
    }

    // MARK: Bounds

    /// Refuses to resolve one more rule reference against the value this level
    /// holds once a bound is reached, and says what the descent costs once it
    /// has been taken.
    func checkRuleNesting(_ ident: Identifier) throws(JSONValidationError) -> Int {
        if ruleNesting >= limits.maxRuleNesting {
            throw limitError(
                "resolving rule \(ident) nests rule references more than \(limits.maxRuleNesting) deep against one data item, exceeding the maximum supported rule nesting"
            )
        }
        switch chargeDescent(descentCost, limits.ruleHopCost, limits.maxDescentCost) {
        case .success(let cost): return cost
        case .failure(let reason): throw limitError(reason.reason)
        }
    }

    /// Resolves `rule`, reached as `ident`, against the value this level holds,
    /// as one more reference on the chain resolved against it.
    func visitRuleAgainstItem(_ ident: Identifier, _ rule: Rule) async throws(JSONValidationError) {
        try await resolveAgainstItem(ident, rule, .rule(rule))
    }

    /// Takes the reference to `rule`, written as `ident`, against the value this
    /// level holds, and walks what it resolves to. A rule re-entered against the
    /// same value without consuming any data is a cycle.
    func resolveAgainstItem(_ ident: Identifier, _ rule: Rule, _ walk: Walk) async throws(JSONValidationError) {
        let ruleName = rule.ruleName
        let ruleKey = ruleName.ident
        if state.visitedRules.contains(ruleKey) {
            addError("rule \(ruleName) is defined in terms of itself without consuming any data")
            return
        }

        let descentCost = try checkRuleNesting(ident)

        let outerDescentCost = self.descentCost
        state.visitedRules.insert(ruleKey)
        ruleNesting += 1
        self.descentCost = descentCost
        defer {
            self.descentCost = outerDescentCost
            ruleNesting -= 1
            state.visitedRules.remove(ruleKey)
        }
        try await self.walk(walk)
    }

    /// Charges one step of the walk to the run's work budget, and refuses to
    /// take it once the budget is gone.
    func chargeWork() throws(JSONValidationError) {
        if work.charge() {
            return
        }
        throw workLimitError()
    }

    /// The error a spent work budget reports.
    func workLimitError() -> JSONValidationError {
        limitError(
            "validating this data against this schema takes more than the maximum supported \(work.limit) steps of validation work"
        )
    }

    /// A fresh shared state against the same schema.
    func freshState() -> ValidationState {
        ValidationState(schema: state.schema, enabledFeatures: state.enabledFeatures)
    }

    /// A level holding `item`, carrying over the generic instantiations in
    /// scope, the limits, the work budget and this level's location.
    func derived(_ item: JSONNode) -> JSONLevel {
        var state = freshState()
        state.genericRules = self.state.genericRules
        state.evalGenericRule = self.state.evalGenericRule

        let level = JSONLevel(state: state, item: item, location: location, limits: limits, work: work, paths: paths)
        level.descentCost = descentCost
        level.dataNesting = dataNesting
        level.embeddedDepth = embeddedDepth
        return level
    }

    /// A level holding the same value as this one.
    func sameItem() -> JSONLevel {
        derived(item)
    }

    /// Refuses the step into a value nested one level inside this one if it
    /// would breach a bound, and says what the descent then costs.
    func chargeStep() throws(JSONValidationError) -> Int {
        if dataNesting + 1 > limits.maxNestingDepth {
            throw limitError(
                "data is nested more deeply than the maximum supported nesting depth of \(limits.maxNestingDepth)")
        }
        let cost: Int
        switch chargeDescent(descentCost, limits.dataLevelCost, limits.maxDescentCost) {
        case .success(let charged): cost = charged
        case .failure(let reason): throw limitError(reason.reason)
        }
        try chargeWork()
        return cost
    }

    /// A level for a value nested one level inside the one this level holds.
    /// The rules being resolved are not carried over: the step moves to a
    /// different value.
    func child(_ item: JSONNode) throws(JSONValidationError) -> JSONLevel {
        let descentCost = try chargeStep()
        let level = derived(item)
        level.dataNesting = dataNesting + 1
        level.descentCost = descentCost
        return level
    }

    /// A level for `item` at `segment` below the value this level holds.
    func childAt(_ item: JSONNode, _ segment: Segment) throws(JSONValidationError) -> JSONLevel {
        let level = try child(item)
        level.location = paths.child(location, segment)
        return level
    }

    /// A level for a value synthesised from the one this level holds -- the
    /// name of one of its members held as a string of its own, or a bit number
    /// `.bits` enumerates. How many may be open at once is bounded.
    func embedded(_ payload: JSONNode) throws(JSONValidationError) -> JSONLevel {
        if embeddedDepth + 1 > limits.maxEmbeddedDepth {
            throw limitError(
                "embedded payloads are nested more deeply than the maximum supported \(limits.maxEmbeddedDepth) open payloads"
            )
        }
        let descentCost = try chargeStep()
        let level = derived(payload)
        level.dataNesting = dataNesting + 1
        level.descentCost = descentCost
        level.embeddedDepth = embeddedDepth + 1
        return level
    }

    /// Walks `walk` against the member name `key`, held as a string of its
    /// own, and says whether the walk admitted it: it recorded no error, and no
    /// array item it went on to walk was left holding one.
    func keyAdmitted(_ key: String, _ walk: Walk) async throws(JSONValidationError) -> Bool {
        let level = try embedded(.string(key))
        try await level.walk(walk)
        return level.errors.isEmpty && level.unvalidatedItemErrorCount() == 0
    }

    /// Resolves a range bound to the value it denotes.
    func resolveBound(_ bound: Type2) -> Result<RangeBound, RangeBoundError> {
        state.resolveRangeBound(bound, limits.maxRuleNesting)
    }

    // MARK: Alternatives

    /// A copy of this level for evaluating one alternative of a type choice in
    /// isolation, starting with both error channels empty; what the copy does
    /// not need is set aside and comes back through ``reclaimFromChoice(_:)``.
    func lendToChoice() -> (JSONLevel, LentToChoice) {
        let lent = LentToChoice(errors: errors, arrayErrors: arrayErrors)
        errors = []
        arrayErrors = nil
        return (clone(), lent)
    }

    /// Takes back what ``lendToChoice()`` set aside.
    func reclaimFromChoice(_ lent: LentToChoice) {
        errors = lent.errors
        arrayErrors = lent.arrayErrors
    }

    /// Takes over the object members a level holding the same value accounted
    /// for.
    func adoptMatchedMapKeys(_ level: JSONLevel) {
        if let keys = level.validatedKeys {
            level.validatedKeys = nil
            validatedKeys = (validatedKeys ?? []) + keys
        }
    }

    /// Captures the state an alternative consumes while it is evaluated.
    func alternativeState() -> JSONAlternativeState {
        JSONAlternativeState(
            groupEntryIdx: state.groupEntryIdx,
            entryCounts: state.entryCounts,
            occurrence: state.occurrence,
            advanceToNextEntry: state.advanceToNextEntry,
            validArrayItems: state.validArrayItems,
            arrayErrors: arrayErrors,
            validatedKeys: validatedKeys,
            valuesToValidate: valuesToValidate,
            objectValue: objectValue,
            arrayFrame: state.arrayFrame
        )
    }

    /// Reinstates the state captured by ``alternativeState()``.
    func restoreAlternativeState(_ saved: JSONAlternativeState) {
        state.groupEntryIdx = saved.groupEntryIdx
        state.entryCounts = saved.entryCounts
        state.occurrence = saved.occurrence
        state.advanceToNextEntry = saved.advanceToNextEntry
        state.validArrayItems = saved.validArrayItems
        arrayErrors = saved.arrayErrors
        validatedKeys = saved.validatedKeys
        valuesToValidate = saved.valuesToValidate
        objectValue = saved.objectValue
        state.arrayFrame = saved.arrayFrame
    }

    /// Number of array items left holding errors that no group entry went on
    /// to validate.
    func unvalidatedItemErrorCount() -> Int {
        guard let arrayErrors else { return 0 }
        let itemsWithErrors = arrayErrors.filter { !$0.value.isEmpty }
        if let indices = state.validArrayItems, !indices.isEmpty {
            let valid = Set(indices)
            return itemsWithErrors.keys.filter { !valid.contains($0) }.count
        }
        return itemsWithErrors.count
    }

    /// Takes the errors of the array items that no group entry went on to
    /// validate, in item order, leaving the per-item channel empty.
    func takeUnvalidatedItemErrors() -> [ErrorRecord] {
        guard var errors = arrayErrors else { return [] }
        arrayErrors = nil
        if let indices = state.validArrayItems {
            for idx in indices {
                errors.removeValue(forKey: idx)
            }
        }
        return errors.keys.sorted().flatMap { errors[$0]! }
    }

    /// Records the errors of the item at `idx` in the per-item channel.
    func appendArrayErrors(_ idx: Int, _ recorded: [ErrorRecord]) {
        if arrayErrors == nil {
            arrayErrors = [:]
        }
        arrayErrors![idx, default: []].append(contentsOf: recorded)
    }

    /// Appends `key` to the member names this level has accounted for.
    func noteValidatedKey(_ key: String) {
        if validatedKeys == nil {
            validatedKeys = []
        }
        validatedKeys!.append(key)
    }

    /// Accounts for `key` the way a member named outright is accounted for:
    /// a level that had accounted for none starts from that one name, and the
    /// name is then added to what it has accounted for.
    func noteNamedKey(_ key: String) {
        if validatedKeys == nil {
            validatedKeys = [key]
        }
        validatedKeys!.append(key)
    }
}

/// Whether `keys` holds a name with the same Unicode scalars as `key`.
func containsName(_ keys: [String], _ key: String) -> Bool {
    keys.contains { sameText($0, key) }
}

/// Whether two texts are the same sequence of Unicode scalars, which is what
/// JSON compares names and strings by (RFC 8259 Section 8.3), rather than
/// canonically equivalent.
func sameText(_ a: String, _ b: String) -> Bool {
    a.utf8.count == b.utf8.count && a.utf8.elementsEqual(b.utf8)
}
