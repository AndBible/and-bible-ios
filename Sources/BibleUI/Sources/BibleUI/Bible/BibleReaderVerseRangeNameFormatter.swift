// BibleReaderVerseRangeNameFormatter.swift -- Android-parity Bible range display names

import BibleCore
import Foundation
import SwordKit

/**
 Formats reader verse ranges with the locale-sensitive book names used by Android's JSword keys.

 Android serializes `VerseRange.name` as `OsisFragment.keyName`; JSword obtains its preferred book
 name from `BibleNames`, not from a module backend.

 Inputs are target-domain verse endpoints, their owning module, and the interface locale. The
 formatter returns JSword's compact range label without changing coordinates. It reads immutable
 bundled names and only enumerates SWORD books if pinned resources are unavailable; unknown books
 remain visible by OSIS id instead of being silently dropped.
 */
enum BibleReaderVerseRangeNameFormatter {
    /**
     Builds the shortest unambiguous display name for one inclusive verse range.

     - Parameters:
       - start: First verse in the range's owning versification.
       - end: Last verse in the same owning versification.
       - module: Owning SWORD module, used only when pinned JSword resources are unavailable.
       - locale: Interface locale corresponding to Android's installed `LocaleProvider`.
     - Returns: A localized book/chapter/verse label matching JSword's range shape.
     - Side effects: May enumerate the module's book catalog for unknown JSword book identifiers.
     - Failure modes: Unknown books fall back to their OSIS id; verse coordinates are preserved.
     */
    static func name(
        start: VerseKeyReference,
        end: VerseKeyReference,
        module: SwordModule,
        locale: Locale = .current
    ) -> String {
        var moduleBooks: [BookInfo]?
        func bookName(for osisBookId: String) -> String {
            if let localizedName = JSwordBibleNames.localizedLongName(
                osisId: osisBookId,
                locale: locale
            ) {
                return localizedName
            }
            if moduleBooks == nil {
                moduleBooks = module.getBookList()
            }
            return moduleBooks?.first(where: { $0.osisId == osisBookId })?.name ?? osisBookId
        }

        let startBook = bookName(for: start.osisBookId)
        let endBook = bookName(for: end.osisBookId)
        if start.osisBookId != end.osisBookId {
            return "\(startBook) \(start.chapter):\(start.verse)-\(endBook) \(end.chapter):\(end.verse)"
        }
        if start.chapter != end.chapter {
            return "\(startBook) \(start.chapter):\(start.verse)-\(end.chapter):\(end.verse)"
        }
        if start.verse != end.verse {
            return "\(startBook) \(start.chapter):\(start.verse)-\(end.verse)"
        }
        return "\(startBook) \(start.chapter):\(start.verse)"
    }
}
