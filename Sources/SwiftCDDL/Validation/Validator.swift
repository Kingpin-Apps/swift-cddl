import BigInt
import Foundation

// What every validator shares: the state a walk of the schema keeps, the
// implementation limits it runs under, the locations it records errors at,
// and the helpers that look rules up and classify what names stand for
// (RFC 8610).

/// A generic rule instantiated during validation: its name, its parameters and
/// the arguments it was instantiated with (RFC 8610 Section 3.10).
struct GenericRule: Sendable {
    /// Rule name.
    var name: String
    /// Generic parameter names.
    var params: [String]
    /// Concrete type arguments for this instantiation.
    var args: [Type1]
}

/// The schema a document is validated against, with its rules indexed by name.
///
/// A name is looked up once for every reference the walk resolves, so the
/// rules defining it are found through the index rather than by scanning the
/// schema; the index keeps them in the order the schema writes them.
final class Schema: Sendable {
    /// The schema.
    let cddl: CDDL
    /// The positions in `cddl.rules` of the rules each name defines, keyed by
    /// the name with its socket prefix.
    private let positions: [String: [Int]]
    /// The same positions keyed by the name without its socket prefix.
    private let barePositions: [String: [Int]]

    init(_ cddl: CDDL) {
        self.cddl = cddl
        var positions: [String: [Int]] = [:]
        var barePositions: [String: [Int]] = [:]
        for (index, rule) in cddl.rules.enumerated() {
            positions[identifierKey(rule.ruleName), default: []].append(index)
            barePositions[rule.ruleName.ident, default: []].append(index)
        }
        self.positions = positions
        self.barePositions = barePositions
    }

    /// The rules named `ident`, in document order.
    func rules(named ident: Identifier) -> [Rule] {
        guard let found = positions[identifierKey(ident)] else { return [] }
        return found.map { cddl.rules[$0] }
    }

    /// The rules named `key`, the name with its socket prefix, in document
    /// order.
    func rules(key: String) -> [Rule] {
        guard let found = positions[key] else { return [] }
        return found.map { cddl.rules[$0] }
    }

    /// The rules whose name, without its socket prefix, is `name`, in document
    /// order.
    func rules(bareName name: String) -> [Rule] {
        guard let found = barePositions[name] else { return [] }
        return found.map { cddl.rules[$0] }
    }
}

/// The key an identifier is looked up by: its name with its socket prefix,
/// which is what two identifiers are compared by.
func identifierKey(_ ident: Identifier) -> String {
    switch ident.socket {
    case .type: return "$" + ident.ident
    case .group: return "$$" + ident.ident
    case nil: return ident.ident
    }
}

/// Validation state shared by the validators: the tracking fields a walk of the
/// schema keeps while it evaluates the CDDL AST against a data item.
struct ValidationState: Sendable {
    /// The schema being validated against.
    let schema: Schema
    /// Occurrence indicator detected in the current state of evaluation.
    var occurrence: Occur?
    /// Current group entry index.
    var groupEntryIdx: Int?
    /// Whether a member key is being evaluated.
    var isMemberKey = false
    /// Whether a cut is present on the member key being evaluated.
    var isCutPresent = false
    /// The generic rule whose parameters are in scope.
    var evalGenericRule: String?
    /// Generic rules instantiated so far.
    var genericRules: [GenericRule] = []
    /// Control operator in effect.
    var ctrl: ControlOperator?
    /// Whether a group turned into a choice is being evaluated.
    var isGroupToChoiceEnum = false
    /// Whether two or more type choices are being evaluated.
    var isMultiTypeChoice = false
    /// Whether two or more group choices are being evaluated.
    var isMultiGroupChoice = false
    /// The rule a type or group name entry names, for error messages.
    var typeGroupNameEntry: String?
    /// Whether to move on to the next group entry when member key validation
    /// fails.
    var advanceToNextEntry = false
    /// Whether map equality is being checked.
    var isCtrlMapEquality = false
    /// Entry counts for array and map validation.
    var entryCounts: [EntryCount]?
    /// Indices of array items that validated under the current type choice.
    var validArrayItems: [Int]?
    /// Whether the member key is written in the colon form.
    var isColonShortcutPresent = false
    /// Whether the rule being evaluated is the root rule.
    var isRoot = false
    /// The type rule the document is validated against, by name. `nil` means
    /// the first type rule of the schema, the root RFC 8610 Section 3.1 names.
    var rootRule: String?
    /// Whether a type rule of several choices is validating an array.
    var isMultiTypeChoiceTypeRuleValidatingArray = false
    /// Span of the array being validated that the group being walked accounts
    /// for, when the entries of that group stand for items of it.
    var arrayFrame: ArrayFrame?
    /// Whether the group entries being walked stand for one way of matching
    /// among several: one alternative of a group choice, or one way of
    /// splitting a run of array items between the entries. A failure settles
    /// such a walk on its own, so the walk stops at the first failure.
    var matchingOneOfSeveral = false
    /// The rules being resolved against the data item held, so that a rule
    /// re-entered against the same item is reported as a cycle.
    var visitedRules: Set<String> = []
    /// Enabled features (RFC 9165 Section 4).
    var enabledFeatures: [String]?
    /// Whether feature-related errors were detected.
    var hasFeatureErrors = false
    /// Disabled features encountered during validation.
    var disabledFeatures: [String]?

    init(schema: Schema, enabledFeatures: [String]?) {
        self.schema = schema
        self.enabledFeatures = enabledFeatures
    }
}

// MARK: - Implementation limits

/// The implementation limits a validation runs under.
///
/// The walk keeps its continuations on the heap, so nesting in the data and in
/// the schema costs it memory rather than stack. The nesting bounds exist
/// because memory is finite; the descent bound because the two nesting bounds
/// count the data side and the schema side apart and so bound neither what a
/// descent holds; the work bound because none of them bounds the breadth of
/// the walk, which a choice multiplies by its alternatives at every level the
/// data nests. None of them is imposed by RFC 8610: reaching one is reported as
/// an implementation limit, never as a statement about the document.
public struct ValidationLimits: Sendable, Hashable {
    /// Default upper bound on how many nesting levels of the data validation
    /// steps into.
    public static let defaultMaxNestingDepth = 16_384
    /// Default upper bound on how many rule references may be resolved against
    /// one data item before validation steps into a nested one.
    public static let defaultMaxRuleNesting = 64
    /// Default weight of a step into one nested data item against the descent
    /// budget.
    public static let defaultDataLevelCost = 8192
    /// Default weight of one rule reference resolved against a data item
    /// against the descent budget.
    public static let defaultRuleHopCost = 6144
    /// Default upper bound on what the descent to one data item may hold,
    /// counted in the units the two weights are stated in.
    public static let defaultMaxDescentCost =
        (defaultMaxNestingDepth + 1) * (defaultDataLevelCost + 2 * defaultRuleHopCost)
    /// Default upper bound on the elementary steps one validation run may take.
    public static let defaultMaxValidationWork = 4_000_000
    /// Default upper bound on how many payloads decoded out of the document
    /// may be open at once.
    public static let defaultMaxEmbeddedDepth = 16
    /// Default upper bound on the size of the report handed out, in bytes of
    /// its rendered errors.
    public static let defaultMaxReportBytes = 8 * 1024 * 1024

    /// Upper bound on how many nesting levels of the data validation steps
    /// into.
    public var maxNestingDepth: Int
    /// Upper bound on how many rule references are resolved against one data
    /// item before validation steps into a nested one.
    public var maxRuleNesting: Int
    /// Upper bound on what the descent to one data item may cost, counted over
    /// the levels stepped into and the rule references resolved on the way.
    public var maxDescentCost: Int
    /// What a step into a nested data item charges `maxDescentCost`.
    public var dataLevelCost: Int
    /// What a rule reference resolved against the data item already held
    /// charges `maxDescentCost`.
    public var ruleHopCost: Int
    /// Upper bound on the elementary steps one validation run may take: a step
    /// is matching a type against the data item held, or stepping into an item
    /// nested inside it.
    public var maxValidationWork: Int
    /// Upper bound on how many payloads decoded out of the document -- byte
    /// strings a `.cbor` or `.cborseq` control decodes, byte strings a text
    /// conversion control decodes, bit numbers `.bits` enumerates -- may be
    /// open at once.
    public var maxEmbeddedDepth: Int
    /// Upper bound on the size of the report handed out, in bytes of the
    /// rendered errors, with the errors most deeply nested in the data kept when the
    /// report would exceed it.
    public var maxReportBytes: Int

    /// Limits with the given bounds; every bound left out takes its default.
    public init(
        maxNestingDepth: Int = defaultMaxNestingDepth,
        maxRuleNesting: Int = defaultMaxRuleNesting,
        maxDescentCost: Int = defaultMaxDescentCost,
        dataLevelCost: Int = defaultDataLevelCost,
        ruleHopCost: Int = defaultRuleHopCost,
        maxValidationWork: Int = defaultMaxValidationWork,
        maxEmbeddedDepth: Int = defaultMaxEmbeddedDepth,
        maxReportBytes: Int = defaultMaxReportBytes
    ) {
        self.maxNestingDepth = maxNestingDepth
        self.maxRuleNesting = maxRuleNesting
        self.maxDescentCost = maxDescentCost
        self.dataLevelCost = dataLevelCost
        self.ruleHopCost = ruleHopCost
        self.maxValidationWork = maxValidationWork
        self.maxEmbeddedDepth = maxEmbeddedDepth
        self.maxReportBytes = maxReportBytes
    }
}

/// What one validation run has spent of its work budget.
///
/// One run is not one validator: a step into nested data walks a level of its
/// own, and every alternative of a choice is evaluated on a copy, so the
/// budget is shared by every level of the run, and what an alternative spent
/// before failing stays spent.
final class WorkBudget: @unchecked Sendable {
    private var spent = 0
    /// The bound this budget was created against.
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// Charges one step, and says whether it was within the budget. Charging
    /// past the limit keeps counting, so every later charge answers `false`
    /// too.
    func charge() -> Bool {
        let before = spent
        spent &+= 1
        return before < limit
    }

    /// Whether a step was ever charged that the budget did not have.
    var overspent: Bool {
        spent > limit
    }
}

/// Charges one step of a descent, and says what the descent then holds, or the
/// reason it would hold more than `limit`.
func chargeDescent(_ spent: Int, _ cost: Int, _ limit: Int) -> Result<Int, LimitReason> {
    let (charged, overflow) = spent.addingReportingOverflow(cost)
    let total = overflow ? Int.max : charged
    if total > limit {
        return .failure(
            LimitReason(
                "the descent to this data item holds more memory than the maximum supported descent budget of \(limit) bytes"
            ))
    }
    return .success(total)
}

/// The reason an implementation limit was reached.
struct LimitReason: Error, Sendable {
    var reason: String
    init(_ reason: String) {
        self.reason = reason
    }
}

// MARK: - Locations

/// A location in the data, as a row of the ``PathArena`` the walk keeps.
struct PathId: Hashable, Sendable {
    let raw: UInt32
    /// The root of the document.
    static let root = PathId(raw: 0)
}

/// One step of a path.
enum Segment: Sendable {
    /// The item at this index of an array.
    case index(Int)
    /// The entry under this key of a map, rendered as a path component.
    case key(String)

    /// How many bytes the segment renders to, after the `/` before it.
    var renderedLength: Int {
        switch self {
        case .index(let idx): return String(idx).utf8.count
        case .key(let key): return key.utf8.count
        }
    }
}

/// The paths a walk has stepped along. Rows are appended, never rewritten, so
/// recording a location costs nothing proportional to how deep it is.
final class PathArena: @unchecked Sendable {
    private struct Row {
        let parent: PathId
        let depth: Int
        let renderedLength: Int
        let segment: Segment
    }

    private var rows: [Row] = []

    /// The location one segment below `parent`.
    func child(_ parent: PathId, _ segment: Segment) -> PathId {
        let row = Row(
            parent: parent,
            depth: depth(parent) + 1,
            renderedLength: renderedLength(parent) + 1 + segment.renderedLength,
            segment: segment
        )
        rows.append(row)
        return PathId(raw: UInt32(rows.count))
    }

    private func row(_ id: PathId) -> Row? {
        id.raw == 0 ? nil : rows[Int(id.raw) - 1]
    }

    /// How many segments from the root `id` is.
    func depth(_ id: PathId) -> Int {
        row(id)?.depth ?? 0
    }

    /// How many bytes ``render(_:)`` writes `id` as.
    func renderedLength(_ id: PathId) -> Int {
        row(id)?.renderedLength ?? 0
    }

    /// `id` as the validators write a location: one `/`-prefixed segment per
    /// step from the root, and the empty string for the root itself.
    func render(_ id: PathId) -> String {
        var segments: [Segment] = []
        var at = id
        while let row = row(at) {
            segments.append(row.segment)
            at = row.parent
        }
        var rendered = ""
        for segment in segments.reversed() {
            rendered += "/"
            switch segment {
            case .index(let idx): rendered += String(idx)
            case .key(let key): rendered += key
            }
        }
        return rendered
    }
}

/// An error recorded while walking, before it is rendered into the report. It
/// names its location by index into the walk's ``PathArena``.
struct ErrorRecord: Sendable {
    var reason: String
    var location: PathId
    var isMultiTypeChoice: Bool
    var isMultiGroupChoice: Bool
    var isGroupToChoiceEnum: Bool
    var typeGroupNameEntry: String?

    /// How many bytes the error renders to in a report: its reason and its
    /// location.
    func renderedLength(_ paths: PathArena) -> Int {
        reason.utf8.count + paths.renderedLength(location)
    }

    /// How many bytes the record holds while the walk keeps it.
    var heldBytes: Int {
        MemoryLayout<ErrorRecord>.size + reason.utf8.count
    }
}

/// How many bytes `errors` hold while the walk keeps them.
func heldBytes(_ errors: [ErrorRecord]) -> Int {
    errors.reduce(0) { $0 + $1.heldBytes }
}

/// Keeps of `errors` what a report of at most `maxBytes` rendered bytes hands
/// out: all of them when they fit, and otherwise the most deeply nested in the data, in
/// the order they were recorded, up to the budget -- the most deeply nested of all
/// whatever it renders to, so that a report is never empty.
func retainWithinReport(_ errors: inout [ErrorRecord], _ paths: PathArena, _ maxBytes: Int) {
    let rendered = errors.reduce(0) { $0 + $1.renderedLength(paths) }
    if rendered <= maxBytes {
        return
    }

    let depths = errors.map { paths.depth($0.location) }
    let maxDepth = depths.max() ?? 0
    var order: [Int]
    if maxDepth < 4 * errors.count {
        var starts = [Int](repeating: 0, count: maxDepth + 2)
        for depth in depths {
            starts[maxDepth - depth + 1] += 1
        }
        for bucket in 1..<starts.count {
            starts[bucket] += starts[bucket - 1]
        }
        order = [Int](repeating: 0, count: errors.count)
        for (i, depth) in depths.enumerated() {
            order[starts[maxDepth - depth]] = i
            starts[maxDepth - depth] += 1
        }
    } else {
        order = Array(errors.indices)
        // A stable sort, most deeply nested first, keeping the recorded order among
        // equals.
        order = order.enumerated().sorted { a, b in
            if depths[a.element] != depths[b.element] {
                return depths[a.element] > depths[b.element]
            }
            return a.offset < b.offset
        }.map(\.element)
    }

    var keep = [Bool](repeating: false, count: errors.count)
    var spent = 0
    for (rank, i) in order.enumerated() {
        let cost = errors[i].renderedLength(paths)
        if rank > 0 && spent + cost > maxBytes {
            break
        }
        spent += cost
        keep[i] = true
    }

    var index = 0
    errors.removeAll { _ in
        defer { index += 1 }
        return !keep[index]
    }
}

/// The errors of a report, in the order they were recorded, with only what a
/// report of `maxBytes` rendered bytes hands out retained.
func retainedErrors(_ errors: [ErrorRecord], _ paths: PathArena, _ maxBytes: Int) -> [ErrorRecord] {
    var errors = errors
    retainWithinReport(&errors, paths, maxBytes)
    return errors
}

// MARK: - Running an asynchronous walk to completion

/// A value handed across the one thread boundary a blocking call makes; the
/// caller waits until the task that uses it is done.
final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}

/// Runs `body` as a task and blocks the calling thread until it completes.
///
/// The walk keeps its continuations in the frames of asynchronous calls, which
/// live on the heap, and it never waits on anything outside itself: every job
/// of the task can run on the thread that asked for the result. The calling
/// thread is the task's preferred executor and runs every job of the task itself, so a blocking call needs no
/// thread of the shared concurrency pool and is safe from any context -- a
/// plain thread, the main thread, or a task on a pool that every other task
/// has blocked.
func runBlocking<T>(_ body: @escaping @Sendable () async -> T) -> T {
    let executor = CallingThreadExecutor()
    let result = UncheckedBox<T?>(nil)
    Task.detached(executorPreference: executor) {
        result.value = await body()
        executor.finish()
    }
    executor.drain()
    return result.value!
}

/// A task executor whose jobs run on the thread that drains it.
private final class CallingThreadExecutor: TaskExecutor, @unchecked Sendable {
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []
    private var head = 0
    private var finished = false

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    /// Marks the task done; ``drain()`` returns once no job is left.
    func finish() {
        condition.lock()
        finished = true
        condition.signal()
        condition.unlock()
    }

    /// Runs the jobs handed to this executor on the calling thread until the
    /// task is done and every job it enqueued has run.
    func drain() {
        let executor = asUnownedTaskExecutor()
        while true {
            condition.lock()
            while head == jobs.count && !finished {
                condition.wait()
            }
            if head == jobs.count {
                condition.unlock()
                return
            }
            let job = jobs[head]
            head += 1
            if head == jobs.count {
                jobs.removeAll(keepingCapacity: true)
                head = 0
            }
            condition.unlock()
            job.runSynchronously(on: executor)
        }
    }
}
