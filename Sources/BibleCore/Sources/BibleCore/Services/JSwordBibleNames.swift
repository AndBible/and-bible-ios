// JSwordBibleNames.swift -- Android-parity localized Bible book display names

import Foundation

/**
 Exposes the pinned localized `BibleNames` resources used by Android's JSword keys.

 Inputs are canonical JSword OSIS book identifiers and an interface locale. Successful lookups
 return the corresponding preferred long name without consulting a SWORD module. Resources are
 loaded once per process; unknown identifiers or unavailable resources fail closed with `nil`.
 */
public enum JSwordBibleNames {
    /// Immutable locale catalogs loaded lazily from the pinned JSword resource bundle.
    private static let localizedCatalogs = JSwordBibleNameCatalog.loadBundledCatalogs()

    /**
     Returns JSword's locale-sensitive preferred long name for one Bible book.

     - Parameters:
       - osisId: Canonical JSword `BibleBook` OSIS identifier.
       - locale: Interface locale installed through Android's `LocaleProvider` equivalent.
     - Returns: Localized long name, including non-KJVA books, or `nil` when unavailable.
     - Side effects: Loads immutable bundled catalogs on first use.
     - Failure modes: Empty/unknown identifiers and missing or malformed resources return `nil`.
     */
    public static func localizedLongName(
        osisId: String,
        locale: Locale = .current
    ) -> String? {
        let normalizedOSISID = osisId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedOSISID.isEmpty else { return nil }
        return JSwordBibleNameCatalog.catalog(for: locale, in: localizedCatalogs)?
            .longName(forOsisID: normalizedOSISID)
    }
}
