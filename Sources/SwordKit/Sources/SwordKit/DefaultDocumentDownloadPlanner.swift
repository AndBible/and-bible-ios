// DefaultDocumentDownloadPlanner.swift - Android startup default-document selection

import Foundation

/**
 Selects installable modules from Android's `default_documents_v2.json` metadata.

 Android's startup Easy Start path opens `DownloadActivity` with `download-recommended=true`,
 refreshes `default_documents_v2.json`, then requests English defaults in category order:
 Bibles, commentaries, add-ons, books, dictionaries, and maps. iOS does not yet model add-ons as
 installable SWORD rows, so this planner preserves the supported category order and intentionally
 ignores add-on tokens until an iOS add-on category exists.

 Inputs:
 - Android-shaped default metadata decoded as `ModuleDownloadConfiguration`
 - available remote modules from `ModuleRepository`
 - installed modules from `SwordManager`

 Outputs:
 - ordered remote modules that should be installed for startup defaults

 Side effects:
 - none; this type is a deterministic value mapper

 Failure modes:
 - malformed or unavailable metadata tokens are ignored
 - installed, unavailable, duplicate, or missing remote rows are skipped rather than throwing
 */
public struct DefaultDocumentDownloadPlanner: Sendable {
    /**
     Parsed default-document token scoped to one supported SWORD module category.

     The optional source name corresponds to Android's `initials::repository` token syntax. A
     `nil` source means "use the first matching module in repository/catalog order", matching
     Android `findBookByInitials(initials, null)`.
     */
    public struct Request: Sendable, Equatable {
        /// Module initials requested by default metadata.
        public let initials: String

        /// Optional Android repository/source name requested by `initials::repository`.
        public let sourceName: String?

        /// Supported SWORD category bucket that supplied the request.
        public let category: ModuleCategory

        /**
         Creates one parsed startup default request.
         - Parameters:
           - initials: Module initials to install.
           - sourceName: Optional repository/source name.
           - category: SWORD category bucket that supplied the token.
         */
        public init(initials: String, sourceName: String?, category: ModuleCategory) {
            self.initials = initials
            self.sourceName = sourceName
            self.category = category
        }
    }

    /**
     Parses supported default-document tokens for one metadata language.

     - Parameters:
       - configuration: Decoded Android default metadata.
       - language: Metadata language bucket to consume. Android Easy Start currently uses `en`.
     - Returns: Parsed requests in Android startup order for supported iOS categories.
     - Side effects: none.
     - Failure modes: Malformed or empty tokens are dropped.
     */
    public static func requests(
        from configuration: ModuleDownloadConfiguration,
        language: String = "en"
    ) -> [Request] {
        [
            (ModuleCategory.bible, configuration.bibles[language, default: []]),
            (ModuleCategory.commentary, configuration.commentaries[language, default: []]),
            (ModuleCategory.generalBook, configuration.books[language, default: []]),
            (ModuleCategory.dictionary, configuration.dictionaries[language, default: []]),
            (ModuleCategory.map, configuration.maps[language, default: []]),
        ].flatMap { category, tokens in
            tokens.compactMap { request(from: $0, category: category) }
        }
    }

    /**
     Resolves installable default modules that are not already present locally.

     - Parameters:
       - configuration: Decoded Android default metadata.
       - availableModules: Remote catalog rows in repository priority order.
       - installedModules: Local installed module snapshot used to skip existing modules.
       - language: Metadata language bucket to consume. Android Easy Start currently uses `en`.
     - Returns: Ordered remote rows to install.
     - Side effects: none.
     - Failure modes: Missing, unavailable, installed, duplicate, and malformed entries are skipped.
     */
    public static func selectedModules(
        from configuration: ModuleDownloadConfiguration,
        availableModules: [RemoteModuleInfo],
        installedModules: [ModuleInfo],
        language: String = "en"
    ) -> [RemoteModuleInfo] {
        let installedNames = Set(installedModules.map(\.name))
        var selectedNames = Set<String>()
        var selected: [RemoteModuleInfo] = []

        for request in requests(from: configuration, language: language) {
            guard !installedNames.contains(request.initials),
                  let module = firstAvailableModule(matching: request, in: availableModules),
                  module.isInstallable,
                  selectedNames.insert(module.name).inserted else {
                continue
            }
            selected.append(module)
        }

        return selected
    }

    /**
     Finds the first catalog row satisfying one parsed request.

     - Parameters:
       - request: Parsed metadata token.
       - modules: Remote catalog rows in repository priority order.
     - Returns: The first matching row, or `nil` when no row exists.
     - Side effects: none.
     - Failure modes: none.
     */
    private static func firstAvailableModule(
        matching request: Request,
        in modules: [RemoteModuleInfo]
    ) -> RemoteModuleInfo? {
        modules.first { module in
            guard module.name == request.initials,
                  module.category == request.category else {
                return false
            }
            guard let sourceName = request.sourceName else {
                return true
            }
            return module.sourceName == sourceName
        }
    }

    /**
     Parses Android's module token syntax.

     - Parameters:
       - token: Raw token such as `KJV` or `KJV::CrossWire`.
       - category: SWORD category bucket that supplied the token.
     - Returns: Parsed request, or `nil` when initials are empty.
     - Side effects: none.
     - Failure modes: Empty initials are ignored; extra `::` fields after the repository are
       ignored to match Android's first-two-component destructuring.
     */
    private static func request(from token: String, category: ModuleCategory) -> Request? {
        let parts = token.components(separatedBy: "::")
        let initials = parts.first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !initials.isEmpty else {
            return nil
        }

        let sourceName = parts.dropFirst().first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return Request(
            initials: initials,
            sourceName: sourceName?.isEmpty == false ? sourceName : nil,
            category: category
        )
    }
}
