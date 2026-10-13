import CLibSword

/**
 Owns one immutable native SWMgr and the SWModule handles allocated by it.

 Managers and escaped module wrappers share this storage. Keeping it separate from the manager's
 wrapper caches prevents a retain cycle while ensuring asynchronous module reads cannot outlive
 their native allocation. All native operations and final destruction use SwordRuntime.
 */
final class SwordNativeManagerStorage: @unchecked Sendable {
    /// Native manager allocation, valid until the last manager or module releases this storage.
    let handle: UnsafeMutableRawPointer

    /** Takes exclusive destruction responsibility for an already-created SWMgr; performs no I/O. */
    init(handle: UnsafeMutableRawPointer) {
        self.handle = handle
    }

    /** Deletes the manager and its modules only after all Swift owners have released them. */
    deinit {
        SwordRuntime.sync { SWMgr_delete(handle) }
    }
}
