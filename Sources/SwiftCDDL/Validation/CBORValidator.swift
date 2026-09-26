import Foundation

// Validation of a CBOR data item (RFC 8949) against a CDDL schema (RFC 8610).

/// Validates one CBOR data item against a CDDL schema.
///
/// The document is matched against the root rule: the first type rule of the
/// schema that takes no generic parameters (RFC 8610 Section 3.1), or the rule
/// named by ``rootRule``.
///
/// The walk keeps its state in the frames of asynchronous calls, which live on
/// the heap, so a document nested as deeply as ``ValidationLimits`` admits is
/// validated on any thread, a Swift concurrency task's included.
public final class CBORValidator {
    var state: ValidationState
    /// The document being validated.
    public let cbor: CBORNode
    var errors: [CBORValidationIssue] = []
    var storedLimits: ValidationLimits
    var work: WorkBudget

    /// A validator of `cbor` against `cddl`, with the given features enabled
    /// for the `.feature` control operator (RFC 9165 Section 4).
    public convenience init(cddl: CDDL, cbor: CBORNode, enabledFeatures: [String]? = nil) {
        self.init(schema: Schema(cddl), cbor: cbor, enabledFeatures: enabledFeatures)
    }

    /// A validator of `cbor` against `document`, with the given features enabled
    /// for the `.feature` control operator (RFC 9165 Section 4).
    public convenience init(document: CDDLDocument, cbor: CBORNode, enabledFeatures: [String]? = nil) {
        self.init(schema: document.schema, cbor: cbor, enabledFeatures: enabledFeatures)
    }

    init(schema: Schema, cbor: CBORNode, enabledFeatures: [String]?) {
        self.state = ValidationState(schema: schema, enabledFeatures: enabledFeatures)
        self.cbor = cbor
        self.storedLimits = ValidationLimits()
        self.work = WorkBudget(limit: ValidationLimits.defaultMaxValidationWork)
    }

    /// The document this validator holds.
    func extractCBOR() -> CBORNode {
        cbor
    }

    /// Validates the document against the type rule named `name` rather than
    /// against the first type rule of the schema. A name the schema does not
    /// define as a non-generic type rule is reported as a validation error.
    func setRootRule(_ name: String) {
        state.rootRule = name
    }

    /// The type rule the document is validated against, by name; `nil`
    /// means the first type rule of the schema that takes no generic
    /// parameters. A name the schema does not define as such a rule is
    /// reported as a validation error.
    public var rootRule: String? {
        get { state.rootRule }
        set { state.rootRule = newValue }
    }

    /// The implementation limits this validator runs under. Setting them
    /// starts a fresh work budget.
    public var limits: ValidationLimits {
        get {
            var limits = storedLimits
            limits.maxValidationWork = work.limit
            return limits
        }
        set {
            setLimits(newValue)
        }
    }

    /// Sets every implementation limit this validator runs under, starting a
    /// fresh work budget.
    func setLimits(_ limits: ValidationLimits) {
        storedLimits = limits
        work = WorkBudget(limit: limits.maxValidationWork)
    }

    /// Sets the upper bound on the nesting depth of the data.
    func setMaxNestingDepth(_ maxNestingDepth: Int) {
        storedLimits.maxNestingDepth = maxNestingDepth
    }

    /// Sets the upper bound on how many rule references are resolved against
    /// one data item.
    func setMaxRuleNesting(_ maxRuleNesting: Int) {
        storedLimits.maxRuleNesting = maxRuleNesting
    }

    /// Sets the upper bound on what the descent to one data item may cost.
    func setMaxDescentCost(_ maxDescentCost: Int) {
        storedLimits.maxDescentCost = maxDescentCost
    }

    /// Sets what a step into a nested data item and a rule reference resolved
    /// against the item already held charge the descent budget.
    func setDescentWeights(dataLevelCost: Int, ruleHopCost: Int) {
        storedLimits.dataLevelCost = dataLevelCost
        storedLimits.ruleHopCost = ruleHopCost
    }

    /// Sets the upper bound on how many decoded payloads may be open at once.
    func setMaxEmbeddedDepth(_ maxEmbeddedDepth: Int) {
        storedLimits.maxEmbeddedDepth = maxEmbeddedDepth
    }

    /// Sets the upper bound on the size of the report, in bytes of its rendered
    /// errors.
    func setMaxReportBytes(_ maxReportBytes: Int) {
        storedLimits.maxReportBytes = maxReportBytes
    }

    /// Sets the upper bound on the work one run may do, starting a fresh work
    /// budget.
    func setMaxValidationWork(_ maxValidationWork: Int) {
        storedLimits.maxValidationWork = maxValidationWork
        work = WorkBudget(limit: maxValidationWork)
    }

    /// Records a validation error at the root of the document, reported with
    /// the errors the walk finds.
    func addError(_ reason: String) {
        errors.append(
            CBORValidationIssue(
                reason: reason,
                cborLocation: "",
                isMultiTypeChoice: state.isMultiTypeChoice,
                isMultiGroupChoice: state.isMultiGroupChoice,
                isGroupToChoiceEnum: state.isGroupToChoiceEnum,
                typeGroupNameEntry: state.typeGroupNameEntry
            ))
    }

    /// The error a spent work budget reports.
    func workLimitError() -> CBORValidationError {
        .validation([
            CBORValidationIssue(
                reason:
                    "validating this data against this schema takes more than the maximum supported \(work.limit) steps of validation work",
                cborLocation: "",
                isMultiTypeChoice: state.isMultiTypeChoice,
                isMultiGroupChoice: state.isMultiGroupChoice,
                isGroupToChoiceEnum: state.isGroupToChoiceEnum,
                typeGroupNameEntry: state.typeGroupNameEntry
            )
        ])
    }

    /// Validates the document, throwing what does not match.
    public func validate() async throws(CBORValidationError) {
        let paths = PathArena()
        let root = Level(root: self, paths: paths)

        try await root.walk(.root)

        // A run that asked for a step it did not have cannot be reported as a
        // verdict: what the budget did not reach went unexamined.
        if work.overspent {
            throw workLimitError()
        }

        let recorded = retainedErrors(root.errors, paths, storedLimits.maxReportBytes)
        if !recorded.isEmpty || !errors.isEmpty {
            var issues = recorded.map { renderError($0, paths) }
            issues.append(contentsOf: errors)
            throw .validation(issues)
        }
    }

    /// Validates the document, blocking the calling thread until the walk is
    /// done; see ``validate()``.
    ///
    /// Safe to call from any context, a task of the shared concurrency pool
    /// included: the calling thread runs the walk itself.
    public func validateSynchronously() throws(CBORValidationError) {
        try validate()
    }

    func validate() throws(CBORValidationError) {
        let validator = UncheckedBox(self)
        let result = runBlocking { () async -> Result<Void, CBORValidationError> in
            do throws(CBORValidationError) {
                try await validator.value.validate()
                return .success(())
            } catch {
                return .failure(error)
            }
        }
        try result.get()
    }
}

/// The report of one recorded error, at its rendered location.
func renderError(_ record: ErrorRecord, _ paths: PathArena) -> CBORValidationIssue {
    CBORValidationIssue(
        reason: record.reason,
        cborLocation: paths.render(record.location),
        isMultiTypeChoice: record.isMultiTypeChoice,
        isMultiGroupChoice: record.isMultiGroupChoice,
        isGroupToChoiceEnum: record.isGroupToChoiceEnum,
        typeGroupNameEntry: record.typeGroupNameEntry
    )
}

// MARK: - One-call entry points

/// Validates CBOR `bytes` against the CDDL schema text `cddl`.
///
/// The bytes must hold exactly one CBOR data item: bytes left over after it are
/// reported rather than ignored. A schema that does not parse and a document
/// that does not decode are reported apart, as
/// ``CBORValidationError/cddlParsing(_:)`` and
/// ``CBORValidationError/cborDecoding(_:)``.
///
/// - Parameters:
///   - cddl: The schema.
///   - cbor: The document.
///   - rule: The type rule to validate against; the first type rule of the
///     schema when `nil`.
///   - enabledFeatures: The features the `.feature` control operator treats as
///     enabled.
///   - limits: The implementation limits the walk runs under.
func validateCBOR(
    cddl: String,
    cbor: [UInt8],
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    limits: ValidationLimits = ValidationLimits()
) async throws(CBORValidationError) {
    let validator = try makeValidator(cddl: cddl, cbor: cbor, rule: rule, enabledFeatures: enabledFeatures)
    validator.setLimits(limits)
    try await validator.validate()
}

/// Validates CBOR `cbor` against the CDDL schema text `cddl`; see
/// ``validateCBOR(cddl:cbor:rule:enabledFeatures:limits:)-(_,[UInt8],_,_,_)``.
func validateCBOR(
    cddl: String,
    cbor: Data,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    limits: ValidationLimits = ValidationLimits()
) async throws(CBORValidationError) {
    try await validateCBOR(cddl: cddl, cbor: [UInt8](cbor), rule: rule, enabledFeatures: enabledFeatures, limits: limits)
}

/// Validates CBOR `bytes` against the CDDL schema text `cddl`, blocking the
/// calling thread until the walk is done.
func validateCBOR(
    cddl: String,
    cbor: [UInt8],
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    limits: ValidationLimits = ValidationLimits()
) throws(CBORValidationError) {
    let validator = try makeValidator(cddl: cddl, cbor: cbor, rule: rule, enabledFeatures: enabledFeatures)
    validator.setLimits(limits)
    try validator.validate()
}

/// Validates CBOR `cbor` against the CDDL schema text `cddl`, blocking the
/// calling thread until the walk is done.
func validateCBOR(
    cddl: String,
    cbor: Data,
    rule: String? = nil,
    enabledFeatures: [String]? = nil,
    limits: ValidationLimits = ValidationLimits()
) throws(CBORValidationError) {
    try validateCBOR(cddl: cddl, cbor: [UInt8](cbor), rule: rule, enabledFeatures: enabledFeatures, limits: limits)
}

private func makeValidator(
    cddl: String,
    cbor: [UInt8],
    rule: String?,
    enabledFeatures: [String]?
) throws(CBORValidationError) -> CBORValidator {
    let schema: CDDL
    do {
        schema = try cddlFromStr(cddl)
    } catch {
        throw .cddlParsing(error.description)
    }
    let node: CBORNode
    do {
        node = try decodeCBOR(cbor)
    } catch {
        throw .cborDecoding(error)
    }
    let validator = CBORValidator(cddl: schema, cbor: node, enabledFeatures: enabledFeatures)
    if let rule {
        validator.setRootRule(rule)
    }
    return validator
}
