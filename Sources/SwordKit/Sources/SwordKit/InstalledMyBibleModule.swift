// InstalledMyBibleModule.swift -- MyBible package sidecar metadata

import Foundation

/**
 Persisted metadata for one installed MyBible package.

 Android exposes MyBible packages through `Books.installed().books` after the SQLite payload is
 imported. iOS stores manifest/install provenance outside libsword in `module.json`, but Android's
 installed identity, description, language, and category come from the actual database. This value
 therefore decodes only durable sidecar provenance; `InstalledMyBibleBookReader` owns inventory
 projection from the payload.
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

}
