// SwordInstalledMyBibleInventory.swift — Payload-owned installed MyBible package registration

import Foundation

/**
 Discovers and admits iOS package-installed MyBible payloads through Android's manual-book contract.

 Database payloads own identity, abbreviation, name, category, language, version, and features.
 Sidecars provide install/repository provenance only. Existing native/restored books are replayed
 before package candidates, matching Android's pre-add `Books.getBook(metadata.initials)` gate.

 - Side effects: Enumerates `mybible` package directories, decodes sidecars, opens SQLite payloads
   read-only, and may load the pinned Android case-fold table.
 - Failure modes: Missing/malformed packages and candidates resolving to an earlier BookSet owner are
   omitted independently and never replace installed content.
 */
enum SwordInstalledMyBibleInventory {
    /**
     Returns package modules in final installed TreeSet order with no earlier registrations.

     - Parameter modulePath: SWORD root containing the `mybible` package directory.
     - Returns: Database-derived, collision-admitted public metadata rows.
     - Side effects: Performs the type-level discovery reads.
     - Failure modes: Invalid candidates are omitted; an unavailable directory returns an empty list.
     */
    static func installedModules(modulePath: String) -> [ModuleInfo] {
        SwordInstalledBookSetProjection.registrationsInInstalledOrder(
            admittedRegistrations(modulePath: modulePath, after: [])
        ).map(\.info)
    }

    /**
     Discovers package candidates and applies Android's pre-add ownership lookup.

     - Parameters:
       - modulePath: SWORD root containing the `mybible` package directory.
       - existing: Native/restored registrations admitted before manual package discovery.
     - Returns: Package registrations accepted in deterministic payload discovery order.
     - Side effects: Performs the type-level discovery reads and exact/case-tier admission replay.
     - Failure modes: Invalid and colliding candidates are skipped independently.
     */
    static func admittedRegistrations(
        modulePath: String,
        after existing: [InstalledModuleRegistration]
    ) -> [InstalledModuleRegistration] {
        admit(discoveredRegistrations(modulePath: modulePath), after: existing)
    }

    /**
     Reads payload-owned registrations in deterministic raw UTF-16 path order.

     - Parameter modulePath: SWORD root containing package directories and sidecars.
     - Returns: Every structurally valid database-derived registration before collision admission.
     - Side effects: Enumerates directories, decodes JSON sidecars, and opens payload databases.
     - Failure modes: Missing/malformed entries are omitted independently; an unavailable root
       returns an empty list.
     */
    private static func discoveredRegistrations(
        modulePath: String
    ) -> [InstalledModuleRegistration] {
        let fileManager = FileManager.default
        let installDirectory = URL(fileURLWithPath: modulePath, isDirectory: true)
            .appendingPathComponent("mybible", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(
            at: installDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else {
            return []
        }

        return entries.sorted {
            SwordInstalledBookSetProjection.compareJavaString($0.path, $1.path) < 0
        }.flatMap { url -> [InstalledModuleRegistration] in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                return []
            }
            let metadataURL = url.appendingPathComponent("module.json")
            guard let data = try? Data(contentsOf: metadataURL),
                  let metadata = try? JSONDecoder().decode(InstalledMyBibleModule.self, from: data)
            else {
                return []
            }
            return InstalledMyBibleBookReader.registrations(in: url, sidecar: metadata).map {
                InstalledModuleRegistration(
                    info: $0.info,
                    abbreviation: $0.abbreviation,
                    fullName: $0.info.description
                )
            }
        }
    }

    /**
     Applies exact initials/name and Java case-tier lookup after every accepted package.

     - Parameters:
       - candidates: Package rows in deterministic discovery order.
       - existing: Native/restored registrations already visible to `Books.getBook`.
     - Returns: Only candidates whose initials do not resolve to an earlier exact or case-tier owner.
     - Side effects: Loads pinned Java case-fold data; no filesystem or registry mutation occurs.
     - Failure modes: Collisions are omitted independently without replacing the current owner.
     */
    private static func admit(
        _ candidates: [InstalledModuleRegistration],
        after existing: [InstalledModuleRegistration]
    ) -> [InstalledModuleRegistration] {
        var exactInitials = Set(existing.map { SwordJavaExactStringIdentity($0.info.name) })
        var exactFullNames = Set(existing.map { SwordJavaExactStringIdentity($0.fullName) })
        var foldedInitials = Set(existing.map { SwordJavaStringIdentity($0.info.name) })
        var foldedFullNames = Set(existing.map { SwordJavaStringIdentity($0.fullName) })
        var admitted: [InstalledModuleRegistration] = []
        for candidate in candidates {
            let lookup = candidate.info.name
            let exactLookup = SwordJavaExactStringIdentity(lookup)
            let hasExactMatch = exactInitials.contains(exactLookup)
                || exactFullNames.contains(exactLookup)
            let foldedLookup = SwordJavaStringIdentity(lookup)
            let hasAliasMatch = !hasExactMatch && (
                foldedInitials.contains(foldedLookup) || foldedFullNames.contains(foldedLookup)
            )
            guard !hasExactMatch, !hasAliasMatch else { continue }

            exactInitials.insert(SwordJavaExactStringIdentity(candidate.info.name))
            exactFullNames.insert(SwordJavaExactStringIdentity(candidate.fullName))
            foldedInitials.insert(SwordJavaStringIdentity(candidate.info.name))
            foldedFullNames.insert(SwordJavaStringIdentity(candidate.fullName))
            admitted.append(candidate)
        }
        return admitted
    }
}
