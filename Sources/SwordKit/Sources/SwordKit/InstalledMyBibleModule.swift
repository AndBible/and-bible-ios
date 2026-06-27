// InstalledMyBibleModule.swift -- MyBible package sidecar metadata

import Foundation

/**
 Persisted metadata for one installed MyBible package.

 Android exposes MyBible packages through `Books.installed().books` after the SQLite payload is
 imported. iOS stores manifest-installed MyBible packages outside libsword with a `module.json`
 sidecar; this value type owns the shared projection from that sidecar into `ModuleInfo` so all
 installed-module callers use one Android-compatible inventory contract.
 */
struct InstalledMyBibleModule: Codable, Sendable {
    /// Installed module initials used by Downloads, reader lists, and uninstall.
    var name: String

    /// User-visible module description from the repository manifest.
    var description: String

    /// Raw `ModuleCategory` value captured at install time.
    var category: String

    /// Module language code captured from the manifest row.
    var language: String

    /// Manifest update marker captured as the installed version.
    var version: String

    /// Repository source name that produced this installed module.
    var sourceName: String

    /// Original package filename from the MyBible manifest.
    var packageFileName: String

    /// HTTPS package URL used for the install.
    var downloadURL: String

    /// Local install timestamp for diagnostics and future migrations.
    var installedAt: Date

    /// Converts sidecar metadata into the common installed-module row model.
    var moduleInfo: ModuleInfo {
        ModuleInfo(
            name: name,
            description: description,
            category: ModuleCategory(typeString: category),
            language: language,
            version: version
        )
    }

    /**
     Checks whether the installed module directory still contains a readable MyBible payload.

     Android only adds MyBible books to `Books.installed()` when the source SQLite file can be read.
     Matching that behavior keeps stale `module.json` files from creating fake installed modules.

     - Parameter moduleDirectory: Directory containing `module.json` and extracted package payloads.
     - Returns: `true` when at least one expected SQLite/MyBible file is readable.
     - Side effects: Reads directory metadata.
     - Failure modes: Missing or unreadable directories return `false`.
     */
    func hasReadablePayload(in moduleDirectory: URL) -> Bool {
        let fm = FileManager.default
        let urls = (try? fm.contentsOfDirectory(
            at: moduleDirectory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let expectedPayloadName = (packageFileName as NSString).deletingPathExtension

        return urls.contains { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  fm.isReadableFile(atPath: url.path) else {
                return false
            }
            let fileName = url.lastPathComponent
            let lowercased = fileName.lowercased()
            return lowercased.hasSuffix(".sqlite3") ||
                lowercased.hasSuffix(".mybible") ||
                (!expectedPayloadName.isEmpty && fileName == expectedPayloadName)
        }
    }
}
