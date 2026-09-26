import BigInt
import Foundation

// The walk of a CDDL schema against a CBOR data item.
//
// The walk descends the data one level at a time. Each level is a `Level`:
// the item it holds, where in the document that item is, the state the
// schema walk has reached against it, and what it has reported. A step into a
// nested item builds a level for that item and walks it in an asynchronous
// call, whose frame lives on the heap, so the nesting of the document and of
// the schema costs memory and never stack.

/// What a level is asked to walk against the item it holds.
enum Walk {
    /// The root rule of the schema, against the root of the document.
    case root
    case rule(Rule)
    case type(Type)
    case typeChoice(TypeChoice)
    case type1(Type1)
    case type2(Type2)
    case group(Group)
    case identifier(Identifier)
    case value(Value)
    case range(Type2, Type2, Bool)
    case control(Type2, ControlOperator, Type2)
}

/// What the items of an array are each matched against.
enum ItemToken {
    case value(Value)
    case range(Type2, Type2, Bool)
    /// A map type, which each item is held to as a whole.
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
        return token.errorMessage(.cbor, idx)
    }

    /// The walk one item of the array is given.
    var walk: Walk {
        switch self {
        case .value(let value): return .value(value)
        case .range(let lower, let upper, let isInclusive): return .range(lower, upper, isInclusive)
        case .map(let t2): return .type2(t2)
        case .identifier(let ident): return .identifier(ident)
        case .taggedData(let t2): return .type2(t2)
        case .control(let target, let ctrl, let controller): return .control(target, ctrl, controller)
        case .type(let t): return .type(t)
        }
    }
}

/// What an enclosing level sets aside while one alternative of a type choice
/// is evaluated, rather than copying it for the alternative.
struct LentToChoice {
    var errors: [ErrorRecord]
    var arrayErrors: [Int: [ErrorRecord]]?
}

/// The validation state one alternative of a choice consumes as it is
/// evaluated, captured before the first alternative and reinstated before each
/// subsequent one.
struct AlternativeState {
    var groupEntryIdx: Int?
    var entryCounts: [EntryCount]?
    var occurrence: Occur?
    var advanceToNextEntry: Bool
    var validArrayItems: [Int]?
    var arrayErrors: [Int: [ErrorRecord]]?
    var validatedKeys: [CBORNode]?
    var valuesToValidate: [CBORNode]?
    var objectValue: CBORNode?
    var arrayFrame: ArrayFrame?
}

/// What a step of the walk holds while it walks one data item.
final class Level {
    /// Shared validation state.
    var state: ValidationState
    /// The data item this level holds.
    let item: CBORNode
    /// Where in the document `item` is.
    var location: PathId
    var errors: [ErrorRecord] = []
    /// A map entry value hoisted from an earlier step of the walk.
    var objectValue: CBORNode?
    /// The member key a cut was detected on.
    var cutValue: Type1?
    /// Map entry keys that have already been validated.
    var validatedKeys: [CBORNode]?
    /// Map entry values that have yet to be validated.
    var valuesToValidate: [CBORNode]?
    /// Whether a map entry value is being validated.
    var validatingValue = false
    /// Errors of array items, keyed by item index; drained in index order.
    var arrayErrors: [Int: [ErrorRecord]]?
    var rangeUpper: UInt64?
    /// The implementation limits the walk runs under.
    let limits: ValidationLimits
    /// Rule references being resolved against the data item this level holds.
    var ruleNesting = 0
    /// What the descent to the data item has cost.
    var descentCost = 0
    /// Nesting levels of the data stepped into to reach the item.
    var dataNesting = 0
    /// Payloads decoded out of the document that are open above this level.
    var embeddedDepth = 0
    /// The run's work budget.
    let work: WorkBudget
    /// The locations the walk has stepped along.
    let paths: PathArena

    init(
        state: ValidationState,
        item: CBORNode,
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
    convenience init(root validator: CBORValidator, paths: PathArena) {
        self.init(
            state: validator.state,
            item: validator.cbor,
            location: .root,
            limits: validator.storedLimits,
            work: validator.work,
            paths: paths
        )
    }

    /// A copy of this level.
    func clone() -> Level {
        let level = Level(state: state, item: item, location: location, limits: limits, work: work, paths: paths)
        level.errors = errors
        level.objectValue = objectValue
        level.cutValue = cutValue
        level.validatedKeys = validatedKeys
        level.valuesToValidate = valuesToValidate
        level.validatingValue = validatingValue
        level.arrayErrors = arrayErrors
        level.rangeUpper = rangeUpper
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
    func validationError(_ reason: String) -> CBORValidationIssue {
        CBORValidationIssue(
            reason: reason,
            cborLocation: paths.render(location),
            isMultiTypeChoice: state.isMultiTypeChoice,
            isMultiGroupChoice: state.isMultiGroupChoice,
            isGroupToChoiceEnum: state.isGroupToChoiceEnum,
            typeGroupNameEntry: state.typeGroupNameEntry
        )
    }

    /// The error a breached implementation limit reports: the whole report,
    /// since nothing below the point it was reached was examined.
    func limitError(_ reason: String) -> CBORValidationError {
        .validation([validationError(reason)])
    }

    /// The error a fault in the schema reports, raised rather than recorded.
    func schemaError(_ reason: String) -> CBORValidationError {
        .invalidSchema(validationError(reason))
    }

    // MARK: Bounds

    /// Refuses to resolve one more rule reference against the data item this
    /// level holds once a bound is reached, and says what the descent costs
    /// once it has been taken.
    func checkRuleNesting(_ ident: Identifier) throws(CBORValidationError) -> Int {
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

    /// Resolves `rule`, reached as `ident`, against the data item this level
    /// holds, as one more reference on the chain resolved against it.
    func visitRuleAgainstItem(_ ident: Identifier, _ rule: Rule) async throws(CBORValidationError) {
        try await resolveAgainstItem(ident, rule, .rule(rule))
    }

    /// Takes the reference to `rule`, written as `ident`, against the data item
    /// this level holds, and walks what it resolves to. A rule re-entered
    /// against the same item without consuming any data is a cycle.
    func resolveAgainstItem(_ ident: Identifier, _ rule: Rule, _ walk: Walk) async throws(CBORValidationError) {
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
    func chargeWork() throws(CBORValidationError) {
        if work.charge() {
            return
        }
        throw workLimitError()
    }

    /// The error a spent work budget reports.
    func workLimitError() -> CBORValidationError {
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
    func derived(_ item: CBORNode) -> Level {
        var state = freshState()
        state.genericRules = self.state.genericRules
        state.evalGenericRule = self.state.evalGenericRule

        let level = Level(state: state, item: item, location: location, limits: limits, work: work, paths: paths)
        level.descentCost = descentCost
        level.dataNesting = dataNesting
        level.embeddedDepth = embeddedDepth
        return level
    }

    /// A level holding the same data item as this one.
    func sameItem() -> Level {
        derived(item)
    }

    /// Refuses the step into a data item nested one level inside this one if
    /// it would breach a bound, and says what the descent then costs.
    func chargeStep() throws(CBORValidationError) -> Int {
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

    /// A level for a data item nested one level inside the one this level
    /// holds. The rules being resolved are not carried over: the step moves to
    /// a different item.
    func child(_ item: CBORNode) throws(CBORValidationError) -> Level {
        let descentCost = try chargeStep()
        let level = derived(item)
        level.dataNesting = dataNesting + 1
        level.descentCost = descentCost
        return level
    }

    /// A level for `item` at `segment` below the item this level holds.
    func childAt(_ item: CBORNode, _ segment: Segment) throws(CBORValidationError) -> Level {
        let level = try child(item)
        level.location = paths.child(location, segment)
        return level
    }

    /// A level for a payload decoded out of the data item this level holds.
    /// How many may be open at once is bounded.
    func embedded(_ payload: CBORNode) throws(CBORValidationError) -> Level {
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

    // MARK: Alternatives

    /// A copy of this level for evaluating one alternative of a type choice in
    /// isolation, starting with both error channels empty; what the copy does
    /// not need is set aside and comes back through ``reclaimFromChoice(_:)``.
    func lendToChoice() -> (Level, LentToChoice) {
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

    /// Takes over the map entries a level holding the same data item accounted
    /// for.
    func adoptMatchedMapKeys(_ level: Level) {
        if let keys = level.validatedKeys {
            level.validatedKeys = nil
            validatedKeys = (validatedKeys ?? []) + keys
        }
    }

    /// Captures the state an alternative consumes while it is evaluated.
    func alternativeState() -> AlternativeState {
        AlternativeState(
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
    func restoreAlternativeState(_ saved: AlternativeState) {
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

    /// Appends `key` to the keys this level has accounted for.
    func noteValidatedKey(_ key: CBORNode) {
        if validatedKeys == nil {
            validatedKeys = []
        }
        validatedKeys!.append(key)
    }

    /// Whether `key` is one of the keys this level has accounted for, compared
    /// as data items.
    func isValidatedKey(_ key: CBORNode) -> Bool {
        validatedKeys?.contains { referenceEquals($0, key) } ?? false
    }
}

/// Whether `keys` holds a data item equal to `key`.
func containsKey(_ keys: [CBORNode], _ key: CBORNode) -> Bool {
    keys.contains { referenceEquals($0, key) }
}
