import Foundation
import XCTest
@testable import SwordKit

/**
 Protects Android's book-name meaning independently of native SWORD prefix parsing.

 Expected values come from pinned BibleNames/BookName precedence and the retained Android locale
 oracle. Tests use bundled immutable resources and explicit locales; they do not change process
 locale, create modules, inspect cache internals, or assert work counts.
 */
final class SwordAnnotationBookResolverTests: XCTestCase {
    /**
     Exact localized names precede English exact aliases, which in turn precede fuzzy names.

     `Jud` is Judges in English but the exact short name for Jude in German. The remaining examples
     exercise a localized full name, English fallback, and Android's dotted numeric-book alias.
     A failure can silently send a commentary annotation to a different Bible book.
     */
    func testLocalizedExactNamesAndEnglishFallbackRetainAndroidBookMeaning() {
        let examples = [
            ("Jud", "en", "Judg"),
            ("Jude", "en", "Jude"),
            ("Jud", "de", "Jude"),
            ("Richter", "de", "Judg"),
            ("Judges", "de", "Judg"),
            ("1 Chron", "en", "1Chr"),
        ]
        for (token, language, expected) in examples {
            XCTAssertEqual(
                SwordAnnotationBookResolver.osisID(
                    matching: token,
                    locale: Locale(identifier: language)
                ),
                expected,
                "\(language): \(token)"
            )
        }
    }

    /**
     Concurrent references retain their own locale even while shared lookup data is replaced.

     English and German deliberately give the same token different exact meanings. Every task
     must return its requested meaning, including after other tasks publish a different locale.
     This checks output isolation without exposing cache representation or synchronization hooks.
     */
    func testConcurrentLocaleLookupsKeepDistinctBookMeanings() async {
        await withTaskGroup(of: (String, String?).self) { group in
            for index in 0..<32 {
                let language = index.isMultiple(of: 2) ? "en" : "de"
                group.addTask {
                    (
                        language,
                        SwordAnnotationBookResolver.osisID(
                            matching: "Jud",
                            locale: Locale(identifier: language)
                        )
                    )
                }
            }
            for await (language, resolved) in group {
                XCTAssertEqual(resolved, language == "en" ? "Judg" : "Jude", language)
            }
        }
    }
}
