// SwordNativeModuleRegistry.swift — pinned JSword native config and owner capture

import CLibSword
import Foundation

/**
 Captures the immutable native SWORD registry consumed by one `SwordManager` generation.

 The service owns config discovery, libsword exact-name verification, native `HashSet` admission,
 exact-map ambiguity handling, handle authorization, and installed TreeSet alias ordering. Manager
 lifecycle/caching and cipher persistence remain with `SwordManager`.

 - Side effects: Reads installed configs, asks libsword for exact native handles, and populates the
 supplied exact-keyed authorization cache for ownership-proven modules. No content is read.
 - Failure modes: Custom, payload-invalid, cross-resolved, unsupported, duplicate-initial, and
 ambiguous-full-name owners fail closed at their documented lookup tiers.
 */
enum SwordNativeModuleRegistry {
    /**
     Builds one supported native inventory and its ownership-proven lookup indexes.

     - Parameters:
       - modulePath: SWORD root containing `mods.d` and payloads.
       - managerHandle: Live libsword manager handle used only inside `SwordRuntime` serialization.
       - authorizationCache: Exact module-wrapper and session-unlock cache owned by the manager.
       - adjustedLocation: Pinned JSword payload/location admission projection.
       - moduleInfo: Current inclusive metadata/access-state projection for one config.
       - bookClassIdentity: Concrete JSword `AbstractBook` class discriminator.
     - Returns: Installed native rows, exact maps, ambiguity sets, and TreeSet alias order.
     - Side effects: Performs the type-level side effects and retains authorized wrappers in cache.
     - Failure modes: Any failed config/payload/handle/identity gate omits that row; raw duplicate
       initials and duplicate exact full names withhold only the unsafe lookup tier.
     - Complexity: O(N log N) for one manager generation.
     */
    static func capture(
        modulePath: String,
        managerHandle: UnsafeMutableRawPointer,
        authorizationCache: SwordModuleHandleAuthorizationCache,
        adjustedLocation: (SwordModuleConfig) -> SwordManager.AdjustedModuleLocation?,
        moduleInfo: (SwordModuleConfig, Bool) -> ModuleInfo,
        bookClassIdentity: (SwordModuleConfig) -> NativeSwordBookClassIdentity
    ) -> NativeModuleRegistrySnapshot {
        let configs = SwordModuleConfig.readAll(modulePath: modulePath)
        var exactInitialCounts: [SwordJavaExactStringIdentity: Int] = [:]
        for config in configs {
            exactInitialCounts[SwordJavaExactStringIdentity(config.name), default: 0] += 1
        }
        let ambiguousExactInitials = Set(
            exactInitialCounts.compactMap { identity, count in
                count > 1 ? identity : nil
            }
        )

        let deterministicConfigs = configs.sorted {
            SwordInstalledBookSetProjection.compareJavaString(
                $0.sourceURL?.path ?? "",
                $1.sourceURL?.path ?? ""
            ) < 0
        }
        var nativeHashIdentities: Set<NativeSwordBookHashIdentity> = []
        var installedBooks: [NativeInstalledBook] = []
        var resolvableRegistrations: [NativeModuleRegistration] = []
        for config in deterministicConfigs {
            guard !config.isAndroidCustomDriver,
                  let configURL = config.sourceURL,
                  let admittedLocation = adjustedLocation(config),
                  let moduleHandle = SWMgr_getModuleByName(managerHandle, config.name) else {
                continue
            }
            let nativeName = String(cString: SWModule_getName(moduleHandle))
            guard SwordJavaStringIdentity.equals(nativeName, config.name) else {
                continue
            }

            let persistedCipherKey = config.values["CipherKey"]?.first
            let isEncrypted = persistedCipherKey != nil
            let isUnlocked = !isEncrypted
                || authorizationCache.isSessionUnlocked(config.name)
                || (persistedCipherKey?.isEmpty == false)
            let info = moduleInfo(config, isUnlocked)
            guard info.isSupported else { continue }

            let nativeHashIdentity = NativeSwordBookHashIdentity(
                bookClass: bookClassIdentity(config),
                categoryOrdinal: SwordInstalledBookSetProjection.categoryOrdinal(info.category),
                initials: SwordJavaExactStringIdentity(info.name),
                fullName: SwordJavaExactStringIdentity(config.description)
            )
            guard nativeHashIdentities.insert(nativeHashIdentity).inserted else { continue }

            let configuredAbbreviation = config.values["Abbreviation"]?.first
                .map(SwordJavaStringIdentity.trim)
            let abbreviation = configuredAbbreviation.flatMap { $0.isEmpty ? nil : $0 }
                ?? info.name
            installedBooks.append(
                NativeInstalledBook(
                    registration: InstalledModuleRegistration(
                        info: info,
                        abbreviation: abbreviation,
                        fullName: config.description
                    ),
                    config: config,
                    locationURL: admittedLocation.url
                )
            )

            let exactInitials = SwordJavaExactStringIdentity(config.name)
            guard !ambiguousExactInitials.contains(exactInitials),
                  let module = authorizationCache.module(
                    name: config.name,
                    handle: moduleHandle,
                    modulePath: modulePath,
                    config: config
                  ) else {
                continue
            }
            resolvableRegistrations.append(
                NativeModuleRegistration(
                    module: module,
                    info: info,
                    abbreviation: abbreviation,
                    fullName: config.description,
                    configURL: configURL
                )
            )
        }

        let treeSetRegistrations = resolvableRegistrations.sorted {
            SwordInstalledBookSetProjection.compareNative($0, $1) < 0
        }
        var exactInitials: [SwordJavaExactStringIdentity: NativeModuleRegistration] = [:]
        var exactFullNameCounts: [SwordJavaExactStringIdentity: Int] = [:]
        for registration in treeSetRegistrations {
            exactInitials[SwordJavaExactStringIdentity(registration.info.name)] = registration
            exactFullNameCounts[
                SwordJavaExactStringIdentity(registration.fullName),
                default: 0
            ] += 1
        }
        var exactFullNames: [SwordJavaExactStringIdentity: NativeModuleRegistration] = [:]
        for registration in treeSetRegistrations {
            let identity = SwordJavaExactStringIdentity(registration.fullName)
            if exactFullNameCounts[identity] == 1 {
                exactFullNames[identity] = registration
            }
        }
        return NativeModuleRegistrySnapshot(
            installedBooks: installedBooks,
            exactInitials: exactInitials,
            exactFullNames: exactFullNames,
            ambiguousExactFullNames: Set(
                exactFullNameCounts.compactMap { identity, count in
                    count > 1 ? identity : nil
                }
            ),
            treeSetRegistrations: treeSetRegistrations
        )
    }
}
