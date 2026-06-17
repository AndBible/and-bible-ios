import Foundation

/**
 Shared notification contract for mutations to the installed module store.

 `SwordManager` instances cache SWORD's module list at both Swift and C bridge levels, and Downloads
 also combines that list with sidecar MyBible installs. File-system mutations therefore need a
 process-wide signal so already-open UI surfaces can rebuild their snapshots instead of waiting for
 an app restart. The notification intentionally carries no payload: consumers must rescan storage
 because installs, restores, overwrites, and uninstalls can affect multiple categories and module
 names.
 */
public enum SwordModuleStore {
    /**
     Posted after a successful mutation of installed module files.

     Side effects:
     - observers may rebuild `SwordManager` instances and refresh installed-module UI state

     Failure modes:
     - notification delivery is best-effort and synchronous according to `NotificationCenter`
       semantics; the storage mutation has already completed before the event is posted.
     */
    public static let modulesDidChangeNotification = Notification.Name(
        "org.andbible.SwordModuleStore.modulesDidChange"
    )

    /**
     Announces that installed module files changed and cached module snapshots should rescan.

     - Parameter center: Notification center used for publication. Tests may inject a local center,
       while production uses `.default`.
     - Side effects: Posts `modulesDidChangeNotification`.
     - Failure modes: None; `NotificationCenter` posting does not throw.
     */
    public static func notifyModulesDidChange(center: NotificationCenter = .default) {
        center.post(name: modulesDidChangeNotification, object: nil)
    }
}
