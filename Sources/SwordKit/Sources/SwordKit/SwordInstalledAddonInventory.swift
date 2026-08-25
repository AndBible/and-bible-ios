// SwordInstalledAddonInventory.swift — shared Android add-on feature projection

import Foundation

/**
 Projects installed add-on owners through Android's final BookSet and feature-admission contract.

 Candidate discovery is performed by the installed registry because standalone CSV books and
 config-backed books participate in one add sequence. This service owns the subsequent TreeSet
 replacement, minimum-version filter, exact-initial ambiguity rules, and safe font projection used
 by every prompt/picker/font/reading-plan consumer.

 - Side effects: Loads pinned Java comparison tables and reads provider-file metadata/symlinks;
 feature contents are not read and the module store is never mutated.
 - Failure modes: Future/malformed owners and unsafe or unreadable provider rows are omitted fail
 closed. Comparator-equal owners are replaced before feature admission, exactly like Android.
 */
enum SwordInstalledAddonInventory {
    /**
     Builds the immutable admitted add-on projection for one installed generation.

     - Parameters:
       - candidates: Config-backed and standalone owners in Android book-add order.
       - applicationVersionNumber: Exact Android version-code compatibility boundary.
     - Returns: Final admitted add-ons in pinned JSword TreeSet order.
     - Side effects: Checks font paths and loads pinned Java string comparison data.
     - Failure modes: Rejected owners are omitted; exact-initial ambiguity suppresses font rows
       whose backing owner cannot be proven while preserving the inclusive installed book.
     */
    static func modules(
        from candidates: [InstalledAddonCandidate],
        applicationVersionNumber: Int
    ) -> [SwordAdmittedAddonModule] {
        let admittedCandidates = admittedCandidates(
            candidates,
            applicationVersionNumber: applicationVersionNumber
        )
        var exactInitialCounts: [SwordJavaExactStringIdentity: Int] = [:]
        for candidate in admittedCandidates {
            exactInitialCounts[
                SwordJavaExactStringIdentity(candidate.registration.info.name),
                default: 0
            ] += 1
        }
        return admittedCandidates.map { candidate in
            let initialsKey = SwordJavaExactStringIdentity(candidate.registration.info.name)
            let hasUnambiguousInitials = exactInitialCounts[initialsKey] == 1
            let candidateFonts = admittedFontProviders(for: candidate)
            return SwordAdmittedAddonModule(
                moduleInfo: candidate.registration.info,
                abbreviation: candidate.registration.abbreviation,
                promptFileName: candidate.config.values["AndBibleProvidesPrompts"]?.first,
                providedFonts: hasUnambiguousInitials ? candidateFonts : [],
                reservedFontFileURLs: candidateFonts.map(\.fileURL),
                providesFont: hasUnambiguousInitials
                    && candidate.config.values["AndBibleProvidesFont"] != nil,
                providesWebFeature: candidate.config.values["AndBibleProvidesFeature"] != nil,
                providesWebStyle: candidate.config.values["AndBibleProvidesStyle"] != nil,
                locationURL: candidate.locationURL,
                removalTarget: candidate.removalTarget,
                isManualTtfRegistration: candidate.config.values["AndBibleIOSManualTtf"]?.first?
                    .caseInsensitiveCompare("true") == .orderedSame
            )
        }
    }

    /**
     Replays final installed TreeSet ownership before Android compatibility filtering.

     - Parameters:
       - candidates: Installed native/synthetic candidates in Android add order.
       - applicationVersionNumber: Android version code supported by this build.
     - Returns: Comparator-distinct compatible owners in installed-book order.
     - Side effects: Loads pinned Java case-fold data for abbreviation comparison.
     - Failure modes: Missing minimum defaults to zero; malformed/overflowing values fail closed.
     */
    static func admittedCandidates(
        _ candidates: [InstalledAddonCandidate],
        applicationVersionNumber: Int
    ) -> [InstalledAddonCandidate] {
        var surviving: [InstalledBookSetIdentity: InstalledAddonCandidate] = [:]
        for candidate in candidates {
            surviving[SwordInstalledBookSetProjection.identity(for: candidate.registration)] = candidate
        }
        return surviving.values.sorted {
            SwordInstalledBookSetProjection.compare($0.registration, $1.registration) < 0
        }.filter {
            configIsAdmitted(
                $0.config,
                applicationVersionNumber: applicationVersionNumber
            )
        }
    }

    /**
     Applies Android's add-on category and first-value minimum-version admission.

     - Parameters:
       - config: Final installed TreeSet owner.
       - applicationVersionNumber: Android version code supported by this build.
     - Returns: True only for a supported `And Bible` owner at or below the compatibility boundary.
     - Side effects: None.
     - Failure modes: Malformed and overflowing minimum-version text fails closed.
     */
    private static func configIsAdmitted(
        _ config: SwordModuleConfig,
        applicationVersionNumber: Int
    ) -> Bool {
        guard config.category == .addon, config.moduleInfo.isSupported else { return false }
        let rawMinimum = config.values["AndBibleMinimumVersion"]?.first ?? "0"
        guard let minimumVersion = Int64(rawMinimum) else { return false }
        return minimumVersion <= Int64(applicationVersionNumber)
    }

    /**
     Resolves readable font markers for one already-admitted exact add-on owner.

     - Parameter candidate: Final installed owner with parsed marker metadata and adjusted location.
     - Returns: Provider rows in repeated-property order with exact names and contained file URLs.
     - Side effects: Resolves symlinks and reads file metadata; font contents are not opened.
     - Failure modes: Missing location, malformed/traversing marker, escaped symlink, directory,
       missing file, and unreadable file omit only that provider row.
     */
    private static func admittedFontProviders(
        for candidate: InstalledAddonCandidate
    ) -> [SwordAdmittedFont] {
        guard let locationURL = candidate.locationURL,
              let markers = candidate.config.values["AndBibleProvidesFont"] else {
            return []
        }
        let root = locationURL.standardizedFileURL.resolvingSymlinksInPath()
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        let fileManager = FileManager.default
        return markers.compactMap { marker in
            let fields = marker.split(
                separator: ";",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard fields.count >= 2 else { return nil }
            let name = fields[0]
            let relativePath = fields[1]
            let components = relativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).map(String.init)
            guard !name.isEmpty,
                  name.unicodeScalars.allSatisfy({
                      !CharacterSet.controlCharacters.contains($0)
                  }),
                  !components.isEmpty,
                  components.allSatisfy({
                      !$0.isEmpty && $0 != "." && $0 != ".."
                          && !$0.contains("\\") && !$0.contains("\0")
                  }) else {
                return nil
            }
            let unresolved = components.reduce(root) { partial, component in
                partial.appendingPathComponent(component)
            }
            let resolved = unresolved.standardizedFileURL.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(rootPrefix),
                  let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true,
                  fileManager.isReadableFile(atPath: resolved.path) else {
                return nil
            }
            return SwordAdmittedFont(
                moduleName: candidate.registration.info.name,
                name: name,
                relativePath: relativePath,
                fileURL: resolved
            )
        }
    }
}
