// ModuleBrowserDefaultDownloadStrictPackageState.swift - Easy Start strict retry state

import SwordKit

/**
 Strict package-policy lifecycle for one startup default module.

 Failed Easy Start installs keep strict package policy so row retries cannot fall back to raw
 testament probes and recreate the partial-Bible failure from issue 354. Successful installs and
 user cancellations clear strict membership because that default request no longer owns retries.
 */
enum ModuleBrowserDefaultDownloadStrictPackageResolution: Sendable, Equatable {
    /// Remove the module from strict package-policy membership.
    case clear

    /// Keep the module strict so the visible retry path still requires the Android package ZIP.
    case retainForRetry
}

/**
 Tracks Easy Start default modules whose retry policy must remain package-only.

 Android's startup flow treats recommended default Bibles as package installs. This reducer keeps
 the active default-install set separate from the strict retry set so a visible failure can finish
 the startup activity while the row retry still requires the package ZIP. The type performs no
 asynchronous work and owns no UI side effects; callers decide when to notify activity observers.
 */
struct ModuleBrowserDefaultDownloadStrictPackageState: Sendable, Equatable {
    /// Startup default module names whose asynchronous installs have not finished yet.
    private(set) var installingModules: Set<String> = []

    /// Startup default module names whose retries must keep strict package-only install policy.
    private(set) var strictModules: Set<String> = []

    /**
     Adds newly planned startup default modules to both active and strict retry state.

     - Parameter moduleNames: Module initials selected by the default-document planner.
     - Side effects: mutates only this value's `installingModules` and `strictModules` sets.
     - Failure modes: none; empty sets are accepted and leave state unchanged.
     */
    mutating func startInstalling(_ moduleNames: Set<String>) {
        installingModules.formUnion(moduleNames)
        strictModules.formUnion(moduleNames)
    }

    /**
     Records one startup default terminal state and reports whether the activity is exhausted.

     Failed installs retain strict policy for row retries. Successful installs and explicit user
     cancellations clear strict membership because the default-document request is no longer the
     owner of that module's retry behavior.

     - Parameters:
       - moduleName: Module initials for the completed, failed, or cancelled install.
       - strictPolicyResolution: Whether this terminal state keeps strict package policy.
     - Returns: `true` when no startup default installs remain active after this transition.
     - Side effects: mutates only this value's active and strict module sets.
     - Failure modes: none; unknown module names are ignored except that `.clear` removes matching
       stale strict membership if present.
     */
    @discardableResult
    mutating func finish(
        _ moduleName: String,
        strictPolicyResolution: ModuleBrowserDefaultDownloadStrictPackageResolution
    ) -> Bool {
        if case .clear = strictPolicyResolution {
            strictModules.remove(moduleName)
        }
        installingModules.remove(moduleName)
        return installingModules.isEmpty
    }

    /**
     Clears active startup activity without changing strict retry membership.

     The Downloads coordinator can stop showing startup activity once every planned default has
     reached a terminal row state. Failed rows remain strict for retry until success, cancellation,
     or the Downloads session ending discards this state value.

     - Side effects: mutates only this value's `installingModules` set.
     - Failure modes: none.
     */
    mutating func finishActivity() {
        installingModules.removeAll()
    }

    /**
     Returns the install policy for a module under the current strict retry state.

     - Parameters:
       - mode: Downloads entry mode; only Easy Start defaults can require package-only installs.
       - moduleName: Module initials about to be installed.
     - Returns: `.requirePackage` only when `moduleName` remains in the strict retry set for an
       Easy Start session; otherwise `.preferPackageThenRaw`.
     - Side effects: none.
     - Failure modes: none.
     */
    func packageInstallPolicy(
        mode: ModuleBrowserDefaultDownloadMode,
        moduleName: String
    ) -> ModulePackageInstallPolicy {
        mode.modulePackageInstallPolicy(for: moduleName, strictDefaultModules: strictModules)
    }
}
