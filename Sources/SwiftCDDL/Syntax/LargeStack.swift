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
func withLargeStack<T>(_ body: @escaping @Sendable () -> T) -> T {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        box.value = body()
        done.signal()
    }
    thread.stackSize = largeStackSize
    thread.start()
    done.wait()
    return box.value!
}
