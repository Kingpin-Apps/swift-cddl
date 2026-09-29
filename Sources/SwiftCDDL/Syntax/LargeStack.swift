import Foundation

// The parser is recursive descent: every level of nesting in a schema costs a
// number of stack frames (many more in debug builds), and a caller may be on a
// thread with a small stack (Swift concurrency's cooperative threads have
// 512 KiB). The recursive passes therefore run on a thread of their own with a
// stack large enough for any realistic nesting depth.

/// Stack size of the thread the recursive passes run on: enough for a
/// thousand levels of nesting even in a debug build.
let largeStackSize = MemoryLayout<Int>.size == 8 ? 256 << 20 : 32 << 20

private final class ResultBox<T>: @unchecked Sendable {
    var value: T?
}

/// Runs `body` on a dedicated thread with a stack of `largeStackSize` bytes
/// and returns its result.
///
/// The thread takes the caller's quality of service. The caller waits for
/// it, so a lower one would leave a user-initiated caller stuck behind
/// default-priority work: a priority inversion.
func withLargeStack<T>(_ body: @escaping @Sendable () -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = largeStackSize
    thread.qualityOfService = callerQualityOfService()
    thread.start()
    done.wait()
    return box.value!
}

/// The quality of service the current thread runs at. `Thread.current`'s own
/// property reports `.default` on Dispatch and Swift concurrency threads, so
/// the thread's actual class is read instead.
func callerQualityOfService() -> QualityOfService {
    #if canImport(Darwin)
    switch qos_class_self() {
    case QOS_CLASS_USER_INTERACTIVE: .userInteractive
    case QOS_CLASS_USER_INITIATED: .userInitiated
    case QOS_CLASS_UTILITY: .utility
    case QOS_CLASS_BACKGROUND: .background
    default: .default
    }
    #else
    Thread.current.qualityOfService
    #endif
}
