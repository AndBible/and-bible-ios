// BibleReaderDocumentDefaultPreference.swift -- Android per-category current-book defaults

import BibleCore
import SwordKit

/** One category default selected from Android's complete installed/local book registry. */
enum BibleReaderDocumentDefaultSelection {
    /// Inclusive installed metadata plus an optional readable native/SQLite source.
    case installed(info: ModuleInfo, readableSource: BibleReaderInstalledModuleSource?)

    /// Admitted EPUB or My Documents owner, both registered as Android general books.
    case local(BibleReaderLocalGeneralBookDocument)

    /// Canonical initials persisted into the pane's category-owned document field.
    var name: String {
        switch self {
        case .installed(let info, _): return info.name
        case .local(.epub(let reader)): return reader.initials
        case .local(.myDocument(let document)): return document.initials
        }
    }

    /// Installed metadata retained for authorization assertions; local owners return nil.
    var installedInfo: ModuleInfo? {
        guard case .installed(let info, _) = self else { return nil }
        return info
    }

    /// Authorized installed content; nil also represents locked native and local owners.
    var installedReadableSource: BibleReaderInstalledModuleSource? {
        guard case .installed(_, let source) = self else { return nil }
        return source
    }
}

/**
 Resolves and stores Android's `default-<BookCategory>` current-document preferences.

 Android writes these settings only through `MainBibleActivity.setCurrentDocument`, which backs the
 reader toolbar's swap and quick-menu actions. A category whose pane-owned document disappears first
 resolves its saved global default, including an installed locked owner, then the first readable
 book in JSword's installed BookSet order.

 - Side effects: `recordToolbarSelection` writes one existing SettingsStore string row.
 - Failure modes: Missing settings, stale saved initials, wrong-category owners, and unsupported
   categories skip the saved preference. Fallback never exposes a locked content handle.
 */
struct BibleReaderDocumentDefaultPreference {
    /** Returns Android's exact persisted key for one supported installed-book category. */
    static func settingKey(for category: ModuleCategory) -> String? {
        switch category {
        case .bible: return "default-BIBLE"
        case .commentary: return "default-COMMENTARY"
        case .dictionary: return "default-DICTIONARY"
        case .generalBook: return "default-GENERAL_BOOK"
        case .map: return "default-MAPS"
        case .dailyDevotion, .glossary, .questionable, .essays, .images, .addon, .unknown:
            return nil
        }
    }

    /**
     Persists one successful Android-parity toolbar selection.

     - Parameters:
       - module: Canonical installed module accepted by the controller switch.
       - settingsStore: Existing local settings owner for the pane.
     - Side effects: Upserts one raw Android-compatible category key.
     - Failure modes: Missing stores and unsupported categories leave settings unchanged.
     */
    static func recordToolbarSelection(
        _ module: ModuleInfo,
        settingsStore: SettingsStore?
    ) {
        recordToolbarSelection(
            name: module.name,
            category: module.category,
            settingsStore: settingsStore
        )
    }

    /** Persists one exact authorized local or installed toolbar document identity. */
    static func recordToolbarSelection(
        name: String,
        category: ModuleCategory,
        settingsStore: SettingsStore?
    ) {
        guard let key = settingKey(for: category) else { return }
        settingsStore?.setString(key, value: name)
    }

    /**
     Selects a replacement only when the pane-owned installed document is absent.

     - Parameters:
       - currentName: Pane-owned category selection before restoration.
       - category: Exact installed category being restored.
       - settingsStore: Store containing Android-compatible global defaults.
       - resolver: One fresh inclusive native/SQLite registry snapshot.
     - Returns: Saved registered default, first readable BookSet entry, or nil when the current
       installed owner remains registered or no replacement exists.
     - Side effects: Reads one settings row and immutable registry metadata only.
     - Failure modes: A wrong-category current owner is retained for the restore layer to reject;
       a wrong-category saved default is ignored before readable fallback.
     */
    static func replacement(
        forMissing currentName: String?,
        category: ModuleCategory,
        settingsStore: SettingsStore?,
        resolver: BibleReaderInstalledModuleResolver
    ) -> BibleReaderDocumentDefaultSelection? {
        if let currentName,
           resolver.registeredModuleInfo(named: currentName) != nil {
            return nil
        }

        if let key = settingKey(for: category),
           let savedName = settingsStore?.getString(key),
           !savedName.isEmpty,
           let savedInfo = resolver.registeredModuleInfo(named: savedName),
           savedInfo.category == category {
            return .installed(
                info: savedInfo,
                readableSource: resolver.module(named: savedName)
            )
        }

        guard let fallback = resolver.readableModulesInBookSetOrder(
            categories: [category]
        ).first else {
            return nil
        }
        return .installed(
            info: fallback.info,
            readableSource: fallback
        )
    }

    /**
     Resolves a missing general book through Android's full installed/local BookSet.

     - Parameters:
       - currentName: Pane-owned general-book identity before restoration.
       - settingsStore: Store containing `default-GENERAL_BOOK`.
       - authorizationService: Existing combined registry owner.
       - resolver: Fresh installed snapshot shared with the surrounding restore.
       - preferredEpub: Pane-retained immutable EPUB generation, when still current.
     - Returns: Exact saved installed/local owner, then the first readable general book in complete
       BookSet order, or nil when the current owner remains present or capture fails.
     - Side effects: Reads EPUB/My Documents registration metadata only; no content entry is read.
     - Failure modes: A partial local registry is never used. Locked installed rows remain owners
       for exact lookup but are skipped by fallback.
     */
    static func generalBookReplacement(
        forMissing currentName: String?,
        settingsStore: SettingsStore?,
        authorizationService: BibleReaderDocumentAuthorizationService,
        resolver: BibleReaderInstalledModuleResolver,
        preferredEpub: EpubReader?
    ) -> BibleReaderDocumentDefaultSelection? {
        authorizationService.generalBookDefaultReplacement(
            currentName: currentName,
            savedDefaultName: settingsStore?.getString("default-GENERAL_BOOK"),
            preferredEpub: preferredEpub,
            resolver: resolver
        )
    }
}
