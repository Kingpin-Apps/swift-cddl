import Foundation
import Testing

@testable import SwiftCDDL

@Suite("Large-stack thread")
struct LargeStackTests {
    #if canImport(Darwin)
    @Test("The thread takes the caller's quality of service, so a waiting caller is not held back")
    func inheritsQualityOfService() async {
        // `async`, not `sync`: a synchronous block keeps the calling thread's own class.
        let (caller, inner) = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let caller = qos_class_self()
                continuation.resume(returning: (caller, withLargeStack { qos_class_self() }))
            }
        }
        #expect(caller == QOS_CLASS_USER_INITIATED)
        #expect(inner == caller)
    }
    #endif
}
