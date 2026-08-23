import Foundation
import BibleCore
import BibleView
import SwordKit

/**
 Projects an installed book and resolved key into Android `OsisFragment` bridge fields.

 The helpers consume actual globally selected metadata instead of route-derived Strong's defaults.
 They keep key identity, category, feature flags, and aggregate content type consistent across live
 Strong's lookup, selected-word lookup, and restored Multi reconstruction.

 - Side effects: Only `fragmentKey` evaluates a deterministic Unicode regular expression.
 - Failure modes: Unsupported categories serialize as Android `OTHER`; absent definition features
   produce an empty feature object rather than inferred Hebrew/Greek metadata.
 */
enum AndroidDictionaryFragmentMetadata {
    /**
     Builds Android's DOM-safe fragment identity from a book and resolved key OSIS identifier.

     - Parameters:
       - bookInitials: Actual globally resolved book initials.
       - keyOsisID: Exact resolved key OSIS identifier, including any carriage return or decoration.
     - Returns: `initials--uniqueId`, where every non-Unicode-letter/non-ASCII-digit key character
       becomes `_`, matching Android 37's default `Pattern` character-class behavior.
     - Side effects: Compiles and evaluates one deterministic Unicode regular expression.
     - Failure modes: None; empty key identifiers produce the stable `initials--` prefix.
     */
    static func fragmentKey(bookInitials: String, keyOsisID: String) -> String {
        let uniqueID = keyOsisID.replacingOccurrences(
            of: #"[^\p{L}0-9]"#,
            with: "_",
            options: .regularExpression
        )
        return "\(bookInitials)--\(uniqueID)"
    }

    /**
     Maps actual definition features into Android's optional fragment feature object.

     - Parameters:
       - moduleFeatures: Features advertised by the resolved installed book.
       - keyName: Exact resolved key name exposed by that book.
     - Returns: Hebrew, Greek, combined Hebrew-and-Greek, or empty metadata exactly as Android's
       `OsisFragment.features` getter produces it.
     - Side effects: None.
     - Failure modes: Books without Greek/Hebrew definition features return an empty object even
       when they were reached from a Strong's or morphology route.
     */
    static func features(
        from moduleFeatures: ModuleFeatures,
        keyName: String
    ) -> OsisFeatures {
        let hasHebrew = moduleFeatures.contains(.hebrewDef)
        let hasGreek = moduleFeatures.contains(.greekDef)
        switch (hasHebrew, hasGreek) {
        case (true, true):
            return OsisFeatures(type: "hebrew-and-greek", keyName: keyName)
        case (true, false):
            return OsisFeatures(type: "hebrew", keyName: keyName)
        case (false, true):
            return OsisFeatures(type: "greek", keyName: keyName)
        case (false, false):
            return OsisFeatures()
        }
    }

    /**
     Reports whether one actual source makes Android's aggregate `Multi` use Strong's mode.

     - Parameter moduleFeatures: Features advertised by the resolved installed book.
     - Returns: `true` for Hebrew/Greek definitions or Greek morphology, matching Android's
       `isStrongsDictionary` and `isMorphDictionary` checks.
     - Side effects: None.
     - Failure modes: Requested route type never substitutes for absent source features.
     */
    static func usesStrongsContentType(_ moduleFeatures: ModuleFeatures) -> Bool {
        moduleFeatures.contains(.hebrewDef)
            || moduleFeatures.contains(.greekDef)
            || moduleFeatures.contains(.greekParse)
    }

    /**
     Maps native/SQLite metadata to JSword `BookCategory.name` bridge values.

     - Parameter category: Actual category of the globally resolved installed book.
     - Returns: Android's serialized enum name for that category.
     - Side effects: None.
     - Failure modes: Unsupported or unknown categories serialize as Android `OTHER`; SWORD
       glossaries retain their distinct JSword `GLOSSARY` identity.
     */
    static func bookCategoryName(for category: ModuleCategory) -> String {
        switch category {
        case .bible:
            return DocumentCategory.bible.rawValue
        case .commentary:
            return DocumentCategory.commentary.rawValue
        case .dictionary:
            return DocumentCategory.dictionary.rawValue
        case .generalBook:
            return DocumentCategory.generalBook.rawValue
        case .map:
            return "MAPS"
        case .dailyDevotion:
            return "DAILY_DEVOTIONS"
        case .glossary:
            return "GLOSSARY"
        case .questionable:
            return "QUESTIONABLE"
        case .essays:
            return "ESSAYS"
        case .images:
            return "IMAGES"
        case .addon:
            return "AND_BIBLE"
        case .unknown:
            return "OTHER"
        }
    }
}
