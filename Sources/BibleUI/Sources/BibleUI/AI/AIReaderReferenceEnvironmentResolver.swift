// AIReaderReferenceEnvironmentResolver.swift -- Android-compatible AI reference defaults

import BibleCore
import Foundation
import SwordKit

/**
 Resolves the installed Bible and reference dictionaries described in Android's agent system prompt.

 Android derives these values from the same installed-book order and exclusion settings used by its
 tools. Keeping the projection in one pure resolver prevents the system message from advertising a
 module that the corresponding iOS tool would not select. The caller supplies the combined installed
 inventory in tool-selection order and the live index predicate.
 */
enum AIReaderReferenceEnvironmentResolver {
    /** Values appended to the Android-compatible agent system message. */
    struct Environment: Equatable {
        /// First allowed indexed Bible used when `searchBible` receives no explicit module list.
        let defaultSearchBible: AIReaderMessageComposer.SearchBible?
        /// First allowed selected-or-featured Hebrew Strong's dictionary.
        let preferredStrongsHebrew: String?
        /// First allowed selected-or-featured Greek Strong's dictionary.
        let preferredStrongsGreek: String?
        /// First allowed selected-or-featured Robinson morphology dictionary.
        let preferredGreekMorphology: String?

        /// Fail-closed environment used when live settings cannot be read consistently.
        static let empty = Environment(
            defaultSearchBible: nil,
            preferredStrongsHebrew: nil,
            preferredStrongsGreek: nil,
            preferredGreekMorphology: nil
        )
    }

    /**
     Resolves the production environment from the same stores used by AI tools and reader settings.

     - Parameters:
       - swordManager: Installed SWORD and Android custom-driver inventory.
       - sqliteLibrary: Manually discovered Android SQLite documents.
       - searchIndexService: Index state authority used by `searchBible`.
       - settingsStore: Android-compatible dictionary preference store.
       - aiSettingsStore: AI document-exclusion authority.
     - Returns: Live environment, or `.empty` when AI settings cannot be read safely.
     - Side effects: Reads installed module metadata, index metadata, and local settings.
     - Failure modes: AI settings failures fail closed so the prompt never advertises a document
       that the production access policy would deny.
     */
    @MainActor
    static func resolve(
        swordManager: SwordManager,
        sqliteLibrary: SQLiteDocumentModuleLibrary,
        searchIndexService: SearchIndexService,
        settingsStore: SettingsStore,
        aiSettingsStore: AISettingsStore
    ) -> Environment {
        guard let excludedInitials = try? aiSettingsStore.globalSettings().aiExcludedDocuments else {
            return .empty
        }
        var seen = Set<String>()
        let installedModules = (swordManager.installedModules() + sqliteLibrary.modules.map(\.info))
            .filter { seen.insert(normalizedIdentity($0.name)).inserted }
        return resolve(
            installedModules: installedModules,
            excludedInitials: excludedInitials,
            indexedModule: searchIndexService.hasIndex(for:),
            selectedStrongsHebrew: settingsStore.getStringSet(.strongsHebrewDictionary),
            selectedStrongsGreek: settingsStore.getStringSet(.strongsGreekDictionary),
            selectedGreekMorphology: settingsStore.getStringSet(.robinsonGreekMorphology)
        )
    }

    /**
     Resolves Android's prompt-visible reference defaults from live module and preference state.

     - Parameters:
       - installedModules: De-duplicated installed modules in the exact order used by AI tools.
       - excludedInitials: Module initials denied by the global AI document filter.
       - indexedModule: Predicate matching the search tool's completed-index check.
       - selectedStrongsHebrew: Persisted selected Hebrew dictionary initials in preference order.
       - selectedStrongsGreek: Persisted selected Greek dictionary initials in preference order.
       - selectedGreekMorphology: Persisted selected morphology initials in preference order.
     - Returns: Immutable values safe to append to the system message.
     - Side effects: Calls `indexedModule` only for allowed Bible modules until one matches.
     - Failure modes: Stale selected initials are skipped. Missing dictionary features use Android's
       named placeholder only when that placeholder has not itself been excluded.
     */
    static func resolve(
        installedModules: [ModuleInfo],
        excludedInitials: Set<String>,
        indexedModule: (String) -> Bool,
        selectedStrongsHebrew: [String],
        selectedStrongsGreek: [String],
        selectedGreekMorphology: [String]
    ) -> Environment {
        let excluded = Set(excludedInitials.map(normalizedIdentity))
        let allowedModules = installedModules.filter {
            !excluded.contains(normalizedIdentity($0.name))
        }
        let defaultBible = allowedModules.first {
            $0.category == .bible && indexedModule($0.name)
        }.map {
            AIReaderMessageComposer.SearchBible(
                initials: $0.name,
                language: androidLanguageName($0.language)
            )
        }

        return Environment(
            defaultSearchBible: defaultBible,
            preferredStrongsHebrew: preferredDictionary(
                selectedInitials: selectedStrongsHebrew,
                feature: .hebrewDef,
                androidPlaceholder: "StrongsHebrew",
                installedModules: installedModules,
                excludedIdentities: excluded
            ),
            preferredStrongsGreek: preferredDictionary(
                selectedInitials: selectedStrongsGreek,
                feature: .greekDef,
                androidPlaceholder: "StrongsGreek",
                installedModules: installedModules,
                excludedIdentities: excluded
            ),
            preferredGreekMorphology: preferredDictionary(
                selectedInitials: selectedGreekMorphology,
                feature: .greekParse,
                androidPlaceholder: "Robinson",
                installedModules: installedModules,
                excludedIdentities: excluded
            )
        )
    }

    /** Mirrors `SwordDocumentFacade.getDictionaries` followed by `AiDocumentFilter`. */
    private static func preferredDictionary(
        selectedInitials: [String],
        feature: ModuleFeatures,
        androidPlaceholder: String,
        installedModules: [ModuleInfo],
        excludedIdentities: Set<String>
    ) -> String? {
        if !selectedInitials.isEmpty {
            for selected in selectedInitials {
                let identity = normalizedIdentity(selected)
                guard !excludedIdentities.contains(identity) else { continue }
                if let installed = installedModules.first(where: {
                    normalizedIdentity($0.name) == identity
                }) {
                    return installed.name
                }
            }
            return nil
        }

        if let featured = installedModules.first(where: {
            $0.features.contains(feature)
                && !excludedIdentities.contains(normalizedIdentity($0.name))
        }) {
            return featured.name
        }

        return excludedIdentities.contains(normalizedIdentity(androidPlaceholder))
            ? nil
            : androidPlaceholder
    }

    /** Projects JSword's language-name field without depending on the current interface locale. */
    private static func androidLanguageName(_ language: String) -> String? {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let languageCode = Locale(identifier: trimmed).language.languageCode?.identifier ?? trimmed
        return Locale(identifier: "en").localizedString(forLanguageCode: languageCode) ?? trimmed
    }

    /** Matches Android's case-insensitive installed-book initials identity. */
    private static func normalizedIdentity(_ value: String) -> String {
        value.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
