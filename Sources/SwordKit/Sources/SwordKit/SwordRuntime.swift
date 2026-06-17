// SwordRuntime.swift - process-wide SWORD runtime serialization

import Foundation

/**
 Process-wide gate for every call into libsword and the local C adapter.

 SWORD and the bridge layer keep process-global state, including cached flat-API pointer lists and
 native parser/rendering state. Instance-level queues cannot protect that state when separate
 `SwordManager`, `SwordModule`, `InstallManager`, or `SwordConfig` values are used concurrently.
 This runtime provides one serialization point for those native calls while remaining reentrant, so
 composite SwordKit methods can call smaller helpers without deadlocking.

 - Inputs: A synchronous closure that performs one or more SWORD or SWORD-adjacent C calls.
 - Returns: The closure's copied Swift result after native pointers have been consumed.
 - Side effects: Serializes all work submitted through this type on a single private queue.
 - Failure modes: Rethrows closure errors. Native crashes remain possible if code bypasses this
   runtime and calls the non-thread-safe SWORD bridge directly.
 - Important: Keep callbacks passed to `sync(_:)` bounded and avoid waiting on work that itself
   needs the SWORD runtime from another thread.
 */
enum SwordRuntime {
    private static let queueKey = DispatchSpecificKey<Void>()

    private static let queue: DispatchQueue = {
        let queue = DispatchQueue(label: "org.andbible.SwordRuntime", qos: .userInitiated)
        queue.setSpecific(key: queueKey, value: ())
        return queue
    }()

    /**
     Executes SWORD work on the shared runtime queue.

     Nested calls execute inline when the current thread is already on the runtime queue. This keeps
     higher-level operations such as module creation safe when they call helper methods that also
     need SWORD access.

     - Parameter operation: Closure containing native SWORD bridge calls and immediate pointer
       copying.
     - Returns: The value returned by `operation`.
     - Throws: Rethrows errors from `operation`.
     - Side effects: May block until prior SWORD work completes.
     */
    static func sync<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try operation()
        }
        return try queue.sync(execute: operation)
    }
}
