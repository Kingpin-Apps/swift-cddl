import Foundation
import Testing

@testable import SwiftCDDL

// The blocking validation entry points must finish from any calling context:
// a plain thread, and tasks of the shared concurrency pool that all block at
// once, more of them than the pool has threads.

private let schema = """
    root = [* entry]
    entry = { name: tstr, ? tags: [* tstr], nested: [* int] }
    """

/// `count` entries matching `schema`, as CBOR.
private func matchingCBOR(_ count: Int) -> [UInt8] {
    // An array of `count` maps { "name": "n", "nested": [1, 2, 3] }.
    var bytes: [UInt8] = [0x98, UInt8(count)]
    for _ in 0..<count {
        bytes += [0xa2, 0x64] + Array("name".utf8) + [0x61, 0x6e]
        bytes += [0x66] + Array("nested".utf8) + [0x83, 0x01, 0x02, 0x03]
    }
    return bytes
}

/// A mismatching document: the first entry carries no `nested`.
private let mismatchingCBOR: [UInt8] = [0x81, 0xa1, 0x64] + Array("name".utf8) + [0x61, 0x6e]

private let matchingJSON = #"[{"name": "n", "nested": [1, 2, 3]}, {"name": "m", "tags": ["a"], "nested": []}]"#
private let mismatchingJSON = #"[{"name": 1, "nested": []}]"#

/// Runs every blocking entry point once and says whether each gave the
/// expected verdict. Synchronous, so the blocking overloads are the ones
/// called.
private func blockingVerdictsHold() -> Bool {
    var holds = true
    do {
        try validateCBOR(cddl: schema, cbor: matchingCBOR(20))
    } catch {
        holds = false
    }
    do {
        try validateCBOR(cddl: schema, cbor: mismatchingCBOR)
        holds = false
    } catch {}
    do {
        try validateJSON(cddl: schema, json: matchingJSON)
    } catch {
        holds = false
    }
    do {
        try validateJSON(cddl: schema, json: mismatchingJSON)
        holds = false
    } catch {}
    return holds
}

/// How long the callers of one test may take in all. The callers are tasks
/// of the shared pool, which the rest of the suite keeps busy, so the bound is
/// generous: it tells a deadlock from a slow start.
private let callerDeadlineSeconds = 300

/// Waits for `count` signals of `finished`, for at most
/// `callerDeadlineSeconds` in all.
///
/// A blocking call that deadlocks takes the threads of the shared pool with
/// it, and a pool left without threads cannot report a test failure either,
/// so running out of time stops the process rather than recording an issue.
private func awaitCallers(_ finished: DispatchSemaphore, _ count: Int, _ what: String) {
    let deadline = DispatchTime.now() + .seconds(callerDeadlineSeconds)
    for _ in 0..<count where finished.wait(timeout: deadline) != .success {
        fatalError("\(what) did not finish within \(callerDeadlineSeconds) seconds: the blocking entry points deadlocked")
    }
}

private final class FailureCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

@Suite struct BlockingContextTests {
    @Test func blockingCallsFinishFromSixtyFourConcurrentTasks() {
        let callers = 64
        let finished = DispatchSemaphore(value: 0)
        let failures = FailureCount()
        for _ in 0..<callers {
            Task.detached {
                if !blockingVerdictsHold() {
                    failures.record()
                }
                finished.signal()
            }
        }
        awaitCallers(finished, callers, "blocking validation from concurrent tasks")
        #expect(failures.value == 0)
    }

    @Test func blockingCallsFinishFromAPlainThread() {
        let finished = DispatchSemaphore(value: 0)
        let failures = FailureCount()
        let thread = Thread {
            if !blockingVerdictsHold() {
                failures.record()
            }
            finished.signal()
        }
        thread.start()
        awaitCallers(finished, 1, "blocking validation from a plain thread")
        #expect(failures.value == 0)
    }

    @Test func blockingValidatorMethodsFinishFromConcurrentTasks() {
        let callers = 64
        let finished = DispatchSemaphore(value: 0)
        let failures = FailureCount()
        for _ in 0..<callers {
            Task.detached {
                do {
                    let cddl = try cddlFromStr(schema)
                    let validator = CBORValidator(cddl: cddl, cbor: try decodeCBOR(matchingCBOR(8)))
                    try validator.validate()
                    let jsonValidator = JSONValidator(cddl: cddl, json: try JSONNode.parse(matchingJSON))
                    try jsonValidator.validate()
                } catch {
                    failures.record()
                }
                finished.signal()
            }
        }
        awaitCallers(finished, callers, "blocking validator methods")
        #expect(failures.value == 0)
    }
}
